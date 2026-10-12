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
    @Published var hovered: OverviewTarget?
    var tiles: [WindowID: OverviewTile] = [:]
    var draggedID: WindowID?
}

/// Floating, click-through panel in the middle of the screen showing every screen in miniature
/// while a window is being dragged. The mouse is polled, so the drag itself is never interrupted.
@MainActor
final class DragOverview {
    private let model = DragOverviewModel()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }
    var hoveredTarget: OverviewTarget? { model.hovered }

    func show(overview: Overview, tiles: [WindowID: OverviewTile], dragged: WindowID, on screen: NSScreen) {
        model.overview = overview
        model.tiles = tiles
        model.draggedID = dragged
        model.hovered = nil

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
        guard let panel, panel.isVisible else { return }
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let target = model.overview.target(at: local)
        if target != model.hovered { model.hovered = target }
    }

    func hide() {
        panel?.orderOut(nil)
        model.hovered = nil
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

    var body: some View {
        let o = model.overview
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15)))

            ForEach(Array(o.pages.enumerated()), id: \.offset) { i, page in
                Text(L("Screen %d", i + 1))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .position(x: page.midX, y: page.minY - Overview.labelHeight / 2)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.25))
                    .frame(width: page.width, height: page.height)
                    .position(x: page.midX, y: page.midY)
            }

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

            ForEach(o.targets, id: \.index) { target in
                let hovered = model.hovered?.index == target.index
                if target.rows.isEmpty {
                    TileView(tile: nil, isDragged: false, isHovered: hovered)
                        .frame(width: target.rect.width, height: target.rect.height)
                        .position(x: target.rect.midX, y: target.rect.midY)
                }
                ForEach(target.rows, id: \.windowID) { row in
                    TileView(tile: model.tiles[row.windowID], isDragged: row.windowID == model.draggedID,
                             isHovered: hovered)
                        .frame(width: row.rect.width, height: row.rect.height)
                        .position(x: row.rect.midX, y: row.rect.midY)
                }
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
