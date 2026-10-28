// Draws the app icon: swift scripts/make-icon.swift <out.png>
// (scripts/make-icon.sh turns that into Sources/NotchApp/AppIcon.icns)
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 190, yRadius: 190)

// soft drop shadow under the tile
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor.black.setFill()
bodyPath.fill()
cg.restoreGState()

bodyPath.addClip()

// background
NSGradient(colors: [NSColor(red: 0.17, green: 0.17, blue: 0.20, alpha: 1),
                    NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)])!
    .draw(in: body, angle: -90)

// warm glow hanging under the notch
let orange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
NSGradient(colors: [orange.withAlphaComponent(0.55), orange.withAlphaComponent(0)])!
    .draw(fromCenter: NSPoint(x: 512, y: 770), radius: 0,
          toCenter: NSPoint(x: 512, y: 770), radius: 360, options: [])

// the notch: a black tab hanging from the top edge
let notchW: CGFloat = 400, notchH: CGFloat = 150
let notch = NSBezierPath()
let top = body.maxY + 2, left = 512 - notchW / 2, right = 512 + notchW / 2, bottom = top - notchH - 2
let r: CGFloat = 62
notch.move(to: NSPoint(x: left, y: top))
notch.line(to: NSPoint(x: left, y: bottom + r))
notch.curve(to: NSPoint(x: left + r, y: bottom),
            controlPoint1: NSPoint(x: left, y: bottom + r * 0.45),
            controlPoint2: NSPoint(x: left + r * 0.45, y: bottom))
notch.line(to: NSPoint(x: right - r, y: bottom))
notch.curve(to: NSPoint(x: right, y: bottom + r),
            controlPoint1: NSPoint(x: right - r * 0.45, y: bottom),
            controlPoint2: NSPoint(x: right, y: bottom + r * 0.45))
notch.line(to: NSPoint(x: right, y: top))
notch.close()
NSColor.black.setFill()
notch.fill()

// equalizer bars
let heights: [CGFloat] = [120, 210, 290, 180, 240, 140, 90]
let barW: CGFloat = 46, gap: CGFloat = 26
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = 512 - totalW / 2
let baseY: CGFloat = 250
for h in heights {
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: h),
                           xRadius: barW / 2, yRadius: barW / 2)
    NSGradient(colors: [NSColor.white, NSColor(red: 0.98, green: 0.78, blue: 0.68, alpha: 1)])!
        .draw(in: bar, angle: -90)
    x += barW + gap
}

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
