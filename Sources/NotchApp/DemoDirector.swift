import AppKit

/// Demo recording, used by `scripts/make-demo.sh`: with NOTCHAPP_DEMO=<dir>
/// the app starts none of its real data sources, plays through a scripted
/// tour on made-up data and writes the panel's own frames (hung from a
/// stand-in desktop) to <dir>/NNNNN.png, then quits. Nothing here runs in
/// normal use.
///
/// The tour runs on its own clock rather than real time: each frame sets the
/// clock, lets the UI settle, snapshots it, and only then moves on. Capturing
/// in real time sampled animations at uneven moments and looked jerky.
final class DemoClock {
    /// Non-nil only while a demo is being recorded.
    static var shared: DemoClock?
    /// Time fed to the made-up equalizer levels.
    static var levelTime: Double = 0

    private let panel: NSPanel
    private(set) var time: Double = 0
    private var move: (from: NSRect, to: NSRect, start: Double)?
    private var afterMove: [() -> Void] = []
    private let duration = 0.5

    init(panel: NSPanel) { self.panel = panel }

    /// Starts the panel's resize, which the app itself would animate.
    func animate(to frame: NSRect) {
        move = (panel.frame, frame, time)
    }

    /// Runs `work` once any resize in flight has finished (at once if none is).
    func whenSettled(_ work: @escaping () -> Void) {
        if move == nil { work() } else { afterMove.append(work) }
    }

    /// Changes where a resize in flight is heading, or jumps if none is.
    func retarget(_ frame: NSRect) {
        if let move {
            self.move = (move.from, frame, move.start)
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func advance(to newTime: Double) {
        time = newTime
        DemoClock.levelTime = newTime
        guard let move else { return }
        let progress = min(max((time - move.start) / duration, 0), 1)
        let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(eased) }
        panel.setFrame(NSRect(x: mix(move.from.minX, move.to.minX), y: mix(move.from.minY, move.to.minY),
                              width: mix(move.from.width, move.to.width), height: mix(move.from.height, move.to.height)),
                       display: true)
        if progress >= 1 {
            self.move = nil
            let work = afterMove
            afterMove = []
            work.forEach { $0() }
        }
    }

    /// Lets a resize in flight finish at once.
    func settle() { advance(to: time + duration + 1) }
}

extension NotchWindowController {
    func startDemo(outputDirectory: URL) {
        let clock = DemoClock(panel: panel)
        DemoClock.shared = clock
        EqualizerLayerView.tickInterval = 0.01
        let recorder = DemoRecorder(panel: panel, directory: outputDirectory) { [weak self] in
            // Mirrors the radii ContentView clips the pill to.
            let open = self?.viewModel.isExpanded == true || self?.viewModel.isPeeking == true
            return (open ? 16 : 8, open ? 24 : 10, self?.viewModel.glowMargin ?? 0)
        }

        // MARK: Made-up content
        let tracks: [(title: String, artist: String, artwork: NSImage)] = [
            ("Midnight Drive", "Neon Harbor", DemoRecorder.artwork(hue: 0)),
            ("Golden Hour", "Paper Kites", DemoRecorder.artwork(hue: 1)),
        ]
        var trackIndex = 0
        var trackElapsed = 62.0
        var playing = true
        func showTrack() {
            let track = tracks[trackIndex]
            nowPlayingManager.applyDemo(title: track.title, artist: track.artist, artwork: track.artwork,
                                        duration: 214, elapsed: trackElapsed)
        }
        showTrack()
        clipboardManager.applyDemo([
            "https://github.com/burr1t0/NotchApp",
            "func hoverDidChange(_ inside: Bool)",
            "Встреча в четверг в 15:00",
            "npm run build && npm run deploy",
            "#FF7A59",
        ])
        let shelfDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("notchapp-demo-files")
        try? FileManager.default.createDirectory(at: shelfDirectory, withIntermediateDirectories: true)
        let shelfFiles: [ShelfFile] = ["Отчёт.pdf", "Диплом.docx", "Бюджет.xlsx", "Макет.fig"].map { name in
            let url = shelfDirectory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return ShelfFile(url: url, added: Date())
        }
        let shots: [ScreenshotItem] = (0..<3).map { index in
            ScreenshotItem(id: "demo-\(index)", origin: .clipboardImage(NSImage()),
                           modified: Date(), thumbnail: DemoRecorder.artwork(hue: index + 2))
        }
        screenshotWatcher.applyDemo(items: shots, files: shelfFiles)

        // MARK: Claude events
        func event(_ session: String, _ project: String, _ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var json: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/Users/me/\(project)"]
            json.merge(extra) { $1 }
            return json
        }
        func todos(_ titles: [String], done: Int) -> [String: Any] {
            let items = titles.enumerated().map { index, title -> [String: Any] in
                ["content": title, "status": index < done ? "completed" : index == done ? "in_progress" : "pending"]
            }
            return ["tool_name": "TodoWrite", "tool_input": ["todos": items]]
        }
        func tool(_ name: String, _ file: String) -> [String: Any] {
            ["tool_name": name, "tool_input": ["file_path": "/Users/me/landing-site/\(file)"]]
        }
        func statusLine(_ session: String, _ project: String, _ percent: Double) -> [String: Any] {
            ["session_id": session, "cwd": "/Users/me/\(project)",
             "context_window": ["used_percentage": percent, "context_window_size": 1_000_000]]
        }
        let landing = ["Разметка страницы", "Стили и анимации", "Форма заявки", "Проверка и деплой"]
        let api = ["Модели данных", "Эндпоинты", "Авторизация", "Тесты", "Документация"]
        let monitor = claudeMonitor
        let ask = "Какой стиль оформления выбрать?"

        // MARK: The tour (times in seconds on the demo clock)
        var steps: [(time: Double, action: () -> Void)] = []
        func at(_ time: Double, _ action: @escaping () -> Void) { steps.append((time, action)) }

        at(1.6) { [weak self] in self?.expand() }
        at(4.0) { [weak self] in playing = false; self?.nowPlayingManager.setDemoPlaying(false) }
        at(5.0) { [weak self] in playing = true; self?.nowPlayingManager.setDemoPlaying(true) }
        at(5.9) { trackIndex = 1; trackElapsed = 0; showTrack() }

        at(7.4) { [weak self] in
            self?.viewModel.selectedTab = .claude
            monitor.ingest(event("demo-1", "landing-site", "UserPromptSubmit"))
            monitor.ingest(statusLine("demo-1", "landing-site", 34))
            monitor.ingest(event("demo-1", "landing-site", "PostToolUse", todos(landing, done: 1)))
            monitor.ingest(event("demo-1", "landing-site", "PreToolUse", tool("Edit", "styles.css")))
        }
        at(7.9) {
            monitor.ingest(event("demo-2", "api-server", "UserPromptSubmit"))
            monitor.ingest(statusLine("demo-2", "api-server", 61))
            monitor.ingest(event("demo-2", "api-server", "PostToolUse", todos(api, done: 2)))
            monitor.ingest(event("demo-2", "api-server", "PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "pytest -q"]]))
        }
        at(8.4) {
            monitor.ingest(["hook_event_name": "ChatStatus", "session_id": "chat-1", "title": "Презентация о Риме",
                            "state": "working", "message": "Подбираю фото", "step": 2, "total_steps": 5])
        }
        for (index, file) in ["index.html", "script.js", "styles.css", "form.html"].enumerated() {
            at(9.2 + Double(index) * 0.8) {
                monitor.ingest(event("demo-1", "landing-site", "PreToolUse", tool(index % 2 == 0 ? "Edit" : "Read", file)))
            }
        }
        at(10.8) { monitor.ingest(event("demo-1", "landing-site", "PostToolUse", todos(landing, done: 2))) }
        at(11.4) {
            monitor.ingest(["hook_event_name": "ChatStatus", "session_id": "chat-1", "title": "Презентация о Риме",
                            "state": "working", "message": "Пишу текст слайдов", "step": 3, "total_steps": 5])
        }

        at(12.6) { [weak self] in self?.scheduleCollapse() }
        at(14.0) {
            monitor.ingest(event("demo-1", "landing-site", "PermissionRequest",
                                 ["tool_name": "Bash", "tool_input": ["command": "npm install framer-motion"]]),
                           permission: true)
        }
        at(17.2) {
            if let request = monitor.pending.first { monitor.allow(request) }
            monitor.ingest(event("demo-1", "landing-site", "PostToolUse", todos(landing, done: 2)))
        }
        at(19.0) {
            let options = ["Минимализм", "Тёмная тема", "Градиенты"].map { ["label": $0, "description": ""] }
            monitor.ingest(event("demo-1", "landing-site", "PermissionRequest", [
                "tool_name": "AskUserQuestion",
                "tool_input": ["questions": [["question": ask, "header": "Стиль", "multiSelect": false, "options": options]]],
            ]), permission: true)
        }
        at(22.4) {
            if let request = monitor.pending.first { monitor.answer(request, answers: [ask: "Тёмная тема"]) }
        }

        at(24.0) { [weak self] in self?.viewModel.selectedTab = .screenshots }
        at(27.0) { [weak self] in self?.viewModel.selectedTab = .clipboard }
        at(29.8) { [weak self] in self?.viewModel.selectedTab = .translate }
        for (index, character) in Array("Привет, как дела?").enumerated() {
            at(30.4 + Double(index) * 0.1) { [weak self] in self?.translatorManager.ruText.append(character) }
        }
        at(33.0) { [weak self] in
            if self?.translatorManager.enText.isEmpty == true { self?.translatorManager.enText = "Hi, how are you?" }
        }
        at(35.2) { [weak self] in self?.scheduleCollapse() }
        let endTime = 37.0

        // MARK: Run
        // One frame per hop through the main queue (a blocking loop would
        // starve the queue the app's own delayed work runs on).
        let fps = 50.0
        var pendingSteps = steps.sorted { $0.time < $1.time }[...]
        func render(frame: Int) {
            let now = Double(frame) / fps
            guard now <= endTime else {
                recorder.finish { NSApp.terminate(nil) }
                return
            }
            while let next = pendingSteps.first, next.time <= now {
                next.action()
                pendingSteps = pendingSteps.dropFirst()
            }
            clock.advance(to: now)
            if playing { trackElapsed += 1 / fps }
            nowPlayingManager.setDemoElapsed(trackElapsed)
            // Time for SwiftUI and the equalizer's layers to catch up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                recorder.capture(frame: frame)
                render(frame: frame + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            clock.advance(to: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                clock.settle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { render(frame: 0) }
            }
        }
    }
}

final class DemoRecorder {
    static let canvas = NSSize(width: 472, height: 214)

    private let panel: NSPanel
    private let directory: URL
    /// Corner radii of the pill's shape and height of the glow strip below it
    /// at this moment: the snapshot comes out as a plain black rectangle, so
    /// the shape is applied afterwards.
    private let shape: () -> (top: CGFloat, bottom: CGFloat, glow: CGFloat)
    private let queue = DispatchQueue(label: "notchapp.demo-encode", qos: .userInitiated, attributes: .concurrent)
    private let backlog = DispatchSemaphore(value: 6)
    private let group = DispatchGroup()

    init(panel: NSPanel, directory: URL, shape: @escaping () -> (top: CGFloat, bottom: CGFloat, glow: CGFloat)) {
        self.panel = panel
        self.directory = directory
        self.shape = shape
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("panel"), withIntermediateDirectories: true)
    }

    func capture(frame: Int) {
        guard let view = panel.contentView,
              let snapshot = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: snapshot)
        let size = view.bounds.size
        let shape = shape()
        let name = String(format: "%05d.png", frame)
        let url = directory.appendingPathComponent(name)
        let panelURL = directory.appendingPathComponent("panel").appendingPathComponent(name)
        backlog.wait()
        queue.async(group: group) { [backlog] in
            // On the stand-in desktop (for the GIFs), and on its own with
            // transparency (for the promo video, which supplies its own backdrop).
            if let data = Self.compose(snapshot, size: size, shape: shape, desktop: true).representation(using: .png, properties: [:]) {
                try? data.write(to: url)
            }
            if let data = Self.compose(snapshot, size: size, shape: shape, desktop: false).representation(using: .png, properties: [:]) {
                try? data.write(to: panelURL)
            }
            backlog.signal()
        }
    }

    /// Waits for pending PNG writes before the app quits.
    func finish(_ completion: @escaping () -> Void) {
        group.notify(queue: .main, execute: completion)
    }

    // MARK: Composition

    /// The panel's frame hung from the top of a stand-in desktop.
    private static func compose(_ snapshot: NSBitmapImageRep, size: NSSize,
                                shape: (top: CGFloat, bottom: CGFloat, glow: CGFloat), desktop: Bool) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if desktop { drawDesktop() }

        let target = NSRect(x: (canvas.width - size.width) / 2, y: canvas.height - size.height,
                            width: size.width, height: size.height)
        let pillHeight = size.height - shape.glow

        // The pill, cut to its notch shape.
        NSGraphicsContext.saveGraphicsState()
        let outline = NotchShape(topCornerRadius: shape.top, bottomCornerRadius: shape.bottom)
            .path(in: CGRect(x: 0, y: 0, width: size.width, height: pillHeight)).cgPath
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: target.minX, ty: canvas.height)
        if let placed = outline.copy(using: &flip) { NSBezierPath(cgPath: placed).addClip() }
        snapshot.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        // The glow underneath: the snapshot already has it with transparency.
        if shape.glow > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: target.minX, y: target.minY, width: size.width, height: shape.glow).clip()
            snapshot.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// A soft pastel sky with a menu bar on top.
    private static func drawDesktop() {
        let bounds = NSRect(origin: .zero, size: canvas)
        NSGradient(colors: [NSColor(red: 1.00, green: 0.91, blue: 0.80, alpha: 1),
                            NSColor(red: 0.99, green: 0.82, blue: 0.86, alpha: 1),
                            NSColor(red: 0.86, green: 0.78, blue: 0.96, alpha: 1),
                            NSColor(red: 0.62, green: 0.70, blue: 0.97, alpha: 1)],
                   atLocations: [0, 0.25, 0.58, 1], colorSpace: .deviceRGB)!
            .draw(in: bounds, angle: 90)

        func cloud(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ alpha: CGFloat) {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: x, yBy: y)
            transform.scaleX(by: 1, yBy: height / width)
            transform.concat()
            NSGradient(colors: [NSColor.white.withAlphaComponent(alpha), NSColor.white.withAlphaComponent(0)])!
                .draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: width / 2, options: [])
            NSGraphicsContext.restoreGraphicsState()
        }
        let clouds: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (70, 70, 230, 110, 0.85), (140, 50, 190, 80, 0.8), (360, 30, 260, 120, 0.9),
            (300, 80, 170, 70, 0.6), (430, 110, 150, 60, 0.5), (20, 20, 160, 70, 0.7),
        ]
        for (x, y, w, h, a) in clouds { cloud(x, y, w, h, a) }

        // menu bar
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSRect(x: 0, y: canvas.height - 30, width: canvas.width, height: 30).fill()
        NSColor(white: 0.12, alpha: 0.55).setFill()
        let items: [(CGFloat, CGFloat)] = [(14, 12), (36, 34), (78, 26), (112, 30),
                                           (canvas.width - 100, 12), (canvas.width - 78, 14),
                                           (canvas.width - 54, 12), (canvas.width - 34, 20)]
        for (x, w) in items {
            NSBezierPath(roundedRect: NSRect(x: x, y: canvas.height - 19, width: w, height: 8), xRadius: 3, yRadius: 3).fill()
        }
    }

    /// A made-up cover; `hue` picks one of a few palettes.
    static func artwork(hue: Int) -> NSImage {
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: 1) }
        let palettes: [[NSColor]] = [
            [color(1.0, 0.45, 0.30), color(0.75, 0.15, 0.55), color(0.20, 0.10, 0.45)],
            [color(1.0, 0.85, 0.40), color(0.95, 0.50, 0.35), color(0.45, 0.20, 0.40)],
            [color(0.40, 0.85, 0.90), color(0.25, 0.45, 0.85), color(0.12, 0.12, 0.40)],
            [color(0.60, 0.90, 0.55), color(0.20, 0.60, 0.55), color(0.08, 0.22, 0.35)],
            [color(0.95, 0.70, 0.90), color(0.60, 0.35, 0.85), color(0.20, 0.12, 0.50)],
        ]
        let colors = palettes[hue % palettes.count]
        let image = NSImage(size: NSSize(width: 300, height: 300))
        image.lockFocus()
        NSGradient(colors: colors)!.draw(in: NSRect(x: 0, y: 0, width: 300, height: 300), angle: -60)
        NSColor(red: 1.0, green: 0.92, blue: 0.65, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: 95, y: 130, width: 110, height: 110)).fill()
        colors[2].withAlphaComponent(0.85).setFill()
        for i in 0..<5 {
            NSBezierPath(rect: NSRect(x: 0, y: 40 + CGFloat(i) * 18, width: 300, height: 7 + CGFloat(i) * 2)).fill()
        }
        image.unlockFocus()
        return image
    }
}
