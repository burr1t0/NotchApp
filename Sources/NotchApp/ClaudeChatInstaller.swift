import AppKit

/// Connects regular Claude chats to the notch. The desktop app can run local
/// MCP tools; this installs a tiny one (`notch_status`) that a chat can call
/// to say it started, finished or needs you. The script just forwards those
/// calls to this app over the same Unix socket the Claude Code hooks use.
enum ClaudeChatInstaller {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let configURL = home
        .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    private static let scriptURL = ClaudeEventServer.directory.appendingPathComponent("notch-mcp.py")
    private static let serverName = "notchapp"

    /// Text to paste into Claude's preferences so chats actually use the tool.
    static let instructions = """
        I use a status tool called notch_status that shows my chats in my Mac's notch. \
        For any task that takes more than a few seconds, call notch_status with state "working" \
        and a short message about what you're doing, plus a short chat title. \
        When you finish, call it with state "done" and a one-line result. \
        If you need my decision before continuing, call it with state "needs_input" and the question, \
        then ask me in the chat as usual. Don't mention these calls to me.
        """

    private static let script = #"""
        #!/usr/bin/python3
        # MCP server (stdio) exposing notch_status and notch_confirm; forwards to NotchApp's socket.
        import json, os, select, socket, sys, threading, time

        SOCK = os.path.expanduser("~/.notchapp/hook.sock")
        TOOL = {
            "name": "notch_status",
            "description": ("Report this chat's status to the user's Mac notch. ALWAYS use it: call with state "
                            "'working' at the start of any task that takes more than a couple of seconds or "
                            "needs other tools (search, files, code); call with state 'done' and a one-line "
                            "result right before your final answer; call with state 'needs_input' when you need "
                            "the user's decision. Keep message to one short line and reuse the same title for "
                            "the whole chat. If you keep a plan or task list, also pass step (the step you are on, 1-based) "
                            "and total_steps on every call so the user sees progress. Do not mention these calls to the user."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "state": {"type": "string", "enum": ["working", "done", "needs_input"]},
                    "message": {"type": "string", "description": "One short line: what is happening / the result / the question."},
                    "title": {"type": "string", "description": "Short title of this chat or task."},
                    "step": {"type": "integer", "description": "If you keep a plan or task list: the 1-based number of the step you are on now."},
                    "total_steps": {"type": "integer", "description": "If you keep a plan or task list: how many steps it has."},
                },
                "required": ["state"],
            },
            "annotations": {"readOnlyHint": True, "openWorldHint": False},
        }
        CONFIRM_TOOL = {
            "name": "notch_confirm",
            "description": ("Ask the user a question with buttons in their Mac notch and wait for the tap. "
                            "Use it whenever you need the user to choose or confirm something before continuing. "
                            "ALSO write the same question and its options in your chat message, so the user can "
                            "answer there instead; whichever answer comes first wins. If the user replies in the "
                            "chat, treat that as their answer. Returns the option they chose in the notch; if it "
                            "says there was no answer, ask in the chat. Do not mention this tool to the user."),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "question": {"type": "string", "description": "The question, one short sentence."},
                    "options": {"type": "array", "items": {"type": "string"},
                                "description": "2-4 short answer choices. Defaults to Yes/No."},
                    "title": {"type": "string", "description": "Short title of this chat or task."},
                },
                "required": ["question"],
            },
            "annotations": {"readOnlyHint": True, "openWorldHint": False},
        }

        write_lock = threading.Lock()
        cancels = {}

        def log(message):
            try:
                with open(os.path.expanduser("~/.notchapp/mcp-error.log"), "a") as f:
                    f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + message + "\n")
            except OSError:
                pass

        def post(event):
            """Fire-and-forget event; three tries. Returns True if it was sent."""
            data = json.dumps(event).encode()
            last = None
            for _ in range(3):
                try:
                    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    s.settimeout(2.0)
                    s.connect(SOCK)
                    s.sendall(data)
                    try:
                        s.shutdown(socket.SHUT_WR)  # lets the app see end-of-message
                    except OSError:
                        pass  # already sent; not worth failing over
                    s.close()
                    return True
                except OSError as error:
                    last = error
                    time.sleep(0.25)
            log("could not reach NotchApp: %r" % (last,))
            return False

        def send(args):
            title = (args.get("title") or "Chat").strip()[:60] or "Chat"
            event = {
                "hook_event_name": "ChatStatus",
                "session_id": "chat:" + title,
                "title": title,
                "state": args.get("state", "working"),
                "message": (args.get("message") or "")[:400],
            }
            for key in ("step", "total_steps"):
                value = args.get(key)
                if isinstance(value, int) and not isinstance(value, bool):
                    event[key] = value
            return post(event)

        def confirm(args, cancelled):
            title = (args.get("title") or "Chat").strip()[:60] or "Chat"
            options = [str(o)[:60] for o in (args.get("options") or [])][:4]
            event = {
                "hook_event_name": "ChatConfirm",
                "session_id": "chat:" + title,
                "title": title,
                "question": (args.get("question") or "")[:300],
                "options": options,
            }
            choice = None
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(3.0)
                s.connect(SOCK)
                s.sendall(json.dumps(event).encode())
                try:
                    s.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                buf = b""
                deadline = time.time() + 50
                while True:
                    if cancelled.is_set():
                        # The user answered in the chat instead: take the card down.
                        post({"hook_event_name": "ChatConfirmCancel", "session_id": "chat:" + title})
                        s.close()
                        return None
                    remaining = deadline - time.time()
                    if remaining <= 0:
                        break
                    ready, _, _ = select.select([s], [], [], min(0.25, remaining))
                    if ready:
                        chunk = s.recv(4096)
                        if not chunk:
                            break
                        buf += chunk
                s.close()
                choice = json.loads(buf.decode()).get("choice") if buf else None
            except (OSError, ValueError) as error:
                log("confirm failed: %r" % (error,))
            if choice:
                return 'The user chose: "%s" (answered in the notch).' % choice
            return ("The user did not answer in the notch (timed out, or NotchApp isn't running). "
                    "Ask them in the chat instead.")

        def reply(msg_id, result=None, error=None):
            out = {"jsonrpc": "2.0", "id": msg_id}
            if error is not None:
                out["error"] = error
            else:
                out["result"] = result
            with write_lock:
                sys.stdout.write(json.dumps(out) + "\n")
                sys.stdout.flush()

        def run_confirm(msg_id, arguments, cancelled):
            text = confirm(arguments, cancelled)
            cancels.pop(msg_id, None)
            if text is not None:  # None: cancelled by the client, which expects no reply
                reply(msg_id, {"content": [{"type": "text", "text": text}]})

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            method, msg_id, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
            if method == "notifications/cancelled":
                event = cancels.get(params.get("requestId"))
                if event:
                    event.set()
                continue
            if msg_id is None:
                continue  # other notifications need no reply
            if method == "initialize":
                reply(msg_id, {
                    "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "notchapp", "version": "0.2"},
                })
            elif method == "tools/list":
                reply(msg_id, {"tools": [TOOL, CONFIRM_TOOL]})
            elif method == "tools/call":
                arguments = params.get("arguments") or {}
                if params.get("name") == "notch_confirm":
                    cancelled = threading.Event()
                    cancels[msg_id] = cancelled
                    threading.Thread(target=run_confirm, args=(msg_id, arguments, cancelled), daemon=True).start()
                else:
                    ok = send(arguments)
                    text = "Shown in the notch." if ok else "NotchApp isn't running; nothing was shown."
                    reply(msg_id, {"content": [{"type": "text", "text": text}]})
            elif method == "ping":
                reply(msg_id, {})
            else:
                reply(msg_id, error={"code": -32601, "message": "Method not found"})
        """#

    static var isInstalled: Bool {
        guard let servers = loadConfig()?["mcpServers"] as? [String: Any] else { return false }
        return servers[serverName] != nil
    }

    @discardableResult
    static func installWithConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Подключить обычные чаты Claude?"
        alert.informativeText = """
            В \(configURL.path) будет добавлен локальный инструмент «\(serverName)» (скрипт \(scriptURL.path)). \
            Он умеет только одно: показывать в шторке статус чата. Текущий файл сохранится рядом как резервная копия.
            После этого перезапустите приложение Claude и вставьте инструкцию (она скопируется в буфер) в Настройки → Профиль → Предпочтения.
            """
        alert.addButton(withTitle: "Подключить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard perform(install: true) else { return false }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(instructions, forType: .string)
        let done = NSAlert()
        done.messageText = "Готово"
        done.informativeText = "Инструкция для Claude скопирована в буфер обмена. Перезапустите приложение Claude, затем вставьте её в Настройки → Профиль → Предпочтения."
        done.runModal()
        return true
    }

    @discardableResult
    static func uninstall() -> Bool { perform(install: false) }

    private static func perform(install: Bool) -> Bool {
        let exists = FileManager.default.fileExists(atPath: configURL.path)
        if !exists, !install { return false }
        if exists, (try? Data(contentsOf: configURL))?.isEmpty == false, loadConfig() == nil {
            let alert = NSAlert()
            alert.messageText = "Не удалось прочитать настройки Claude"
            alert.informativeText = "\(configURL.path) не похож на корректный JSON, поэтому я его не трогаю."
            alert.runModal()
            return false
        }

        var config = loadConfig() ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        if install {
            servers[serverName] = ["command": "/usr/bin/python3", "args": [scriptURL.path]]
        } else {
            servers.removeValue(forKey: serverName)
        }
        if servers.isEmpty { config.removeValue(forKey: "mcpServers") } else { config["mcpServers"] = servers }

        do {
            if install {
                try FileManager.default.createDirectory(
                    at: ClaudeEventServer.directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            }
            if exists {
                let stamp = Int(Date().timeIntervalSince1970)
                try FileManager.default.copyItem(
                    at: configURL,
                    to: configURL.deletingLastPathComponent()
                        .appendingPathComponent("claude_desktop_config.json.notchapp-backup-\(stamp)"))
            }
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: configURL, options: .atomic)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    private static func loadConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
