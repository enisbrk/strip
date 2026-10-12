import AppKit
import StripCore

/// Small template images drawn from a preset's slots, so every layout has an accurate icon.
@MainActor
enum LayoutIcon {
    private static var cache: [LayoutPreset: NSImage] = [:]

    static func image(for preset: LayoutPreset) -> NSImage {
        if let cached = cache[preset] { return cached }
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: true) { bounds in
            NSColor.black.setFill()
            let frame = bounds.insetBy(dx: 1, dy: 1)
            let gap: CGFloat = 1.5
            let units: [CGRect] = preset == .strip
                // Strip: three columns running off the right edge.
                ? [CGRect(x: 0, y: 0, width: 0.38, height: 1), CGRect(x: 0.38, y: 0, width: 0.38, height: 1),
                   CGRect(x: 0.76, y: 0, width: 0.24, height: 1)]
                : preset.slots
            for u in units {
                let r = CGRect(
                    x: frame.minX + u.minX * frame.width + (u.minX > 0 ? gap / 2 : 0),
                    y: frame.minY + u.minY * frame.height + (u.minY > 0 ? gap / 2 : 0),
                    width: u.width * frame.width - (u.minX > 0 ? gap / 2 : 0) - (u.maxX < 1 ? gap / 2 : 0),
                    height: u.height * frame.height - (u.minY > 0 ? gap / 2 : 0) - (u.maxY < 1 ? gap / 2 : 0)
                )
                NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        image.isTemplate = true
        cache[preset] = image
        return image
    }
}
