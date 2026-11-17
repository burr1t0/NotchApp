import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("notch-codex-tests-" + UUID().uuidString)
try fm.createDirectory(at: root.appendingPathComponent("sessions/2026/11"), withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let file = root.appendingPathComponent("sessions/2026/11/rollout-test.jsonl")
let now = Date()
let stamp = ISO8601DateFormatter().string(from: now)
func record(_ type: String, _ payload: [String: Any], timestamp: String? = nil, ordinal: Int? = nil) -> Data {
    var json: [String: Any] = ["timestamp": timestamp ?? stamp, "type": type, "payload": payload]
    if let ordinal { json["ordinal"] = ordinal }
    var data = try! JSONSerialization.data(withJSONObject: json)
    data.append(10)
    return data
}
func event(_ type: String, _ fields: [String: Any] = [:]) -> Data {
    record("event_msg", fields.merging(["type": type]) { _, value in value })
}
func append(_ data: Data) {
    let h = try! FileHandle(forWritingTo: file); try! h.seekToEnd(); try! h.write(contentsOf: data); try! h.close()
}
var data = record("session_meta", ["id": "user-chat", "cwd": "/tmp/project", "source": "vscode", "thread_source": "user"])
data.append(event("task_started", ["turn_id": "turn-1", "model_context_window": 475000]))
data.append(record("turn_context", ["model": "gpt-6.1-sol"]))
data.append(event("token_count", ["info": ["model_context_window": 475000, "total_token_usage": ["total_tokens": 9000000], "last_token_usage": ["total_tokens": 149000, "cached_input_tokens": 140000]]]))
try data.write(to: file)
try record("irrelevant", [:]).write(to: root.appendingPathComponent("session_index.jsonl"))
let reader = CodexSessionReader(home: root)
var result = reader.scan(now: now)
check(result.count == 1, "Discover user chat")
check(result[0].state == .working, "Running task")
check(result[0].contextUsed == 149000 && result[0].contextWindow == 475000, "Use latest usage, not cumulative or cached twice")
check(result[0].model == "gpt-6.1-sol", "Model")
check(reader.scan(now: now)[0].toolCount == 0, "Unchanged poll is idempotent")
let final = event("task_complete", ["last_agent_message": "Готово ✓"])
append(final.prefix(final.count / 2))
check(reader.scan(now: now)[0].state == .working, "Partial JSON line waits")
append(final.suffix(final.count - final.count / 2))
result = reader.scan(now: now)
check(result[0].state == .done && result[0].lastMessage == "Готово ✓", "Partial UTF-8 append completes")
append(event("token_count", ["info": NSNull()]))
check(reader.scan(now: now)[0].contextUsed == 149000, "Null usage retains last known count")
append(record("compacted", [:]))
check(reader.scan(now: now)[0].contextUsed == nil, "Compaction clears stale window usage")
append(event("token_count", ["info": ["model_context_window": 250000, "last_token_usage": ["total_tokens": 32000]]]))
check(reader.scan(now: now)[0].contextUsed == 32000 && reader.scan(now: now)[0].contextWindow == 250000, "Post-compaction/model change")
append(event("task_started", ["turn_id": "turn-2"]))
append(record("response_item", ["type": "function_call", "call_id": "q1", "name": "request_user_input"]))
check(reader.scan(now: now)[0].state == .waiting, "User question")
append(record("response_item", ["type": "function_call_output", "call_id": "q1", "output": "answer"]))
check(reader.scan(now: now)[0].state == .working, "Answered question resumes")
append(event("turn_aborted"))
check(reader.scan(now: now)[0].state == .idle, "Interrupted task")
let title = try JSONSerialization.data(withJSONObject: ["id": "user-chat", "thread_name": "Название из Codex"])
var titleData = title; titleData.append(10)
try titleData.write(to: root.appendingPathComponent("session_index.jsonl"))
check(reader.scan(now: now)[0].title == "Название из Codex", "Chat name from index")
var guardian = record("session_meta", ["id": "guardian", "source": ["subagent": ["other": "guardian"]], "thread_source": "guardian_review"])
guardian.append(event("task_started", ["turn_id": "review"]))
try guardian.write(to: root.appendingPathComponent("sessions/guardian.jsonl"))
var imported = record("session_meta", ["id": "import", "source": "vscode"])
imported.append(event("task_started", ["turn_id": "external-import-turn-1"]))
imported.append(event("task_complete"))
try imported.write(to: root.appendingPathComponent("sessions/imported.jsonl"))
check(reader.scan(now: now).count == 1, "Exclude guardian and untouched imports")
// A record larger than the read chunk must be reassembled, and parsed once.
append(record("response_item", ["type": "message", "role": "assistant", "content": [["text": String(repeating: "я", count: 70000)]]]))
check(reader.scan(now: now)[0].lastMessage?.count == 16000, "Chunk-spanning UTF-8 and bounded preview")
var reset = record("session_meta", ["id": "user-chat", "source": "cli"])
reset.append(event("task_started", ["turn_id": "reset"]))
try reset.write(to: file)
check(reader.scan(now: now)[0].contextUsed == nil, "Truncated file resets cursor")
check(reader.scan(now: now.addingTimeInterval(1000))[0].state == .idle, "Stale work becomes unknown/idle")
var replacement = record("session_meta", ["id": "replacement", "source": "cli"])
replacement.append(event("task_started", ["turn_id": "new-file"]))
replacement.append(event("task_complete", ["last_agent_message": "Replaced " + String(repeating: "x", count: 2000)]))
try replacement.write(to: file, options: .atomic)
check(reader.scan(now: now)[0].id == "replacement", "Atomic replacement resets cursor even for a larger file")
// A resumed chat can have several rollout files sharing the same session ID.
let duplicateFile = root.appendingPathComponent("sessions/resumed.jsonl")
let olderStamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
var duplicate = record("session_meta", ["id": "replacement", "source": "vscode", "thread_source": "user"])
duplicate.append(record("event_msg", ["type": "task_started", "turn_id": "older"], timestamp: olderStamp))
try duplicate.write(to: duplicateFile)
try fm.setAttributes([.modificationDate: now.addingTimeInterval(10)], ofItemAtPath: duplicateFile.path)
result = reader.scan(now: now)
check(result.count == 1 && result[0].state == .done, "Duplicate IDs keep newest activity even when older rollout has newer mtime")
check(reader.scan(now: now).count == 1, "Repeated polls keep session IDs unique")
let duplicateHandle = try FileHandle(forWritingTo: duplicateFile)
try duplicateHandle.seekToEnd()
let newerStamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(5))
try duplicateHandle.write(contentsOf: record("event_msg", ["type": "turn_aborted"], timestamp: newerStamp))
try duplicateHandle.close()
result = reader.scan(now: now)
check(result.count == 1 && result[0].state == .idle, "New activity in another rollout replaces the previous snapshot")
try fm.removeItem(at: duplicateFile)
check(reader.scan(now: now)[0].state == .done, "Removing a duplicate keeps the remaining rollout")
try fm.removeItem(at: file)
check(reader.scan(now: now).isEmpty, "Archived/deleted rollout disappears")
// Real v2 workers have their own header followed by inherited parent headers
// and history. Only records at/after historyStartOrdinal belong to the worker.
func fixture(_ name: String, _ records: [Data]) throws -> URL {
    let url = root.appendingPathComponent("sessions/" + name + ".jsonl")
    try records.reduce(into: Data()) { $0.append($1) }.write(to: url)
    return url
}
let parent = try fixture("parent", [
    record("session_meta", ["id": "parent", "source": "vscode", "cwd": "/tmp/shared-project"]),
    event("task_started"), event("task_complete")])
let other = try fixture("other", [
    record("session_meta", ["id": "other", "source": "vscode", "cwd": "/tmp/shared-project"]),
    event("task_started")])
let worker = try fixture("worker", [
    record("session_meta", ["id": "worker", "session_id": "parent", "thread_source": "subagent",
                            "parent_thread_id": "parent", "subagent_history_start_ordinal": 20,
                            "agent_nickname": "Curie", "agent_path": "/root/check_tests",
                            "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]]], ordinal: 0),
    record("session_meta", ["id": "parent", "source": "vscode", "cwd": "/tmp/wrong-project"], ordinal: 1),
    record("event_msg", ["type": "task_started", "turn_id": "inherited"], ordinal: 2),
    record("event_msg", ["type": "token_count", "info": ["last_token_usage": ["total_tokens": 999999]]], ordinal: 3),
    record("event_msg", ["type": "task_complete", "last_agent_message": "Parent reply"], ordinal: 19),
    record("event_msg", ["type": "task_started", "model_context_window": 475000,
                        "turn_attribution": ["parent_turn_id": "parent-turn"]], ordinal: 21),
    record("token_usage_record", ["thread_id": "worker", "usage": ["total_tokens": 1234]], ordinal: 22)])
result = reader.scan(now: now)
let child = result.first { $0.id == "worker" }!
check(child.isSubagent && child.parentID == "parent", "Worker retains its own identity and explicit parent")
check(child.state == .working && child.contextUsed == 1234 && child.lastMessage == nil, "Inherited parent state and context never become worker data")
check(child.agentLabel == "Curie · check tests", "Worker name and task path are readable without guessing")
var groups = CodexSessionReader.groups(result)
check(groups.count == 2 && groups.first { $0.root.id == "parent" }?.agents.count == 1, "Same project does not merge independent chats")
check(groups.first { $0.root.id == "parent" }?.state == .working, "Completed parent stays active while worker runs")
let grandchild = try fixture("grandchild", [
    record("session_meta", ["id": "grandchild", "thread_source": "subagent", "parent_thread_id": "worker", "agent_role": "Review"]),
    event("task_started", ["turn_attribution": ["parent_turn_id": "worker-turn"]]),
    record("response_item", ["type": "function_call", "call_id": "question", "name": "request_user_input"])])
groups = CodexSessionReader.groups(reader.scan(now: now))
let team = groups.first { $0.root.id == "parent" }!
check(team.agents.count == 2 && team.state == .waiting && team.agents[0].id == "grandchild", "Nested worker belongs to root and waiting agents appear first")
let orphan = try fixture("orphan", [
    record("session_meta", ["id": "orphan", "thread_source": "subagent", "parent_thread_id": "missing"]),
    event("task_started")])
groups = CodexSessionReader.groups(reader.scan(now: now))
check(groups.contains { $0.root.id == "orphan" && $0.root.isSubagent }, "Missing parent leaves a standalone labelled worker")
var cycleA = CodexSessionSnapshot(id: "cycle-a", title: "A")
cycleA.isSubagent = true; cycleA.parentID = "cycle-b"
var cycleB = CodexSessionSnapshot(id: "cycle-b", title: "B")
cycleB.isSubagent = true; cycleB.parentID = "cycle-a"
check(CodexSessionReader.groups([cycleA, cycleB]).count == 2, "Cycles never loop or hide workers")
let handle = try FileHandle(forWritingTo: worker)
try handle.seekToEnd()
try handle.write(contentsOf: event("task_complete"))
try handle.close()
try fm.removeItem(at: grandchild)
groups = CodexSessionReader.groups(reader.scan(now: now))
check(groups.first { $0.root.id == "parent" }?.state == .done, "Team finishes only after parent and workers finish")
print("PASS: reader regressions, duplicate IDs, worker identity, inherited history, context, parent grouping, nested agents, waiting state, orphan handling, cycles and team completion")
if CommandLine.arguments.contains("--live") {
    let live = CodexSessionReader(home: fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    let chats = live.scan()
    check(!chats.isEmpty, "Live local chats should be present")
    check(Set(chats.map { $0.id }).count == chats.count, "Live local chat IDs must be unique")
    for chat in chats {
        print("LIVE: \(chat.isSubagent ? "AGENT " + chat.agentLabel : chat.title) | \(chat.state) | parent=\(chat.parentID ?? "none") | \(chat.contextUsed.map(String.init) ?? "unknown")/\(chat.contextWindow.map(String.init) ?? "unknown")")
    }
}
