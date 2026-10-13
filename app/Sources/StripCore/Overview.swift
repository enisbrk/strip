import CoreGraphics

/// One window of a column in the overview: the rows of a stack, or the visible tab.
public struct OverviewRow: Equatable, Sendable {
    public let windowID: WindowID
    public let rect: CGRect
    /// The column's active window (the visible tab, or the focused row of a stack).
    public let isActive: Bool
}

/// A drop target in the drag overview: a slot (grid presets) or a column (strip).
public struct OverviewTarget: Equatable, Sendable {
    /// Strip index the dragged window should end up at.
    public let index: Int
    /// Rect inside the overview panel (top-left origin).
    public let rect: CGRect
    /// Window currently there (the active one of a stack); nil for an empty slot on a partly
    /// filled last page.
    public let windowID: WindowID?
    /// How the column is split: one row per window of a stack, or one row under a tab bar.
    public var rows: [OverviewRow] = []
    /// Number of tabs when the column is tabbed (0 otherwise).
    public var tabCount: Int = 0
    /// Tab bar strip at the top of a tabbed column.
    public var tabBar: CGRect?

    init(index: Int, rect: CGRect, column: Column?) {
        self.index = index
        self.rect = rect
        windowID = column?.windowID
        guard let column else { return }
        if column.maximized && column.isStack {
            rows = [OverviewRow(windowID: column.windowID, rect: rect, isActive: true)]
        } else if column.tabbed {
            let bar = max(2, (rect.height * 0.12).rounded())
            tabBar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bar)
            tabCount = column.windows.count
            rows = [OverviewRow(windowID: column.windowID,
                                rect: CGRect(x: rect.minX, y: rect.minY + bar + 1, width: rect.width,
                                             height: rect.height - bar - 1),
                                isActive: true)]
        } else {
            let gap = column.isStack ? max(1, (rect.height * 0.03).rounded()) : 0
            let available = rect.height - gap * CGFloat(column.windows.count - 1)
            var y = rect.minY
            for (i, (id, fraction)) in zip(column.windows, column.heightFractions).enumerated() {
                let h = i == column.windows.count - 1 ? rect.maxY - y : available * fraction
                rows.append(OverviewRow(windowID: id, rect: CGRect(x: rect.minX, y: y, width: rect.width, height: h),
                                        isActive: id == column.windowID))
                y += h + gap
            }
        }
    }

    private init(index: Int, rect: CGRect, windowID: WindowID?, rows: [OverviewRow], tabCount: Int, tabBar: CGRect?) {
        self.index = index
        self.rect = rect
        self.windowID = windowID
        self.rows = rows
        self.tabCount = tabCount
        self.tabBar = tabBar
    }

    func scaled(by s: CGFloat) -> OverviewTarget {
        func scale(_ r: CGRect) -> CGRect { CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s) }
        return OverviewTarget(index: index, rect: scale(rect), windowID: windowID,
                              rows: rows.map { OverviewRow(windowID: $0.windowID, rect: scale($0.rect), isActive: $0.isActive) },
                              tabCount: tabCount, tabBar: tabBar.map(scale))
    }
}

/// Geometry of the miniature "all screens" panel shown while dragging a window.
/// Pure layout so the drawing and the hit testing always agree.
public struct Overview: Equatable, Sendable {
    public var size: CGSize
    /// Each miniature screen with its label ("Ekran 1"…); empty in strip mode.
    public var pages: [CGRect]
    /// Strip mode: the part of the strip currently on screen.
    public var viewport: CGRect?
    public var targets: [OverviewTarget]

    public static let empty = Overview(size: .zero, pages: [], viewport: nil, targets: [])

    public static let padding: CGFloat = 20
    public static let spacing: CGFloat = 16
    public static let labelHeight: CGFloat = 20
    static let maxPageWidth: CGFloat = 300
    static let minPageWidth: CGFloat = 140

    public func target(at point: CGPoint) -> OverviewTarget? {
        targets.first { $0.rect.contains(point) }
    }

    /// - Parameter compact: no outer padding and no page labels (for the minimap).
    public static func make(strip: Strip, preset: LayoutPreset, engine: LayoutEngine, maxSize: CGSize,
                            compact: Bool = false) -> Overview {
        let padding = compact ? 3 : Self.padding
        let labelHeight = compact ? 0 : Self.labelHeight
        return preset == .strip
            ? stripOverview(strip: strip, engine: engine, maxSize: maxSize, padding: padding, labelHeight: labelHeight)
            : presetOverview(strip: strip, preset: preset, engine: engine, maxSize: maxSize,
                             padding: padding, labelHeight: labelHeight)
    }

    public func scaled(by s: CGFloat) -> Overview {
        func scale(_ r: CGRect) -> CGRect { CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s) }
        return Overview(size: CGSize(width: size.width * s, height: size.height * s), pages: pages.map(scale),
                        viewport: viewport.map(scale),
                        targets: targets.map { $0.scaled(by: s) })
    }

    private static func presetOverview(strip: Strip, preset: LayoutPreset, engine: LayoutEngine,
                                       maxSize: CGSize, padding: CGFloat, labelHeight: CGFloat) -> Overview {
        let n = preset.slots.count
        let count = strip.columns.count
        let pageCount = max(1, (count + n - 1) / n)
        let aspect = engine.area.width / max(engine.area.height, 1)
        let available = maxSize.width - 2 * padding

        let perRow = max(1, min(pageCount, Int((available + spacing) / (minPageWidth + spacing))))
        let pageWidth = min(maxPageWidth, (available - spacing * CGFloat(perRow - 1)) / CGFloat(perRow)).rounded()
        let pageHeight = (pageWidth / aspect).rounded()
        let rows = (pageCount + perRow - 1) / perRow

        var pages: [CGRect] = []
        var targets: [OverviewTarget] = []
        for page in 0..<pageCount {
            let row = page / perRow, col = page % perRow
            let x = padding + CGFloat(col) * (pageWidth + spacing)
            let y = padding + CGFloat(row) * (labelHeight + pageHeight + spacing) + labelHeight
            let pageRect = CGRect(x: x, y: y, width: pageWidth, height: pageHeight)
            pages.append(pageRect)
            let inner = pageRect.insetBy(dx: 4, dy: 4)
            for (s, u) in preset.slots.enumerated() {
                let index = page * n + s
                let rect = CGRect(x: inner.minX + u.minX * inner.width, y: inner.minY + u.minY * inner.height,
                                  width: u.width * inner.width, height: u.height * inner.height)
                    .insetBy(dx: 1.5, dy: 1.5)
                targets.append(OverviewTarget(index: index, rect: rect,
                                              column: index < count ? strip.columns[index] : nil))
            }
        }
        let width = 2 * padding + CGFloat(perRow) * pageWidth + CGFloat(perRow - 1) * spacing
        let height = 2 * padding + CGFloat(rows) * (labelHeight + pageHeight) + CGFloat(rows - 1) * spacing
        return Overview(size: CGSize(width: width, height: height), pages: pages, viewport: nil, targets: targets)
    }

    private static func stripOverview(strip: Strip, engine: LayoutEngine, maxSize: CGSize,
                                      padding: CGFloat, labelHeight: CGFloat) -> Overview {
        let area = engine.area
        let total = max(engine.totalWidth(strip), area.width)
        let available = maxSize.width - 2 * padding
        let scale = min(maxPageWidth / area.width, available / total)
        let top = padding + labelHeight
        let height = (area.height * scale).rounded()

        let targets = zip(strip.columns, engine.columnOrigins(strip)).enumerated().map { i, pair in
            OverviewTarget(
                index: i,
                rect: CGRect(x: padding + (pair.1 + engine.inset(of: pair.0)) * scale, y: top,
                             width: engine.pixelWidth(of: pair.0) * scale, height: height).insetBy(dx: 1, dy: 0),
                column: pair.0
            )
        }
        let viewport = CGRect(x: padding + strip.viewportOffset * scale, y: top,
                              width: area.width * scale, height: height).insetBy(dx: -3, dy: -3)
        return Overview(size: CGSize(width: 2 * padding + total * scale, height: top + height + padding),
                        pages: [], viewport: viewport, targets: targets)
    }
}
