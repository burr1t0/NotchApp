import SwiftUI
import AppKit

/// Equalizer bars shown beside the collapsed notch while something plays.
///
/// Each bar is one frequency band (bass on the left → treble on the right)
/// of the audio the system is actually playing, supplied by
/// `AudioLevelMonitor`.
///
/// Drawn with plain Core Animation layers rather than SwiftUI shapes on
/// purpose. A per-frame SwiftUI `TimelineView` made the whole hosting view
/// re-run layout and its view graph ~45 times a second — profiling showed
/// that, not the FFT, was nearly all of the cost (~4% of a core).
///
/// Heights are set directly, 24 times a second, with implicit animations
/// switched off: measured at idle, letting Core Animation interpolate each
/// update (implicit animation creation + presentation-layer lookups per bar)
/// cost roughly 2.5x as much as stepping at the same rate, and interpolating
/// at a lower rate would add visible lag behind the beat. 24 fps stepping
/// keeps latency under ~40 ms and looks like any bar equalizer.
struct EqualizerBars: NSViewRepresentable {
    let isPlaying: Bool
    let monitor: AudioLevelMonitor

    func makeNSView(context: Context) -> EqualizerLayerView {
        let view = EqualizerLayerView(monitor: monitor)
        view.setPlaying(isPlaying)
        return view
    }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ view: EqualizerLayerView, coordinator: ()) {
        view.setPlaying(false)
    }
}

final class EqualizerLayerView: NSView {
    private let monitor: AudioLevelMonitor
    private var bars: [CALayer] = []
    private var timer: Timer?
    private var playing = false

    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2
    private let maxHeight: CGFloat = 16
    private let restingLevel: CGFloat = 0.18
    private static let tickInterval: TimeInterval = 1.0 / 24.0
    /// Last heights pushed to the layers; lets `apply` skip a commit when
    /// nothing visibly changed (silence, steady tones).
    private var lastHeights = [CGFloat](repeating: -1, count: AudioLevelMonitor.bandCount)

    private var totalWidth: CGFloat {
        let count = CGFloat(AudioLevelMonitor.bandCount)
        return count * barWidth + (count - 1) * barSpacing
    }

    init(monitor: AudioLevelMonitor) {
        self.monitor = monitor
        super.init(frame: .zero)
        wantsLayer = true
        buildBars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { timer?.invalidate() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: totalWidth, height: maxHeight)
    }

    /// SwiftUI stretches this view to whatever room the parent offers (the
    /// full pill height, not the 16pt intrinsic size), so the bars must be
    /// centred on the view's *actual* bounds. Positioning them at a fixed
    /// offset from the bottom — as before — pinned them to the lower edge
    /// instead of lining up with the middle of the album art.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let originX = (bounds.width - totalWidth) / 2
        for (index, bar) in bars.enumerated() {
            bar.position = CGPoint(
                x: originX + CGFloat(index) * (barWidth + barSpacing) + barWidth / 2,
                y: bounds.midY
            )
        }
        CATransaction.commit()
    }

    func setPlaying(_ newValue: Bool) {
        guard newValue != playing else { return }
        playing = newValue

        if playing {
            // A pause→resume inside the 0.3s settle animation would otherwise
            // leave that animation overriding the stepped updates.
            bars.forEach { $0.removeAllAnimations() }
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            // Settle to the resting height rather than freezing mid-beat.
            apply(levels: [], settleOver: 0.3)
        }
    }

    private func buildBars() {
        for index in 0..<AudioLevelMonitor.bandCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            bar.cornerRadius = barWidth / 2
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: maxHeight * restingLevel)
            bar.position = CGPoint(
                x: CGFloat(index) * (barWidth + barSpacing) + barWidth / 2,
                y: maxHeight / 2
            )
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    private func tick() {
        apply(levels: monitor.currentLevels(), settleOver: nil)
    }

    /// `settleOver == nil`: set heights immediately (per-tick path).
    /// Otherwise ease to them over that many seconds (pause → resting bars).
    private func apply(levels: [Float], settleOver duration: TimeInterval?) {
        let heights: [CGFloat] = (0..<bars.count).map { index in
            let level = index < levels.count ? CGFloat(levels[index]) : 0
            return maxHeight * (restingLevel + (1 - restingLevel) * level)
        }

        if duration == nil, zip(heights, lastHeights).allSatisfy({ abs($0 - $1) < 0.3 }) {
            return
        }
        lastHeights = heights

        CATransaction.begin()
        if let duration {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (bar, height) in zip(bars, heights) {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: height)
        }
        CATransaction.commit()
    }
}
