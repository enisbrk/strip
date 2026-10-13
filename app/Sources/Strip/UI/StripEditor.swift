import AppKit
import StripCore
import SwiftUI

/// A change asked for in the strip editor; the window manager applies it and sends the new strip back.
enum StripEditAction {
    case drop(WindowID, on: StripDrop)
    case width(WindowID, CGFloat)
    case toggleTabs(WindowID)
    case toggleCentered(WindowID)
    case focus(WindowID)
    case close
}

@MainActor
final class StripEditorModel: ObservableObject {
    @Published var strip = Strip()
    var tiles: [WindowID: OverviewTile] = [:]
    var widths: [CGFloat] = []
    /// Width of one screen in the editor, and the screen's aspect ratio.
    var unit: CGFloat = 400
    var aspect: CGFloat = 1.6
    var maxWidth: CGFloat = 1200
    var onAction: (StripEditAction) -> Void = { _ in }
}

/// Borderless panels can't take keys (Esc) unless told so.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The whole strip of a display in miniature, on top of everything, to rearrange it with the
/// mouse: drag to reorder, drop onto a window to stack, pick a width, click to focus.
@MainActor
final class StripEditor {
    private let model = StripEditorModel()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private(set) var displayID: CGDirectDisplayID?

    var isVisible: Bool { panel?.isVisible ?? false }
    var onAction: (StripEditAction) -> Void {
        get { model.onAction }
        set { model.onAction = newValue }
    }

    func show(displayID: CGDirectDisplayID, screen: NSScreen, aspect: CGFloat, widths: [CGFloat]) {
        self.displayID = displayID
        model.aspect = aspect
        model.widths = widths.sorted()
        model.unit = max((screen.visibleFrame.width * 0.2).rounded(), 220)
        model.maxWidth = (screen.visibleFrame.width * 0.8).rounded()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        keyMonitor = keyMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            self?.onAction(.close)
            return nil
        }
    }

    func update(strip: Strip, tiles: [WindowID: OverviewTile]) {
        model.tiles = tiles
        model.strip = strip
    }

    func hide() {
        panel?.orderOut(nil)
        displayID = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: StripEditorView(model: model))
        return panel
    }
}

private struct Frames: PreferenceKey {
    static let defaultValue: [WindowID: CGRect] = [:]
    static func reduce(value: inout [WindowID: CGRect], nextValue: () -> [WindowID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Column frames, keyed by the column's first window.
private struct ColumnFrames: PreferenceKey {
    static let defaultValue: [WindowID: CGRect] = [:]
    static func reduce(value: inout [WindowID: CGRect], nextValue: () -> [WindowID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct StripEditorView: View {
    @ObservedObject var model: StripEditorModel
    @Namespace private var namespace
    @State private var dragged: WindowID?
    @State private var dragPoint: CGPoint = .zero
    /// From the pointer to the middle of the dragged tile, so the tile doesn't jump under it.
    @State private var grab: CGSize = .zero
    @State private var target: StripDrop?
    /// After a drop: the floating tile glides into its new place, then disappears.
    @State private var settling = false
    @State private var tileFrames: [WindowID: CGRect] = [:]
    @State private var columnFrames: [WindowID: CGRect] = [:]

    private static let gap: CGFloat = 8
    private static let space = "stripEditor"
    private static let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)
    private var height: CGFloat { (model.unit / max(model.aspect, 0.1)).rounded() }

    /// The strip as it would be after dropping here: shown while dragging, so windows make room live.
    private var shown: Strip {
        guard let dragged, let target, !settling else { return model.strip }
        var s = model.strip
        s.drop(dragged, on: target, share: false)
        return s
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { model.onAction(.close) }
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Edit strip")).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 16)
                Text(L("Drag to reorder · drop above or below a window to stack · click to focus · Esc to close"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                content.padding(4)
            }
        }
        .padding(14)
        .frame(maxWidth: model.maxWidth)
        .fixedSize(horizontal: false, vertical: true)
        // Opaque, so windows behind never show through while dragging.
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .contentShape(Rectangle())
        .onTapGesture {} // clicks on the card don't close the editor
    }

    private var content: some View {
        let strip = shown
        return HStack(alignment: .top, spacing: 14) {
            ForEach(Array(strip.screenGroups().enumerated()), id: \.offset) { n, group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Screen %d", n + 1))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(group.map { strip.columns[$0] }, id: \.windows[0]) { c in
                            column(c, focusedID: strip.focusedWindowID)
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(Frames.self) { tileFrames = $0 }
        .onPreferenceChange(ColumnFrames.self) { columnFrames = $0 }
        .overlay(alignment: .topLeading) { floatingTile }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged(dragChanged)
            .onEnded { _ in dragEnded() })
    }

    private func column(_ c: Column, focusedID: WindowID?) -> some View {
        let width = max((c.width * model.unit).rounded(), 70)
        let rowGap: CGFloat = 3
        let fractions = c.tabbed ? Array(repeating: 1 / CGFloat(c.windows.count), count: c.windows.count) : c.heightFractions
        let available = height - rowGap * CGFloat(c.windows.count - 1)
        // A centered column fills a whole screen: its windows in the middle, empty margins around.
        let slot = c.centered ? max(model.unit, width) : width
        return VStack(spacing: 6) {
            VStack(spacing: rowGap) {
                ForEach(Array(zip(c.windows, fractions)), id: \.0) { id, fraction in
                    tile(id, size: CGSize(width: width, height: (available * fraction).rounded()),
                         active: id == c.windowID, tabbed: c.tabbed, focused: id == focusedID)
                }
            }
            .frame(width: slot, height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .opacity(c.centered ? 1 : 0))
            .background(GeometryReader { g in
                Color.clear.preference(key: ColumnFrames.self, value: [c.windows[0]: g.frame(in: .named(Self.space))])
            })
            controls(c).frame(width: slot)
        }
    }

    private func tile(_ id: WindowID, size: CGSize, active: Bool, tabbed: Bool, focused: Bool) -> some View {
        let isDragged = id == dragged
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Group {
            if isDragged {
                // Where the dragged window will land.
                shape.fill(Color.accentColor.opacity(0.12))
                    .overlay(shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            } else {
                TileFace(tile: model.tiles[id], size: size, focused: focused, dimmed: tabbed && !active)
            }
        }
        .frame(width: size.width, height: max(size.height, 1))
        .matchedGeometryEffect(id: id, in: namespace)
        .background(GeometryReader { g in
            Color.clear.preference(key: Frames.self, value: [id: g.frame(in: .named(Self.space))])
        })
        .contentShape(shape)
        .onTapGesture { model.onAction(.focus(id)) }
    }

    /// The dragged window under the pointer; after a drop it glides into its slot.
    @ViewBuilder
    private var floatingTile: some View {
        if let dragged, let slot = tileFrames[dragged] {
            let center = settling ? CGPoint(x: slot.midX, y: slot.midY)
                : CGPoint(x: dragPoint.x + grab.width, y: dragPoint.y + grab.height)
            TileFace(tile: model.tiles[dragged], size: slot.size, focused: true, dimmed: false)
                .frame(width: slot.width, height: slot.height)
                .shadow(color: .black.opacity(settling ? 0 : 0.35), radius: 12, y: 5)
                .scaleEffect(settling ? 1 : 1.04)
                .position(center)
                .allowsHitTesting(false)
        }
    }

    private func dragChanged(_ value: DragGesture.Value) {
        if dragged == nil {
            guard !settling,
                  let (id, frame) = tileFrames.first(where: { $0.value.contains(value.startLocation) }) else { return }
            dragged = id
            grab = CGSize(width: frame.midX - value.startLocation.x, height: frame.midY - value.startLocation.y)
        }
        dragPoint = value.location
        let next = dropTarget(at: value.location)
        if next != target {
            withAnimation(Self.spring) { target = next }
        }
    }

    private func dragEnded() {
        guard let id = dragged else { return }
        let drop = target
        // The strip about to arrive from the window manager is the one already shown.
        target = nil
        if let drop { model.onAction(.drop(id, on: drop)) }
        withAnimation(Self.spring) { settling = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            dragged = nil
            settling = false
        }
    }

    /// The spot under the pointer in the strip as shown: a column's edge (beside it) or a window's
    /// upper / lower half (above / below it). Over the dragged window's own new place, or between
    /// columns, the current target stays, so the preview doesn't flicker.
    private func dropTarget(at p: CGPoint) -> StripDrop? {
        guard let dragged else { return nil }
        let strip = shown
        let rows = columnFrames.values
        guard let top = rows.map(\.minY).min(), let bottom = rows.map(\.maxY).max(),
              p.y > top - 40, p.y < bottom + 40 else { return nil }
        for c in strip.columns {
            guard let r = columnFrames[c.windows[0]], r.insetBy(dx: -Self.gap / 2 - 4, dy: -24).contains(p) else { continue }
            let own = c.contains(dragged)
            // Its own plain column: wherever it goes there, nothing changes.
            if own && !c.isStack { return target }
            let others = c.windows.filter { $0 != dragged }
            let band = min(r.width * 0.25, 48)
            if p.x < r.minX + band || p.x > r.maxX - band {
                return StripDrop(windowID: others[0], edge: p.x < r.minX + band ? -1 : 1)
            }
            // The window under the pointer (rows are stacked top to bottom).
            let row = c.windows.first { tileFrames[$0].map { p.y < $0.maxY + 2 } ?? false } ?? c.windows.last!
            guard row != dragged, let f = tileFrames[row] else { return target }
            return StripDrop(windowID: row, edge: nil, row: p.y < f.midY ? -1 : 1)
        }
        return target
    }

    private func controls(_ c: Column) -> some View {
        // Narrow columns drop the percent signs and tighten up.
        ViewThatFits(in: .horizontal) {
            controlRow(c, compact: false)
            controlRow(c, compact: true)
        }
    }

    private func controlRow(_ c: Column, compact: Bool) -> some View {
        HStack(spacing: compact ? 2 : 3) {
            ForEach(model.widths, id: \.self) { w in
                let current = abs(c.width - w) < 0.01
                Button { model.onAction(.width(c.windowID, w)) } label: {
                    Text("\(Int((w * 100).rounded()))" + (compact ? "" : "%"))
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, compact ? 4 : 5)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(current ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(L("Width"))
            }
            Button { model.onAction(.toggleCentered(c.windowID)) } label: {
                Image(systemName: "align.horizontal.center")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(c.centered ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(L("Center on its own screen"))
            if c.isStack {
                Button { model.onAction(.toggleTabs(c.windowID)) } label: {
                    Image(systemName: c.tabbed ? "rectangle.split.1x2" : "menubar.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(L("Show stack as tabs / rows"))
            }
        }
    }

}

/// How a window looks in the editor: its icon and title on a rounded tile.
private struct TileFace: View {
    let tile: OverviewTile?
    let size: CGSize
    let focused: Bool
    let dimmed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let iconSide = min(26, max(size.height - 24, 14))
        ZStack {
            shape.fill(Color(nsColor: .windowBackgroundColor))
            shape.fill(focused ? Color.accentColor.opacity(0.35) : Color.primary.opacity(dimmed ? 0.05 : 0.11))
            shape.strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: focused ? 1.5 : 0.5)
            VStack(spacing: 4) {
                if let icon = tile?.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: iconSide, height: iconSide)
                }
                if size.height >= 44 {
                    Text(tile?.title ?? "")
                        .font(.system(size: 10))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(6)
        }
    }
}
