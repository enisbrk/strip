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

    public init(windowID: WindowID, width: CGFloat) {
        windows = [windowID]
        weights = [1]
        active = 0
        tabbed = false
        self.width = Column.clamp(width)
    }

    private enum CodingKeys: String, CodingKey {
        case windows, weights, active, tabbed, width, widthBeforeFull, maximized
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
    }

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

    /// Swaps the column holding `id` with the one at `target`, keeping focus on the same window.
    public mutating func swap(_ id: WindowID, withIndex target: Int) {
        guard let i = index(of: id), columns.indices.contains(target), i != target else { return }
        let focused = focusedWindowID
        columns.swapAt(i, target)
        if let focused { focus(focused) }
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
