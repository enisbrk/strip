import CoreGraphics

/// How windows are shown: the scrolling strip, or a fixed on-screen grid. With a grid, the strip
/// is split into pages of `slots.count` windows and the page holding the focused window is shown.
public enum LayoutPreset: String, Codable, CaseIterable, Sendable {
    case strip
    case full
    case twoColumns
    case grid2x2
    case twoTopOneBottom
    case oneTopTwoBottom
    case twoLeftOneRight
    case oneLeftTwoRight

    /// Slots in unit coordinates (top-left origin), in fill order.
    public var slots: [CGRect] {
        let h: CGFloat = 0.5
        switch self {
        case .strip, .full:
            return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case .twoColumns:
            return [CGRect(x: 0, y: 0, width: h, height: 1), CGRect(x: h, y: 0, width: h, height: 1)]
        case .grid2x2:
            return [CGRect(x: 0, y: 0, width: h, height: h), CGRect(x: h, y: 0, width: h, height: h),
                    CGRect(x: 0, y: h, width: h, height: h), CGRect(x: h, y: h, width: h, height: h)]
        case .twoTopOneBottom:
            return [CGRect(x: 0, y: 0, width: h, height: h), CGRect(x: h, y: 0, width: h, height: h),
                    CGRect(x: 0, y: h, width: 1, height: h)]
        case .oneTopTwoBottom:
            return [CGRect(x: 0, y: 0, width: 1, height: h),
                    CGRect(x: 0, y: h, width: h, height: h), CGRect(x: h, y: h, width: h, height: h)]
        case .twoLeftOneRight:
            return [CGRect(x: 0, y: 0, width: h, height: h), CGRect(x: 0, y: h, width: h, height: h),
                    CGRect(x: h, y: 0, width: h, height: 1)]
        case .oneLeftTwoRight:
            return [CGRect(x: 0, y: 0, width: h, height: 1),
                    CGRect(x: h, y: 0, width: h, height: h), CGRect(x: h, y: h, width: h, height: h)]
        }
    }

    /// English name; the app translates it.
    public var title: String {
        switch self {
        case .strip: "Strip (scrolling)"
        case .full: "Full screen"
        case .twoColumns: "Two side by side"
        case .grid2x2: "Four (2 top, 2 bottom)"
        case .twoTopOneBottom: "Three (2 top, 1 bottom)"
        case .oneTopTwoBottom: "Three (1 top, 2 bottom)"
        case .twoLeftOneRight: "Three (2 left, 1 right)"
        case .oneLeftTwoRight: "Three (1 left, 2 right)"
        }
    }
}

extension LayoutEngine {
    /// Pages sit side by side, one screen apart, so switching pages is a horizontal scroll.
    public var pageStride: CGFloat { area.width + 2 * outerGap + innerGap }

    public func page(of index: Int, preset: LayoutPreset) -> Int { index / preset.slots.count }

    public func pageCount(_ strip: Strip, preset: LayoutPreset) -> Int {
        (strip.columns.count + preset.slots.count - 1) / preset.slots.count
    }

    /// Viewport offset that shows the page holding the focused column.
    public func presetOffset(for strip: Strip, preset: LayoutPreset) -> CGFloat {
        CGFloat(page(of: strip.focusedIndex ?? 0, preset: preset)) * pageStride
    }

    /// The on-screen rect of a unit slot, with `innerGap` only between neighbouring slots.
    public func rect(forSlot u: CGRect) -> CGRect {
        let g = innerGap / 2
        let left = u.minX > 0 ? g : 0, right = u.maxX < 1 ? g : 0
        let top = u.minY > 0 ? g : 0, bottom = u.maxY < 1 ? g : 0
        return CGRect(
            x: (area.minX + u.minX * area.width + left).rounded(),
            y: (area.minY + u.minY * area.height + top).rounded(),
            width: (u.width * area.width - left - right).rounded(),
            height: (u.height * area.height - top - bottom).rounded()
        )
    }

    /// Frames for a grid preset at a given (possibly mid-animation) viewport offset.
    public func presetFrames(for strip: Strip, preset: LayoutPreset, offset: CGFloat) -> [WindowID: CGRect] {
        windowFrames(strip, columnRects: presetColumnRects(for: strip, preset: preset, offset: offset))
    }

    /// The slot rect of every column (a stack shares its slot) at a viewport offset.
    public func presetColumnRects(for strip: Strip, preset: LayoutPreset, offset: CGFloat) -> [CGRect] {
        let slots = preset.slots
        return strip.columns.indices.map { i in
            let shift = CGFloat(i / slots.count) * pageStride - offset
            return rect(forSlot: slots[i % slots.count]).offsetBy(dx: shift.rounded(), dy: 0)
        }
    }

    /// Index of the first window on the next / previous page, or nil at either end.
    public func presetScreenStep(_ strip: Strip, preset: LayoutPreset, direction: Int) -> Int? {
        let target = page(of: strip.focusedIndex ?? 0, preset: preset) + direction
        guard target >= 0, target < pageCount(strip, preset: preset) else { return nil }
        return target * preset.slots.count
    }

    /// Strip index of the slot under `point` on the shown page (for drag-to-reorder).
    public func presetIndex(at point: CGPoint, strip: Strip, preset: LayoutPreset) -> Int? {
        let start = page(of: strip.focusedIndex ?? 0, preset: preset) * preset.slots.count
        for (i, u) in preset.slots.enumerated() where rect(forSlot: u).contains(point) {
            let index = start + i
            return index < strip.columns.count ? index : nil
        }
        return nil
    }
}
