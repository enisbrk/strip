import CoreGraphics
import XCTest
@testable import StripCore

final class StripTests: XCTestCase {
    func testInsertGoesAfterFocused() {
        var s = Strip()
        s.insert(1, width: 0.5, focus: true)
        s.insert(2, width: 0.5, focus: true)
        s.focus(1)
        s.insert(3, width: 0.5, focus: true)
        XCTAssertEqual(s.columns.map(\.windowID), [1, 3, 2])
        XCTAssertEqual(s.focusedWindowID, 3)
    }

    func testBackgroundInsertKeepsFocus() {
        var s = Strip()
        s.insert(1, width: 0.5, focus: true)
        s.insert(2, width: 0.5, focus: false)
        XCTAssertEqual(s.focusedWindowID, 1)
        XCTAssertEqual(s.columns.map(\.windowID), [1, 2])
    }

    func testRemoveFocusedMovesLeft() {
        var s = Strip()
        [1, 2, 3].forEach { s.append($0, width: 0.5) }
        s.focus(2)
        s.remove(2)
        XCTAssertEqual(s.focusedWindowID, 1)
        s.focus(1)
        s.remove(1)
        XCTAssertEqual(s.focusedWindowID, 3)
        s.remove(3)
        XCTAssertNil(s.focusedIndex)
    }

    func testRemoveLeftOfFocusKeepsSameWindowFocused() {
        var s = Strip()
        [1, 2, 3].forEach { s.append($0, width: 0.5) }
        s.focus(3)
        s.remove(1)
        XCTAssertEqual(s.focusedWindowID, 3)
    }

    func testMoveFocusedColumn() {
        var s = Strip()
        [1, 2, 3].forEach { s.append($0, width: 0.5) }
        s.focus(1)
        s.moveFocusedColumn(by: 1)
        XCTAssertEqual(s.columns.map(\.windowID), [2, 1, 3])
        s.moveFocusedColumn(by: 5)
        XCTAssertEqual(s.columns.map(\.windowID), [2, 3, 1])
        XCTAssertEqual(s.focusedWindowID, 1)
    }

    func testDragMoveKeepsFocus() {
        var s = Strip()
        [1, 2, 3].forEach { s.append($0, width: 0.5) }
        s.focus(2)
        s.move(3, to: 0)
        XCTAssertEqual(s.columns.map(\.windowID), [3, 1, 2])
        XCTAssertEqual(s.focusedWindowID, 2)
    }

    func testFullWidthToggles() {
        var s = Strip()
        s.append(1, width: 1.0 / 3.0)
        s.toggleFocusedFullWidth()
        XCTAssertEqual(s.columns[0].width, 1)
        s.toggleFocusedFullWidth()
        XCTAssertEqual(s.columns[0].width, 1.0 / 3.0, accuracy: 0.001)
    }

    func testCycleWidth() {
        var s = Strip()
        s.append(1, width: 0.5)
        let presets: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0]
        s.cycleFocusedWidth(presets: presets)
        XCTAssertEqual(s.columns[0].width, 2.0 / 3.0, accuracy: 0.001)
        s.cycleFocusedWidth(presets: presets)
        XCTAssertEqual(s.columns[0].width, 1.0, accuracy: 0.001)
        s.cycleFocusedWidth(presets: presets)
        XCTAssertEqual(s.columns[0].width, 1.0 / 3.0, accuracy: 0.001)
    }
}

final class LayoutEngineTests: XCTestCase {
    let area = CGRect(x: 10, y: 30, width: 1000, height: 700)

    func strip(_ widths: [CGFloat], focus: Int) -> Strip {
        var s = Strip()
        for (i, w) in widths.enumerated() { s.append(WindowID(i + 1), width: w) }
        s.focus(index: focus)
        return s
    }

    func testFramesNoOverlapWithGaps() {
        let e = LayoutEngine(area: area, innerGap: 10, centerMode: .never)
        let s = strip([0.5, 0.5, 0.3], focus: 0)
        let f = e.frames(for: s, offset: 0)
        XCTAssertEqual(f[1], CGRect(x: 10, y: 30, width: 495, height: 700))
        XCTAssertEqual(f[2], CGRect(x: 515, y: 30, width: 495, height: 700))
        XCTAssertEqual(f[3], CGRect(x: 1020, y: 30, width: 293, height: 700))
    }

    func testNeverModeScrollsMinimally() {
        let e = LayoutEngine(area: area, innerGap: 10, centerMode: .never)
        var s = strip([0.5, 0.5, 0.5, 0.5], focus: 2)
        // Column 2 spans 1010...1505 → right edge must align with viewport right edge.
        XCTAssertEqual(e.targetOffset(for: s), 505)
        s.viewportOffset = 505
        s.focus(index: 1) // spans 505...1000, already visible → no scroll
        XCTAssertEqual(e.targetOffset(for: s), 505)
        s.focus(index: 0)
        XCTAssertEqual(e.targetOffset(for: s), 0)
    }

    func testNeverModeNoScrollWhenFits() {
        let e = LayoutEngine(area: area, innerGap: 10, centerMode: .never)
        let s = strip([0.4, 0.4], focus: 1)
        XCTAssertEqual(e.targetOffset(for: s), 0)
    }

    func testAlwaysCenters() {
        let e = LayoutEngine(area: area, innerGap: 10, centerMode: .always)
        let s = strip([0.5, 0.5, 0.5], focus: 1)
        // Column 1 spans 505...1000, center 752.5 → offset 252.5
        XCTAssertEqual(e.targetOffset(for: s), 252.5)
    }

    func testOnOverflowOnlyCentersWhenOverflowing() {
        let e = LayoutEngine(area: area, innerGap: 10, centerMode: .onOverflow)
        XCTAssertEqual(e.targetOffset(for: strip([0.4, 0.4], focus: 1)), 0)
        XCTAssertEqual(e.targetOffset(for: strip([0.5, 0.5, 0.5], focus: 1)), 252.5)
    }

    func testColumnIndexAtX() {
        let e = LayoutEngine(area: area, innerGap: 10, centerMode: .never)
        let s = strip([0.5, 0.5, 0.5], focus: 0)
        XCTAssertEqual(e.columnIndex(atScreenX: 100, strip: s, offset: 0), 0)
        XCTAssertEqual(e.columnIndex(atScreenX: 600, strip: s, offset: 0), 1)
        XCTAssertEqual(e.columnIndex(atScreenX: 600, strip: s, offset: 520), 2)
    }

    func testOffscreenParkingSingleDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let off = OffscreenPlacer.place(CGRect(x: -900, y: 0, width: 400, height: 800), display: screen)
        XCTAssertEqual(off.origin, CGPoint(x: 999, y: 799)) // bottom-right corner, 1 px showing
        XCTAssertEqual(off.size, CGSize(width: 400, height: 800))
        let partial = CGRect(x: 800, y: 0, width: 400, height: 800)
        XCTAssertEqual(OffscreenPlacer.place(partial, display: screen), partial)
        XCTAssertTrue(OffscreenPlacer.isParked(off, display: screen))
        XCTAssertFalse(OffscreenPlacer.isParked(partial, display: screen))
    }

    func testParkingNeverShowsOnANeighbourDisplay() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1200, height: 900)
        // A column sliding off the left display towards the right one is parked, not shown there.
        let sliding = CGRect(x: 900, y: 0, width: 400, height: 800)
        let placed = OffscreenPlacer.place(sliding, display: left, otherDisplays: [right])
        XCTAssertFalse(placed.intersects(right))
        // The right display's bottom-right corner is free; the left one's isn't (neighbour on the right).
        XCTAssertEqual(placed.origin, CGPoint(x: -399, y: 799))
        let parkedRight = OffscreenPlacer.park(size: CGSize(width: 400, height: 800), display: right,
                                               otherDisplays: [left])
        XCTAssertEqual(parkedRight.origin, CGPoint(x: 2199, y: 899))
    }

    func testParkingWithDisplaysOnBothSides() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let others = [CGRect(x: -1000, y: 0, width: 1000, height: 800),
                      CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        let p = OffscreenPlacer.park(size: CGSize(width: 400, height: 800), display: main, otherDisplays: others)
        // Left and right are taken, so it hides straight below — whatever macOS keeps visible
        // of its title bar stays on this display.
        XCTAssertEqual(p.minX, 300)
        let titleBar = CGRect(x: p.minX, y: p.minY - OffscreenPlacer.titleBarAllowance, width: p.width, height: 200)
        XCTAssertFalse(others.contains { $0.intersects(titleBar) })
    }

    func testRefusedLeftOverflowIsParked() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let partialLeft = CGRect(x: -200, y: 0, width: 400, height: 800)
        XCTAssertEqual(OffscreenPlacer.place(partialLeft, display: screen), partialLeft)
        XCTAssertTrue(OffscreenPlacer.isParked(
            OffscreenPlacer.place(partialLeft, display: screen, allowLeftOverflow: false), display: screen))
    }

    func testBestDisplay() {
        let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        XCTAssertEqual(DisplayAssignment.bestDisplay(for: CGRect(x: 900, y: 0, width: 400, height: 400), displays: displays), 1)
        XCTAssertEqual(DisplayAssignment.bestDisplay(for: CGRect(x: 100, y: 0, width: 400, height: 400), displays: displays), 0)
        // Completely off screen: nearest display.
        XCTAssertEqual(DisplayAssignment.bestDisplay(for: CGRect(x: 2500, y: 0, width: 100, height: 100), displays: displays), 1)
    }

    func testPresetSlotsWithGaps() {
        let e = LayoutEngine(area: area, innerGap: 10, centerMode: .never)
        let s = strip([0.5, 0.5, 0.5, 0.5], focus: 0)
        let f = e.presetFrames(for: s, preset: .grid2x2, offset: 0)
        XCTAssertEqual(f[1], CGRect(x: 10, y: 30, width: 495, height: 345))
        XCTAssertEqual(f[2], CGRect(x: 515, y: 30, width: 495, height: 345))
        XCTAssertEqual(f[3], CGRect(x: 10, y: 385, width: 495, height: 345))
        XCTAssertEqual(f[4], CGRect(x: 515, y: 385, width: 495, height: 345))
    }

    func testPresetPagesSitOneScreenApart() {
        let e = LayoutEngine(area: area, innerGap: 0, centerMode: .never)
        // 5 windows, pages of 2: focus on index 2 shows windows 3 and 4.
        var s = strip([0.5, 0.5, 0.5, 0.5, 0.5], focus: 2)
        let offset = e.presetOffset(for: s, preset: .twoColumns)
        XCTAssertEqual(offset, 1000)
        let f = e.presetFrames(for: s, preset: .twoColumns, offset: offset)
        XCTAssertEqual(f[3]?.minX, 10)
        XCTAssertEqual(f[4]?.minX, 510)
        XCTAssertLessThanOrEqual(f[1]!.maxX, area.minX)
        XCTAssertGreaterThanOrEqual(f[5]!.minX, area.maxX)
        // Half-way through the slide both pages are partly on screen.
        let mid = e.presetFrames(for: s, preset: .twoColumns, offset: 500)
        XCTAssertEqual(mid[2]?.minX, 10)
        XCTAssertEqual(mid[3]?.minX, 510)
        s.focus(index: 4)
        XCTAssertEqual(e.presetOffset(for: s, preset: .twoColumns), 2000)
    }

    func testPresetScreenStep() {
        let e = LayoutEngine(area: area, innerGap: 0, centerMode: .never)
        let s = strip([0.5, 0.5, 0.5, 0.5, 0.5], focus: 3)
        XCTAssertEqual(e.presetScreenStep(s, preset: .twoColumns, direction: 1), 4)
        XCTAssertEqual(e.presetScreenStep(s, preset: .twoColumns, direction: -1), 0)
        XCTAssertNil(e.presetScreenStep(s, preset: .grid2x2, direction: -1))
        XCTAssertEqual(e.presetScreenStep(s, preset: .grid2x2, direction: 1), 4)
        XCTAssertNil(e.presetScreenStep(s, preset: .full, direction: 5))
    }

    func testStripScreenStep() {
        let e = LayoutEngine(area: area, innerGap: 10, centerMode: .never)
        // Columns of 495 px at 0, 505, 1010, 1515 — exactly two per screen.
        var s = strip([0.5, 0.5, 0.5, 0.5], focus: 0)
        let next = e.screenStep(s, direction: 1)
        XCTAssertEqual(next?.index, 2)
        XCTAssertEqual(next?.offset, 1010)
        XCTAssertNil(e.screenStep(s, direction: -1))
        s.focus(index: 2)
        s.viewportOffset = 1010
        XCTAssertNil(e.screenStep(s, direction: 1))
        let prev = e.screenStep(s, direction: -1)
        XCTAssertEqual(prev?.index, 0)
        XCTAssertEqual(prev?.offset, 0)
    }

    func testPresetIndexAtPoint() {
        let e = LayoutEngine(area: area, innerGap: 0, centerMode: .never)
        let s = strip([0.5, 0.5, 0.5], focus: 0)
        XCTAssertEqual(e.presetIndex(at: CGPoint(x: 900, y: 600), strip: s, preset: .oneLeftTwoRight), 2)
        XCTAssertEqual(e.presetIndex(at: CGPoint(x: 100, y: 600), strip: s, preset: .oneLeftTwoRight), 0)
    }

    func testOverviewPresetHasPagesAndSlots() {
        let e = LayoutEngine(area: area, innerGap: 0, centerMode: .never)
        let s = strip([0.5, 0.5, 0.5, 0.5, 0.5], focus: 0)
        let o = Overview.make(strip: s, preset: .twoColumns, engine: e, maxSize: CGSize(width: 2000, height: 1000))
        // 5 windows in pages of 2 → 3 pages, the last one has a free slot.
        XCTAssertEqual(o.pages.count, 3)
        XCTAssertEqual(o.targets.count, 6)
        XCTAssertEqual(o.targets.map(\.windowID), [1, 2, 3, 4, 5, nil])
        // Every target lies inside its page and is hit-testable at its center.
        for t in o.targets {
            XCTAssertTrue(o.pages[t.index / 2].contains(t.rect))
            XCTAssertEqual(o.target(at: CGPoint(x: t.rect.midX, y: t.rect.midY))?.index, t.index)
        }
        XCTAssertLessThanOrEqual(o.size.width, 2000)
    }

    func testOverviewWrapsPagesIntoRows() {
        let e = LayoutEngine(area: area, innerGap: 0, centerMode: .never)
        let s = strip(Array(repeating: 1, count: 9), focus: 0)
        let o = Overview.make(strip: s, preset: .full, engine: e, maxSize: CGSize(width: 700, height: 1000))
        XCTAssertEqual(o.pages.count, 9)
        XCTAssertLessThanOrEqual(o.size.width, 700)
        XCTAssertGreaterThan(o.pages.last!.minY, o.pages.first!.minY)
    }

    func testOverviewStripColumnsAndViewport() {
        let e = LayoutEngine(area: area, innerGap: 10, centerMode: .never)
        var s = strip([0.5, 0.5, 0.5, 0.5], focus: 2)
        s.viewportOffset = 1010
        let o = Overview.make(strip: s, preset: .strip, engine: e, maxSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(o.targets.map(\.index), [0, 1, 2, 3])
        XCTAssertTrue(o.viewport!.contains(o.targets[2].rect))
        XCTAssertFalse(o.viewport!.intersects(o.targets[0].rect))
    }

}

final class StackTests: XCTestCase {
    func strip(_ ids: [WindowID]) -> Strip {
        var s = Strip()
        ids.forEach { s.append($0, width: 0.5) }
        return s
    }

    func testStackIntoNeighbourAndPopOut() {
        var s = strip([1, 2, 3])
        s.focus(2)
        s.stackFocused(direction: -1)
        XCTAssertEqual(s.columns.count, 2)
        XCTAssertEqual(s.columns[0].windows, [1, 2])
        XCTAssertEqual(s.focusedWindowID, 2)
        XCTAssertEqual(s.focusedIndex, 0)
        s.popOutFocused(direction: 1)
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2], [3]])
        XCTAssertEqual(s.focusedWindowID, 2)
        // Popping out a plain column does nothing.
        s.popOutFocused(direction: 1)
        XCTAssertEqual(s.columns.count, 3)
    }

    func testVerticalFocusAndReorder() {
        var s = strip([1, 2])
        s.focus(2)
        s.stackFocused(direction: -1) // [[1, 2]]
        XCTAssertEqual(s.moveFocusInColumn(by: -1), 1)
        XCTAssertNil(s.moveFocusInColumn(by: -1))
        s.moveFocusedWindowInColumn(by: 1)
        XCTAssertEqual(s.columns[0].windows, [2, 1])
        XCTAssertEqual(s.focusedWindowID, 1)
    }

    func testRemovingFromStackKeepsColumn() {
        var s = strip([1, 2, 3])
        s.focus(3)
        s.stackFocused(direction: -1) // [[1], [2, 3]]
        XCTAssertNil(s.remove(3))
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2]])
        XCTAssertEqual(s.focusedWindowID, 2)
    }

    func testStackRowsAndHeights() {
        let e = LayoutEngine(area: CGRect(x: 0, y: 0, width: 1000, height: 810), innerGap: 10, centerMode: .never)
        var s = strip([1, 2])
        s.focus(2)
        s.stackFocused(direction: -1)
        var f = e.frames(for: s, offset: 0)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 495, height: 400))
        XCTAssertEqual(f[2], CGRect(x: 0, y: 410, width: 495, height: 400))
        s.adjustFocusedHeight(by: 0.25) // window 2 → 75 %
        f = e.frames(for: s, offset: 0)
        XCTAssertEqual(f[1]?.height, 200)
        XCTAssertEqual(f[2]?.maxY, 810)
        s.equalizeFocusedHeights()
        XCTAssertEqual(e.frames(for: s, offset: 0)[1]?.height, 400)
    }

    func testTabbedShowsOnlyActiveUnderTabBar() {
        let e = LayoutEngine(area: CGRect(x: 0, y: 0, width: 1000, height: 800), innerGap: 10, centerMode: .never)
        var s = strip([1, 2])
        s.focus(2)
        s.stackFocused(direction: -1)
        s.toggleFocusedTabbed()
        let f = e.frames(for: s, offset: 0)
        XCTAssertNil(f[1])
        XCTAssertEqual(f[2], CGRect(x: 0, y: LayoutEngine.tabBarHeight, width: 495,
                                    height: 800 - LayoutEngine.tabBarHeight))
        XCTAssertEqual(e.hiddenWindows(s), [1])
        // Leaving the stack turns tabs off.
        s.popOutFocused(direction: 1)
        XCTAssertFalse(s.columns[0].tabbed)
    }

    func testDraggingAWindowOutOfAStack() {
        var s = strip([1, 2, 3])
        s.focus(2)
        s.stackFocused(direction: -1) // [[1, 2], [3]]
        s.move(2, to: 2)
        XCTAssertEqual(s.columns.map(\.windows), [[1], [3], [2]])
    }

    func testRestoreKeepsSavedOrderStacksAndWidths() {
        var saved = strip([3, 1, 2])
        saved.focus(2)
        saved.stackFocused(direction: -1) // [[3], [1, 2]]
        saved.setWidth(0.7, for: 3)
        var now = strip([1, 2, 3, 4]) // 4 is new; nothing has gone
        now.restore(from: saved)
        XCTAssertEqual(now.columns.map(\.windows), [[3], [1, 2], [4]])
        XCTAssertEqual(now.columns[0].width, 0.7, accuracy: 0.001)
        XCTAssertEqual(now.focusedWindowID, 2)
        // A window that closed meanwhile simply drops out of its stack.
        var later = strip([2, 3])
        later.restore(from: saved)
        XCTAssertEqual(later.columns.map(\.windows), [[3], [2]])
    }

    func testCodableRoundTrip() throws {
        var s = strip([1, 2])
        s.focus(2)
        s.stackFocused(direction: -1)
        s.toggleFocusedTabbed()
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(Strip.self, from: data), s)
    }
}

final class SettleTests: XCTestCase {
    func testSettlesOnNearestColumnAndRespectsFling() {
        let e = LayoutEngine(area: CGRect(x: 0, y: 0, width: 1000, height: 800), innerGap: 10, centerMode: .never)
        var s = Strip()
        [1, 2, 3, 4].forEach { s.append($0, width: 0.5) } // origins 0, 505, 1010, 1515
        XCTAssertEqual(e.settle(s, offset: 300)?.index, 1)
        XCTAssertEqual(e.settle(s, offset: 200)?.index, 0)
        XCTAssertEqual(e.settle(s, offset: 200, fling: 1)?.index, 1)
        // The last columns cannot scroll past the end of the strip.
        XCTAssertEqual(e.settle(s, offset: 1600)?.offset, 1010)
        XCTAssertEqual(e.settle(s, offset: -400, fling: -1)?.index, 0)
    }
}

final class SettingsTests: XCTestCase {
    func testLegacyFloatingListBecomesRules() throws {
        let json = #"{"outerGap": 4, "floatingBundleIDs": ["com.example.a"]}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.outerGap, 4)
        XCTAssertTrue(s.shouldFloat("com.example.a"))
        XCTAssertFalse(s.shouldFloat("com.example.b"))
    }

    func testRoundTripKeepsRules() throws {
        var s = Settings()
        s.appRules = [AppRule(bundleID: "x", appName: "X", width: 0.75, position: .last)]
        s.disabledDisplays = ["UUID"]
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.rule(for: "x")?.position, .last)
    }

    func testInsertAtFixedPositionKeepsFocus() {
        var strip = Strip()
        [1, 2, 3].forEach { strip.append($0, width: 0.5) }
        strip.focus(2)
        strip.insert(9, width: 0.5, at: 0, focus: false)
        XCTAssertEqual(strip.columns.map(\.windowID), [9, 1, 2, 3])
        XCTAssertEqual(strip.focusedWindowID, 2)
        strip.insert(8, width: 0.5, at: 99, focus: true)
        XCTAssertEqual(strip.focusedWindowID, 8)
        XCTAssertEqual(strip.columns.last?.windowID, 8)
    }
}

final class OverviewStackTests: XCTestCase {
    func testStackedColumnShowsRowsAndTabs() {
        let e = LayoutEngine(area: CGRect(x: 0, y: 0, width: 1000, height: 800), innerGap: 10, centerMode: .never)
        var s = Strip()
        [1, 2, 3].forEach { s.append($0, width: 0.5) }
        s.focus(2)
        s.stackFocused(direction: -1) // [[1, 2], [3]], 2 active
        var o = Overview.make(strip: s, preset: .strip, engine: e, maxSize: CGSize(width: 1000, height: 800))
        let stack = o.targets[0]
        XCTAssertEqual(stack.rows.map(\.windowID), [1, 2])
        XCTAssertEqual(stack.rows.map(\.isActive), [false, true])
        XCTAssertLessThan(stack.rows[0].rect.maxY, stack.rows[1].rect.minY) // gap between rows
        XCTAssertEqual(stack.rows[1].rect.maxY, stack.rect.maxY, accuracy: 0.01)
        XCTAssertEqual(o.targets[1].rows.count, 1)
        XCTAssertNil(stack.tabBar)

        s.toggleFocusedTabbed()
        o = Overview.make(strip: s, preset: .twoColumns, engine: e, maxSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(o.targets[0].tabCount, 2)
        XCTAssertNotNil(o.targets[0].tabBar)
        XCTAssertEqual(o.targets[0].rows.map(\.windowID), [2])
        // Scaling for the minimap keeps rows inside their column.
        let small = o.scaled(by: 0.1)
        XCTAssertTrue(small.targets[0].rect.contains(small.targets[0].rows[0].rect))
    }
}

final class MaximizeTests: XCTestCase {
    let e = LayoutEngine(area: CGRect(x: 0, y: 0, width: 1000, height: 800), innerGap: 10, centerMode: .never)

    func testFullWidthOnAStackedWindowFillsTheScreen() {
        var s = Strip()
        [1, 2, 3].forEach { s.append($0, width: 1.0 / 3.0) }
        s.focus(2)
        s.stackFocused(direction: -1) // [[1, 2], [3]], 2 focused, small rows
        s.toggleFocusedFullWidth()
        let f = e.frames(for: s, offset: 0)
        XCTAssertEqual(f[2], CGRect(x: 0, y: 0, width: 1000, height: 800)) // whole screen
        XCTAssertNil(f[1])
        XCTAssertEqual(e.hiddenWindows(s), [1])
        // Moving inside the stack keeps it maximized: the other window now fills the screen.
        s.moveFocusInColumn(by: -1)
        XCTAssertEqual(e.frames(for: s, offset: 0)[1]?.height, 800)
        // Second press: back to the stack at its old width.
        s.toggleFocusedFullWidth()
        XCTAssertFalse(s.columns[0].maximized)
        XCTAssertEqual(s.columns[0].width, 1.0 / 3.0, accuracy: 0.001)
        let back = e.frames(for: s, offset: 0)
        XCTAssertNotNil(back[1])
        XCTAssertNotNil(back[2])
        XCTAssertLessThan(back[2]!.height, 800)
    }

    func testFullWidthStackThatWasAlreadyWide() {
        var s = Strip()
        [1, 2].forEach { s.append($0, width: 1) }
        s.focus(2)
        s.stackFocused(direction: -1) // a full-width stack
        s.toggleFocusedFullWidth()      // must maximize, not narrow it
        XCTAssertTrue(s.columns[0].maximized)
        XCTAssertEqual(s.columns[0].width, 1)
        s.toggleFocusedFullWidth()
        XCTAssertFalse(s.columns[0].maximized)
        XCTAssertEqual(s.columns[0].width, 1)
    }

    func testOldSessionsWithoutNewFieldsStillDecode() throws {
        let json = #"{"windows":[1,2],"weights":[1,1],"active":1,"tabbed":false,"width":0.5}"#
        let c = try JSONDecoder().decode(Column.self, from: Data(json.utf8))
        XCTAssertEqual(c.windows, [1, 2])
        XCTAssertFalse(c.maximized)
    }
}

final class ShareTests: XCTestCase {
    private func strip(_ widths: [CGFloat]) -> Strip {
        var s = Strip()
        for (i, w) in widths.enumerated() { s.append(WindowID(i + 1), width: w) }
        return s
    }

    func testOneWindowBecomesTwoHalves() {
        var s = strip([1, 1])
        s.share(2, with: 1)
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2]])
        XCTAssertEqual(s.columns.map(\.width), [0.5, 0.5])
        XCTAssertEqual(s.focusedWindowID, 2)
    }

    func testTwoBecomeHalfAndTwoQuarters() {
        var s = strip([0.5, 0.5, 1])
        s.share(3, with: 2)
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2, 3]])
        XCTAssertEqual(s.columns.map(\.width), [0.5, 0.5])
        XCTAssertEqual(s.columns[1].heightFractions, [0.5, 0.5])
    }

    func testThreeBecomeFourQuarters() {
        var s = strip([0.5, 0.5, 1])
        s.share(3, with: 2)
        s.append(4, width: 1)
        s.share(4, with: 3) // onto the stack: the single half takes it
        XCTAssertEqual(s.columns.map(\.windows), [[1, 4], [2, 3]])
    }

    func testFullScreenOpensNewScreenAfterIt() {
        var s = strip([0.5, 0.5, 1])
        s.share(3, with: 2)
        s.append(4, width: 1)
        s.share(4, with: 1)
        s.append(5, width: 1)
        s.share(5, with: 1)
        XCTAssertEqual(s.columns.map(\.windows), [[1, 4], [2, 3], [5]])
        XCTAssertEqual(s.columns.last?.width, 1)
    }

    func testScreensGroupFromTheLeft() {
        var s = strip([0.5, 0.5, 0.5, 0.5, 1])
        s.share(5, with: 3) // 3 pairs with 4, not with 2
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2], [3, 5], [4]])
    }

    func testDroppingOntoOwnColumnDoesNothing() {
        var s = strip([0.5, 0.5])
        let before = s
        s.share(1, with: 1)
        XCTAssertEqual(s, before)
    }
}

final class CenteredTests: XCTestCase {
    private let engine = LayoutEngine(area: CGRect(x: 0, y: 0, width: 1000, height: 600), innerGap: 0, centerMode: .never)

    func testCenteredColumnTakesWholeScreenWithMargins() {
        var s = Strip()
        s.append(1, width: 0.5)
        s.append(2, width: 0.5)
        s.focus(1)
        s.toggleFocusedCentered()
        XCTAssertEqual(engine.columnOrigins(s), [0, 1000])
        XCTAssertEqual(engine.frames(for: s, offset: 0)[1], CGRect(x: 250, y: 0, width: 500, height: 600))
        // The next column stays off screen.
        XCTAssertEqual(engine.frames(for: s, offset: 0)[2]?.minX, 1000)
        XCTAssertEqual(s.screenGroups(), [0..<1, 1..<2])
    }

    func testCenteringFullWidthStartsAtHalf() {
        var s = Strip()
        s.append(1, width: 1)
        s.toggleCentered(containing: 1)
        XCTAssertTrue(s.columns[0].centered)
        XCTAssertEqual(s.columns[0].width, 0.5)
        s.toggleCentered(containing: 1)
        XCTAssertFalse(s.columns[0].centered)
    }

    func testCenteredSurvivesCoding() throws {
        var s = Strip()
        s.append(1, width: 0.4)
        s.toggleFocusedCentered()
        let decoded = try JSONDecoder().decode(Strip.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(decoded.columns[0].centered)
    }
}

final class RestoreTests: XCTestCase {
    func testComesBackBetweenTheSameNeighboursAsItWas() {
        var s = Strip()
        s.append(1, width: 1)
        s.append(2, width: 0.4)
        s.append(3, width: 1)
        s.focus(2)
        s.toggleFocusedCentered()
        let place = s.place(of: 2)!
        s.remove(2)
        s.focus(3)
        s.restore(2, at: place, focus: true)
        XCTAssertEqual(s.columns.map(\.windowID), [1, 2, 3])
        XCTAssertEqual(s.columns[1].width, 0.4)
        XCTAssertTrue(s.columns[1].centered)
    }

    func testSharedWindowComesBackOnItsOwnScreen() {
        var s = Strip()
        s.append(1, width: 0.5)
        s.append(2, width: 0.5)
        s.append(3, width: 1)
        let place = s.place(of: 2)!
        XCTAssertTrue(place.shared)
        s.remove(2)
        s.restore(2, at: place, focus: true)
        XCTAssertEqual(s.columns.map(\.windowID), [1, 2, 3])
        XCTAssertEqual(s.columns[1].width, 1)

        s.stack(3, onto: 1)
        let stacked = s.place(of: 3)!
        XCTAssertTrue(stacked.shared)
        s.remove(3)
        s.restore(3, at: stacked, focus: false)
        XCTAssertEqual(s.columns.map(\.windows), [[1], [3], [2]])
        XCTAssertEqual(s.columns[1].width, 1)
    }

    func testFirstWindowComesBackFirst() {
        var s = Strip()
        s.append(1, width: 1)
        s.append(2, width: 1)
        let place = s.place(of: 1)!
        s.remove(1)
        s.restore(1, at: place, focus: true)
        XCTAssertEqual(s.columns.map(\.windowID), [1, 2])
    }
}

final class EditTests: XCTestCase {
    private func strip(_ count: Int) -> Strip {
        var s = Strip()
        for i in 1...count { s.append(WindowID(i), width: 0.5) }
        return s
    }

    func testMoveBesideColumn() {
        var s = strip(4)
        s.move(1, beside: 2, after: true)
        XCTAssertEqual(s.columns.map(\.windowID), [2, 3, 1, 4])
        s.move(4, beside: 0, after: false)
        XCTAssertEqual(s.columns.map(\.windowID), [4, 2, 3, 1])
    }

    func testMoveOutOfStackBesideColumn() {
        var s = strip(3)
        s.stack(2, onto: 1)
        s.move(2, beside: 1, after: true)
        XCTAssertEqual(s.columns.map(\.windows), [[1], [3], [2]])
    }

    func testDropPicksMoveStackOrShare() {
        var s = strip(3)
        s.drop(3, on: StripDrop(windowID: 1, edge: -1), share: false)
        XCTAssertEqual(s.columns.map(\.windows), [[3], [1], [2]])
        s.drop(3, on: StripDrop(windowID: 2, edge: nil), share: false)
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2, 3]])
        var t = strip(2)
        t.setWidth(1, for: 1)
        t.drop(2, on: StripDrop(windowID: 1, edge: nil), share: true)
        XCTAssertEqual(t.columns.map(\.width), [0.5, 0.5])
    }

    func testReorderInsideStack() {
        var s = strip(3)
        s.stack(2, onto: 1)
        s.stack(3, onto: 1)
        s.focus(1)
        s.insert(3, nextTo: 1, below: false)
        XCTAssertEqual(s.columns.map(\.windows), [[3, 1, 2]])
        s.insert(3, nextTo: 2, below: true)
        XCTAssertEqual(s.columns.map(\.windows), [[1, 2, 3]])
        XCTAssertEqual(s.focusedWindowID, 1)
    }

    func testInsertAboveWindowOfAnotherColumn() {
        var s = strip(3)
        s.drop(3, on: StripDrop(windowID: 1, edge: nil, row: -1), share: false)
        XCTAssertEqual(s.columns.map(\.windows), [[3, 1], [2]])
    }

    func testDropOnNewScreen() {
        var s = strip(3)
        s.drop(2, on: StripDrop(windowID: 3, edge: 1, newScreen: true), share: false)
        XCTAssertEqual(s.columns.map(\.windowID), [1, 3, 2])
        XCTAssertEqual(s.columns.map(\.width), [0.5, 0.5, 1])
        s.stack(1, onto: 3)
        s.drop(1, on: StripDrop(windowID: 3, edge: -1, newScreen: true), share: false)
        XCTAssertEqual(s.columns.map(\.windows), [[1], [3], [2]])
        XCTAssertEqual(s.columns[0].width, 1)
    }

    func testUnstackSharesWidth() {
        var s = strip(3)
        s.setWidth(1, for: 1)
        s.stack(2, onto: 1)
        s.focus(3)
        s.unstack(containing: 1)
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2], [3]])
        XCTAssertEqual(s.columns.map(\.width), [0.5, 0.5, 0.5])
        XCTAssertEqual(s.focusedWindowID, 3)
    }

    func testStackKeepsFocus() {
        var s = strip(3)
        s.focus(3)
        s.stack(1, onto: 2)
        XCTAssertEqual(s.columns.map(\.windows), [[2, 1], [3]])
        XCTAssertEqual(s.focusedWindowID, 3)
        s.toggleTabbed(containing: 1)
        XCTAssertTrue(s.columns[0].tabbed)
    }
}
