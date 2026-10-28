import AppKit
import IOKit.pwr_mgt

enum ClaudeState { case working, waiting, done, idle }

struct PlanItem {
    var id: String
    var title: String
    var status: String   // pending / in_progress / completed
}

struct ClaudeSession: Identifiable {
    let id: String
    var project: String
    var state: ClaudeState
    var detail: String
    var updated: Date
    /// Tool calls since the last prompt.
    var toolCount = 0
    /// 0...100, from Claude Code's status-line payload.
    var contextPercent: Double?
    var contextWindow: Int?
    var transcriptPath: String?
    /// Once the exact numbers arrive from the status line, don't second-guess
    /// them with the transcript estimate.
    var hasStatusLineData = false
    var lastTranscriptRead = Date.distantPast
    /// When the current prompt started, for the elapsed-time readout.
    var startedAt: Date?
    /// A regular chat reporting through notch_status rather than a Code session.
    var isChat = false
    var finalNote: String?
    /// The agent's task list (Code sessions, from TodoWrite / TaskCreate / TaskUpdate).
    var plan: [PlanItem] = []
    var planNextID = 1
    /// Plan progress a regular chat reports through notch_status.
    var chatStep: Int?
    var chatTotal: Int?
    var chatStepTitle: String?

    /// Steps done, total steps and what's being worked on, if a plan is known.
    var planProgress: (done: Int, total: Int, current: String?)? {
        if let total = chatTotal, total > 0 {
            return (min(max((chatStep ?? 1) - 1, 0), total), total, chatStepTitle)
        }
        guard !plan.isEmpty else { return nil }
        let done = plan.filter { $0.status == "completed" }.count
        let current = plan.first { $0.status == "in_progress" } ?? plan.first { $0.status == "pending" }
        return (done, plan.count, current?.title)
    }
}

/// What a permission prompt is actually about, shaped for the small card.
enum ClaudePreview {
    case command(String)
    case edit(file: String, removed: [String], added: [String])
    case write(file: String, lines: Int)
    case plan(String)
    case generic(String)
}

/// A permission prompt Claude Code is waiting on, answerable from the notch.
struct ClaudePermissionRequest: Identifiable {
    struct Question {
        let text: String
        let options: [String]
    }

    let id = UUID()
    let sessionID: String
    let project: String
    let toolName: String
    let detail: String
    let toolInput: [String: Any]
    /// Non-nil for AskUserQuestion: the choices to present as buttons.
    let questions: [Question]?
    let preview: ClaudePreview
    /// A question from a regular chat's `notch_confirm` tool, answered with
    /// the chosen option rather than a hook decision.
    var isChatConfirm = false
    /// For the desktop app's end-of-turn card (`wrap_up`): the text each
    /// button sends into the chat, by button label. There's no hook decision
    /// to give, so the answer is typed into the chat instead.
    var wrapUpMessages: [String: String]?
    fileprivate let channel: ClaudePermissionChannel?

    var isWrapUp: Bool { wrapUpMessages != nil }
    var isQuestion: Bool { questions != nil }
    var isPlan: Bool { if case .plan = preview { return true } else { return false } }
    /// Questions and plans need more room than the peek drop-down offers.
    var needsFullPanel: Bool { isQuestion || isPlan }
}

/// What the collapsed pill shows for Claude, if anything.
enum ClaudeIndicator { case needsInput, finished }

/// Turns hook events into per-session state, and decides what the collapsed
/// pill should flash.
final class ClaudeMonitor: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = [] {
        didSet { updateKeepAwake() }
    }
    @Published private(set) var indicator: ClaudeIndicator?
    /// Plan usage (percent of the 5-hour and weekly limits), when Claude Code
    /// reports it.
    @Published private(set) var fiveHourPercent: Double?
    @Published private(set) var sevenDayPercent: Double?
    @Published private(set) var pending: [ClaudePermissionRequest] = []
    /// Keeps the Mac from idle-sleeping while a session is working.
    @Published var keepAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "claudeKeepAwake")
            updateKeepAwake()
        }
    }
    private var awakeAssertion: IOPMAssertionID = 0
    @Published var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "claudeSounds") }
    }

    private let server = ClaudeEventServer()
    private var finishedTimer: Timer?
    private var pruneTimer: Timer?

    private static let finishedDisplayTime: TimeInterval = 4
    private static let staleAfter: TimeInterval = 30 * 60
    /// After this long unanswered, the request is handed back to Claude's own
    /// prompt (the hook script's reply stays empty).
    private static let permissionTimeout: TimeInterval = 60
    private static let chatConfirmTimeout: TimeInterval = 45

    var needsAttention: Bool { !pending.isEmpty || sessions.contains { $0.state == .waiting } }

    init() {
        soundsEnabled = UserDefaults.standard.object(forKey: "claudeSounds") as? Bool ?? true
        keepAwake = UserDefaults.standard.bool(forKey: "claudeKeepAwake")
    }

    func start() {
        server.onEvent = { [weak self] in self?.handle($0) }
        server.onPermissionRequest = { [weak self] in self?.handlePermission($0, channel: $1) }
        server.start()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.pruneStale()
        }
    }

    /// Drops a session from the list by hand (it comes back if it reports again).
    func dismiss(_ session: ClaudeSession) {
        sessions.removeAll { $0.id == session.id }
        refreshIndicator()
    }

    /// Keeps a session's task list in step with the agent's own, from the
    /// tool calls that edit it.
    private static func applyPlan(from event: ClaudeEvent, to session: inout ClaudeSession) {
        let input = event.toolInput ?? [:]
        switch event.toolName {
        case "TodoWrite":
            guard let todos = input["todos"] as? [[String: Any]] else { return }
            session.plan = todos.enumerated().map { index, todo in
                PlanItem(id: String(index + 1),
                         title: (todo["content"] as? String) ?? (todo["activeForm"] as? String) ?? "Шаг \(index + 1)",
                         status: (todo["status"] as? String) ?? "pending")
            }
        case "TaskCreate":
            let title = (input["subject"] as? String) ?? (input["title"] as? String) ?? "Задача"
            // Prefer the id the tool reports ("Task #3 created…"), else count on.
            let reported = event.toolResponse.flatMap { text -> String? in
                guard let range = text.range(of: "\\d+", options: .regularExpression) else { return nil }
                return String(text[range])
            }
            let id = reported ?? String(session.planNextID)
            session.plan.append(PlanItem(id: id, title: title, status: "pending"))
            session.planNextID = (Int(id) ?? session.planNextID) + 1
        case "TaskUpdate":
            let id = (input["taskId"] as? String) ?? (input["taskId"] as? NSNumber)?.stringValue
            guard let id, let index = session.plan.firstIndex(where: { $0.id == id }) else { return }
            if let status = input["status"] as? String {
                if status == "deleted" { session.plan.remove(at: index); return }
                session.plan[index].status = status
            }
            if let title = input["subject"] as? String { session.plan[index].title = title }
        default:
            break
        }
    }

    private func updateKeepAwake() {
        let shouldHold = keepAwake && sessions.contains { $0.state == .working || $0.state == .waiting }
        if shouldHold, awakeAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Claude Code is working" as CFString,
                &awakeAssertion)
        } else if !shouldHold, awakeAssertion != 0 {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
        }
    }

    // MARK: - Events

    private func handle(_ event: ClaudeEvent) {
        // Any later activity from a session means its prompt was answered
        // elsewhere (Claude's own UI) or abandoned — stop offering it here.
        if event.name != "Notification", event.name != "SessionStart" {
            // A wrap-up card outlives the turn that raised it (Stop follows
            // right away); only the user's next message or the end of the
            // session settles it.
            dropPending(forSession: event.sessionID, answering: nil,
                        includingWrapUps: event.name == "UserPromptSubmit" || event.name == "SessionEnd")
        }

        if event.name == "SessionEnd" {
            sessions.removeAll { $0.id == event.sessionID }
            refreshIndicator()
            return
        }

        if event.name == "StatusLine" {
            applyStatusLine(event)
            return
        }

        var session = sessions.first { $0.id == event.sessionID } ?? ClaudeSession(
            id: event.sessionID,
            project: Self.projectName(event.cwd),
            state: .idle,
            detail: "",
            updated: Date())
        if let cwd = event.cwd { session.project = Self.projectName(cwd) }
        if event.name == "ChatStatus" {
            session.isChat = true
            session.project = event.chatTitle ?? "Чат Claude"
        }
        if let path = event.transcriptPath { session.transcriptPath = path }
        session.updated = Date()
        let previous = session.state

        switch event.name {
        case "SessionStart":
            session.state = .idle
            session.detail = "Сессия начата"
        case "UserPromptSubmit":
            session.state = .working
            session.detail = "Думает…"
            session.toolCount = 0
            session.startedAt = Date()
            if !session.plan.isEmpty, session.plan.allSatisfy({ $0.status == "completed" }) { session.plan = [] }
        case "PreToolUse":
            session.state = .working
            session.toolCount += 1
            let tool = event.toolName ?? "инструмент"
            session.detail = event.toolDetail.map { "\(tool): \($0)" } ?? tool
        case "PostToolUse":
            // Also what clears a permission prompt once it's been answered.
            session.state = .working
            Self.applyPlan(from: event, to: &session)
        case "Notification":
            if Self.isIdleReminder(event) {
                session.state = .idle
                session.detail = "Ждёт новую задачу"
            } else {
                session.state = .waiting
                session.detail = event.message ?? "Нужно ваше внимание"
            }
        case "ChatStatus":
            let note = (event.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let total = event.chatTotal, total > 0 {
                session.chatTotal = total
                session.chatStep = event.chatStep ?? session.chatStep ?? 1
                session.chatStepTitle = note.isEmpty ? session.chatStepTitle : note
            }
            switch event.chatState {
            case "done":
                if let total = session.chatTotal { session.chatStep = total + 1 }   // all steps done
                session.state = .done
                session.detail = note.isEmpty ? "Готово" : note
                session.finalNote = note.isEmpty ? nil : note
            case "needs_input":
                session.state = .waiting
                session.detail = note.isEmpty ? "Нужно ваше решение" : note
            default:
                session.state = .working
                session.detail = note.isEmpty ? "Работает…" : note
                session.startedAt = session.startedAt ?? Date()
            }
        case "Stop":
            if pending.contains(where: { $0.sessionID == session.id && $0.isWrapUp }) {
                session.state = .waiting
                session.detail = "Задаёт вопрос"
            } else {
                session.state = .done
                session.detail = "Готово"
            }
        default:
            return
        }

        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.updated > $1.updated }

        estimateContext(for: session)

        if event.name == "PreToolUse", event.toolName?.hasSuffix("wrap_up") == true {
            presentWrapUp(event, project: session.project)
        }

        let becameWaiting = session.state == .waiting && previous != .waiting
        let becameDone = session.state == .done && previous != .done
        refreshIndicator()
        if becameWaiting {
            play("Ping")
        } else if becameDone {
            flashFinished()
            play("Glass")
        }
    }

    /// Fallback when Claude Code doesn't run the status line (the desktop
    /// app's Code tab doesn't): read the last token usage from the session
    /// transcript. Throttled, and done off the main thread.
    private func estimateContext(for session: ClaudeSession) {
        guard !session.hasStatusLineData, let path = session.transcriptPath,
              Date().timeIntervalSince(session.lastTranscriptRead) > 5,
              let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index].lastTranscriptRead = Date()
        let id = session.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let tokens = Self.lastContextTokens(inTranscript: path) else { return }
            DispatchQueue.main.async {
                guard let self, let i = self.sessions.firstIndex(where: { $0.id == id }),
                      !self.sessions[i].hasStatusLineData else { return }
                self.sessions[i].contextWindow = Self.assumedContextWindow
                self.sessions[i].contextPercent = Double(tokens) / Double(Self.assumedContextWindow) * 100
            }
        }
    }

    /// The transcript doesn't say which window size applies; this is the
    /// 1M-token window of the models in use.
    private static let assumedContextWindow = 1_000_000

    private static func lastContextTokens(inTranscript path: String) -> Int? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 512 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"usage\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
            func value(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            let total = value("input_tokens") + value("cache_creation_input_tokens") + value("cache_read_input_tokens")
            if total > 0 { return total }
        }
        return nil
    }

    /// The final text of the session's most recent assistant turn, read from
    /// its transcript (off the main thread; the completion runs on main).
    func lastMessage(for session: ClaudeSession, completion: @escaping (String?) -> Void) {
        guard let path = session.transcriptPath else { completion(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Self.lastAssistantText(inTranscript: path)
            DispatchQueue.main.async { completion(text) }
        }
    }

    private static func lastAssistantText(inTranscript path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 1024 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"assistant\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let combined = content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !combined.isEmpty { return combined }
        }
        return nil
    }

    /// Opens Claude's desktop app on the chat this hook session belongs to,
    /// via its `claude://code/continue?session=local_…` link. The app files
    /// each session under its own `local_` id, which maps back to the CLI
    /// session id we receive in hooks. Falls back to just opening the app.
    func openChat(for session: ClaudeSession) {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        var localID: String?
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator
            where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["cliSessionId"] as? String == session.id else { continue }
                localID = json["sessionId"] as? String
                break
            }
        }
        if let localID, let url = URL(string: "claude://code/continue?session=\(localID)") {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Writing to a chat

    /// Types `text` into the session's chat in Claude's desktop app and sends
    /// it. There's no API for this, so it opens the chat via its link and
    /// then posts keystrokes to the app (needs Accessibility), bringing the
    /// previous app back to the front afterwards. It only types if Claude
    /// really is in front, so keystrokes can't land in another app.
    func send(_ text: String, to session: ClaudeSession, completion: @escaping (String?) -> Void) {
        let message = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else { completion(nil); return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            completion("Нужен доступ «Универсальный доступ» для NotchApp: Системные настройки → Конфиденциальность и безопасность")
            return
        }

        let claudeID = "com.anthropic.claudefordesktop"
        let previous = NSWorkspace.shared.frontmostApplication
        openChat(for: session)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == claudeID }),
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeID else {
                completion("Не удалось открыть чат Claude")
                return
            }
            Self.type(message, toProcess: app.processIdentifier)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Self.press(keyCode: 36, toProcess: app.processIdentifier)   // Return
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if previous?.bundleIdentifier != claudeID { previous?.activate() }
                    completion(nil)
                }
            }
        }
    }

    private static func type(_ text: String, toProcess pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 16, units.count)])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.postToPid(pid)
            }
            index += 16
        }
    }

    private static func press(keyCode: CGKeyCode, toProcess pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)?.postToPid(pid)
        }
    }

    private func applyStatusLine(_ event: ClaudeEvent) {
        if let value = event.fiveHourPercent { fiveHourPercent = value }
        if let value = event.sevenDayPercent { sevenDayPercent = value }
        guard let index = sessions.firstIndex(where: { $0.id == event.sessionID }) else { return }
        sessions[index].hasStatusLineData = true
        if let percent = event.contextPercent { sessions[index].contextPercent = percent }
        if let window = event.contextWindow { sessions[index].contextWindow = window }
    }

    // MARK: - Permission requests

    private func handlePermission(_ event: ClaudeEvent, channel: ClaudePermissionChannel) {
        let isChatConfirm = event.name == "ChatConfirm"
        let project = isChatConfirm ? (event.chatTitle ?? "Чат Claude") : Self.projectName(event.cwd)
        let toolName = isChatConfirm ? "notch_confirm" : (event.toolName ?? "инструмент")
        var questions: [ClaudePermissionRequest.Question]?
        if isChatConfirm {
            let options = event.chatOptions.isEmpty ? ["Да", "Нет"] : Array(event.chatOptions.prefix(4))
            questions = [.init(text: event.chatQuestion ?? "Нужен ваш выбор", options: options)]
        } else if toolName == "AskUserQuestion", let parsed = Self.parseQuestions(event.toolInput) {
            questions = parsed
        }

        var request = ClaudePermissionRequest(
            sessionID: event.sessionID,
            project: project,
            toolName: toolName,
            detail: event.toolDetail ?? "",
            toolInput: event.toolInput ?? [:],
            questions: questions,
            preview: Self.makePreview(toolName: toolName, input: event.toolInput ?? [:], detail: event.toolDetail),
            channel: channel)
        request.isChatConfirm = isChatConfirm
        // A newer prompt from the same session replaces the old one.
        dropPending(forSession: event.sessionID, answering: nil)
        pending.append(request)

        var session = sessions.first { $0.id == event.sessionID } ?? ClaudeSession(
            id: event.sessionID, project: project, state: .waiting, detail: "", updated: Date())
        session.isChat = isChatConfirm
        session.state = .waiting
        session.detail = request.isQuestion ? "Задаёт вопрос"
            : request.isPlan ? "Предлагает план" : "Просит разрешение: \(toolName)"
        session.updated = Date()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.updated > $1.updated }
        refreshIndicator()
        play("Ping")

        let id = request.id
        // A gentle second nudge if it's still sitting there half way in.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.permissionTimeout / 2) { [weak self] in
            guard let self, self.pending.contains(where: { $0.id == id }) else { return }
            self.play("Tink")
        }
        // Chat questions give up a bit sooner than the chat client does.
        let timeout = isChatConfirm ? Self.chatConfirmTimeout : Self.permissionTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.expire(id)
        }
    }

    /// The desktop app's own end-of-turn card (`ccd_turn__wrap_up`) carries a
    /// question and buttons, each with the text it would send. It isn't a
    /// permission prompt, so the hook only sees it as an ordinary tool call.
    private func presentWrapUp(_ event: ClaudeEvent, project: String) {
        let input = event.toolInput ?? [:]
        guard let ask = (input["ask"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !ask.isEmpty,
              let actions = input["actions"] as? [[String: Any]] else { return }
        var messages: [String: String] = [:]
        var labels: [String] = []
        for action in actions {
            guard let label = action["label"] as? String else { continue }
            labels.append(label)
            messages[label] = (action["message"] as? String) ?? label
        }
        guard !labels.isEmpty else { return }

        var request = ClaudePermissionRequest(
            sessionID: event.sessionID,
            project: project,
            toolName: "wrap_up",
            detail: "",
            toolInput: input,
            questions: [.init(text: ask, options: Array(labels.prefix(4)))],
            preview: .generic("wrap_up"),
            channel: nil)
        request.wrapUpMessages = messages
        dropPending(forSession: event.sessionID, answering: nil)
        pending.append(request)
        play("Ping")
        refreshIndicator()

        let id = request.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60) { [weak self] in
            self?.expire(id)
        }
    }

    private static func makePreview(toolName: String, input: [String: Any], detail: String?) -> ClaudePreview {
        func lines(_ text: String?) -> [String] {
            (text ?? "").split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(2)
                .map { String($0.prefix(70)) }
        }
        func name(_ path: String?) -> String { ((path ?? "файл") as NSString).lastPathComponent }

        switch toolName {
        case "ExitPlanMode":
            return .plan((input["plan"] as? String) ?? "")
        case "Edit":
            return .edit(file: name(input["file_path"] as? String),
                         removed: lines(input["old_string"] as? String),
                         added: lines(input["new_string"] as? String))
        case "MultiEdit":
            let first = (input["edits"] as? [[String: Any]])?.first
            return .edit(file: name(input["file_path"] as? String),
                         removed: lines(first?["old_string"] as? String),
                         added: lines(first?["new_string"] as? String))
        case "Write":
            let content = (input["content"] as? String) ?? ""
            return .write(file: name(input["file_path"] as? String),
                          lines: content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count)
        case "Bash":
            return .command(detail ?? "")
        default:
            return .generic(detail.map { "\(toolName): \($0)" } ?? toolName)
        }
    }

    private static func parseQuestions(_ input: [String: Any]?) -> [ClaudePermissionRequest.Question]? {
        guard let raw = input?["questions"] as? [[String: Any]], !raw.isEmpty else { return nil }
        var result: [ClaudePermissionRequest.Question] = []
        for item in raw {
            // Multi-select can't be expressed as one tap per question.
            guard let text = item["question"] as? String,
                  (item["multiSelect"] as? Bool) != true,
                  let options = item["options"] as? [[String: Any]] else { return nil }
            let labels = options.compactMap { $0["label"] as? String }
            guard !labels.isEmpty else { return nil }
            result.append(.init(text: text, options: labels))
        }
        return result
    }

    func allow(_ request: ClaudePermissionRequest) {
        answer(request, decision: ["behavior": "allow"])
    }

    func deny(_ request: ClaudePermissionRequest) {
        answer(request, decision: ["behavior": "deny", "message": "Отклонено в NotchApp"])
    }

    /// `answers` maps each question's text to the chosen option label.
    func answer(_ request: ClaudePermissionRequest, answers: [String: String]) {
        if request.isChatConfirm {
            guard pending.contains(where: { $0.id == request.id }) else { return }
            pending.removeAll { $0.id == request.id }
            let choice = answers.values.first ?? ""
            request.channel?.reply(["choice": choice])
            // The chat carries on with the answer; nothing else will tell us.
            if let index = sessions.firstIndex(where: { $0.id == request.sessionID }) {
                sessions[index].state = .working
                sessions[index].detail = "Ответ получен: \(choice)"
                sessions[index].updated = Date()
            }
            refreshIndicator()
            return
        }
        if let messages = request.wrapUpMessages {
            guard pending.contains(where: { $0.id == request.id }) else { return }
            pending.removeAll { $0.id == request.id }
            let choice = answers.values.first ?? ""
            let text = messages[choice] ?? choice   // typed free text goes as it is
            if let index = sessions.firstIndex(where: { $0.id == request.sessionID }) {
                sessions[index].state = .working
                sessions[index].detail = "Отправляю ответ: \(choice)"
                sessions[index].updated = Date()
                send(text, to: sessions[index]) { [weak self] error in
                    guard let self, let error,
                          let index = self.sessions.firstIndex(where: { $0.id == request.sessionID }) else { return }
                    self.sessions[index].state = .waiting
                    self.sessions[index].detail = error
                }
            }
            refreshIndicator()
            return
        }
        var input = request.toolInput
        input["answers"] = answers
        answer(request, decision: ["behavior": "allow", "updatedInput": input])
    }

    private func answer(_ request: ClaudePermissionRequest, decision: [String: Any]) {
        guard pending.contains(where: { $0.id == request.id }) else { return }
        pending.removeAll { $0.id == request.id }
        request.channel?.reply([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ] as [String: Any]
        ])
        refreshIndicator()
    }

    /// Gives a request back to Claude's own prompt without deciding.
    func handBack(_ request: ClaudePermissionRequest) {
        expire(request.id)
    }

    private func expire(_ id: UUID) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        request.channel?.reply(nil)
        refreshIndicator()
    }

    private func dropPending(forSession sessionID: String, answering reply: [String: Any]?,
                             includingWrapUps: Bool = true) {
        let stale = pending.filter { $0.sessionID == sessionID && (includingWrapUps || !$0.isWrapUp) }
        guard !stale.isEmpty else { return }
        pending.removeAll { request in stale.contains { $0.id == request.id } }
        stale.forEach { $0.channel?.reply(reply) }
    }

    /// Claude's "waiting for your input" nudge after a minute of idleness
    /// isn't something to interrupt anyone for.
    private static func isIdleReminder(_ event: ClaudeEvent) -> Bool {
        if event.notificationType == "idle_prompt" { return true }
        return event.notificationType == nil
            && (event.message ?? "").localizedCaseInsensitiveContains("waiting for your input")
    }

    private static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Claude" }
        return (cwd as NSString).lastPathComponent
    }

    // MARK: - Indicator

    private func refreshIndicator() {
        if needsAttention {
            finishedTimer?.invalidate()
            indicator = .needsInput
        } else if indicator == .needsInput {
            indicator = nil
        }
    }

    private func flashFinished() {
        guard !needsAttention else { return }
        indicator = .finished
        finishedTimer?.invalidate()
        finishedTimer = Timer.scheduledTimer(withTimeInterval: Self.finishedDisplayTime, repeats: false) { [weak self] _ in
            guard let self, self.indicator == .finished else { return }
            self.indicator = nil
        }
    }

    private func play(_ name: String) {
        guard soundsEnabled else { return }
        NSSound(named: name)?.play()
    }

    private func pruneStale() {
        let now = Date()
        // Chats have no end-of-session signal, so let them lapse sooner.
        let kept = sessions.filter {
            now.timeIntervalSince($0.updated) < ($0.isChat ? Self.staleAfter / 3 : Self.staleAfter)
        }
        if kept.count != sessions.count {
            sessions = kept
            refreshIndicator()
        }
    }
}
