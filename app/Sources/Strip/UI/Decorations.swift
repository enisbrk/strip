import AppKit
import StripCore
import SwiftUI

/// AX (top-left origin) → AppKit (bottom-left origin) global coordinates.
@MainActor
func appKitRect(fromAX rect: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}

/// A panel AppKit never pushes back under the menu bar or onto the screen, so overlays can sit
/// exactly around windows that touch the screen edges.
final class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private func overlayPanel(level: NSWindow.Level) -> NSPanel {
    let panel = UnconstrainedPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.level = level
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return panel
}

/// Coloured outline around the focused window.
@MainActor
final class FocusBorder {
    private lazy var panel: NSPanel = {
        let p = overlayPanel(level: .floating)
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderWidth = 3
        view.layer?.cornerRadius = 12
        view.layer?.borderColor = NSColor.systemOrange.cgColor
        p.contentView = view
        return p
    }()

    /// `frame` in AX space; nil hides the border.
    func show(around frame: CGRect?) {
        guard let frame else {
            panel.orderOut(nil)
            return
        }
        let rect = appKitRect(fromAX: frame).insetBy(dx: -3, dy: -3)
        if panel.frame != rect { panel.setFrame(rect, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

/// Darkens everything behind the focused window: one translucent panel per display, ordered
/// directly below the focused window.
@MainActor
final class DimOverlay {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]

    func show(below windowID: WindowID?, displays: [(id: CGDirectDisplayID, frame: CGRect)], amount: CGFloat) {
        guard let windowID else {
            hide()
            return
        }
        for (id, frame) in displays {
            let panel = panels[id] ?? {
                let p = overlayPanel(level: .normal)
                p.contentView = NSView()
                p.contentView?.wantsLayer = true
                panels[id] = p
                return p
            }()
            panel.contentView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(amount).cgColor
            let rect = appKitRect(fromAX: frame)
            if panel.frame != rect { panel.setFrame(rect, display: true) }
            panel.order(.below, relativeTo: Int(windowID))
        }
        for (id, panel) in panels where !displays.contains(where: { $0.id == id }) {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
        }
    }

    func hide() {
        panels.values.forEach { $0.orderOut(nil) }
    }
}

// MARK: - Minimap

/// The shortcut shown above the minimap after it was pressed.
struct MinimapCaption: Equatable {
    /// Key caps, e.g. ["⌃", "⌥", "→"]; empty when the command came from the menu or a URL.
    let keys: [String]
    let title: String
}

@MainActor
final class MinimapModel: ObservableObject {
    @Published var overview = Overview.empty
    @Published var focusedIndex: Int?
    /// Strip mode: on-screen part of the strip; grid presets: the page on screen.
    @Published var highlight: CGRect?
    @Published var showsMap = true
    @Published var caption: MinimapCaption?
}

/// A small glass map of the strip shown above the Dock while navigating, then faded out, with
/// the shortcut that was just pressed above it.
@MainActor
final class Minimap {
    private static let maxWidth: CGFloat = 260
    private static let maxHeight: CGFloat = 46
    /// How long a caption stays after its key press (later scroll updates keep it).
    private static let captionHold: TimeInterval = 1.4
    private var panels: [CGDirectDisplayID: (panel: NSPanel, model: MinimapModel, hosting: NSHostingView<MinimapView>)] = [:]
    private var fadeWork: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var captionTime: [CGDirectDisplayID: Date] = [:]

    /// - Parameters:
    ///   - showMap: false shows only the caption (minimap turned off in Settings).
    ///   - caption: the shortcut just used; nil keeps a recent caption on screen.
    func show(displayID: CGDirectDisplayID, screen: NSScreen, strip: Strip, preset: LayoutPreset,
              engine: LayoutEngine, showMap: Bool = true, caption: MinimapCaption? = nil) {
        let entry = panels[displayID] ?? makePanel(displayID)
        let model = entry.model

        if let caption {
            model.caption = caption
            captionTime[displayID] = Date()
        } else if let shown = captionTime[displayID], Date().timeIntervalSince(shown) > Self.captionHold {
            model.caption = nil
        }
        model.showsMap = showMap && !strip.columns.isEmpty
        guard model.showsMap || model.caption != nil else { return }

        if model.showsMap {
            // Lay the map out large (no wrapping), then scale it down to minimap size.
            var o = Overview.make(strip: strip, preset: preset, engine: engine,
                                  maxSize: CGSize(width: 100_000, height: 100_000), compact: true)
            o = o.scaled(by: min(Self.maxWidth / o.size.width, Self.maxHeight / o.size.height, 1))
            model.overview = o
            model.focusedIndex = strip.focusedIndex
            if preset == .strip {
                model.highlight = o.viewport
            } else if let f = strip.focusedIndex {
                let page = engine.page(of: f, preset: preset)
                model.highlight = o.pages.indices.contains(page) ? o.pages[page].insetBy(dx: -2, dy: -2) : nil
            }
        }

        let size = entry.hosting.fittingSize
        let visible = screen.visibleFrame
        let frame = CGRect(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 10,
                           width: size.width, height: size.height)
        entry.panel.setFrame(frame, display: true)
        fadeWork[displayID]?.cancel()
        entry.panel.alphaValue = 1
        entry.panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self, weak panel = entry.panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel?.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    guard let panel, panel.alphaValue == 0 else { return }
                    panel.orderOut(nil)
                    self?.panels[displayID]?.model.caption = nil
                }
            })
        }
        fadeWork[displayID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captionHold, execute: work)
    }

    func hideAll() {
        panels.values.forEach { $0.panel.orderOut(nil) }
    }

    private func makePanel(_ displayID: CGDirectDisplayID)
        -> (panel: NSPanel, model: MinimapModel, hosting: NSHostingView<MinimapView>) {
        let model = MinimapModel()
        let panel = overlayPanel(level: .statusBar)
        let hosting = NSHostingView(rootView: MinimapView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        let entry = (panel, model, hosting)
        panels[displayID] = entry
        return entry
    }
}

enum GlassStyle {
    /// Offscreen rendering (ImageRenderer) can't draw real glass; the diagnostics turn this on.
    nonisolated(unsafe) static var forceMaterial = false
}

extension View {
    /// macOS "Liquid Glass" on macOS 26 and later; a frosted material with a hairline before that.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *), !GlassStyle.forceMaterial {
            glassEffect(.regular, in: shape)
        } else {
            background(shape.fill(.ultraThinMaterial))
                .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
    }
}

struct MinimapView: View {
    @ObservedObject var model: MinimapModel

    var body: some View {
        VStack(spacing: 8) {
            if let caption = model.caption {
                CaptionView(caption: caption)
            }
            if model.showsMap {
                map
                    .padding(7)
                    .glassSurface(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
        .padding(12) // room for the glass shadow
        .fixedSize()
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.caption)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.focusedIndex)
    }

    private var map: some View {
        let o = model.overview
        return ZStack(alignment: .topLeading) {
            ForEach(Array(o.pages.enumerated()), id: \.offset) { _, page in
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.06))
                    .frame(width: page.width, height: page.height)
                    .position(x: page.midX, y: page.midY)
            }
            ForEach(o.targets, id: \.index) { t in
                let focused = t.index == model.focusedIndex
                if t.rows.isEmpty {
                    // Empty slot on a partly filled page.
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: max(t.rect.width, 2), height: t.rect.height)
                        .position(x: t.rect.midX, y: t.rect.midY)
                }
                // One tile per window of a stack; the focused window glows orange, the rest of its
                // column is a softer orange.
                ForEach(t.rows, id: \.windowID) { row in
                    Tile(focused: focused, active: row.isActive)
                        .frame(width: max(row.rect.width - 1, 2), height: max(row.rect.height, 1))
                        .position(x: row.rect.midX, y: row.rect.midY)
                }
                if let bar = t.tabBar {
                    HStack(spacing: 1) {
                        ForEach(0..<t.tabCount, id: \.self) { i in
                            Capsule().fill(focused && i == 0 ? Color.orange : Color.primary.opacity(0.35))
                        }
                    }
                    .frame(width: max(bar.width - 2, 2), height: max(bar.height - 1, 1))
                    .position(x: bar.midX, y: bar.midY)
                }
            }
            if let h = model.highlight {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.75), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .frame(width: h.width + 4, height: h.height + 4)
                    .position(x: h.midX, y: h.midY)
            }
        }
        .frame(width: o.size.width, height: o.size.height)
    }

    private struct Tile: View {
        let focused: Bool
        let active: Bool

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
            if focused {
                shape
                    .fill(LinearGradient(colors: [Color.orange.opacity(active ? 1 : 0.55),
                                                  Color(red: 1, green: 0.45, blue: 0.1).opacity(active ? 1 : 0.45)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color.orange.opacity(active ? 0.6 : 0), radius: 4)
            } else {
                shape
                    .fill(Color.primary.opacity(0.22))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            }
        }
    }
}

/// "⌃ ⌥ →  Slide to next screen" in a glass capsule.
private struct CaptionView: View {
    let caption: MinimapCaption

    var body: some View {
        HStack(spacing: 8) {
            if !caption.keys.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(caption.keys.enumerated()), id: \.offset) { _, key in
                        Text(key)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(minWidth: 22, minHeight: 22)
                            .padding(.horizontal, key.count > 1 ? 5 : 0)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                    }
                }
            }
            Text(caption.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.leading, caption.keys.isEmpty ? 14 : 7)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .glassSurface(Capsule())
    }
}
