import AppKit
import StripCore
import SwiftUI

/// Tab bars drawn above tabbed columns (in the strip they reserve `LayoutEngine.tabBarHeight`).
@MainActor
final class TabBars {
    struct Tab: Equatable {
        let id: WindowID
        let title: String
        let icon: NSImage?
        let isActive: Bool
    }

    struct Bar {
        /// Identifies the column: its windows, independent of order.
        let key: String
        /// AX-space rect of the bar.
        let frame: CGRect
        let isVisible: Bool
        /// nil keeps the current content (cheap updates while animating).
        let tabs: [Tab]?
    }

    var onSelect: ((WindowID) -> Void)?
    private var bars: [String: (displayID: CGDirectDisplayID, panel: NSPanel, model: TabBarModel)] = [:]

    static func key(for column: Column) -> String {
        column.windows.sorted().map(String.init).joined(separator: "-")
    }

    /// Shows exactly `newBars` for this display; bars of columns that are gone are removed.
    func update(displayID: CGDirectDisplayID, bars newBars: [Bar]) {
        let keys = Set(newBars.map(\.key))
        for (key, bar) in bars where bar.displayID == displayID && !keys.contains(key) {
            bar.panel.orderOut(nil)
            bars.removeValue(forKey: key)
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for bar in newBars {
            let entry = bars[bar.key] ?? makeBar(displayID: displayID)
            bars[bar.key] = entry
            if let tabs = bar.tabs, tabs != entry.model.tabs { entry.model.tabs = tabs }
            guard bar.isVisible else {
                entry.panel.orderOut(nil)
                continue
            }
            let appKitFrame = CGRect(x: bar.frame.minX, y: primaryHeight - bar.frame.maxY,
                                     width: bar.frame.width, height: bar.frame.height)
            if entry.panel.frame != appKitFrame { entry.panel.setFrame(appKitFrame, display: true) }
            if !entry.panel.isVisible { entry.panel.orderFrontRegardless() }
        }
    }

    func removeAll() {
        bars.values.forEach { $0.panel.orderOut(nil) }
        bars.removeAll()
    }

    private func makeBar(displayID: CGDirectDisplayID) -> (displayID: CGDirectDisplayID, panel: NSPanel, model: TabBarModel) {
        let model = TabBarModel()
        model.onSelect = { [weak self] id in self?.onSelect?(id) }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .normal
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.contentView = NSHostingView(rootView: TabBarView(model: model))
        return (displayID, panel, model)
    }
}

@MainActor
final class TabBarModel: ObservableObject {
    @Published var tabs: [TabBars.Tab] = []
    var onSelect: ((WindowID) -> Void)?
}

private struct TabBarView: View {
    @ObservedObject var model: TabBarModel

    var body: some View {
        HStack(spacing: 3) {
            ForEach(model.tabs, id: \.id) { tab in
                HStack(spacing: 5) {
                    if let icon = tab.icon {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    Text(tab.title.isEmpty ? "—" : tab.title)
                        .font(.system(size: 11, weight: tab.isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(tab.isActive ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tab.isActive ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { model.onSelect?(tab.id) }
                .help(tab.title)
            }
        }
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial).padding(.bottom, 3))
    }
}
