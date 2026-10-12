import AppKit
import ApplicationServices
import StripCore
import SwiftUI

/// `open -n Strip.app --args --diagnose` writes a report of how every window is seen through
/// the Accessibility API, without managing anything, then quits.
@MainActor
enum Diagnostics {
    static let reportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Strip-diagnose.txt")

    static func run() {
        var lines = ["trusted: \(AXIsProcessTrusted())"]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            let windows = AX.elements(ax, kAXWindowsAttribute)
            lines.append("\n\(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "-")] pid=\(app.processIdentifier) hidden=\(app.isHidden) windows=\(windows.count)")
            for element in windows {
                let id = AX.windowID(of: element).map(String.init) ?? "nil"
                guard let w = AXWindow(element: element, pid: app.processIdentifier) else {
                    lines.append("  id=\(id) (no window id) role=\(AX.value(element, kAXRoleAttribute, as: String.self) ?? "nil")")
                    continue
                }
                lines.append("  id=\(id) role=\(w.role ?? "nil") subrole=\(w.subrole ?? "nil") resizable=\(w.isResizable) min=\(w.isMinimized) fs=\(w.isFullscreen) frame=\(w.frame.map { "\($0)" } ?? "nil") title=\(w.title)")
            }
        }
        try? lines.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
    }

    /// `--fullscreen <windowID> on|off`: toggles native full screen on one window (test hook).
    static func setFullscreen(windowID: WindowID, on: Bool) {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            for element in AX.elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute)
            where AX.windowID(of: element) == windowID {
                AX.set(element, "AXFullScreen", on ? kCFBooleanTrue : kCFBooleanFalse)
            }
        }
    }

    /// `--render-overview <png>`: draws the drag overview for the current windows, for checking its look.
    static func renderOverview(to path: String, layout: LayoutPreset, settings: StripCore.Settings) {
        var strip = Strip()
        var tiles: [WindowID: OverviewTile] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
            for element in AX.elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) {
                guard let w = AXWindow(element: element, pid: app.processIdentifier),
                      w.isStandardWindow, !w.isMinimized else { continue }
                strip.append(w.id, width: settings.defaultWidth)
                tiles[w.id] = OverviewTile(icon: app.icon, title: w.title.isEmpty ? app.localizedName ?? "" : w.title)
            }
        }
        if CommandLine.arguments.contains("--with-stacks"), strip.columns.count >= 5 {
            // Column 1 becomes a stack of two, column 3 a tabbed stack of two.
            strip.focus(index: 1)
            strip.stackFocused(direction: -1)
            strip.focus(index: 2)
            strip.stackFocused(direction: -1)
            strip.toggleFocusedTabbed()
            strip.focus(index: 0)
        } else {
            strip.focus(index: 2)
        }
        guard let screen = NSScreen.screens.first else { return }
        let visible = AX.axRect(fromAppKit: screen.visibleFrame)
        let engine = LayoutEngine(screen: visible, settings: settings)
        strip.viewportOffset = layout == .strip ? engine.targetOffset(for: strip) : 0
        let maxSize = CGSize(width: visible.width * 0.8, height: visible.height * 0.8)
        let model = DragOverviewModel()
        model.overview = Overview.make(strip: strip, preset: layout, engine: engine, maxSize: maxSize)
        model.tiles = tiles
        model.draggedID = strip.columns.first?.windowID
        model.hovered = model.overview.targets.dropFirst(3).first
        let renderer = ImageRenderer(content: OverviewView(model: model).background(Color(white: 0.3)))
        renderer.scale = 1
        write(renderer.nsImage, to: path)

        // The minimap of the same strip, next to it.
        var mini = Overview.make(strip: strip, preset: layout, engine: engine,
                                 maxSize: CGSize(width: 100_000, height: 100_000), compact: true)
        mini = mini.scaled(by: min(240 / mini.size.width, 44 / mini.size.height, 1))
        GlassStyle.forceMaterial = true
        let miniModel = MinimapModel()
        miniModel.overview = mini
        miniModel.focusedIndex = strip.focusedIndex
        miniModel.highlight = layout == .strip ? mini.viewport : mini.pages.first
        miniModel.caption = MinimapCaption(keys: ["⌃", "⌥", "→"], title: Command.screenRight.title)
        let miniRenderer = ImageRenderer(content: MinimapView(model: miniModel).padding(10).background(Color(white: 0.85)))
        miniRenderer.scale = 3
        write(miniRenderer.nsImage, to: path.replacingOccurrences(of: ".png", with: "-minimap.png"))
    }

    private static func write(_ image: NSImage?, to path: String) {
        guard let tiff = image?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
