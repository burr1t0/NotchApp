import AppKit

/// Installs / removes the hooks in `~/.claude/settings.json`. Nothing is
/// written without the user confirming, and the previous file is always
/// backed up next to it first.
enum ClaudeHookInstaller {
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit",
                         "PreToolUse", "PostToolUse", "Notification", "Stop", "PermissionRequest"]

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let settingsURL = home.appendingPathComponent(".claude/settings.json")
    private static let scriptURL = ClaudeEventServer.directory.appendingPathComponent("notch-hook.sh")
    private static let statusScriptURL = ClaudeEventServer.directory.appendingPathComponent("notch-statusline.sh")
    private static let permissionScriptURL = ClaudeEventServer.directory.appendingPathComponent("notch-permission-hook.sh")
    private static let marker = ".notchapp/notch-"

    private static let script = """
        #!/bin/sh
        # Forwards Claude Code hook events to NotchApp. Never blocks or fails Claude.
        SOCK="$HOME/.notchapp/hook.sock"
        [ -S "$SOCK" ] || exit 0
        /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1
        exit 0

        """

    /// Same as `script`, but waits (up to a bit over the app's own 60 s
    /// timeout) for the app to answer, and passes its reply back to Claude.
    private static let permissionScript = """
        #!/bin/sh
        # Asks NotchApp to decide a Claude Code permission prompt. If the app isn't
        # running, is slow, or declines, prints nothing and Claude asks as usual.
        SOCK="$HOME/.notchapp/hook.sock"
        [ -S "$SOCK" ] || exit 0
        /usr/bin/nc -U -w 70 "$SOCK" 2>/dev/null
        exit 0

        """

    /// Claude Code runs this to render its status line and feeds it context
    /// size and plan-limit numbers; we forward them and print nothing.
    private static let statusScript = """
        #!/bin/sh
        # Forwards Claude Code's status-line data (context size, plan limits) to NotchApp.
        SOCK="$HOME/.notchapp/hook.sock"
        [ -S "$SOCK" ] && /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1
        exit 0

        """

    static var isInstalled: Bool {
        let settings = loadSettings()
        guard let hooks = settings?["hooks"] as? [String: Any] else { return false }
        let hooksInstalled = events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains(where: containsOurHook)
        }
        // A status line of someone else's is left alone and counts as done.
        let statusLineHandled = (settings?["statusLine"] as? [String: Any])?["command"] != nil
        return hooksInstalled && statusLineHandled
    }

    /// Asks first, then installs. Returns whether anything was changed.
    @discardableResult
    static func installWithConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Подключить Claude Code?"
        alert.informativeText = """
            В \(settingsURL.path) будут добавлены хуки для событий: \(events.joined(separator: ", ")).
            Хуки запускают маленькие скрипты в \(ClaudeEventServer.directory.path), которые передают события этому приложению. Хук PermissionRequest ждёт вашего ответа в шторке (до минуты); если приложение не запущено или вы не ответили, Claude Code спрашивает как обычно.
            Если у вас ещё нет своей строки статуса, она будет занята скриптом, который отдаёт приложению размер контекста и лимиты тарифа (на экране ничего не показывает); если есть, она не тронута.
            Перед записью текущий файл настроек будет сохранён рядом с суффиксом .notchapp-backup.
            """
        alert.addButton(withTitle: "Подключить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return perform(install: true)
    }

    @discardableResult
    static func uninstall() -> Bool { perform(install: false) }

    // MARK: - Implementation

    private static func perform(install: Bool) -> Bool {
        let exists = FileManager.default.fileExists(atPath: settingsURL.path)
        if !exists, !install { return false }
        // Never overwrite a settings file we couldn't parse.
        if exists, (try? Data(contentsOf: settingsURL))?.isEmpty == false, loadSettings() == nil {
            let alert = NSAlert()
            alert.messageText = "Не удалось прочитать настройки Claude Code"
            alert.informativeText = "\(settingsURL.path) не похож на корректный JSON, поэтому я его не трогаю."
            alert.runModal()
            return false
        }
        var settings = loadSettings() ?? [:]

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups.removeAll(where: containsOurHook)
            if install {
                let isPermission = event == "PermissionRequest"
                let command = "'\((isPermission ? permissionScriptURL : scriptURL).path)'"
                var group: [String: Any] = ["hooks": [
                    ["type": "command", "command": command, "timeout": isPermission ? 75 : 5]
                ]]
                if ["PreToolUse", "PostToolUse", "PermissionRequest"].contains(event) { group["matcher"] = "*" }
                groups.append(group)
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }

        // The status line is a single slot: only take it if it's free (or
        // already ours), and only give it back if it's ours.
        let existingStatus = (settings["statusLine"] as? [String: Any])?["command"] as? String
        if install, existingStatus == nil || existingStatus?.contains(marker) == true {
            settings["statusLine"] = ["type": "command", "command": "'\(statusScriptURL.path)'"]
        } else if !install, existingStatus?.contains(marker) == true {
            settings.removeValue(forKey: "statusLine")
        }

        do {
            if install {
                try FileManager.default.createDirectory(
                    at: ClaudeEventServer.directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                for (url, text) in [(scriptURL, script), (permissionScriptURL, permissionScript),
                                    (statusScriptURL, statusScript)] {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
            }
            try backUpSettings()
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return false
        }
    }

    private static func containsOurHook(_ group: [String: Any]) -> Bool {
        ((group["hooks"] as? [[String: Any]]) ?? []).contains {
            ($0["command"] as? String)?.contains(marker) == true
        }
    }

    private static func loadSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func backUpSettings() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.notchapp-backup-\(stamp)")
        try FileManager.default.copyItem(at: settingsURL, to: backup)
    }
}
