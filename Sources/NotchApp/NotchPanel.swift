import AppKit

final class NotchPanel: NSPanel {
    // Buttons must work without stealing key window status from whatever app
    // the user was in — otherwise Cmd+V after a clipboard click goes nowhere.
    // Only the translator's text field needs real keyboard focus, so key
    // status is allowed in on demand (see NotchWindowController) instead of
    // permanently, and is dropped again the moment the panel collapses.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // A window shadow reads as a pale outline around the black shape —
        // the panel should look like it grows straight out of the bezel,
        // not float above it.
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
    }
}
