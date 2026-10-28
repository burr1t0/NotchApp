import AppKit
import Combine
import SwiftUI

/// Drives hover state by polling the global cursor position against fixed
/// rects, rather than relying on NSTrackingArea enter/exit events — those
/// fire spuriously while the panel's own frame is mid-animation, which is
/// exactly what caused the flicker when hovering near the notch.
final class NotchWindowController {
    var panel: NotchPanel!
    let viewModel = NotchViewModel()
    let clipboardManager = ClipboardManager()
    let screenshotWatcher = ScreenshotWatcher()
    let nowPlayingManager = NowPlayingManager()
    let audioMonitor = AudioLevelMonitor()
    let translatorManager = TranslatorManager()
    let claudeMonitor = ClaudeMonitor()

    private var notch: NSRect = .zero
    private var collapsedFrame: NSRect = .zero
    private var expandedFrame: NSRect = .zero
    /// Generous rect around the expanded panel: once open, the cursor can
    /// wander a bit outside the visible card without it snapping shut.
    private var hotZone: NSRect = .zero
    /// Shallow drop-down used to show a permission prompt without opening
    /// the whole panel.
    private var peekFrame: NSRect = .zero
    private var isPeeking = false
    private var glowActive = false
    private let glowMargin: CGFloat = 18
    /// Tracks whether the collapsed frame currently includes room for the
    /// album-art/equalizer indicator, so we only resize when this flips.
    private var collapsedHasMusicIndicator = false

    private var pollTimer: Timer?
    private var collapseWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    /// Plain mirrors of the `@Published` view-model state, kept current by
    /// `stateDidChange`. The 20 Hz cursor poll reads these instead of the
    /// `@Published` properties: profiling showed each `@Published` read goes
    /// through a Combine storage lookup plus a dynamic cast, which was a
    /// visible slice of the poll's cost.
    private var isExpanded = false
    private var selectedTab: NotchTab = .music
    private var wantsKeyboard = false
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount

    private let expandedWidth: CGFloat = 414
    private let expandedHeight: CGFloat = 184
    private let hotZoneMargin: CGFloat = 28
    private let peekWidth: CGFloat = 360
    private let peekHeight: CGFloat = 172
    private let collapseDelay: TimeInterval = 0.35
    /// Extra width added on each side of the notch, while collapsed, to fit
    /// the album art thumbnail / equalizer bars — mirrors the reference
    /// app's "MusicLiveActivity" layout.
    private let musicIndicatorWidth: CGFloat = 42

    func show() {
        guard let screen = NSScreen.main else { return }
        notch = NotchGeometry.notchFrame(on: screen)
        viewModel.notchWidth = notch.width

        collapsedFrame = collapsedFrame(withMusicIndicator: false)

        expandedFrame = NSRect(
            x: notch.midX - expandedWidth / 2,
            y: screen.frame.maxY - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )

        peekFrame = NSRect(
            x: notch.midX - peekWidth / 2,
            y: expandedFrame.maxY - peekHeight,
            width: peekWidth,
            height: peekHeight
        )

        hotZone = expandedFrame.insetBy(dx: -hotZoneMargin, dy: -hotZoneMargin)

        panel = NotchPanel(contentRect: collapsedFrame)

        let trackingView = HoverTrackingView(frame: NSRect(origin: .zero, size: collapsedFrame.size))
        trackingView.autoresizingMask = [.width, .height]

        // Demo recording runs on made-up data only: nothing real is started.
        let demoDirectory = ProcessInfo.processInfo.environment["NOTCHAPP_DEMO"]
        if demoDirectory == nil {
            clipboardManager.start()
            screenshotWatcher.start()
            nowPlayingManager.start()
            claudeMonitor.start()
        } else {
            audioMonitor.demoMode = true
        }

        let content = ContentView(
            viewModel: viewModel,
            clipboardManager: clipboardManager,
            screenshotWatcher: screenshotWatcher,
            nowPlayingManager: nowPlayingManager,
            audioMonitor: audioMonitor,
            translatorManager: translatorManager,
            claudeMonitor: claudeMonitor
        )
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: collapsedFrame.size)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = true

        trackingView.addSubview(hosting)
        panel.contentView = trackingView

        panel.setFrame(collapsedFrame, display: true)
        panel.orderFrontRegardless()

        // Everything that depends on *state* (audio capture, collapsed-pill
        // width, whether track time needs updating) reacts to changes here
        // instead of being re-derived on every poll tick. @Published emits
        // the new value to subscribers, so the closure gets the fresh state.
        Publishers.CombineLatest4(
            nowPlayingManager.$isAvailable.removeDuplicates(),
            nowPlayingManager.$isPlaying.removeDuplicates(),
            viewModel.$isExpanded.removeDuplicates(),
            viewModel.$selectedTab.removeDuplicates()
        )
        .sink { [weak self] available, playing, expanded, tab in
            self?.stateDidChange(available: available, playing: playing, expanded: expanded, tab: tab)
        }
        .store(in: &cancellables)

        // The collapsed pill is wider whenever it has something to show:
        // a playing track's art + equalizer, or a Claude status.
        Publishers.CombineLatest(
            nowPlayingManager.$isAvailable,
            claudeMonitor.$indicator.map { $0 != nil }
        )
        .map { $0 || $1 }
        .removeDuplicates()
        .sink { [weak self] in self?.pillVisibilityDidChange($0) }
        .store(in: &cancellables)

        // While Claude is waiting on you the window grows a transparent strip
        // underneath, which the glow is drawn into.
        claudeMonitor.$indicator
            .map { $0 == .needsInput }
            .removeDuplicates()
            .sink { [weak self] in self?.setGlow($0) }
            .store(in: &cancellables)

        // A permission prompt arriving drops the panel open just enough to
        // answer it; a question (needs more room) opens the full panel.
        // (@Published fires *before* the property changes, so the new value
        // has to be taken from the sink, not read back from the monitor.)
        claudeMonitor.$pending
            .map { $0.first }
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] request in self?.pendingDidChange(request) }
            .store(in: &cancellables)

        viewModel.$wantsKeyboard
            .removeDuplicates()
            .sink { [weak self] in self?.wantsKeyboard = $0 }
            .store(in: &cancellables)

        // Only hit-testing the cursor still needs a timer.
        if let demoDirectory {
            startDemo(outputDirectory: URL(fileURLWithPath: demoDirectory))
        } else {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.pollCursor()
            }
        }
    }

    private func collapsedFrame(withMusicIndicator: Bool) -> NSRect {
        let width = notch.width + (withMusicIndicator ? musicIndicatorWidth * 2 : 0)
        return NSRect(x: notch.midX - width / 2, y: notch.minY, width: width, height: notch.height)
    }

    private func pollCursor() {
        let location = NSEvent.mouseLocation
        // A file being dragged towards the notch opens it on the files tab
        // (hover doesn't update during a drag, so tabs can't be picked).
        // The drag pasteboard keeps the *last* drag's contents long after it
        // ended, so "has files on it" alone would make every later click
        // look like a file drag. A real drag changes it after the button
        // went down; compare against the count seen while it was up.
        let dragBoard = NSPasteboard(name: .drag)
        var draggingFile = false
        if NSEvent.pressedMouseButtons & 1 != 0 {
            draggingFile = dragBoard.changeCount != dragChangeCount && Self.dragCarriesFiles()
        } else {
            dragChangeCount = dragBoard.changeCount
        }

        if isExpanded {
            if draggingFile, selectedTab != .screenshots, expandedFrame.contains(location) {
                viewModel.selectedTab = .screenshots
            }
            if hotZone.contains(location) {
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
            } else if collapseWorkItem == nil, claudeMonitor.pending.isEmpty {
                // (Stay open while a prompt is waiting for an answer.)
                scheduleCollapse()
            }
        } else if !isPeeking, collapsedFrame.contains(location) {
            // (While peeking the cursor heads for the buttons — don't
            // yank the layout out from under it by opening the full panel.)
            expand(forFileDrag: draggingFile)
        }

        let shouldBeKey = isExpanded && (selectedTab == .translate || wantsKeyboard)
        if shouldBeKey != panel.allowsKey {
            panel.allowsKey = shouldBeKey
            if shouldBeKey {
                // Become key proactively, the moment the translate tab is
                // shown — waiting for the user's first click to trigger it
                // means that click just wakes the window up instead of
                // also focusing/placing the cursor in the text field,
                // which is why it used to take an extra click to type.
                panel.makeKey()
            } else if panel.isKeyWindow {
                panel.resignKey()
            }
        }
    }

    /// Single place that reacts to now-playing / panel state changes.
    private func stateDidChange(available: Bool, playing: Bool, expanded: Bool, tab: NotchTab) {
        isExpanded = expanded
        selectedTab = tab

        // Audio capture is only worth its (small) cost while the equalizer is
        // actually on screen and moving: collapsed pill visible *and* a track
        // playing. Everything else — paused, panel open, nothing loaded —
        // tears the tap down entirely.
        if !expanded && available && playing {
            audioMonitor.start()
        } else {
            audioMonitor.stop()
        }

        // Track time is only displayed in the open panel's music tab; while
        // collapsed, ticking it just re-renders SwiftUI for nothing.
        nowPlayingManager.wantsElapsedUpdates = expanded && tab == .music

    }

    /// Grow/shrink the collapsed pill to make room for the indicator as
    /// tracks start/stop or Claude wants attention (the reference app's
    /// `updateWindowSizeIfNeeded`). The frame is always kept current; it's
    /// only animated into place when the pill is what's on screen —
    /// otherwise the next collapse animates to the updated frame.
    private func pillVisibilityDidChange(_ visible: Bool) {
        guard visible != collapsedHasMusicIndicator else { return }
        collapsedHasMusicIndicator = visible
        collapsedFrame = collapsedFrame(withMusicIndicator: visible)
        if !isExpanded { animate(to: collapsedFrame) }
    }

    private func pendingDidChange(_ request: ClaudePermissionRequest?) {
        if let request {
            if isExpanded {
                if selectedTab != .translate { viewModel.selectedTab = .claude }
            } else if request.needsFullPanel {
                expand()
                viewModel.selectedTab = .claude
            } else {
                // Sized to this prompt, so there's no dead space under short ones.
                peekFrame = makePeekFrame(height: peekHeight(for: request))
                if !isPeeking {
                    isPeeking = true
                    viewModel.isPeeking = true
                }
                animate(to: peekFrame)
            }
        } else if isPeeking {
            isPeeking = false
            viewModel.isPeeking = false
            if !isExpanded { animate(to: collapsedFrame) }
        }
    }

    private func makePeekFrame(height: CGFloat) -> NSRect {
        NSRect(x: notch.midX - peekWidth / 2, y: expandedFrame.maxY - height,
               width: peekWidth, height: height)
    }

    /// Music row + header + buttons + padding are fixed; the preview box is
    /// the part that varies with the prompt.
    private func peekHeight(for request: ClaudePermissionRequest) -> CGFloat {
        let box: CGFloat
        switch request.preview {
        case .command(let text), .generic(let text):
            let lines = min(3, max(1, Int((Double(text.count + 8) / 46).rounded(.up))))
            box = CGFloat(lines) * 12.5 + 12
        case .edit(_, let removed, let added):
            box = CGFloat(1 + removed.count + added.count) * 12.5 + 12
        case .write, .plan:
            box = 12.5 + 12
        }
        return 98 + box
    }

    private static func dragCarriesFiles() -> Bool {
        NSPasteboard(name: .drag).canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
    }

    func expand(forFileDrag: Bool = false) {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        guard !isExpanded else { return }
        viewModel.selectedTab = forFileDrag ? .screenshots : (claudeMonitor.needsAttention ? .claude : .music)
        isPeeking = false
        viewModel.isPeeking = false
        viewModel.isExpanded = true
        animate(to: expandedFrame)
    }

    func scheduleCollapse() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWorkItem = nil
            self.viewModel.isExpanded = false
            self.panel.allowsKey = false
            if self.panel.isKeyWindow {
                self.panel.resignKey()
            }
            self.animate(to: self.collapsedFrame)
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: workItem)
    }

    private func setGlow(_ on: Bool) {
        glowActive = on
        viewModel.glowMargin = on ? glowMargin : 0
        // Instant, not animated: the content shrinks/grows its pill by the
        // same amount in the same moment, so nothing visibly moves.
        // Through the animator with zero duration, so it also replaces any
        // resize animation still in flight (a plain setFrame loses to it and
        // the window ends up at the stale size, leaving a stub below the pill).
        let base = isExpanded ? expandedFrame : isPeeking ? peekFrame : collapsedFrame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(framed(base), display: true)
        }
    }

    /// `frame` plus the glow strip underneath, when it's showing.
    private func framed(_ frame: NSRect) -> NSRect {
        guard glowActive else { return frame }
        return NSRect(x: frame.minX, y: frame.minY - glowMargin, width: frame.width, height: frame.height + glowMargin)
    }

    private func animate(to frame: NSRect) {
        let frame = framed(frame)
        // Deliberately plain — an overshoot curve here animates x/y/width/
        // height as four independent values, and since collapsed↔collapsed
        // width changes (for the music indicator) are centered on the
        // notch, any overshoot bulges symmetrically out from that center,
        // reading as "jumping from the middle" rather than staying pinned
        // to the notch. The springy feel instead comes from the SwiftUI
        // content animation layered on top, which keeps the top edge fixed
        // since it only ever grows downward from it.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}
