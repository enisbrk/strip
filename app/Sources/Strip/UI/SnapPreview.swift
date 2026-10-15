import AppKit
import SwiftUI

@MainActor
final class SnapPreviewModel: ObservableObject {
    /// Where the window will land, in the panel's (top-left origin) coordinates; nil hides it.
    @Published var frame: CGRect?
}

/// The glass outline of where a window dragged against a screen edge will land, drawn on the
/// screen itself (like macOS window tiling) until the mouse is released.
@MainActor
final class SnapPreview {
    private let model = SnapPreviewModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { model.frame != nil }

    /// - Parameter frame: in AppKit screen coordinates.
    func show(_ frame: CGRect, on screen: NSScreen) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.frame != screen.frame || !panel.isVisible {
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
        }
        let local = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                           width: frame.width, height: frame.height)
        guard local != model.frame else { return }
        // The first frame appears in place; later ones glide there.
        if model.frame == nil {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { model.frame = local }
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { model.frame = local }
        }
    }

    func hide() {
        guard model.frame != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.frame = nil }
        let work = DispatchWorkItem { [weak self] in
            guard self?.model.frame == nil else { return }
            self?.panel?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = UnconstrainedPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: SnapPreviewView(model: model))
        return panel
    }
}

private struct SnapPreviewView: View {
    @ObservedObject var model: SnapPreviewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let frame = model.frame {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                shape.fill(Color.white.opacity(0.08))
                    .glassSurface(shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}
