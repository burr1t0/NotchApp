import Foundation

/// One Claude Code hook invocation, as forwarded by `notch-hook.sh`.
struct ClaudeEvent {
    let name: String
    let sessionID: String
    let cwd: String?
    let toolName: String?
    let toolDetail: String?
    let message: String?
    let notificationType: String?
    let toolInput: [String: Any]?
    let transcriptPath: String?
    /// Only for `ChatStatus` events (the `notch_status` tool in regular chats).
    let chatState: String?
    let chatTitle: String?
    /// Only for `ChatConfirm` events (the `notch_confirm` tool).
    let chatQuestion: String?
    /// 1-based current step / total steps, when a chat reports plan progress.
    let chatStep: Int?
    let chatTotal: Int?
    /// `tool_response` of a tool hook, flattened to text.
    let toolResponse: String?
    let chatOptions: [String]
    /// Only for `StatusLine` payloads (see `notch-statusline.sh`).
    let contextPercent: Double?
    let contextWindow: Int?
    let fiveHourPercent: Double?
    let sevenDayPercent: Double?

    init?(json: [String: Any]) {
        guard let sessionID = json["session_id"] as? String else { return nil }
        // The status-line command gets a different payload from hooks: no
        // event name, but a context_window block and (for subscribers)
        // rate_limits.
        let isStatusLine = json["hook_event_name"] == nil
            && (json["context_window"] != nil || json["rate_limits"] != nil)
        guard let name = isStatusLine ? "StatusLine" : json["hook_event_name"] as? String else { return nil }
        self.name = name
        self.sessionID = sessionID
        cwd = json["cwd"] as? String
        toolName = json["tool_name"] as? String
        message = json["message"] as? String
        notificationType = json["notification_type"] as? String
        transcriptPath = json["transcript_path"] as? String
        chatState = json["state"] as? String
        chatTitle = json["title"] as? String
        chatQuestion = json["question"] as? String
        chatStep = (json["step"] as? NSNumber)?.intValue
        chatTotal = (json["total_steps"] as? NSNumber)?.intValue
        if let text = json["tool_response"] as? String {
            toolResponse = text
        } else if let object = json["tool_response"],
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) {
            toolResponse = String(data: data, encoding: .utf8)
        } else {
            toolResponse = nil
        }
        chatOptions = (json["options"] as? [Any])?.compactMap { $0 as? String } ?? []

        let context = json["context_window"] as? [String: Any]
        let limits = json["rate_limits"] as? [String: Any]
        func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
        contextPercent = number(context?["used_percentage"])
        contextWindow = number(context?["context_window_size"]).map { Int($0) }
        fiveHourPercent = number((limits?["five_hour"] as? [String: Any])?["used_percentage"])
        sevenDayPercent = number((limits?["seven_day"] as? [String: Any])?["used_percentage"])

        let input = json["tool_input"] as? [String: Any]
        toolInput = input
        if let command = input?["command"] as? String {
            toolDetail = command.split(separator: "\n").first.map(String.init)
        } else if let path = (input?["file_path"] ?? input?["path"]) as? String {
            toolDetail = (path as NSString).lastPathComponent
        } else {
            toolDetail = nil
        }
    }
}

/// An open connection from a `PermissionRequest` hook, kept alive so the
/// decision can be written back to the waiting hook script. Answering is
/// one-shot. (Peer death can't be detected from here: `nc` half-closes its
/// side right after sending, so the socket always reads as EOF. The owner
/// drops stale requests when Claude moves on instead.)
final class ClaudePermissionChannel {
    private let fd: Int32
    private let lock = NSLock()
    private var finished = false

    fileprivate init(fd: Int32) {
        self.fd = fd
        // Writing to a peer that already hung up must fail quietly, not
        // raise SIGPIPE and take the whole app down.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Sends the decision (or nothing, which makes Claude fall back to its
    /// normal prompt) and closes the connection.
    func reply(_ json: [String: Any]?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        if let json, let data = try? JSONSerialization.data(withJSONObject: json) {
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        }
        close(fd)
    }
}

/// Listens on a Unix socket in `~/.notchapp` for the small hook script that
/// Claude Code runs on its lifecycle events. The socket directory is 0700 and
/// the socket 0600, so only this user can post events. Events are purely
/// informational — the hook never waits for a reply, so Claude Code can't be
/// blocked or altered by this app.
final class ClaudeEventServer {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".notchapp", isDirectory: true)
    static var socketPath: String { directory.appendingPathComponent("hook.sock").path }

    var onEvent: ((ClaudeEvent) -> Void)?
    var onPermissionRequest: ((ClaudeEvent, ClaudePermissionChannel) -> Void)?

    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "notchapp.claude.accept")
    private let clientQueue = DispatchQueue(label: "notchapp.claude.client", attributes: .concurrent)

    func start() {
        guard source == nil else { return }
        let path = Self.socketPath
        try? FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); return }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                _ = path.withCString { strncpy(chars, $0, capacity - 1) }
            }
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                self?.clientQueue.async { self?.read(client) }
            }
        }
        source.setCancelHandler { close(fd); unlink(path) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func read(_ client: Int32) {
        var keepOpen = false
        defer { if !keepOpen { close(client) } }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < 4 * 1024 * 1024 {
            let count = Foundation.read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = ClaudeEvent(json: json) else { return }
        if event.name == "StatusLine" {
            // Handy when a Claude Code update changes the payload layout.
            try? data.write(to: Self.directory.appendingPathComponent("last-statusline.json"))
        }
        if event.name == "PermissionRequest" || event.name == "ChatConfirm" {
            // Wait indefinitely for the reply from here on; the owner decides
            // when to give up.
            var none = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
            keepOpen = true
            DispatchQueue.main.async { [weak self] in
                let channel = ClaudePermissionChannel(fd: client)
                self?.onPermissionRequest?(event, channel)
            }
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
