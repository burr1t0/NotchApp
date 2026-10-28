import AppKit

/// Demo recording, used by `scripts/make-demo.sh`: with NOTCHAPP_DEMO=<dir>
/// the app starts none of its real data sources, plays through a scripted
/// scenario on made-up data and writes the panel's own frames (on a stand-in
/// desktop) to <dir>/<scene>/NNNN.png, then quits. Nothing here runs in
/// normal use.
extension NotchWindowController {
    func startDemo(outputDirectory: URL) {
        let recorder = DemoRecorder(panel: panel, directory: outputDirectory) { [weak self] in
            // Mirrors the radii ContentView clips the pill to.
            let open = self?.viewModel.isExpanded == true || self?.viewModel.isPeeking == true
            return (open ? 16 : 8, open ? 24 : 10, self?.viewModel.glowMargin ?? 0)
        }
        var scenes: [(name: String, steps: [(Double, () -> Void)], length: Double)] = []

        // MARK: Scene 1 — music
        var elapsed = 62.0
        let tick = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            elapsed += 0.1
            self?.nowPlayingManager.setDemoElapsed(elapsed)
        }
        RunLoop.main.add(tick, forMode: .common)

        scenes.append(("music", [
            (1.6, { [weak self] in self?.expand() }),
            (6.4, { [weak self] in self?.scheduleCollapse() }),
        ], 8.0))

        // MARK: Scene 2 — Claude
        func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var json: [String: Any] = ["hook_event_name": name, "session_id": "demo-1", "cwd": "/Users/me/landing-site"]
            json.merge(extra) { $1 }
            return json
        }
        func todos(_ done: Int) -> [String: Any] {
            let titles = ["Разметка страницы", "Стили и анимации", "Форма заявки", "Проверка и деплой"]
            let items = titles.enumerated().map { index, title -> [String: Any] in
                ["content": title, "status": index < done ? "completed" : index == done ? "in_progress" : "pending"]
            }
            return ["tool_name": "TodoWrite", "tool_input": ["todos": items]]
        }
        scenes.append(("claude", [
            (0.2, { [weak self] in self?.claudeMonitor.ingest(event("UserPromptSubmit")) }),
            (0.4, { [weak self] in
                self?.claudeMonitor.ingest(["session_id": "demo-1", "cwd": "/Users/me/landing-site",
                                            "context_window": ["used_percentage": 34.0, "context_window_size": 1_000_000]])
            }),
            (0.6, { [weak self] in self?.claudeMonitor.ingest(event("PostToolUse", todos(1))) }),
            (0.9, { [weak self] in
                self?.expand(); self?.viewModel.selectedTab = .claude
                self?.claudeMonitor.ingest(event("PreToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/Users/me/landing-site/styles.css"]]))
            }),
            (1.5, { [weak self] in self?.claudeMonitor.ingest(event("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/Users/me/landing-site/index.html"]])) }),
            (2.1, { [weak self] in self?.claudeMonitor.ingest(event("PreToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/Users/me/landing-site/index.html"]])) }),
            (3.2, { [weak self] in self?.scheduleCollapse() }),
            (4.3, { [weak self] in
                self?.claudeMonitor.ingest(event("PermissionRequest", ["tool_name": "Bash",
                                                                       "tool_input": ["command": "npm install framer-motion"]]),
                                           permission: true)
            }),
            (7.0, { [weak self] in
                if let request = self?.claudeMonitor.pending.first { self?.claudeMonitor.allow(request) }
                self?.claudeMonitor.ingest(event("PostToolUse", todos(2)))
            }),
            (8.2, { [weak self] in self?.claudeMonitor.ingest(event("Stop")) }),
        ], 11.0))

        // MARK: Scene 3 — everything else
        let phrase = Array("Привет, как дела?")
        var steps3: [(Double, () -> Void)] = [
            (0.4, { [weak self] in self?.expand(); self?.viewModel.selectedTab = .clipboard }),
            (3.0, { [weak self] in self?.viewModel.selectedTab = .translate }),
        ]
        for (index, character) in phrase.enumerated() {
            steps3.append((3.6 + Double(index) * 0.07, { [weak self] in
                self?.translatorManager.ruText.append(character)
            }))
        }
        steps3.append((6.4, { [weak self] in
            if self?.translatorManager.enText.isEmpty == true { self?.translatorManager.enText = "Hi, how are you?" }
        }))
        steps3.append((7.6, { [weak self] in self?.scheduleCollapse() }))
        scenes.append(("tools", steps3, 9.0))

        // MARK: Run
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.nowPlayingManager.applyDemo(title: "Midnight Drive", artist: "Neon Harbor",
                                             artwork: DemoRecorder.artwork(), duration: 214, elapsed: elapsed)
            self.clipboardManager.applyDemo([
                "https://github.com/burr1t0/NotchApp",
                "func hoverDidChange(_ inside: Bool)",
                "Встреча в четверг в 15:00",
                "npm run build && npm run deploy",
                "#FF7A59",
            ])
            var offset = 1.2
            for scene in scenes {
                let begin = offset
                DispatchQueue.main.asyncAfter(deadline: .now() + begin) { recorder.begin(scene.name) }
                for (time, action) in scene.steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + begin + time, execute: action)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + begin + scene.length) { recorder.end() }
                offset += scene.length + 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + offset + 1.0) {
                recorder.finish { NSApp.terminate(nil) }
            }
        }
    }
}

final class DemoRecorder {
    static let canvas = NSSize(width: 470, height: 208)
    private static let fps = 20.0

    private let panel: NSPanel
    private let directory: URL
    /// Corner radii of the pill's shape and height of the glow strip below it
    /// at this moment: the snapshot comes out as a plain black rectangle, so
    /// the shape is applied afterwards.
    private let shape: () -> (top: CGFloat, bottom: CGFloat, glow: CGFloat)
    private let queue = DispatchQueue(label: "notchapp.demo-encode")
    private var sceneDirectory: URL?
    private var started = Date()
    private var nextIndex = 0
    private var timer: Timer?

    init(panel: NSPanel, directory: URL, shape: @escaping () -> (top: CGFloat, bottom: CGFloat, glow: CGFloat)) {
        self.panel = panel
        self.directory = directory
        self.shape = shape
    }

    func begin(_ scene: String) {
        let url = directory.appendingPathComponent(scene)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        sceneDirectory = url
        started = Date()
        nextIndex = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.capture() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end() {
        timer?.invalidate()
        timer = nil
        sceneDirectory = nil
    }

    /// Waits for pending PNG writes before the app quits.
    func finish(_ completion: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: completion) }
    }

    private func capture() {
        guard let directory = sceneDirectory, let view = panel.contentView else { return }
        let due = Int(Date().timeIntervalSince(started) * Self.fps)
        guard due >= nextIndex else { return }

        let snapshot = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        if let snapshot { view.cacheDisplay(in: view.bounds, to: snapshot) }
        let first = nextIndex
        nextIndex = due + 1
        let size = view.bounds.size
        let shape = shape()
        queue.async {
            guard let snapshot, let data = Self.compose(snapshot, size: size, shape: shape).representation(using: .png, properties: [:]) else { return }
            // A frame that took longer than one tick is held for the ticks it covered.
            for index in first...due {
                try? data.write(to: directory.appendingPathComponent(String(format: "%04d.png", index)))
            }
        }
    }

    /// The panel's frame hung from the top of a stand-in desktop.
    private static func compose(_ snapshot: NSBitmapImageRep, size: NSSize,
                                shape: (top: CGFloat, bottom: CGFloat, glow: CGFloat)) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let bounds = NSRect(origin: .zero, size: canvas)

        NSGradient(colors: [NSColor(red: 0.30, green: 0.16, blue: 0.58, alpha: 1),
                            NSColor(red: 0.10, green: 0.18, blue: 0.52, alpha: 1),
                            NSColor(red: 0.04, green: 0.08, blue: 0.26, alpha: 1)])!
            .draw(in: bounds, angle: -50)
        NSGradient(colors: [NSColor(red: 0.95, green: 0.45, blue: 0.35, alpha: 0.35), .clear])!
            .draw(fromCenter: NSPoint(x: 410, y: 30), radius: 0, toCenter: NSPoint(x: 410, y: 30), radius: 260, options: [])
        // menu bar
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSRect(x: 0, y: canvas.height - 32, width: canvas.width, height: 32).fill()

        let target = NSRect(x: (canvas.width - size.width) / 2, y: canvas.height - size.height,
                            width: size.width, height: size.height)
        let pillHeight = size.height - shape.glow

        // The pill, cut to its notch shape.
        NSGraphicsContext.saveGraphicsState()
        let outline = NotchShape(topCornerRadius: shape.top, bottomCornerRadius: shape.bottom)
            .path(in: CGRect(x: 0, y: 0, width: size.width, height: pillHeight)).cgPath
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: target.minX, ty: canvas.height)
        if let placed = outline.copy(using: &flip) { NSBezierPath(cgPath: placed).addClip() }
        snapshot.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()

        // The glow strip underneath: black adds nothing, the glow adds light.
        if shape.glow > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: target.minX, y: target.minY, width: size.width, height: shape.glow).clip()
            snapshot.draw(in: target, from: .zero, operation: .plusLighter, fraction: 1,
                          respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// A made-up cover.
    static func artwork() -> NSImage {
        let image = NSImage(size: NSSize(width: 300, height: 300))
        image.lockFocus()
        NSGradient(colors: [NSColor(red: 1.0, green: 0.45, blue: 0.30, alpha: 1),
                            NSColor(red: 0.75, green: 0.15, blue: 0.55, alpha: 1),
                            NSColor(red: 0.20, green: 0.10, blue: 0.45, alpha: 1)])!
            .draw(in: NSRect(x: 0, y: 0, width: 300, height: 300), angle: -60)
        NSColor(red: 1.0, green: 0.85, blue: 0.5, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: 95, y: 130, width: 110, height: 110)).fill()
        NSColor(red: 0.12, green: 0.06, blue: 0.30, alpha: 0.85).setFill()
        for i in 0..<5 {
            NSBezierPath(rect: NSRect(x: 0, y: 40 + CGFloat(i) * 18, width: 300, height: 7 + CGFloat(i) * 2)).fill()
        }
        image.unlockFocus()
        return image
    }
}
