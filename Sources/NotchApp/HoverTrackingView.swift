import AppKit

/// Hosts the SwiftUI content. Hover open/close is driven by
/// NotchWindowController's cursor polling, not by this view's own tracking —
/// AppKit's mouseEntered/mouseExited fire unreliably while the window's own
/// frame is being animated.
final class HoverTrackingView: NSView {
    // Let SwiftUI buttons respond to the first click even though the panel
    // never becomes key window (see NotchPanel.canBecomeKey).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
