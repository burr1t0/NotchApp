import AppKit

/// Reading "now playing" metadata via Apple's private MediaRemote framework
/// is normally blocked for any process that isn't an Apple-signed platform
/// binary (verified directly — even a custom entitlement claiming
/// `com.apple.private.mediaremote` gets the process killed by the kernel on
/// launch). But `/usr/bin/perl` IS one of those platform binaries
/// (`com.apple.perl`), so this bundles the `mediaremote-adapter` tool
/// (github.com/ungive/mediaremote-adapter, BSD-3-Clause — see
/// MediaControl/LICENSE) and shells out to it: a Perl script + a small
/// helper framework that, running *as* `/usr/bin/perl`, is trusted to read
/// and control the same system-wide "Now Playing" state Control Center
/// shows. This works for any player (Yandex Music, Spotify, browser tabs,
/// Apple Music, ...), stays live even while the player's own window is
/// minimized or hidden (unlike scraping its UI), and supports real seeking.
final class NowPlayingManager: ObservableObject {
    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isAvailable = false
    /// Elapsed time interpolated locally between stream updates (the tool
    /// only pushes an update when something actually changes, not every
    /// tick) so the progress bar still moves smoothly second to second.
    @Published private(set) var displayedElapsed: Double = 0

    /// True once the adapter keeps dying right after launch (or can't start
    /// at all) — e.g. a macOS update closing the loophole it relies on — so
    /// the UI can say so instead of just showing "nothing playing".
    @Published private(set) var adapterProblem = false

    private var streamProcess: Process?
    private var streamStartedAt = Date()
    private var quickFailures = 0
    private var uiTimer: Timer?
    private var stdoutBuffer = Data()

    private var anchorElapsed: Double = 0
    private var anchorDate = Date()
    private var playbackRate: Double = 1
    /// Hash of the artwork bytes currently shown. Deliberately not keyed on
    /// `contentItemIdentifier`: Yandex changes that on almost every event
    /// (even pause/play of the same track) and delivers the new cover a beat
    /// *after* the title event, so an id-based check both reloads needlessly
    /// and can miss the one event that actually carries the new image.
    private var lastArtworkDigest: Int?

    private static let isoFormatter = ISO8601DateFormatter()

    private static var scriptURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("MediaControl/bin/media-control")
    }

    /// Fills in a fixed track for recording the demo animation.
    func applyDemo(title: String, artist: String, artwork: NSImage, duration: Double, elapsed: Double) {
        self.title = title
        self.artist = artist
        self.artwork = artwork
        self.duration = duration
        displayedElapsed = elapsed
        isPlaying = true
        isAvailable = true
    }

    func setDemoElapsed(_ seconds: Double) { displayedElapsed = seconds }

    func start() {
        // A previous instance that was killed (reinstall, crash) leaves its
        // adapter process running as an orphan — it would keep streaming
        // alongside the new one. Clear those out first.
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        cleanup.arguments = ["-f", "mediaremote-adapter.pl.* stream"]
        try? cleanup.run()
        cleanup.waitUntilExit()

        startStreamProcess()
    }

    /// Whether anything is currently displaying the track time. Set by the
    /// window controller (open panel on the music tab). While false the
    /// interpolation timer doesn't run at all: it publishes `displayedElapsed`
    /// every 0.3s, which re-renders SwiftUI for a value nobody can see.
    var wantsElapsedUpdates = false {
        didSet {
            guard wantsElapsedUpdates != oldValue else { return }
            if wantsElapsedUpdates {
                tickInterpolatedElapsed()   // fresh value the moment it's shown
                uiTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                    self?.tickInterpolatedElapsed()
                }
            } else {
                uiTimer?.invalidate()
                uiTimer = nil
            }
        }
    }

    func stop() {
        uiTimer?.invalidate()
        uiTimer = nil
        streamProcess?.terminationHandler = nil
        streamProcess?.terminate()
        streamProcess = nil
    }

    func togglePlayPause() { runCommand(["toggle-play-pause"]) }
    func next() { runCommand(["next-track"]) }
    func previous() { runCommand(["previous-track"]) }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        let seconds = fraction.clamped(to: 0...1) * duration
        anchorElapsed = seconds
        anchorDate = Date()
        displayedElapsed = seconds
        runCommand(["seek", String(format: "%.2f", seconds)])
    }

    // MARK: - Streaming process

    private func startStreamProcess() {
        guard let scriptURL = Self.scriptURL,
              FileManager.default.fileExists(atPath: scriptURL.path) else {
            adapterProblem = true
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, "stream", "--no-diff"]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.consume(data)
            }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.streamProcess = nil
                // The adapter can be killed if the system media session
                // resets, so restart it rather than staying dark — but back
                // off if it dies immediately every time, instead of
                // spinning up a new process every 2 s forever.
                if Date().timeIntervalSince(self.streamStartedAt) < 5 {
                    self.quickFailures += 1
                } else {
                    self.quickFailures = 0
                }
                if self.quickFailures >= 3 { self.adapterProblem = true }
                let delay = min(2 * pow(2, Double(max(self.quickFailures - 1, 0))), 60)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.startStreamProcess()
                }
            }
        }

        do {
            streamStartedAt = Date()
            try process.run()
            streamProcess = process
        } catch {
            streamProcess = nil
            adapterProblem = true
        }
    }

    private func consume(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[..<newlineIndex]
            stdoutBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handleLine(lineData)
        }
    }

    private func handleLine(_ lineData: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = json["payload"] as? [String: Any] else { return }
        // A well-formed line proves the adapter is working.
        quickFailures = 0
        if adapterProblem { adapterProblem = false }
        apply(payload)
    }

    private func apply(_ payload: [String: Any]) {
        guard !payload.isEmpty, let playing = payload["playing"] as? Bool else {
            isAvailable = false
            title = nil
            artist = nil
            artwork = nil
            duration = 0
            displayedElapsed = 0
            lastArtworkDigest = nil
            return
        }

        let previousTitle = title
        title = payload["title"] as? String
        artist = payload["artist"] as? String
        duration = payload["duration"] as? Double ?? 0
        isPlaying = playing
        playbackRate = payload["playbackRate"] as? Double ?? (playing ? 1 : 0)

        let elapsed = payload["elapsedTime"] as? Double ?? 0
        anchorElapsed = elapsed
        if let timestampString = payload["timestamp"] as? String,
           let date = Self.isoFormatter.date(from: timestampString) {
            anchorDate = date
        } else {
            anchorDate = Date()
        }
        displayedElapsed = elapsed

        // On a track change Yandex sends the title first with no artwork,
        // then the *previous* cover, and only ~0.5s later the new one. So:
        // decode whenever the bytes actually differ from what's shown (or
        // nothing is shown yet), never blank on a mere missing field within
        // the same track, and drop the old cover only when the title
        // changed and this event brings none (a track with no art at all).
        if let base64 = payload["artworkData"] as? String {
            let digest = base64.hashValue
            if digest != lastArtworkDigest || artwork == nil,
               let data = Data(base64Encoded: base64),
               let image = NSImage(data: data) {
                artwork = image
                lastArtworkDigest = digest
            }
        } else if title != previousTitle {
            artwork = nil
        }

        isAvailable = true
    }

    private func tickInterpolatedElapsed() {
        guard isAvailable, isPlaying, duration > 0 else { return }
        let projected = anchorElapsed + Date().timeIntervalSince(anchorDate) * playbackRate
        displayedElapsed = projected.clamped(to: 0...duration)
    }

    // MARK: - Control commands

    private func runCommand(_ args: [String]) {
        guard let scriptURL = Self.scriptURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path] + args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
