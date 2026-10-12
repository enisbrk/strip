// Draws the DMG window background (660×400 pt, @2x): an arrow from the app to Applications.
// Usage: swift scripts/make-dmg-background.swift <output.png>
import AppKit

let width: CGFloat = 660, height: CGFloat = 400, scale: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.97, blue: 1.0, alpha: 1),
                    NSColor(srgbRed: 0.90, green: 0.92, blue: 0.99, alpha: 1)])!
    .draw(in: CGRect(x: 0, y: 0, width: width, height: height), angle: -90)

// Finder positions icons by their center from the top-left; y = 190 → 210 from the bottom.
let arrowY = height - 190
let arrow = NSBezierPath()
arrow.move(to: CGPoint(x: 265, y: arrowY))
arrow.line(to: CGPoint(x: 385, y: arrowY))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
NSColor(srgbRed: 0.33, green: 0.38, blue: 0.85, alpha: 0.75).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: CGPoint(x: 400, y: arrowY))
head.line(to: CGPoint(x: 376, y: arrowY + 18))
head.line(to: CGPoint(x: 376, y: arrowY - 18))
head.close()
NSColor(srgbRed: 0.33, green: 0.38, blue: 0.85, alpha: 0.75).setFill()
head.fill()

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(srgbRed: 0.15, green: 0.17, blue: 0.30, alpha: alpha),
    ]
    let s = NSAttributedString(string: string, attributes: attrs)
    s.draw(at: CGPoint(x: (width - s.size().width) / 2, y: y))
}
text("Drag Strip to the Applications folder", size: 17, weight: .semibold, alpha: 0.85, y: height - 60)
text("Strip asks for Accessibility permission on first launch", size: 12, weight: .regular, alpha: 0.55, y: 48)

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
