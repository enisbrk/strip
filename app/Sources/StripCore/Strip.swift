import CoreGraphics

public typealias WindowID = UInt32

/// One column of the strip: a single window, or a stack of windows shown top to bottom
/// (or as tabs, one at a time).
public struct Column: Equatable, Sendable, Codable {
    /// Windows top to bottom (tab order when tabbed). Never empty.
    public private(set) var windows: [WindowID]
    /// Relative heights of the windows in a stack, same count as `windows`.
    public private(set) var weights: [CGFloat]
    /// The window of this column that has (or last had) focus.
    public private(set) var active: Int
    /// Show the stack as tabs: only the active window is visible, under a tab bar.
    public var tabbed: Bool
    /// Width as a fraction of the usable screen width (0 < width <= 1).
    public var width: CGFloat
    /// Width before "full width" was turned on, to go back to it.
    public var widthBeforeFull: CGFloat?
    /// A stack showing only its active window over the whole column (⌃⌥F on a stacked window).
    public var maximized: Bool = false
    /// Takes a whole screen of the strip with its windows centered and empty margins on both
    /// sides, so the next column never shows next to it.
    public var centered: Bool = false

    public init(windowID: WindowID, width: CGFloat) {
        windows = [windowID]
        weights = [1]
        active = 0
        tabbed = false
        self.width = Column.clamp(width)
    }

    private enum CodingKeys: String, CodingKey {
        case windows, weights, active, tabbed, width, widthBeforeFull, maximized, centered
    }

    public init(from decoder: Decoder) throws {
        // Lenient so sessions saved by older versions still restore.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windows = try c.decode([WindowID].self, forKey: .windows)
        weights = try c.decodeIfPresent([CGFloat].self, forKey: .weights) ?? Array(repeating: 1, count: windows.count)
        active = min(try c.decodeIfPresent(Int.self, forKey: .active) ?? 0, max(windows.count - 1, 0))
        tabbed = try c.decodeIfPresent(Bool.self, forKey: .tabbed) ?? false
        width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 0.5
        widthBeforeFull = try c.decodeIfPresent(CGFloat.self, forKey: .widthBeforeFull)
        maximized = try c.decodeIfPresent(Bool.self, forKey: .maximized) ?? false
        centered = try c.decodeIfPresent(Bool.self, forKey: .centered) ?? false
    }

    /// Share of the screen the column takes in the strip: a centered column takes a whole one.
    public var footprint: CGFloat { centered ? 1 : width }

    /// Only the active window is on screen (tabs, or a maximized stack); the others are parked.
    public var showsOnlyActive: Bool { isStack && (tabbed || maximized) }

    /// The active window (the only one for a plain column).
    public var windowID: WindowID { windows[active] }
    public var isStack: Bool { windows.count > 1 }

    public func contains(_ id: WindowID) -> Bool { windows.contains(id) }
    public func row(of id: WindowID) -> Int? { windows.firstIndex(of: id) }

    public static func clamp(_ w: CGFloat) -> CGFloat { min(max(w, 0.1), 1.0) }

    /// Heights of the rows as fractions summing to 1.
    public var heightFractions: [CGFloat] {
        let total = weights.reduce(0, +)
        return weights.map { total > 0 ? $0 / total : 1 / CGFloat(weights.count) }
    }

    mutating func append(_ id: WindowID, activate: Bool) {
        windows.append(id)
        // A new row gets an average share.
        weights.append(weights.reduce(0, +) / CGFloat(weights.count))
        if activate { active = windows.count - 1 }
    }

    /// Removes a window; returns false when it was the last one (the column should go).
    mutating func remove(_ id: WindowID) -> Bool {
        guard let r = row(of: id), windows.count > 1 else { return false }
        windows.remove(at: r)
        weights.remove(at: r)
        if r < active || active >= windows.count { active = max(active - 1, 0) }
        if windows.count == 1 {
            tabbed = false
            maximized = false
        }
        return true
    }

    mutating func activate(_ id: WindowID) {
        if let r = row(of: id) { active = r }
    }

    /// Adds a window at row `r`, with an average share of the height.
    mutating func insert(_ id: WindowID, at r: Int) {
        let r = min(max(r, 0), windows.count)
        windows.insert(id, at: r)
        weights.insert(weights.reduce(0, +) / CGFloat(weights.count), at: r)
        if r <= active { active += 1 }
    }

    /// Moves one of the column's windows to row `r` (counted without it), keeping its height share.
    mutating func moveRow(_ id: WindowID, to r: Int) {
        guard let from = row(of: id) else { return }
        let activeID = windowID
        let w = weights.remove(at: from)
        windows.remove(at: from)
        let r = min(max(r, 0), windows.count)
        windows.insert(id, at: r)
        weights.insert(w, at: r)
        active = row(of: activeID) ?? 0
    }

    mutating func moveActive(by delta: Int) -> Bool {
        let target = min(max(active + delta, 0), windows.count - 1)
        guard target != active else { return false }
        active = target
        return true
    }

    mutating func moveActiveRow(by delta: Int) {
        let target = min(max(active + delta, 0), windows.count - 1)
        guard target != active else { return }
        let id = windows.remove(at: active), w = weights.remove(at: active)
        windows.insert(id, at: target)
        weights.insert(w, at: target)
        active = target
    }

    /// Grows (or shrinks) the active row by `delta` of the column height, taking it from the others.
    mutating func adjustActiveHeight(by delta: CGFloat) {
        guard windows.count > 1 else { return }
        var f = heightFractions
        let minimum: CGFloat = 0.1
        let newActive = min(max(f[active] + delta, minimum), 1 - minimum * CGFloat(f.count - 1))
        let othersBefore = 1 - f[active], othersAfter = 1 - newActive
        for i in f.indices where i != active {
            f[i] = othersBefore > 0 ? f[i] / othersBefore * othersAfter : othersAfter / CGFloat(f.count - 1)
        }
        f[active] = newActive
        weights = f
    }

    /// Sets a row's height fraction directly (manual resize), redistributing the rest.
    mutating func setHeightFraction(_ fraction: CGFloat, for id: WindowID) {
        guard let r = row(of: id), windows.count > 1 else { return }
        let previous = active
        active = r
        adjustActiveHeight(by: fraction - heightFractions[r])
        active = previous
    }

    mutating func equalizeHeights() {
        weights = Array(repeating: 1, count: windows.count)
    }
}

/// Where a dragged window would land: next to (edge -1 / +1) or onto (nil) the column holding `windowID`.
public struct StripDrop: Equatable, Sendable {
    public let windowID: WindowID
    public let edge: Int?
    /// Into the column, right above (-1) or below (+1) `windowID`; nil: at the bottom.
    public let row: Int?
    /// With `edge`: on a screen of its own (full width) before / after that column.
    public let newScreen: Bool

    public init(windowID: WindowID, edge: Int?, row: Int? = nil, newScreen: Bool = false) {
        self.windowID = windowID
        self.edge = edge
        self.row = row
        self.newScreen = newScreen
    }
}

/// The horizontal strip of columns. Pure model: knows nothing about AppKit or Accessibility.
public struct Strip: Equatable, Sendable, Codable {
    public private(set) var columns: [Column] = []
    public private(set) var focusedIndex: Int?
    /// Strip x-coordinate that is aligned with the left edge of the usable area.
    public var viewportOffset: CGFloat = 0

    public init() {}

    public var focusedWindowID: WindowID? {
        focusedIndex.map { columns[$0].windowID }
    }

    public var focusedColumn: Column? {
        focusedIndex.map { columns[$0] }
    }

    /// Every window in the strip, column by column.
    public var allWindows: [WindowID] { columns.flatMap(\.windows) }

    /// Index of the column holding `id`.
    public func index(of id: WindowID) -> Int? {
        columns.firstIndex { $0.contains(id) }
    }

    public func contains(_ id: WindowID) -> Bool { index(of: id) != nil }

    /// Inserts a new column right after the focused one (or at the end when nothing is focused).
    public mutating func insert(_ id: WindowID, width: CGFloat, focus: Bool) {
        guard !contains(id) else { return }
        let at = focusedIndex.map { $0 + 1 } ?? columns.count
        columns.insert(Column(windowID: id, width: width), at: at)
        if focus || focusedIndex == nil {
            focusedIndex = at
        }
    }

    /// Inserts a new column at a fixed position (an app rule's "first" / "last").
    public mutating func insert(_ id: WindowID, width: CGFloat, at index: Int, focus: Bool) {
        guard !contains(id) else { return }
        let at = min(max(index, 0), columns.count)
        let focused = focusedWindowID
        columns.insert(Column(windowID: id, width: width), at: at)
        if focus || focused == nil {
            focusedIndex = at
        } else if let focused {
            self.focus(focused)
        }
    }

    /// Appends at the end without changing focus (used for the initial scan).
    public mutating func append(_ id: WindowID, width: CGFloat) {
        guard !contains(id) else { return }
        columns.append(Column(windowID: id, width: width))
        if focusedIndex == nil { focusedIndex = columns.count - 1 }
    }

    /// Appends a whole column (used when restoring a saved session or moving between displays).
    public mutating func append(_ column: Column) {
        let fresh = column.windows.filter { !contains($0) }
        guard !fresh.isEmpty else { return }
        var c = column
        for id in column.windows where !fresh.contains(id) { _ = c.remove(id) }
        columns.append(c)
        if focusedIndex == nil { focusedIndex = columns.count - 1 }
    }

    /// Removes a window. Returns the column it was the last window of, if that column went away.
    @discardableResult
    public mutating func remove(_ id: WindowID) -> Column? {
        guard let i = index(of: id) else { return nil }
        if columns[i].remove(id) { return nil }
        return removeColumn(at: i)
    }

    /// Removes and returns the whole column holding `id` (all of its windows).
    public mutating func removeColumn(containing id: WindowID) -> Column? {
        index(of: id).map { removeColumn(at: $0) }
    }

    private mutating func removeColumn(at i: Int) -> Column {
        let removed = columns.remove(at: i)
        if columns.isEmpty {
            focusedIndex = nil
        } else if let f = focusedIndex {
            // Removing the focused column moves focus to its left neighbour (niri behaviour).
            if i < f || (i == f && f > 0) { focusedIndex = f - 1 }
            focusedIndex = min(focusedIndex!, columns.count - 1)
        }
        return removed
    }

    public mutating func focus(_ id: WindowID) {
        guard let i = index(of: id) else { return }
        focusedIndex = i
        columns[i].activate(id)
    }

    public mutating func focus(index: Int) {
        guard !columns.isEmpty else { return }
        focusedIndex = min(max(index, 0), columns.count - 1)
    }

    /// Moves focus by `delta` columns. Returns the newly focused window, if it changed.
    @discardableResult
    public mutating func moveFocus(by delta: Int) -> WindowID? {
        guard let f = focusedIndex else { return nil }
        let target = min(max(f + delta, 0), columns.count - 1)
        guard target != f else { return nil }
        focusedIndex = target
        return columns[target].windowID
    }

    /// Moves focus up / down inside the focused stack (switches tab when tabbed).
    @discardableResult
    public mutating func moveFocusInColumn(by delta: Int) -> WindowID? {
        guard let f = focusedIndex, columns[f].moveActive(by: delta) else { return nil }
        return columns[f].windowID
    }

    /// Moves the focused column by `delta` positions, keeping it focused.
    public mutating func moveFocusedColumn(by delta: Int) {
        guard let f = focusedIndex else { return }
        let target = min(max(f + delta, 0), columns.count - 1)
        guard target != f else { return }
        let col = columns.remove(at: f)
        columns.insert(col, at: target)
        focusedIndex = target
    }

    /// Moves the focused window up / down inside its stack.
    public mutating func moveFocusedWindowInColumn(by delta: Int) {
        guard let f = focusedIndex else { return }
        columns[f].moveActiveRow(by: delta)
    }

    /// Moves a window to column position `target` (drag-to-reorder). A window dragged out of a
    /// stack becomes its own column there; a plain column just moves.
    public mutating func move(_ id: WindowID, to target: Int) {
        guard let i = index(of: id) else { return }
        let focused = focusedWindowID
        let column: Column
        if columns[i].isStack {
            _ = columns[i].remove(id)
            column = Column(windowID: id, width: columns[i].width)
        } else {
            column = columns.remove(at: i)
        }
        columns.insert(column, at: min(max(target, 0), columns.count))
        if let focused { focus(focused) }
    }

    /// Moves a window just before / after the column at `target` (`target` counts the strip as it is now).
    public mutating func move(_ id: WindowID, beside target: Int, after: Bool) {
        guard let from = index(of: id) else { return }
        var index = target + (after ? 1 : 0)
        if from < index && !columns[from].isStack { index -= 1 }
        move(id, to: index)
    }

    /// Swaps the column holding `id` with the one at `target`, keeping focus on the same window.
    public mutating func swap(_ id: WindowID, withIndex target: Int) {
        guard let i = index(of: id), columns.indices.contains(target), i != target else { return }
        let focused = focusedWindowID
        columns.swapAt(i, target)
        if let focused { focus(focused) }
    }

    // MARK: Minimize and restore

    /// Where a window sat, to put it back there later (after minimizing it).
    public struct Place: Equatable, Sendable {
        /// A window of the column before / after it; nil at that end of the strip.
        public let after: WindowID?
        public let before: WindowID?
        public let width: CGFloat
        public let centered: Bool
        /// It shared its screen (a stack, or columns side by side).
        public let shared: Bool
    }

    public func place(of id: WindowID) -> Place? {
        guard let i = index(of: id) else { return nil }
        let c = columns[i]
        let group = screenGroups().first { $0.contains(i) }
        return Place(after: i > 0 ? columns[i - 1].windows[0] : nil,
                     before: i + 1 < columns.count ? columns[i + 1].windows[0] : nil,
                     width: c.width, centered: c.centered,
                     shared: c.isStack || (group?.count ?? 1) > 1)
    }

    /// Puts a window back where it was: between the same neighbours, as wide and centered as it
    /// was. A window that shared its screen comes back on a screen of its own. When neither
    /// neighbour is still here it opens next to the focused column.
    public mutating func restore(_ id: WindowID, at place: Place, focus: Bool) {
        guard !contains(id) else { return }
        let width = place.shared ? 1 : place.width
        if let a = place.after, let i = index(of: a) {
            insert(id, width: width, at: i + 1, focus: focus)
        } else if let b = place.before, let i = index(of: b) {
            insert(id, width: width, at: i, focus: focus)
        } else if place.after == nil, place.before != nil || columns.isEmpty {
            insert(id, width: width, at: 0, focus: focus)
        } else {
            insert(id, width: width, focus: focus)
        }
        if place.centered && !place.shared, let i = index(of: id) { columns[i].centered = true }
    }

    // MARK: Drag and drop

    /// Drops `id` on a column (`target`): beside it on an edge, else stacked into it or sharing
    /// its screen. The overviews preview a drag by applying this to a copy of the strip.
    public mutating func drop(_ id: WindowID, on target: StripDrop, share: Bool) {
        guard let t = index(of: target.windowID) else { return }
        if let edge = target.edge {
            move(id, beside: t, after: edge > 0)
            if target.newScreen, let i = index(of: id) {
                columns[i].width = 1
                columns[i].centered = false
            }
        } else if let row = target.row {
            insert(id, nextTo: target.windowID, below: row > 0)
        } else if share {
            self.share(id, with: target.windowID)
        } else {
            stack(id, onto: target.windowID)
        }
    }

    // MARK: Sharing a screen

    /// Columns grouped into screens from the left: each group fills at most one screen width.
    public func screenGroups() -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var i = 0
        while i < columns.count {
            var j = i, width: CGFloat = 0
            while j < columns.count, j == i || width + columns[j].footprint <= 1.01 {
                width += columns[j].footprint
                j += 1
            }
            groups.append(i..<j)
            i = j
        }
        return groups
    }

    /// Drops `id` onto `targetID` (drag and drop): the two share the target's screen. One window
    /// becomes two halves, two become a half and two quarters, three become four quarters; a full
    /// screen gets `id` as a new full-width screen right after it.
    public mutating func share(_ id: WindowID, with targetID: WindowID) {
        guard id != targetID, contains(id), let source = index(of: targetID), !columns[source].contains(id) else { return }
        _ = remove(id)
        guard let t = index(of: targetID), let group = screenGroups().first(where: { $0.contains(t) }) else { return }
        // A column that can take one more window as a quarter: a plain window not sharing a stack.
        func stackable(_ i: Int) -> Bool { !columns[i].isStack && !columns[i].tabbed }
        func isPair(_ i: Int) -> Bool { columns[i].isStack && !columns[i].tabbed && columns[i].windows.count == 2 }

        if group.count == 1, stackable(t) || isPair(t) {
            // Alone on its screen: side by side, half each.
            columns[t].width = 0.5
            columns[t].centered = false
            columns.insert(Column(windowID: id, width: 0.5), at: t + 1)
        } else if group.count == 2 {
            let other = t == group.lowerBound ? group.upperBound - 1 : group.lowerBound
            let into: Int?
            switch (stackable(t), stackable(other)) {
            case (true, _): into = t
            case (false, true) where isPair(t): into = other
            default: into = nil
            }
            if let into {
                columns[into].append(id, activate: true)
                columns[into].equalizeHeights()
                columns[t].width = 0.5
                columns[other].width = 0.5
            } else {
                columns.insert(Column(windowID: id, width: 1), at: group.upperBound)
            }
        } else {
            columns.insert(Column(windowID: id, width: 1), at: group.upperBound)
        }
        focus(id)
    }

    // MARK: Stacks

    /// Puts the focused window at the bottom of the neighbouring column (`direction` -1 left, +1 right).
    public mutating func stackFocused(direction: Int) {
        guard let f = focusedIndex else { return }
        let target = f + (direction < 0 ? -1 : 1)
        guard columns.indices.contains(target) else { return }
        let id = columns[f].windowID
        let targetID = columns[target].windowID
        _ = remove(id)
        guard let t = index(of: targetID) else { return }
        columns[t].append(id, activate: true)
        focusedIndex = t
    }

    /// Puts `id` at the bottom of the column holding `targetID`, keeping focus where it was.
    public mutating func stack(_ id: WindowID, onto targetID: WindowID) {
        guard let from = index(of: id), let to = index(of: targetID), from != to else { return }
        let focused = focusedWindowID
        _ = remove(id)
        guard let t = index(of: targetID) else { return }
        columns[t].append(id, activate: false)
        if let focused { focus(focused) }
    }

    /// Puts `id` into the column holding `rowID`, right above or below it (reorders a stack when
    /// both are in the same one). Focus stays where it was.
    public mutating func insert(_ id: WindowID, nextTo rowID: WindowID, below: Bool) {
        guard id != rowID, let from = index(of: id), let t = index(of: rowID) else { return }
        let focused = focusedWindowID
        if from == t {
            guard let r = columns[t].row(of: rowID), let own = columns[t].row(of: id) else { return }
            var to = r + (below ? 1 : 0)
            if own < to { to -= 1 }
            columns[t].moveRow(id, to: to)
        } else {
            _ = remove(id)
            guard let t = index(of: rowID), let r = columns[t].row(of: rowID) else { return }
            columns[t].insert(id, at: r + (below ? 1 : 0))
        }
        if let focused { focus(focused) }
    }

    /// Takes the focused window out of its stack into a new column to the left / right.
    public mutating func popOutFocused(direction: Int) {
        guard let f = focusedIndex, columns[f].isStack else { return }
        let id = columns[f].windowID
        let width = columns[f].width
        _ = columns[f].remove(id)
        let at = direction < 0 ? f : f + 1
        columns.insert(Column(windowID: id, width: width), at: at)
        focusedIndex = at
    }

    public mutating func toggleFocusedTabbed() {
        guard let f = focusedIndex, columns[f].isStack else { return }
        columns[f].tabbed.toggle()
    }

    /// Turns a stack into columns side by side that share its width.
    public mutating func unstack(containing id: WindowID) {
        guard let i = index(of: id), columns[i].isStack else { return }
        let focused = focusedWindowID
        let stack = columns.remove(at: i)
        let width = Column.clamp(stack.width / CGFloat(stack.windows.count))
        for (k, window) in stack.windows.enumerated() {
            columns.insert(Column(windowID: window, width: width), at: i + k)
        }
        if let focused { focus(focused) }
    }

    public mutating func toggleTabbed(containing id: WindowID) {
        guard let i = index(of: id), columns[i].isStack else { return }
        columns[i].tabbed.toggle()
    }

    public mutating func adjustFocusedHeight(by delta: CGFloat) {
        guard let f = focusedIndex else { return }
        columns[f].adjustActiveHeight(by: delta)
    }

    public mutating func setHeightFraction(_ fraction: CGFloat, for id: WindowID) {
        guard let i = index(of: id) else { return }
        columns[i].setHeightFraction(fraction, for: id)
    }

    public mutating func equalizeFocusedHeights() {
        guard let f = focusedIndex else { return }
        columns[f].equalizeHeights()
    }

    /// Activates a tab / row without moving column focus (clicking a tab).
    public mutating func activate(_ id: WindowID) {
        guard let i = index(of: id) else { return }
        columns[i].activate(id)
    }

    // MARK: Widths

    public mutating func setWidth(_ width: CGFloat, for id: WindowID) {
        guard let i = index(of: id) else { return }
        columns[i].width = Column.clamp(width)
    }

    /// Cycles the focused column through `presets`: picks the first preset larger than the current width.
    public mutating func cycleFocusedWidth(presets: [CGFloat]) {
        guard let f = focusedIndex, !presets.isEmpty else { return }
        let sorted = presets.sorted()
        let current = columns[f].width
        let next = sorted.first { $0 > current + 0.01 } ?? sorted[0]
        columns[f].width = Column.clamp(next)
    }

    /// Full width on / off: the second press restores the width the column had before. On a stack
    /// the focused window also takes the whole height (the rest of the stack steps aside) so it
    /// covers the screen.
    public mutating func toggleFocusedFullWidth() {
        guard let f = focusedIndex else { return }
        let isFull = columns[f].width >= 0.999 && (!columns[f].isStack || columns[f].maximized)
        if isFull {
            columns[f].width = columns[f].widthBeforeFull ?? (columns[f].maximized ? columns[f].width : 0.5)
            columns[f].widthBeforeFull = nil
            columns[f].maximized = false
        } else {
            if columns[f].widthBeforeFull == nil { columns[f].widthBeforeFull = columns[f].width }
            columns[f].width = 1
            columns[f].maximized = columns[f].isStack
        }
    }

    /// Centers the focused column on a screen of its own, with empty margins (or back to normal).
    public mutating func toggleFocusedCentered() {
        guard let f = focusedIndex else { return }
        toggleCentered(at: f)
    }

    public mutating func toggleCentered(containing id: WindowID) {
        guard let i = index(of: id) else { return }
        toggleCentered(at: i)
    }

    private mutating func toggleCentered(at i: Int) {
        columns[i].centered.toggle()
        // Centering a full-width column would leave no margins: start from half the screen.
        if columns[i].centered && columns[i].width >= 0.999 && !columns[i].maximized { columns[i].width = 0.5 }
    }

    public mutating func adjustFocusedWidth(by delta: CGFloat) {
        guard let f = focusedIndex else { return }
        columns[f].width = Column.clamp(columns[f].width + delta)
    }

    // MARK: Session restore

    /// Reorders the strip to follow a saved one: saved columns (with their stacks, widths and tabs)
    /// come first, in saved order, keeping only windows that are still here; the rest follow.
    public mutating func restore(from saved: Strip) {
        let present = Set(allWindows)
        var rebuilt = Strip()
        for column in saved.columns where column.windows.contains(where: present.contains) {
            var c = column
            // Safe: at least one window of the column is still present, so it never empties.
            for id in column.windows where !present.contains(id) { _ = c.remove(id) }
            rebuilt.append(c)
        }
        for column in columns {
            for id in column.windows where !rebuilt.contains(id) {
                rebuilt.append(id, width: column.width)
            }
        }
        let focused = saved.focusedWindowID.flatMap { rebuilt.contains($0) ? $0 : nil } ?? focusedWindowID
        rebuilt.viewportOffset = saved.viewportOffset
        if let focused { rebuilt.focus(focused) }
        self = rebuilt
    }
}
