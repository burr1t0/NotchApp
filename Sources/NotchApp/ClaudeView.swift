import SwiftUI
import AppKit

struct ClaudeView: View {
    @ObservedObject var monitor: ClaudeMonitor
    /// Tells the window it needs to be the key window (a text field is up).
    var setKeyboard: (Bool) -> Void = { _ in }
    @State private var hooksInstalled = ClaudeHookInstaller.isInstalled
    @State private var openedSessionID: String?
    @State private var chatsInstalled = ClaudeChatInstaller.isInstalled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !hooksInstalled {
                setupPrompt
            } else if let request = monitor.pending.first {
                PermissionCard(monitor: monitor, request: request, more: monitor.pending.count - 1)
                    .id(request.id)   // fresh question state per request
            } else if let id = openedSessionID, let session = monitor.sessions.first(where: { $0.id == id }) {
                SessionDetail(monitor: monitor, session: session) { openedSessionID = nil }
            } else if monitor.sessions.isEmpty {
                Spacer()
                Text("Нет активных сессий Claude Code")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(monitor.sessions) { session in
                            SessionCard(session: session,
                                        open: { openedSessionID = session.id },
                                        dismiss: { monitor.dismiss(session) })
                        }
                    }
                }
            }

            if hooksInstalled, openedSessionID == nil, monitor.pending.isEmpty { footer }
        }
        .onAppear { hooksInstalled = ClaudeHookInstaller.isInstalled }
        .onChange(of: needsKeyboard) { setKeyboard($0) }
        .onDisappear { setKeyboard(false) }
    }

    private var needsKeyboard: Bool {
        monitor.pending.first?.isQuestion == true || openedSessionID != nil
    }

    private var limitsText: String {
        var parts: [String] = []
        if let value = monitor.fiveHourPercent { parts.append("5ч \(Int(value.rounded()))%") }
        if let value = monitor.sevenDayPercent { parts.append("нед \(Int(value.rounded()))%") }
        return parts.joined(separator: " · ")
    }

    private var setupPrompt: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Показывает, что делают сессии Claude Code и когда нужен ответ")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
            Button("Подключить Claude Code") {
                if ClaudeHookInstaller.installWithConfirmation() {
                    hooksInstalled = ClaudeHookInstaller.isInstalled
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.16)))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                monitor.soundsEnabled.toggle()
            } label: {
                Image(systemName: monitor.soundsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .help(monitor.soundsEnabled ? "Звуки включены" : "Звуки выключены")

            Button {
                monitor.keepAwake.toggle()
            } label: {
                Image(systemName: "cup.and.saucer.fill")
                    .foregroundStyle(monitor.keepAwake ? Color.claudeOrange : .white.opacity(0.4))
            }
            .help(monitor.keepAwake ? "Мак не уснёт, пока Claude работает" : "Не давать Маку уснуть, пока Claude работает")

            if monitor.fiveHourPercent != nil || monitor.sevenDayPercent != nil {
                Text(limitsText)
                    .font(.system(size: 9, weight: .medium))
            }

            Spacer()

            if !chatsInstalled {
                Button("+ Чаты") {
                    if ClaudeChatInstaller.installWithConfirmation() { chatsInstalled = true }
                }
                .help("Показывать в шторке статус обычных чатов Claude")
            }

            Button("Отключить") {
                if ClaudeHookInstaller.uninstall() { hooksInstalled = false }
                if ClaudeChatInstaller.uninstall() { chatsInstalled = false }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.4))
    }
}

struct PermissionCard: View {
    @ObservedObject var monitor: ClaudeMonitor
    let request: ClaudePermissionRequest
    let more: Int
    var compact = false

    @State private var step = 0
    @State private var answers: [String: String] = [:]
    @State private var customAnswer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PulsingDotView().frame(width: 7, height: 7)
                Text(request.project)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if more > 0 {
                    Text("ещё \(more)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
                if !compact {
                    Button("В Claude") { openClaude() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .help("Ответить в самом Claude")
                }
            }

            if let questions = request.questions {
                // Scrolls rather than spilling up under the notch if it ever
                // doesn't fit the panel.
                ScrollView { questionBody(questions) }
                    .scrollIndicators(.hidden)
            } else {
                commandBody
            }

        }
    }

    private var commandBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            previewBox

            HStack(spacing: 8) {
                pill(request.isPlan ? "Approve" : "Allow", fill: .white, text: .black) { monitor.allow(request) }
                pill(request.isPlan ? "Reject" : "Deny", fill: Color.white.opacity(0.18), text: .white) { monitor.deny(request) }
            }
        }
    }

    @ViewBuilder private var previewBox: some View {
        switch request.preview {
        case .command(let text):
            mono(Text(text.isEmpty ? "Bash" : "Bash: \(text)"))
        case .generic(let text):
            mono(Text(text))
        case .write(let file, let lines):
            mono(Text("Write \(file)" + (lines > 0 ? " · \(lines) стр." : "")))
        case .edit(let file, let removed, let added):
            VStack(alignment: .leading, spacing: 1) {
                Text("Edit \(file)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                ForEach(Array(removed.enumerated()), id: \.offset) { _, line in
                    Text("− " + line).foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
                }
                ForEach(Array(added.enumerated()), id: \.offset) { _, line in
                    Text("+ " + line).foregroundStyle(Color(red: 0.5, green: 0.9, blue: 0.55))
                }
            }
            .font(.system(size: 9.5, design: .monospaced))
            .lineLimit(1)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
        case .plan(let text):
            ScrollView {
                Text(text)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
        }
    }

    private func mono(_ text: Text) -> some View {
        text
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(3)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
    }

    private func questionBody(_ questions: [ClaudePermissionRequest.Question]) -> some View {
        let question = questions[min(step, questions.count - 1)]
        return VStack(alignment: .leading, spacing: 4) {
            Text(question.text)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 4) {
                ForEach(question.options, id: \.self) { option in
                    Button {
                        choose(option, for: question, of: questions)
                    } label: {
                        Text(option)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }

            TextField("Свой вариант…", text: $customAnswer)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .onSubmit {
                    let text = customAnswer.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    choose(text, for: question, of: questions)
                    customAnswer = ""
                }
        }
    }

    private func choose(_ answer: String, for question: ClaudePermissionRequest.Question,
                        of questions: [ClaudePermissionRequest.Question]) {
        answers[question.text] = answer
        if step + 1 < questions.count {
            step += 1
        } else {
            monitor.answer(request, answers: answers)
        }
    }

    private func pill(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
    }

    /// Hands the prompt back to Claude itself and brings its app forward.
    private func openClaude() {
        monitor.handBack(request)
        if let session = monitor.sessions.first(where: { $0.id == request.sessionID }) {
            monitor.openChat(for: session)
        }
    }
}

/// A session row with a close button that appears on hover.
private struct SessionCard: View {
    let session: ClaudeSession
    let open: () -> Void
    let dismiss: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) { SessionRow(session: session) }
                .buttonStyle(.plain)
            if isHovering {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                // Clear of the scroll bar, which sits against the right edge.
                .padding(.top, 5)
                .padding(.trailing, 16)
                .help("Убрать из списка")
            }
        }
        .onHover { isHovering = $0 }
    }
}

private struct SessionRow: View {
    let session: ClaudeSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(session.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                planLine
                stats
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(session.state == .waiting ? 0.14 : 0.07))
        )
        // The whole card is the click target, not just the text on it.
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// "Шаг 2 из 5 · Подбираю фото" with a segmented bar.
    @ViewBuilder private var planLine: some View {
        if let progress = session.planProgress {
            HStack(spacing: 6) {
                if progress.total <= 10 {
                    HStack(spacing: 2) {
                        ForEach(0..<progress.total, id: \.self) { index in
                            Capsule()
                                .fill(index < progress.done ? Color.claudeOrange
                                      : index == progress.done ? Color.claudeOrange.opacity(0.45)
                                      : Color.white.opacity(0.14))
                                .frame(width: 9, height: 3)
                        }
                    }
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.14))
                            Capsule().fill(Color.claudeOrange)
                                .frame(width: geo.size.width * CGFloat(progress.done) / CGFloat(progress.total))
                        }
                    }
                    .frame(width: 60, height: 3)
                }
                Text(progress.done >= progress.total
                     ? "\(progress.total)/\(progress.total)"
                     : "\(progress.done + 1)/\(progress.total)" + (progress.current.map { " · \($0)" } ?? ""))
                    .lineLimit(1)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder private var stats: some View {
        let hasContext = session.contextPercent != nil
        if hasContext || session.toolCount > 0 || session.state == .working {
            HStack(spacing: 6) {
                if let percent = session.contextPercent {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule().fill(contextColor(percent))
                                .frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
                        }
                    }
                    .frame(width: 46, height: 3)
                    Text(contextLabel(percent))
                }
                if session.toolCount > 0 {
                    Text("· \(session.toolCount) \(Self.actionsWord(session.toolCount))")
                }
                if session.state == .working, let started = session.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("· " + Self.clock(context.date.timeIntervalSince(started)))
                    }
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func contextColor(_ percent: Double) -> Color {
        percent > 85 ? .red : percent > 65 ? .orange : .white.opacity(0.6)
    }

    private func contextLabel(_ percent: Double) -> String {
        guard let window = session.contextWindow else { return "\(Int(percent.rounded()))%" }
        let used = Int((Double(window) * percent / 100 / 1000).rounded())
        return "\(Int(percent.rounded()))% · \(used)k"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func actionsWord(_ n: Int) -> String {
        let tens = n % 100, ones = n % 10
        if (11...14).contains(tens) { return "действий" }
        switch ones {
        case 1: return "действие"
        case 2...4: return "действия"
        default: return "действий"
        }
    }

    private var color: Color {
        switch session.state {
        case .working: return .blue
        case .waiting: return .orange
        case .done: return .green
        case .idle: return .gray
        }
    }
}

/// Right-hand slot of the collapsed pill while Claude wants attention or has
/// just finished. The pulse runs on a Core Animation layer so it costs the
/// main thread nothing while it waits for you.
struct ClaudeStatusBadge: View {
    let indicator: ClaudeIndicator

    var body: some View {
        switch indicator {
        case .needsInput:
            PulsingDot(color: .systemOrange).frame(width: 10, height: 10)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green)
        }
    }
}

struct PulsingDotView: View {
    var body: some View { PulsingDot(color: .systemOrange) }
}

/// Round-cornered to whatever size SwiftUI gives it.
private final class DotView: NSView {
    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }
}

private struct PulsingDot: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = DotView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        view.layer?.add(pulse, forKey: "pulse")
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// One session in detail: what it said at the end of its last turn, plus a
/// shortcut to the chat it lives in.
private struct SessionDetail: View {
    @ObservedObject var monitor: ClaudeMonitor
    let session: ClaudeSession
    let back: () -> Void

    @State private var text: String?
    @State private var loaded = false
    @State private var draft = ""
    @State private var sendStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                Text(session.project)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Открыть чат") { monitor.openChat(for: session) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }
            .foregroundStyle(.white)

            ScrollView {
                Text(session.isChat ? (session.finalNote ?? session.detail) : (loaded ? (text ?? "Пока нет ответа") : "…"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))

            if !session.isChat {
            HStack(spacing: 6) {
                TextField("Написать Claude…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? .white.opacity(0.3) : .white)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            }

            if let sendStatus {
                Text(sendStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
            }
        }
        .onAppear { if !session.isChat { load() } }
        // Reload when the session finishes another turn.
        .onChange(of: session.updated) { _ in if session.state == .done { load() } }
    }

    private func send() {
        let message = draft
        guard !message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        sendStatus = "Отправляю…"
        monitor.send(message, to: session) { error in
            if let error {
                sendStatus = error
            } else {
                draft = ""
                sendStatus = nil
            }
        }
    }

    private func load() {
        monitor.lastMessage(for: session) { result in
            text = result
            loaded = true
        }
    }
}
