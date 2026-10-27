import AppKit

enum NotchGeometry {
    /// Returns (origin x, width, height) of the physical notch cutout in screen coordinates,
    /// falling back to a reasonable centered guess on displays without a notch.
    static func notchFrame(on screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let topInset = screen.safeAreaInsets.top

        if topInset > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let notchMinX = leftArea.maxX
            let notchMaxX = rightArea.minX
            let width = notchMaxX - notchMinX
            return NSRect(
                x: notchMinX,
                y: screenFrame.maxY - topInset,
                width: width,
                height: topInset
            )
        }

        // Fallback for external / non-notch displays: small invisible trigger zone top-center.
        let width: CGFloat = 200
        let height: CGFloat = 6
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }
}
