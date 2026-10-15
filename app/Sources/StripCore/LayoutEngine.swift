import CoreGraphics

/// Turns a `Strip` into concrete window frames. All rects use a top-left origin
/// (the Accessibility coordinate space), but nothing here depends on that.
public struct LayoutEngine: Sendable {
    /// Usable area: the screen's visible frame already inset by the outer gap.
    public var area: CGRect
    public var innerGap: CGFloat
    public var outerGap: CGFloat

    public init(area: CGRect, innerGap: CGFloat, outerGap: CGFloat = 0) {
        self.area = area
        self.innerGap = innerGap
        self.outerGap = outerGap
    }

    public init(screen visibleFrame: CGRect, settings: Settings) {
        self.init(
            area: visibleFrame.insetBy(dx: settings.outerGap, dy: settings.outerGap),
            innerGap: settings.innerGap,
            outerGap: settings.outerGap
        )
    }

    public func pixelWidth(of column: Column) -> CGFloat {
        // Fractions include their share of the gap, so two 50% columns fill the screen exactly.
        (column.width * (area.width + innerGap) - innerGap).rounded()
    }

    /// Room the column takes in the strip: its width, or a whole screen when centered.
    public func slotWidth(of column: Column) -> CGFloat {
        column.centered || column.pin != nil ? area.width : pixelWidth(of: column)
    }

    /// One screen of the strip (see `Strip.screenGroups`): its columns, where it starts in strip
    /// coordinates and how wide it is. Every screen takes at least a whole screen width, so a
    /// screen its columns don't fill shows empty space, never the next screen's windows.
    public struct Page: Equatable, Sendable {
        public let columns: Range<Int>
        public let start: CGFloat
        public let width: CGFloat
    }

    public func pages(_ strip: Strip) -> [Page] {
        var x: CGFloat = 0
        return strip.screenGroups().map { group in
            let content = group.map { slotWidth(of: strip.columns[$0]) }.reduce(0, +) + innerGap * CGFloat(group.count - 1)
            let page = Page(columns: group, start: x, width: max(area.width, content))
            x += page.width + innerGap
            return page
        }
    }

    /// Left edge of every column's slot in strip coordinates (first column starts at 0). Each
    /// screen starts a whole screen width after the previous one.
    public func columnOrigins(_ strip: Strip) -> [CGFloat] {
        var origins = Array(repeating: CGFloat(0), count: strip.columns.count)
        for page in pages(strip) {
            var x = page.start
            for i in page.columns {
                origins[i] = x
                x += slotWidth(of: strip.columns[i]) + innerGap
            }
        }
        return origins
    }

    /// The screen holding column `index`.
    func page(of index: Int, in pages: [Page]) -> Page? {
        pages.first { $0.columns.contains(index) }
    }

    /// Where the windows of a column start inside its slot (the left margin of a centered column).
    public func inset(of column: Column) -> CGFloat {
        if column.centered { return ((area.width - pixelWidth(of: column)) / 2).rounded() }
        return column.pin?.x == 1 ? area.width - pixelWidth(of: column) : 0
    }

    public func totalWidth(_ strip: Strip) -> CGFloat {
        guard let last = pages(strip).last else { return 0 }
        return last.start + last.width
    }

    /// The viewport offset that should be used after focus or widths changed: the start of the
    /// focused column's screen. Only a screen wider than the display (one very wide column)
    /// scrolls within itself, just enough to show the focused column.
    public func targetOffset(for strip: Strip) -> CGFloat {
        guard let f = strip.focusedIndex else { return 0 }
        if let page = page(of: f, in: pages(strip)), page.width <= area.width + 0.5 { return page.start }
        let origins = columnOrigins(strip)
        let x = origins[f]
        let w = slotWidth(of: strip.columns[f])
        let total = totalWidth(strip)
        if total <= area.width { return 0 }
        var offset = strip.viewportOffset
        if x < offset { offset = x }
        if x + w > offset + area.width { offset = x + w - area.width }
        return min(max(offset, 0), total - area.width)
    }

    /// Frames for every column given a viewport offset.
    /// Height of the tab bar drawn above a tabbed column.
    public static let tabBarHeight: CGFloat = 28

    /// Frames of the visible windows given a viewport offset. Inactive tabs are left out
    /// (see `hiddenWindows`).
    public func frames(for strip: Strip, offset: CGFloat) -> [WindowID: CGRect] {
        windowFrames(strip, columnRects: columnRects(for: strip, offset: offset))
    }

    /// The rect of every column (its whole stack) at a viewport offset.
    public func columnRects(for strip: Strip, offset: CGFloat) -> [CGRect] {
        zip(strip.columns, columnOrigins(strip)).map { col, x in
            // A column pinned to the top or bottom half of its screen.
            let half = ((area.height - innerGap) / 2).rounded()
            let y = col.pin?.y == 1 ? area.maxY - half : area.minY
            return CGRect(x: (area.minX + x + inset(of: col) - offset).rounded(), y: y,
                          width: pixelWidth(of: col), height: (col.pin?.y ?? 0) != 0 ? half : area.height)
        }
    }

    func windowFrames(_ strip: Strip, columnRects: [CGRect]) -> [WindowID: CGRect] {
        var result: [WindowID: CGRect] = [:]
        for (column, rect) in zip(strip.columns, columnRects) {
            result.merge(layout(column, in: rect)) { a, _ in a }
        }
        return result
    }

    /// Splits a column rect between its windows: rows for a stack, the active one under the
    /// tab bar for tabs.
    public func layout(_ column: Column, in rect: CGRect) -> [WindowID: CGRect] {
        if column.maximized && column.isStack {
            return [column.windowID: rect]
        }
        if column.tabbed {
            let bar = Self.tabBarHeight
            return [column.windowID: CGRect(x: rect.minX, y: rect.minY + bar,
                                            width: rect.width, height: rect.height - bar)]
        }
        let n = column.windows.count
        let available = rect.height - innerGap * CGFloat(n - 1)
        var result: [WindowID: CGRect] = [:]
        var y = rect.minY
        for (i, (id, fraction)) in zip(column.windows, column.heightFractions).enumerated() {
            // The last row takes whatever is left so rounding never leaves a gap at the bottom.
            let h = i == n - 1 ? rect.maxY - y : (available * fraction).rounded()
            result[id] = CGRect(x: rect.minX, y: y, width: rect.width, height: h)
            y += h + innerGap
        }
        return result
    }

    /// Windows that are not shown: the inactive tabs of tabbed columns. They get parked.
    public func hiddenWindows(_ strip: Strip) -> [WindowID] {
        strip.columns.filter(\.showsOnlyActive).flatMap { c in c.windows.filter { $0 != c.windowID } }
    }

    /// Where a free scroll (trackpad swipe) settles: the screen whose start is nearest to
    /// `offset`, nudged one screen in the direction of a fast fling. Returns that screen's first
    /// column and the offset showing it.
    public func settle(_ strip: Strip, offset: CGFloat, fling: Int = 0) -> (index: Int, offset: CGFloat)? {
        let pages = pages(strip)
        guard !pages.isEmpty else { return nil }
        let maxOffset = max(0, totalWidth(strip) - area.width)
        var nearest = pages.indices.min { abs(pages[$0].start - offset) < abs(pages[$1].start - offset) }!
        nearest = min(max(nearest + fling, 0), pages.count - 1)
        return (pages[nearest].columns.lowerBound, min(max(pages[nearest].start, 0), maxOffset))
    }

    /// "Next / previous screen" in strip mode: the first column of that screen and the viewport
    /// offset showing it; nil when already at the end.
    public func screenStep(_ strip: Strip, direction: Int) -> (index: Int, offset: CGFloat)? {
        let pages = pages(strip)
        guard !pages.isEmpty else { return nil }
        let offset = strip.viewportOffset
        let maxOffset = max(0, totalWidth(strip) - area.width)
        // The screen on display: the last one starting at or before the viewport.
        let current = pages.lastIndex { $0.start <= offset + 1 } ?? 0
        let target = current + (direction > 0 ? 1 : -1)
        guard pages.indices.contains(target) else { return nil }
        return (pages[target].columns.lowerBound, min(max(pages[target].start, 0), maxOffset))
    }

    /// Index of the column whose span contains `screenX` (for drag-to-reorder).
    public func columnIndex(atScreenX screenX: CGFloat, strip: Strip, offset: CGFloat) -> Int? {
        guard !strip.columns.isEmpty else { return nil }
        let stripX = screenX - area.minX + offset
        let origins = columnOrigins(strip)
        for (i, x) in origins.enumerated().reversed() where stripX >= x {
            return i
        }
        return 0
    }
}

/// macOS refuses to put a window completely off screen, so columns that are out of view get
/// parked in a corner of their display with only `peek` pixels showing. The corner is chosen so
/// the window never shows up on a neighbouring display.
public enum OffscreenPlacer {
    /// - Parameters:
    ///   - display: full frame of the window's display.
    ///   - otherDisplays: frames of every other display; frames reaching into them are parked
    ///     (so sliding columns never appear on the next monitor).
    ///   - allowLeftOverflow: false for apps that refuse a negative x (Sublime Text, Sequel Ace…)
    ///     and snap back to the left edge; their partly visible columns are parked instead.
    public static func place(_ frame: CGRect, display: CGRect, otherDisplays: [CGRect] = [],
                             peek: CGFloat = 1, allowLeftOverflow: Bool = true) -> CGRect {
        let crossesNeighbour = otherDisplays.contains { $0.intersects(frame) }
        let refusedOverflow = !allowLeftOverflow && frame.minX < display.minX
        if isVisible(frame, in: display) && !crossesNeighbour && !refusedOverflow { return frame }
        return park(size: frame.size, display: display, otherDisplays: otherDisplays, peek: peek)
    }

    /// macOS keeps a window's title bar on screen, so a window pushed below the bottom edge
    /// still shows up to about this much of its top. Used to keep that part off other displays.
    public static let titleBarAllowance: CGFloat = 150

    public static func park(size: CGSize, display: CGRect, otherDisplays: [CGRect], peek: CGFloat = 1) -> CGRect {
        let below = display.maxY - peek
        // Bottom corners leave a 1 px sliver; straight below (horizontally inside the display) is
        // the fallback when monitors sit on both sides: then the title bar shows at the bottom
        // of this display, never on another one.
        let xs = [display.maxX - peek, display.minX - size.width + peek,
                  display.minX + max(0, (display.width - size.width) / 2)]
        for x in xs {
            let reach = CGRect(x: x, y: display.maxY - titleBarAllowance,
                               width: size.width, height: size.height + titleBarAllowance)
            if !otherDisplays.contains(where: { $0.intersects(reach) }) {
                return CGRect(x: x, y: below, width: size.width, height: size.height)
            }
        }
        return CGRect(x: xs[2], y: below, width: size.width, height: size.height)
    }

    public static func isVisible(_ frame: CGRect, in screen: CGRect) -> Bool {
        frame.maxX > screen.minX && frame.minX < screen.maxX
    }

    public static func isParked(_ frame: CGRect, display: CGRect, peek: CGFloat = 1) -> Bool {
        let visible = frame.intersection(display)
        return visible.isNull || (visible.width <= peek + 0.5 || visible.height <= peek + 0.5)
    }
}

public enum DisplayAssignment {
    /// The display a window belongs to: the one showing most of it, else the nearest one.
    public static func bestDisplay(for frame: CGRect, displays: [CGRect]) -> Int? {
        guard !displays.isEmpty else { return nil }
        let areas = displays.map { d -> CGFloat in
            let i = d.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        func distance(_ d: CGRect) -> CGFloat {
            let dx = max(d.minX - center.x, 0, center.x - d.maxX)
            let dy = max(d.minY - center.y, 0, center.y - d.maxY)
            return dx * dx + dy * dy
        }
        return displays.indices.min { distance(displays[$0]) < distance(displays[$1]) }
    }
}
