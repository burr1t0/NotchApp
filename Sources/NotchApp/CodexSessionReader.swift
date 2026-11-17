import Foundation

/// Read-only adapter for local Codex JSONL rollouts. It never resumes a chat,
/// starts an agent, changes hooks, or opens the account's credential files.
struct CodexSessionSnapshot {
    enum State { case working, waiting, done, idle }
    let id: String
    var title: String
    var cwd = ""
    var state: State = .idle
    var detail = "Нет новых событий"
    var updated = Date.distantPast
    var startedAt: Date?
    var contextUsed: Int?
    var contextWindow: Int?
    var model: String?
    var lastMessage: String?
    var toolCount = 0
    var hasLocalTurn = false
    var isUserSession = true
    var isSubagent = false
    var parentID: String?
    var agentNickname: String?
    var agentRole: String?
    var agentPath: String?
    var historyStartOrdinal: Int?
    var pendingCalls = Set<String>()

    var agentLabel: String {
        let role = agentRole ?? agentPath.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: "_", with: " ") }
        return [agentNickname, role].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ").nonEmpty ?? "Агент Codex"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct CodexSessionGroup {
    let root: CodexSessionSnapshot
    var agents: [CodexSessionSnapshot] = []
    var updated: Date { agents.reduce(root.updated) { max($0, $1.updated) } }
    var state: CodexSessionSnapshot.State {
        if root.state == .waiting || agents.contains(where: { $0.state == .waiting }) { return .waiting }
        if root.state == .working || agents.contains(where: { $0.state == .working }) { return .working }
        return root.state
    }
}

/// Owned by one background queue. Keeps a byte cursor per file, including an
/// unfinished line, so polling does not re-read growing transcripts in full.
final class CodexSessionReader {
    private struct Cursor {
        var fileID: UInt64?
        var offset: UInt64 = 0
        var partial = Data()
        var droppingLongLine = false
        var snapshot: CodexSessionSnapshot?
    }
    private let home: URL
    private var cursors: [String: Cursor] = [:]
    private let iso = ISO8601DateFormatter()
    private let fractional = ISO8601DateFormatter()
    private let maxLineBytes = 8 * 1024 * 1024

    init(home: URL) {
        self.home = home
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func scan(now: Date = Date()) -> [CodexSessionSnapshot] {
        let root = home.appendingPathComponent("sessions")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else {
            cursors.removeAll()
            return []
        }
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        var candidates: [(URL, Date)] = []
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let modified = values.contentModificationDate,
                  modified >= cutoff else { continue }
            candidates.append((url, modified))
        }
        candidates.sort { $0.1 > $1.1 }
        candidates = Array(candidates.prefix(100))
        let paths = Set(candidates.map { $0.0.path })
        cursors = cursors.filter { paths.contains($0.key) }
        let titles = readTitles()
        var result: [String: CodexSessionSnapshot] = [:]
        for (url, _) in candidates {
            var cursor = cursors[url.path] ?? Cursor()
            read(url, cursor: &cursor)
            cursors[url.path] = cursor
            guard var snapshot = cursor.snapshot, snapshot.isUserSession,
                  snapshot.hasLocalTurn, snapshot.updated >= cutoff else { continue }
            if let title = titles[snapshot.id], !title.isEmpty { snapshot.title = title }
            // A crashed/closed client has no final event. Don't pretend an old
            // outstanding turn is still running indefinitely.
            if snapshot.state == .working && now.timeIntervalSince(snapshot.updated) > 15 * 60 {
                snapshot.state = .idle
                snapshot.detail = "Нет новых событий"
            }
            // Resuming a chat can create another rollout with the same ID.
            // Keep the newest chat activity, not whichever file was touched last.
            if let existing = result[snapshot.id], existing.updated >= snapshot.updated { continue }
            result[snapshot.id] = snapshot
        }
        // Limit parent tasks, not individual agents, so a team cannot displace
        // its own parent or be cut into apparently unrelated chats.
        return Self.groups(Array(result.values)).prefix(20).flatMap { [$0.root] + $0.agents }
    }

    static func groups(_ snapshots: [CodexSessionSnapshot]) -> [CodexSessionGroup] {
        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { $0.updated >= $1.updated ? $0 : $1 })
        var grouped: [String: CodexSessionGroup] = [:]
        for snapshot in byID.values {
            var root = snapshot
            var visited: Set<String> = [snapshot.id]
            while root.isSubagent, let parentID = root.parentID, let parent = byID[parentID] {
                // Malformed ancestry stays separate rather than hiding cards.
                guard visited.insert(parentID).inserted else { root = snapshot; break }
                root = parent
            }
            var group = grouped[root.id] ?? CodexSessionGroup(root: root)
            if root.id != snapshot.id { group.agents.append(snapshot) }
            grouped[root.id] = group
        }
        return grouped.values.map { group in
            var group = group
            group.agents.sort {
                let left = $0.state == .waiting ? 0 : $0.state == .working ? 1 : 2
                let right = $1.state == .waiting ? 0 : $1.state == .working ? 1 : 2
                return left == right ? ($0.updated == $1.updated ? $0.id < $1.id : $0.updated > $1.updated) : left < right
            }
            return group
        }.sorted { $0.updated == $1.updated ? $0.root.id < $1.root.id : $0.updated > $1.updated }
    }

    private func readTitles() -> [String: String] {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("session_index.jsonl")) else { return [:] }
        var titles: [String: String] = [:]
        for line in data.split(separator: 10) {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = json["id"] as? String, let name = json["thread_name"] as? String else { continue }
            titles[id] = String(name.prefix(160))
        }
        return titles
    }

    private func read(_ url: URL, cursor: inout Cursor) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        let fileID = (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        if size < cursor.offset || (cursor.fileID != nil && cursor.fileID != fileID) {
            cursor = Cursor() // rotation/truncation
        }
        cursor.fileID = fileID
        if cursor.snapshot?.isUserSession == false { cursor.offset = size; return }
        try? handle.seek(toOffset: cursor.offset)
        // Bound work per pass, even when importing a very large existing chat.
        var budget = 16 * 1024 * 1024
        while budget > 0, let chunk = try? handle.read(upToCount: min(64 * 1024, budget)), !chunk.isEmpty {
            cursor.offset += UInt64(chunk.count)
            budget -= chunk.count
            for segment in chunk.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
                // Every segment except the first follows a newline.
                if segment.offset > 0 {
                    if !cursor.droppingLongLine { consume(cursor.partial, snapshot: &cursor.snapshot) }
                    cursor.partial.removeAll(keepingCapacity: true)
                    cursor.droppingLongLine = false
                }
                if !cursor.droppingLongLine {
                    if cursor.partial.count + segment.element.count <= maxLineBytes {
                        cursor.partial.append(contentsOf: segment.element)
                    } else {
                        cursor.partial.removeAll(keepingCapacity: true)
                        cursor.droppingLongLine = true
                    }
                }
            }
            if cursor.snapshot?.isUserSession == false { cursor.offset = size; break }
        }
    }

    private func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        guard let s = value as? String else { return nil }
        return fractional.date(from: s) ?? iso.date(from: s)
    }

    private func text(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        guard let parts = value as? [[String: Any]] else { return nil }
        let result = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    private func consume(_ data: Data, snapshot: inout CodexSessionSnapshot?) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = json["type"] as? String, let p = json["payload"] as? [String: Any] else { return }
        if kind == "session_meta" {
            // The first header owns this file. Forked histories can contain
            // the parent's session_meta after the child's own header.
            guard snapshot == nil else { return }
            guard let id = (p["id"] ?? p["session_id"]) as? String else { return }
            var s = CodexSessionSnapshot(id: id, title: "Чат Codex")
            s.cwd = p["cwd"] as? String ?? s.cwd
            let source = p["source"] as? String
            let threadSource = p["thread_source"] as? String
            let subagent = (p["source"] as? [String: Any])?["subagent"] as? [String: Any]
            let spawn = subagent?["thread_spawn"] as? [String: Any]
            s.isSubagent = threadSource == "subagent" || spawn != nil
            s.parentID = (p["parent_thread_id"] as? String) ?? (spawn?["parent_thread_id"] as? String)
            if s.parentID == id { s.parentID = nil }
            s.agentNickname = p["agent_nickname"] as? String ?? spawn?["agent_nickname"] as? String
            s.agentRole = p["agent_role"] as? String ?? spawn?["agent_role"] as? String
            s.agentPath = p["agent_path"] as? String ?? spawn?["agent_path"] as? String
            s.historyStartOrdinal = p["subagent_history_start_ordinal"] as? Int
            // Keep actual workers; automatic approval reviews stay hidden.
            s.isUserSession = threadSource != "guardian_review" && subagent?["other"] as? String != "guardian" && (s.isSubagent || (!(p["source"] is [String: Any])
                && (threadSource == nil || threadSource == "user")
                && (source == nil || ["cli", "vscode", "exec", "appServer"].contains(source!))))
            snapshot = s
            return
        }
        guard var s = snapshot, s.isUserSession else { return }
        if let start = s.historyStartOrdinal, let ordinal = json["ordinal"] as? Int, ordinal < start { return }
        // With no explicit boundary, wait for the worker's own turn before
        // treating inherited tool calls and usage as its current activity.
        if s.isSubagent, !s.hasLocalTurn {
            guard kind == "event_msg", p["type"] as? String == "task_started" else { return }
            if let attribution = p["turn_attribution"] as? [String: Any],
               attribution["parent_turn_id"] == nil || attribution["parent_turn_id"] is NSNull { return }
        }
        if kind == "turn_context" {
            s.model = p["model"] as? String ?? s.model
            s.cwd = p["cwd"] as? String ?? s.cwd
        } else if kind == "compacted" {
            // Old pre-compaction usage must not masquerade as current usage.
            s.contextUsed = nil
        } else if kind == "event_msg", let type = p["type"] as? String {
            let timestamp = date(json["timestamp"]) ?? s.updated
            switch type {
            case "task_started":
                if (p["turn_id"] as? String)?.hasPrefix("external-import-") == true { break }
                s.hasLocalTurn = true
                s.state = .working
                s.detail = "Думает…"
                s.updated = timestamp
                s.startedAt = date(p["started_at"]) ?? timestamp
                s.updated = max(s.updated, s.startedAt ?? timestamp)
                s.toolCount = 0
                s.pendingCalls.removeAll()
                if let w = p["model_context_window"] as? Int, w > 0 { s.contextWindow = w }
            case "user_message":
                if s.title == "Чат Codex", let prompt = text(p["message"]) {
                    s.title = String(prompt.prefix(80))
                }
            case "token_count":
                if let info = p["info"] as? [String: Any] {
                    if let w = info["model_context_window"] as? Int, w > 0 { s.contextWindow = w }
                    if let last = info["last_token_usage"] as? [String: Any],
                       let used = last["total_tokens"] as? Int, used >= 0 { s.contextUsed = used }
                }
                // total_token_usage is cumulative billing, never window usage.
            case "task_complete":
                s.state = .done
                s.detail = "Готово"
                s.updated = max(date(p["completed_at"]) ?? timestamp, timestamp)
                s.lastMessage = text(p["last_agent_message"]).map { String($0.prefix(16000)) } ?? s.lastMessage
                s.pendingCalls.removeAll()
            case "turn_aborted":
                s.state = .idle
                s.detail = "Остановлено"
                s.updated = timestamp
                s.pendingCalls.removeAll()
            case "agent_message":
                if let message = text(p["message"]) { s.lastMessage = String(message.prefix(16000)) }
                if s.state == .working { s.updated = timestamp }
            case "item_completed":
                if let item = p["item"] as? [String: Any] {
                    applyItem(item, timestamp: timestamp, session: &s)
                }
            default: break
            }
        } else if kind == "token_usage_record" {
            if let thread = p["thread_id"] as? String, thread != s.id { return }
            if let usage = p["usage"] as? [String: Any], let used = usage["total_tokens"] as? Int, used >= 0 {
                s.contextUsed = used
            }
        } else if kind == "response_item" {
            let timestamp = date(json["timestamp"]) ?? s.updated
            switch p["type"] as? String {
            case "message":
                if p["role"] as? String == "assistant", let message = text(p["content"]) {
                    s.lastMessage = String(message.prefix(16000))
                    if s.state == .working { s.updated = timestamp }
                }
            case "function_call", "custom_tool_call":
                let call = p["call_id"] as? String ?? ""
                if s.pendingCalls.insert(call).inserted { s.toolCount += 1 }
                let name = p["name"] as? String ?? "Инструмент"
                s.detail = name.contains("request_user_input") ? "Ждёт вашего ответа в Codex" : "Инструмент: \(name)"
                s.state = name.contains("request_user_input") ? .waiting : .working
                s.updated = timestamp
            case "function_call_output", "custom_tool_call_output":
                s.pendingCalls.remove(p["call_id"] as? String ?? "")
                if s.hasLocalTurn { s.state = .working; s.detail = "Работает…"; s.updated = timestamp }
            default: break
            }
        }
        snapshot = s
    }

    private func applyItem(_ item: [String: Any], timestamp: Date, session s: inout CodexSessionSnapshot) {
        switch item["type"] as? String {
        case "UserMessage":
            if s.title == "Чат Codex", let prompt = text(item["content"]) { s.title = String(prompt.prefix(80)) }
        case "AgentMessage":
            if let message = text(item["content"]) {
                s.lastMessage = String(message.prefix(16000))
                if s.state == .working { s.updated = timestamp }
            }
        case "CommandExecution", "FileChange", "McpToolCall", "WebSearch":
            s.toolCount += 1
            s.detail = "Работает…"
            if s.hasLocalTurn { s.state = .working; s.updated = timestamp }
        default: break
        }
    }
}
