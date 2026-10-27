import SwiftUI

/// The panel sits flush against the screen's top edge, so a plain rounded
/// rectangle makes its top corners read as a separate floating pill next to
/// the camera housing. This shape instead curves the top corners *inward*
/// (concave) so the panel visually grows out of the notch/bezel, while the
/// bottom corners stay a normal convex round.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    /// Bezier "kappa" constant for approximating a quarter circle with a
    /// cubic curve — gives a genuinely round arc instead of a quadratic
    /// curve's slightly flattened, uneven-curvature look.
    private let kappa: CGFloat = 0.5523

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tr = topCornerRadius
        let br = bottomCornerRadius

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left: concave quarter-circle down into the left edge.
        path.addCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control1: CGPoint(x: rect.minX + tr * kappa, y: rect.minY),
            control2: CGPoint(x: rect.minX + tr, y: rect.minY + tr * (1 - kappa))
        )

        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))

        // Bottom-left: normal convex quarter-circle.
        path.addCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control1: CGPoint(x: rect.minX + tr, y: rect.maxY - br * (1 - kappa)),
            control2: CGPoint(x: rect.minX + tr + br * (1 - kappa), y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))

        // Bottom-right: normal convex quarter-circle.
        path.addCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control1: CGPoint(x: rect.maxX - tr - br * (1 - kappa), y: rect.maxY),
            control2: CGPoint(x: rect.maxX - tr, y: rect.maxY - br * (1 - kappa))
        )

        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))

        // Top-right: concave quarter-circle back up to the top edge.
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - tr, y: rect.minY + tr * (1 - kappa)),
            control2: CGPoint(x: rect.maxX - tr * kappa, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}
