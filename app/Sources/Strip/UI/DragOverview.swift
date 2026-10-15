import AppKit
import StripCore
import SwiftUI

/// What a tile in the overview shows.
struct OverviewTile {
    let icon: NSImage?
    let title: String
}

@MainActor
final class DragOverviewModel: ObservableObject {
    @Published var overview = Overview.empty
    /// Grid presets: the slot under the pointer.
    @Published var hovered: OverviewTarget?
    /// Strip mode: where the window would land; `overview` then already shows the strip after it.
    @Published var stripDrop: StripDrop?
    var tiles: [WindowID: OverviewTile] = [:]
    var draggedID: WindowID?
}

/// Floating, click-through panel in the middle of the screen showing every screen in miniature
/// while a window is being dragged. The mouse is polled, so the drag itself is never interrupted.
@MainActor
final class DragOverview {
    private static let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)
    private let model = DragOverviewModel()
    private var panel: NSPanel?
    /// The overview of the strip after a drop (nil: as it is now).
    private var preview: ((StripDrop?) -> Overview)?
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { panel?.isVisible ?? false }
    var stripDrop: StripDrop? { model.stripDrop }

    /// - Parameter preview: the strip after a drop; the windows move aside live to show it.
    func show(overview: Overview, tiles: [WindowID: OverviewTile], dragged: WindowID, on screen: NSScreen,
              preview: @escaping (StripDrop?) -> Overview) {
        hideWork?.cancel()
        self.preview = preview
        model.overview = overview
        model.tiles = tiles
        model.draggedID = dragged
        model.hovered = nil
        model.stripDrop = nil

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let visible = screen.visibleFrame
        let origin = CGPoint(x: (visible.midX - overview.size.width / 2).rounded(),
                             y: (visible.midY - overview.size.height / 2).rounded())
        panel.setFrame(CGRect(origin: origin, size: overview.size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Updates the highlighted target for a mouse location in AppKit screen coordinates.
    func updateHover(mouse: CGPoint) {
        guard let panel, panel.isVisible, let preview else { return }
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let drop = stripDrop(at: local)
        guard drop != model.stripDrop else { return }
        let next = preview(drop)
        if next.size != model.overview.size {
            // Keep the panel centered where it was when the previewed strip changes size.
            let old = panel.frame
            panel.setFrame(CGRect(x: (old.midX - next.size.width / 2).rounded(), y: (old.midY - next.size.height / 2).rounded(),
                                  width: next.size.width, height: next.size.height), display: false)
        }
        withAnimation(Self.spring) {
            model.stripDrop = drop
            model.overview = next
        }
    }

    /// The column under the pointer in the strip as shown. Over the dragged window's own new
    /// place, or between columns, the current drop stays, so the preview doesn't flicker.
    private func stripDrop(at p: CGPoint) -> StripDrop? {
        let targets = model.overview.targets
        guard let top = targets.map(\.rect.minY).min(), let bottom = targets.map(\.rect.maxY).max(),
              p.y > top - 20, p.y < bottom + 20 else { return nil }
        for t in targets {
            guard let id = t.windowID, t.rect.insetBy(dx: -Overview.spacing / 2, dy: -20).contains(p) else { continue }
            if t.rows.contains(where: { $0.windowID == model.draggedID }) { return model.stripDrop }
            let band = t.rect.width * 0.25
            return StripDrop(windowID: id, edge: p.x < t.rect.minX + band ? -1 : p.x > t.rect.maxX - band ? 1 : nil)
        }
        return model.stripDrop
    }

    /// Fades the overview back while a screen edge (not the overview) is the drop target.
    func setDimmed(_ dimmed: Bool) {
        guard let panel, panel.isVisible else { return }
        let alpha: CGFloat = dimmed ? 0.25 : 1
        guard panel.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = alpha
        }
    }

    /// - Parameter after: keeps the final arrangement on screen a moment before fading out.
    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        guard delay > 0, let panel else {
            panel?.orderOut(nil)
            model.hovered = nil
            return
        }
        let work = DispatchWorkItem { [weak self, weak panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel?.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    guard let panel, panel.alphaValue == 0 else { return }
                    panel.orderOut(nil)
                    self?.model.hovered = nil
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverviewView(model: model))
        return panel
    }
}

struct OverviewView: View {
    @ObservedObject var model: DragOverviewModel

    /// One window of the overview; listed flat so a window keeps its identity (and animates)
    /// when the preview moves it to another column.
    private struct Item: Identifiable {
        let row: OverviewRow
        let target: Int
        var id: WindowID { row.windowID }
    }

    var body: some View {
        let o = model.overview
        let items = o.targets.flatMap { t in t.rows.map { Item(row: $0, target: t.index) } }
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.13).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15)))

            if let viewport = o.viewport {
                Text(L("Strip — the frame is what's on screen now"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .position(x: o.size.width / 2, y: Overview.padding + Overview.labelHeight / 2 - 4)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
                    .frame(width: viewport.width, height: viewport.height)
                    .position(x: viewport.midX, y: viewport.midY)
            }

            ForEach(o.targets.filter(\.rows.isEmpty), id: \.index) { target in
                TileView(tile: nil, isDragged: false, isHovered: model.hovered?.index == target.index)
                    .frame(width: target.rect.width, height: target.rect.height)
                    .position(x: target.rect.midX, y: target.rect.midY)
            }
            ForEach(items) { item in
                let isDragged = item.row.windowID == model.draggedID
                // Strip mode lights up where the dragged window lands; grid presets the slot.
                let lit = model.stripDrop != nil ? isDragged : model.hovered?.index == item.target
                TileView(tile: model.tiles[item.row.windowID], isDragged: isDragged, isHovered: lit)
                    .frame(width: item.row.rect.width, height: item.row.rect.height)
                    .position(x: item.row.rect.midX, y: item.row.rect.midY)
            }
            ForEach(o.targets.filter { $0.tabBar != nil }, id: \.index) { target in
                if let bar = target.tabBar {
                    HStack(spacing: 2) {
                        ForEach(0..<target.tabCount, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(i == 0 ? Color.white.opacity(0.35) : Color.white.opacity(0.15))
                        }
                    }
                    .frame(width: bar.width, height: bar.height)
                    .position(x: bar.midX, y: bar.midY)
                }
            }
        }
        .frame(width: o.size.width, height: o.size.height)
        // Drawn on a dark panel whatever the system appearance.
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.12), value: model.hovered?.index)
    }
}

private struct TileView: View {
    let tile: OverviewTile?
    let isDragged: Bool
    let isHovered: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.accentColor.opacity(0.45)
                      : tile == nil ? Color.white.opacity(0.05) : Color.white.opacity(0.14))
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isHovered ? Color.accentColor : Color.white.opacity(isDragged ? 0.8 : 0.2),
                              style: StrokeStyle(lineWidth: isHovered ? 2 : 1, dash: isDragged || tile == nil ? [4, 3] : []))
            if let tile {
                VStack(spacing: 2) {
                    if let icon = tile.icon {
                        Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                    }
                    Text(tile.title)
                        .font(.system(size: 9))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                }
                .padding(3)
                .opacity(isDragged ? 0.5 : 1)
            } else {
                Image(systemName: "plus").foregroundStyle(.secondary)
            }
        }
    }
}
