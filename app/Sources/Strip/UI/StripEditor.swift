import AppKit
import ImageIO
import StripCore
import SwiftUI

/// A change asked for in the strip editor; the window manager applies it and sends the new strip back.
enum StripEditAction {
    case drop(WindowID, on: StripDrop)
    /// The screen holding the first window, before / after the screen holding the second.
    case moveScreen(WindowID, beside: WindowID, after: Bool)
    case width(WindowID, CGFloat)
    case toggleTabs(WindowID)
    case sideBySide(WindowID)
    case toggleCentered(WindowID)
    case focus(WindowID)
    case close
}

@MainActor
final class StripEditorModel: ObservableObject {
    @Published var strip = Strip() {
        didSet {
            if selected.map({ !strip.contains($0) }) ?? true { selected = strip.focusedWindowID }
        }
    }
    /// The highlighted window, as in the app switcher: arrows and the pointer move it, Return focuses it.
    @Published var selected: WindowID?
    /// Drives the open / close animation of the panel.
    @Published var presented = false
    var tiles: [WindowID: OverviewTile] = [:]
    var widths: [CGFloat] = []
    /// Width of one miniature screen, and the screen's aspect ratio.
    var unit: CGFloat = 280
    var aspect: CGFloat = 1.6
    /// The desktop picture of the edited screen: the backdrop and the face of every miniature screen.
    var wallpaper: NSImage?
    var maxWidth: CGFloat = 1200
    var onAction: (StripEditAction) -> Void = { _ in }

    /// Moves the highlight to the column `dx` away (wrapping around, like ⌘-Tab), or to the window
    /// `dy` rows away within its stack.
    func moveSelection(dx: Int = 0, dy: Int = 0) {
        let columns = strip.columns
        guard !columns.isEmpty else { return }
        let i = selected.flatMap { id in columns.firstIndex { $0.contains(id) } }
        guard let i, let selected else {
            self.selected = columns[0].windowID
            return
        }
        if dx != 0 {
            self.selected = columns[((i + dx) % columns.count + columns.count) % columns.count].windowID
        } else if let row = columns[i].windows.firstIndex(of: selected) {
            let windows = columns[i].windows
            self.selected = windows[min(max(row + dy, 0), windows.count - 1)]
        }
    }
}

/// Borderless panels can't take keys (Esc) unless told so.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The whole strip of a display as an app-switcher-like glass panel in the middle of the screen,
/// to rearrange it with the mouse or the keyboard: drag to reorder, drop onto a window to stack,
/// pick a width, click (or Return) to focus.
@MainActor
final class StripEditor {
    private static let openAnimation = Animation.spring(response: 0.32, dampingFraction: 0.74)
    private static let closeAnimation = Animation.easeIn(duration: 0.14)

    private let model = StripEditorModel()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    /// Pending order-out while the close animation runs.
    private var closing: DispatchWorkItem?
    private var wallpapers: [URL: NSImage] = [:]
    private(set) var displayID: CGDirectDisplayID?

    var isVisible: Bool { (panel?.isVisible ?? false) && closing == nil }
    var onAction: (StripEditAction) -> Void {
        get { model.onAction }
        set { model.onAction = newValue }
    }

    func show(displayID: CGDirectDisplayID, screen: NSScreen, aspect: CGFloat, widths: [CGFloat]) {
        self.displayID = displayID
        model.aspect = aspect
        model.widths = widths.sorted()
        model.unit = min(max((screen.visibleFrame.width * 0.2).rounded(), 240), 440)
        model.maxWidth = (screen.visibleFrame.width * 0.8).rounded()
        model.wallpaper = wallpaper(for: screen)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let closing {
            // Opened again while closing: grow back from where it is.
            closing.cancel()
            self.closing = nil
        } else {
            model.presented = false
            model.selected = nil
        }
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        // One run-loop turn later, so the panel has drawn the closed state to animate from.
        DispatchQueue.main.async { [model] in
            withAnimation(Self.openAnimation) { model.presented = true }
        }
        keyMonitor = keyMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    func update(strip: Strip, tiles: [WindowID: OverviewTile]) {
        model.tiles = tiles
        model.strip = strip
    }

    func hide() {
        displayID = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard let panel, panel.isVisible, closing == nil else { return }
        withAnimation(Self.closeAnimation) { model.presented = false }
        let work = DispatchWorkItem { [weak self] in
            panel.orderOut(nil)
            self?.closing = nil
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    /// Esc closes; arrows and Tab move the highlight; Return focuses the highlighted window.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: onAction(.close) // Esc
        case 36, 76: // Return, Enter
            if let id = model.selected { onAction(.focus(id)) }
        case 123: model.moveSelection(dx: -1) // ←
        case 124: model.moveSelection(dx: 1) // →
        case 126: model.moveSelection(dy: -1) // ↑
        case 125: model.moveSelection(dy: 1) // ↓
        case 48: model.moveSelection(dx: event.modifierFlags.contains(.shift) ? -1 : 1) // Tab
        default: return event
        }
        return nil
    }

    /// The desktop picture of `screen`, decoded once at the screen's size.
    private func wallpaper(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let image = wallpapers[url] { return image }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: screen.frame.width * screen.backingScaleFactor] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        wallpapers[url] = image
        return image
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

/// Where a dragged screen goes: before or after the screen holding `id`.
private struct ScreenTarget: Equatable {
    let id: WindowID
    let after: Bool
}

private struct ScreenFrames: PreferenceKey {
    static let defaultValue: [WindowID: CGRect] = [:]
    static func reduce(value: inout [WindowID: CGRect], nextValue: () -> [WindowID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The "new screen" slot, while dragging.
private struct SlotFrame: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// Lays its views out in rows, starting a new row when one would get wider than `maxWidth`;
/// every row is centered, its views aligned at the top.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var maxWidth: CGFloat

    private func rows(_ subviews: Subviews) -> [(indices: [Int], size: CGSize)] {
        var rows: [(indices: [Int], size: CGSize)] = []
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if let last = rows.last, !last.indices.isEmpty, last.size.width + spacing + size.width <= maxWidth {
                rows[rows.count - 1].indices.append(i)
                rows[rows.count - 1].size = CGSize(width: last.size.width + spacing + size.width,
                                                   height: max(last.size.height, size.height))
            } else {
                rows.append(([i], size))
            }
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews)
        return CGSize(width: rows.map(\.size.width).max() ?? 0,
                      height: rows.map(\.size.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews) {
            var x = bounds.minX + (bounds.width - row.size.width) / 2
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.size.height + lineSpacing
        }
    }
}

private struct ContentWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
    @State private var slotFrame: CGRect?
    /// A whole screen being dragged (by its margin or name): the first window on it.
    @State private var draggedScreen: WindowID?
    @State private var screenTarget: ScreenTarget?
    /// Miniature screen frames, keyed by the first window of the screen's first column.
    @State private var screenFrames: [WindowID: CGRect] = [:]
    /// Width of the widest row of screens, for the footer.
    @State private var contentWidth: CGFloat = 400

    private static let gap: CGFloat = 5
    /// Margin between a miniature screen's edge and its windows.
    private static let inset: CGFloat = 7
    private static let screenGap: CGFloat = 18
    private static let space = "stripEditor"
    private static let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// Height of a miniature screen, and of the columns inside it.
    private var screenHeight: CGFloat { (model.unit / max(model.aspect, 0.1)).rounded() }
    private var height: CGFloat { screenHeight - Self.inset * 2 }

    /// The strip as it would be after dropping here: shown while dragging, so windows make room live.
    private var shown: Strip {
        guard !settling else { return model.strip }
        var s = model.strip
        if let dragged, let target {
            s.drop(dragged, on: target, share: false)
        } else if let draggedScreen, let screenTarget {
            s.moveScreen(containing: draggedScreen, beside: screenTarget.id, after: screenTarget.after)
        }
        return s
    }

    private var dragging: Bool { dragged != nil || draggedScreen != nil }

    private var selectedColumn: Column? {
        model.selected.flatMap { id in model.strip.columns.first { $0.contains(id) } }
    }

    var body: some View {
        ZStack {
            // The bare desktop, as if every window stepped aside while the strip is edited.
            Wallpaper(image: model.wallpaper)
                .ignoresSafeArea()
                .opacity(model.presented ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { model.onAction(.close) }
            card
                .scaleEffect(model.presented ? 1 : 0.86)
                .opacity(model.presented ? 1 : 0)
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            content
                .padding(8)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentWidth.self, value: g.size.width)
                })
            footer
        }
        .padding(18)
        .onPreferenceChange(ContentWidth.self) { contentWidth = $0 }
        .glassSurface(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {} // clicks on the card don't close the editor
        .padding(30) // room for the glass shadow
    }

    /// The highlighted window's title and its column's controls, then the keys.
    private var footer: some View {
        VStack(spacing: 8) {
            Text(model.selected.flatMap { model.tiles[$0]?.title } ?? " ")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let c = selectedColumn {
                controls(c)
                    .opacity(dragging ? 0.4 : 1)
                    .allowsHitTesting(!dragging)
            }
            Text(L("← → to choose · Return to focus · drag windows to reorder or stack · drag a screen by its name or edge to move it · Esc to close"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: max(contentWidth, 320))
    }

    private var content: some View {
        let strip = shown
        // Screens wrap onto further rows instead of scrolling sideways.
        return FlowLayout(spacing: Self.screenGap, lineSpacing: 16, maxWidth: model.maxWidth - 52) {
            ForEach(Array(strip.screenGroups().enumerated()), id: \.offset) { n, group in
                screen(n, columns: group.map { strip.columns[$0] }, focusedID: strip.focusedWindowID)
            }
            if dragged != nil && !settling { newScreenSlot }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(Frames.self) { tileFrames = $0 }
        .onPreferenceChange(ColumnFrames.self) { columnFrames = $0 }
        .onPreferenceChange(SlotFrame.self) { slotFrame = $0 }
        .onPreferenceChange(ScreenFrames.self) { screenFrames = $0 }
        .overlay(alignment: .topLeading) { floatingTile }
        .overlay(alignment: .topLeading) { floatingScreen }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged(dragChanged)
            .onEnded { _ in dragEnded() })
    }

    private func columnWidth(_ c: Column) -> CGFloat {
        max((c.width * (model.unit - Self.inset * 2)).rounded(), 40)
    }

    /// One screen of the strip as a miniature display: the desktop picture with its windows on
    /// it, brighter when it holds the highlighted window, its name underneath.
    private func screen(_ n: Int, columns: [Column], focusedID: WindowID?) -> some View {
        let current = columns.contains { c in model.selected.map(c.contains) ?? false }
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // Dragged as a whole: it travels with the pointer, an empty well marks where it lands.
        let lifted = draggedScreen.map { id in columns.contains { $0.contains(id) } } ?? false
        return VStack(spacing: 8) {
            screenFace(columns, focusedID: focusedID, live: true)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ScreenFrames.self, value: [columns[0].windows[0]: g.frame(in: .named(Self.space))])
                })
                .opacity(lifted ? 0 : 1)
                // No outline: the screen in use stays bright and lifts a little, the others recede.
                .brightness(current || lifted ? 0 : -0.12)
                .shadow(color: .black.opacity(lifted ? 0 : current ? 0.34 : 0.18), radius: current ? 14 : 8, y: current ? 6 : 3)
                .background(shape.fill(Color.black.opacity(lifted ? 0.18 : 0)))
            Text(L("Screen %d", n + 1))
                .font(.system(size: 11, weight: current ? .semibold : .medium))
                .foregroundStyle(current ? .primary : .secondary)
        }
        .animation(.easeOut(duration: 0.15), value: current)
    }

    /// A miniature screen: the desktop picture with its windows on it. `live` measures the windows
    /// for dragging and lets them be hovered and clicked; the copy under the pointer is not live.
    private func screenFace(_ columns: [Column], focusedID: WindowID?, live: Bool) -> some View {
        let used = columns.map(columnWidth).reduce(0, +) + Self.gap * CGFloat(max(columns.count - 1, 0))
        // A centered column sits in the middle of its screen, a pinned one against its side.
        let centered = columns.count == 1 && columns[0].centered
        let right = columns.count == 1 && columns[0].pin?.x == 1
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(alignment: .top, spacing: Self.gap) {
            ForEach(columns, id: \.windows[0]) { c in
                if live {
                    column(c, focusedID: focusedID)
                } else {
                    let width = columnWidth(c)
                    VStack(spacing: 3) {
                        ForEach(Array(zip(c.windows, rowHeights(c))), id: \.0) { id, h in
                            TileFace(tile: model.tiles[id], size: CGSize(width: width, height: h), selected: false,
                                     focused: id == focusedID, dimmed: c.tabbed && id != c.windowID)
                                .frame(width: width, height: h)
                        }
                    }
                    .frame(width: width, height: height, alignment: c.pin?.y == 1 ? .bottom : .top)
                }
            }
        }
        .padding(Self.inset)
        .frame(width: max(model.unit, used + Self.inset * 2), height: screenHeight, alignment: centered ? .top : right ? .topTrailing : .topLeading)
        .background(Wallpaper(image: model.wallpaper).clipShape(shape))
        .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
    }

    /// Heights of a column's windows, top to bottom.
    private func rowHeights(_ c: Column) -> [CGFloat] {
        let rowGap: CGFloat = 3
        let fractions = c.tabbed ? Array(repeating: 1 / CGFloat(c.windows.count), count: c.windows.count) : c.heightFractions
        // Pinned to the top or bottom half of its screen.
        let column = (c.pin?.y ?? 0) != 0 ? ((height - rowGap) / 2).rounded() : height
        let available = column - rowGap * CGFloat(c.windows.count - 1)
        return fractions.map { (available * $0).rounded() }
    }

    /// Shown while dragging: drop here (or between screens) for a screen of its own.
    private var newScreenSlot: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus.rectangle.on.rectangle").font(.system(size: 18, weight: .medium))
            Text(L("New screen")).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Color.accentColor)
        .frame(width: max((model.unit * 0.45).rounded(), 90), height: screenHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .background(GeometryReader { g in
            Color.clear.preference(key: SlotFrame.self, value: g.frame(in: .named(Self.space)))
        })
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private func column(_ c: Column, focusedID: WindowID?) -> some View {
        let width = columnWidth(c)
        return VStack(spacing: 3) {
            ForEach(Array(zip(c.windows, rowHeights(c))), id: \.0) { id, h in
                tile(id, size: CGSize(width: width, height: h),
                     active: id == c.windowID, tabbed: c.tabbed, focused: id == focusedID)
            }
        }
        .frame(width: width, height: height, alignment: c.pin?.y == 1 ? .bottom : .top)
        .background(GeometryReader { g in
            Color.clear.preference(key: ColumnFrames.self, value: [c.windows[0]: g.frame(in: .named(Self.space))])
        })
        .id(c.windows[0])
    }

    private func tile(_ id: WindowID, size: CGSize, active: Bool, tabbed: Bool, focused: Bool) -> some View {
        let isDragged = id == dragged
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Group {
            if isDragged {
                // Where the dragged window will land.
                shape.fill(Color.accentColor.opacity(0.12))
                    .overlay(shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            } else {
                TileFace(tile: model.tiles[id], size: size, selected: id == model.selected, focused: focused,
                         dimmed: tabbed && !active)
            }
        }
        .frame(width: size.width, height: max(size.height, 1))
        .matchedGeometryEffect(id: id, in: namespace)
        .background(GeometryReader { g in
            Color.clear.preference(key: Frames.self, value: [id: g.frame(in: .named(Self.space))])
        })
        .contentShape(shape)
        .onHover { inside in
            if inside, !dragging { model.selected = id }
        }
        .onTapGesture { model.onAction(.focus(id)) }
        .help(model.tiles[id]?.title ?? "")
    }

    /// The dragged window under the pointer; after a drop it glides into its slot.
    @ViewBuilder
    private var floatingTile: some View {
        if let dragged, let slot = tileFrames[dragged] {
            let center = settling ? CGPoint(x: slot.midX, y: slot.midY)
                : CGPoint(x: dragPoint.x + grab.width, y: dragPoint.y + grab.height)
            TileFace(tile: model.tiles[dragged], size: slot.size, selected: true, focused: false, dimmed: false)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.regularMaterial))
                .frame(width: slot.width, height: slot.height)
                .shadow(color: .black.opacity(settling ? 0 : 0.35), radius: 12, y: 5)
                .scaleEffect(settling ? 1 : 1.06)
                .position(center)
                .allowsHitTesting(false)
        }
    }

    /// Miniature screen frames, with the name underneath, in the strip as shown.
    private func screenHit(_ p: CGPoint, gap: CGFloat = 0) -> Range<Int>? {
        let strip = shown
        return strip.screenGroups().first { g in
            screenFrames[strip.columns[g.lowerBound].windows[0]].map {
                CGRect(x: $0.minX - gap, y: $0.minY - 4, width: $0.width + gap * 2, height: $0.height + 28).contains(p)
            } ?? false
        }
    }

    private func dragChanged(_ value: DragGesture.Value) {
        if !dragging {
            guard !settling else { return }
            if let (id, frame) = tileFrames.first(where: { $0.value.contains(value.startLocation) }) {
                dragged = id
                grab = CGSize(width: frame.midX - value.startLocation.x, height: frame.midY - value.startLocation.y)
            } else if let g = screenHit(value.startLocation) {
                // Off the windows, on the screen's margin or name: the whole screen moves.
                let id = shown.columns[g.lowerBound].windows[0]
                draggedScreen = id
                if let frame = screenFrames[id] {
                    grab = CGSize(width: frame.midX - value.startLocation.x, height: frame.midY - value.startLocation.y)
                }
            } else {
                return
            }
        }
        dragPoint = value.location
        if dragged != nil {
            let next = dropTarget(at: value.location)
            if next != target {
                withAnimation(Self.spring) { target = next }
            }
        } else {
            let next = screenDropTarget(at: value.location)
            if next != screenTarget {
                withAnimation(Self.spring) { screenTarget = next }
            }
        }
    }

    private func dragEnded() {
        if let id = dragged {
            let drop = target
            // The strip about to arrive from the window manager is the one already shown.
            target = nil
            if let drop { model.onAction(.drop(id, on: drop)) }
        } else if let id = draggedScreen {
            let drop = screenTarget
            screenTarget = nil
            if let drop { model.onAction(.moveScreen(id, beside: drop.id, after: drop.after)) }
        } else {
            return
        }
        withAnimation(Self.spring) { settling = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            dragged = nil
            draggedScreen = nil
            settling = false
        }
    }

    /// The screen under the pointer, the dragged one going before or after it by the pointer's
    /// side. Over the dragged screen's own new place the current target stays, so the preview
    /// doesn't flicker.
    private func screenDropTarget(at p: CGPoint) -> ScreenTarget? {
        guard let draggedScreen, let g = screenHit(p, gap: Self.screenGap / 2) else { return screenTarget }
        let strip = shown
        if strip.columns[g].contains(where: { $0.contains(draggedScreen) }) { return screenTarget }
        let id = strip.columns[g.lowerBound].windows[0]
        guard let frame = screenFrames[id] else { return screenTarget }
        return ScreenTarget(id: id, after: p.x > frame.midX)
    }

    /// The dragged screen, lifted under the pointer; after a drop it glides into its new place.
    @ViewBuilder
    private var floatingScreen: some View {
        if let draggedScreen, let slot = screenFrames[draggedScreen] {
            let strip = model.strip
            let columns = strip.screenGroups()
                .first { g in strip.columns[g].contains { $0.contains(draggedScreen) } }
                .map { g in Array(strip.columns[g]) } ?? []
            let center = settling ? CGPoint(x: slot.midX, y: slot.midY)
                : CGPoint(x: dragPoint.x + grab.width, y: dragPoint.y + grab.height)
            if !columns.isEmpty {
                screenFace(columns, focusedID: strip.focusedWindowID, live: false)
                    .scaleEffect(settling ? 1 : 1.05)
                    .shadow(color: .black.opacity(settling ? 0.2 : 0.4), radius: settling ? 8 : 22, y: settling ? 3 : 10)
                    .position(center)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The spot under the pointer in the strip as shown. Anywhere on a miniature screen picks the
    /// column nearest the pointer: its outer third (or the screen's margin beside it) puts the
    /// window beside it, its middle above / below the window under the pointer. Between screens
    /// and on the "new screen" slot it gets a screen of its own. Over the dragged window's own new
    /// place the current target stays, so the preview doesn't flicker.
    private func dropTarget(at p: CGPoint) -> StripDrop? {
        guard let dragged else { return nil }
        let strip = shown
        let rows = columnFrames.values
        let bottom = max(rows.map(\.maxY).max() ?? 0, slotFrame?.maxY ?? 0)
        guard let top = rows.map(\.minY).min(), p.y > top - 40, p.y < bottom + 40 else { return nil }
        let onSlot = slotFrame.map { $0.insetBy(dx: -Self.screenGap / 2, dy: -20).contains(p) } ?? false
        if !onSlot, let group = strip.screenGroups().first(where: { g in
            screenFrames[strip.columns[g.lowerBound].windows[0]].map { $0.insetBy(dx: 0, dy: -14).contains(p) } ?? false
        }) {
            func distance(_ r: CGRect) -> CGFloat { p.x < r.minX ? r.minX - p.x : max(p.x - r.maxX, 0) }
            guard let c = group.map({ strip.columns[$0] }).min(by: {
                distance(columnFrames[$0.windows[0]] ?? .null) < distance(columnFrames[$1.windows[0]] ?? .null)
            }), let r = columnFrames[c.windows[0]] else { return target }
            // Its own plain column: wherever it goes there, nothing changes.
            if c.contains(dragged) && !c.isStack { return target }
            let others = c.windows.filter { $0 != dragged }
            let band = min(max(r.width * 0.3, 16), 60)
            if p.x < r.minX + band || p.x > r.maxX - band {
                return StripDrop(windowID: others[0], edge: p.x < r.midX ? -1 : 1, fit: true)
            }
            // The window under the pointer (rows are stacked top to bottom).
            let row = c.windows.first { tileFrames[$0].map { p.y < $0.maxY + 2 } ?? false } ?? c.windows.last!
            guard row != dragged, let f = tileFrames[row] else { return target }
            return StripDrop(windowID: row, edge: nil, row: p.y < f.midY ? -1 : 1)
        }
        // Outside the columns: the margin of a screen, the space between screens, the start or end
        // of a row of screens or the "new screen" slot puts the window on a screen of its own there.
        let groups = strip.screenGroups()
        guard !groups.isEmpty else { return target }
        func frame(_ i: Int) -> CGRect? { columnFrames[strip.columns[i].windows[0]] }
        func anchor(_ i: Int) -> WindowID? {
            let c = strip.columns[i]
            if c.contains(dragged) && !c.isStack { return nil }
            return c.windows.first { $0 != dragged }
        }
        func sameRow(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minY - b.minY) < 1 }
        /// A screen of its own between screen `n` and the next one.
        func after(_ n: Int) -> StripDrop? {
            // Its own lone column ends this screen: the neighbour on the other side anchors it.
            if let a = anchor(groups[n].upperBound - 1) { return StripDrop(windowID: a, edge: 1, newScreen: true) }
            if n + 1 < groups.count, let a = anchor(groups[n + 1].lowerBound) {
                return StripDrop(windowID: a, edge: -1, newScreen: true)
            }
            return target
        }
        if onSlot { return after(groups.count - 1) }
        for (n, g) in groups.enumerated() {
            guard let first = frame(g.lowerBound), let last = frame(g.upperBound - 1),
                  p.y > first.minY - 30, p.y < first.maxY + 30 else { continue }
            let previous = n > 0 ? frame(groups[n - 1].upperBound - 1) : nil
            if p.x < first.minX, previous.map({ !sameRow($0, first) }) ?? true {
                if let a = anchor(g.lowerBound) { return StripDrop(windowID: a, edge: -1, newScreen: true) }
                return n > 0 ? after(n - 1) : target
            }
            guard p.x > last.maxX else { continue }
            if n + 1 < groups.count, let next = frame(groups[n + 1].lowerBound), sameRow(next, last), p.x >= next.minX {
                continue
            }
            return after(n)
        }
        return target
    }

    private func controls(_ c: Column) -> some View {
        VStack(spacing: 4) {
            // Narrow columns drop the percent signs and tighten up.
            ViewThatFits(in: .horizontal) {
                controlRow(c, compact: false)
                controlRow(c, compact: true)
            }
            if c.isStack { stackRow(c) }
        }
    }

    private func stackRow(_ c: Column) -> some View {
        HStack(spacing: 3) {
            Button { model.onAction(.toggleTabs(c.windowID)) } label: {
                Image(systemName: c.tabbed ? "rectangle.split.1x2" : "menubar.rectangle")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(L("Show stack as tabs / rows"))
            Button { model.onAction(.sideBySide(c.windowID)) } label: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(L("Side by side"))
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
        }
    }

}

/// The desktop picture, filling its frame; a deep gradient when there is none to read.
private struct Wallpaper: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            LinearGradient(colors: [Color(red: 0.2, green: 0.26, blue: 0.4), Color(red: 0.06, green: 0.07, blue: 0.12)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// How a window looks on a miniature screen: a small glass window with its app's icon and title,
/// lit up when highlighted, a dot under the focused one.
private struct TileFace: View {
    let tile: OverviewTile?
    let size: CGSize
    let selected: Bool
    let focused: Bool
    let dimmed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let showsTitle = size.height >= 62 && size.width >= 64
        let iconSide = max(min(44, size.height - (showsTitle ? 30 : 10), size.width - 14), 12)
        VStack(spacing: 3) {
            if let icon = tile?.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: iconSide, height: iconSide)
            } else {
                Image(systemName: "macwindow").font(.system(size: iconSide * 0.6)).frame(width: iconSide, height: iconSide)
            }
            if showsTitle {
                Text(tile?.title ?? "")
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 6)
        .opacity(dimmed ? 0.45 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassSurface(shape)
        .overlay(shape.fill(Color.white.opacity(selected ? 0.22 : 0)).allowsHitTesting(false))
        .overlay(alignment: .bottom) {
            if focused {
                Circle().fill(Color.primary.opacity(0.75)).frame(width: 4, height: 4).padding(.bottom, 3)
            }
        }
        .shadow(color: .black.opacity(selected ? 0.22 : 0), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}
