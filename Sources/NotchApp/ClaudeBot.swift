import SwiftUI

/// A little pixel robot, drawn on a 16x10 grid: body with two eyes, arms
/// out to the sides, four stubby legs. Takes its colour from
/// `foregroundStyle`; the eyes are cut out so whatever is behind shows
/// through.
struct ClaudeBot: View {
    private static let columns: CGFloat = 16
    private static let rows: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / Self.columns, size.height / Self.rows)
            let originX = (size.width - unit * Self.columns) / 2
            let originY = (size.height - unit * Self.rows) / 2

            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
                Path(CGRect(x: originX + x * unit, y: originY + y * unit, width: w * unit, height: h * unit))
            }

            var body = Path()
            body.addPath(rect(2, 0, 12, 8))    // torso
            body.addPath(rect(0, 4, 16, 2))    // arms
            for legX: CGFloat in [3, 5, 10, 12] {
                body.addPath(rect(legX, 8, 1, 2))
            }
            context.fill(body, with: .foreground)

            context.blendMode = .clear
            context.fill(rect(4, 2, 1, 2), with: .color(.black))
            context.fill(rect(11, 2, 1, 2), with: .color(.black))
        }
        .aspectRatio(Self.columns / Self.rows, contentMode: .fit)
    }
}

extension Color {
    /// Warm terracotta used for the robot in the pill.
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
}
