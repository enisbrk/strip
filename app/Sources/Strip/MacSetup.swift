import AppKit
import ApplicationServices
import StripCore

/// Checks the macOS settings and other apps that affect Strip ("Mac Setup").
@MainActor
final class MacSetup: ObservableObject {
    enum Status { case ok, warning, problem }

    struct Check: Identifiable {
        let id: String
        let title: String
        let status: Status
        let detail: String
        /// What the fix button says and does (opens the right System Settings pane, quits an app…).
        var fixTitle: String?
        var fix: (() -> Void)?
    }

    @Published private(set) var checks: [Check] = []

    var problemCount: Int { checks.filter { $0.status != .ok }.count }

    /// Window managers that would fight Strip over window positions.
    static let conflictingApps: [String: String] = [
        "com.knollsoft.Rectangle": "Rectangle",
        "com.knollsoft.Hookshot": "Hookshot",
        "com.crowdcafe.windowmagnet": "Magnet",
        "com.manytricks.Moom": "Moom",
        "com.amethyst.Amethyst": "Amethyst",
        "bobko.aerospace": "AeroSpace",
        "com.hegenberg.BetterSnapTool": "BetterSnapTool",
        "com.mizage.Divvy": "Divvy",
        "com.divisiblebyzero.Spectacle": "Spectacle",
        "com.sergey-gorbunov.Loop": "Loop",
        "com.MrKai77.Loop": "Loop",
    ]

    func refresh(trackpadFingers: Int) {
        var list: [Check] = []

        let trusted = AXIsProcessTrusted()
        list.append(Check(
            id: "accessibility", title: L("Accessibility permission"),
            status: trusted ? .ok : .problem,
            detail: trusted ? L("Strip can move windows.") : L("The only permission Strip needs to move windows."),
            fixTitle: trusted ? nil : L("Open Settings"),
            fix: trusted ? nil : { Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
        ))

        let running = NSWorkspace.shared.runningApplications
        var conflicts = running.compactMap { app -> (String, NSRunningApplication)? in
            guard let id = app.bundleIdentifier, let name = Self.conflictingApps[id] else { return nil }
            return (name, app)
        }
        // yabai is a command-line daemon without a bundle.
        if Self.isProcessRunning("yabai"), let app = running.first(where: { $0.localizedName == "yabai" }) {
            conflicts.append(("yabai", app))
        }
        if conflicts.isEmpty {
            list.append(Check(id: "conflicts", title: L("Conflicting window managers"), status: .ok,
                              detail: L("Rectangle, Magnet, Moom, Amethyst, yabai, AeroSpace… aren't running.")))
        } else {
            let names = conflicts.map(\.0).joined(separator: ", ")
            list.append(Check(
                id: "conflicts", title: L("Conflicting window managers"), status: .problem,
                detail: L("%@ is running and moves windows at the same time as Strip.", names),
                fixTitle: conflicts.count == 1 ? L("Quit %@", names) : L("Quit All"),
                fix: { conflicts.forEach { $0.1.terminate() } }
            ))
        }

        // "Displays have separate Spaces": true unless spans-displays is set.
        let spansDisplays = Self.bool("spans-displays", domain: "com.apple.spaces") ?? false
        if NSScreen.screens.count > 1 || spansDisplays {
            list.append(Check(
                id: "separate-spaces", title: L("Displays have separate Spaces"),
                status: spansDisplays ? .warning : .ok,
                detail: spansDisplays
                    ? L("Off: switching Spaces switches every display together. Turning it on is recommended (needs logging out).")
                    : L("On: every display has its own Spaces and strips."),
                fixTitle: spansDisplays ? L("Desktop & Dock Settings") : nil,
                fix: spansDisplays ? { Self.open("x-apple.systempreferences:com.apple.Desktop-Settings.extension") } : nil
            ))
        }

        let rearranges = Self.bool("mru-spaces", domain: "com.apple.dock") ?? true
        list.append(Check(
            id: "mru-spaces", title: L("Automatically rearrange Spaces based on most recent use"),
            status: rearranges ? .warning : .ok,
            detail: rearranges
                ? L("On: macOS reorders your Spaces by itself, so strips seem to swap places.")
                : L("Off."),
            fixTitle: rearranges ? L("Desktop & Dock Settings") : nil,
            fix: rearranges ? { Self.open("x-apple.systempreferences:com.apple.Desktop-Settings.extension") } : nil
        ))

        let stageManager = Self.bool("GloballyEnabled", domain: "com.apple.WindowManager") ?? false
        list.append(Check(
            id: "stage-manager", title: L("Stage Manager"),
            status: stageManager ? .problem : .ok,
            detail: stageManager ? L("On: it arranges windows its own way and doesn't work with Strip.") : L("Off."),
            fixTitle: stageManager ? L("Desktop & Dock Settings") : nil,
            fix: stageManager ? { Self.open("x-apple.systempreferences:com.apple.Desktop-Settings.extension") } : nil
        ))

        let edgeTiling = (Self.bool("EnableTilingByEdgeDrag", domain: "com.apple.WindowManager") ?? true)
            || (Self.bool("EnableTopTilingByEdgeDrag", domain: "com.apple.WindowManager") ?? true)
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) {
            list.append(Check(
                id: "edge-tiling", title: L("Tile windows by dragging them to screen edges"),
                status: edgeTiling ? .warning : .ok,
                detail: edgeTiling
                    ? L("On: while you drag a window, macOS tries to place it too. Turning it off is recommended.")
                    : L("Off."),
                fixTitle: edgeTiling ? L("Desktop & Dock Settings") : nil,
                fix: edgeTiling ? { Self.open("x-apple.systempreferences:com.apple.Desktop-Settings.extension") } : nil
            ))
        }

        if trackpadFingers > 0 {
            let systemThree = TrackpadSwipe.defaultFingerCount() == 4
            let clash = trackpadFingers == 3 && systemThree
            list.append(Check(
                id: "trackpad", title: L("Trackpad swipe (%d fingers)", trackpadFingers),
                status: clash ? .warning : .ok,
                detail: clash
                    ? L("macOS also swipes between Spaces with 3 fingers, so both would react. Set Strip to 4 fingers or change the macOS gesture.")
                    : L("No clash with macOS gestures."),
                fixTitle: clash ? L("Trackpad Settings") : nil,
                fix: clash ? { Self.open("x-apple.systempreferences:com.apple.Trackpad-Settings.extension") } : nil
            ))
        }

        checks = list
    }

    static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    private static func bool(_ key: String, domain: String) -> Bool? {
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else { return nil }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    private static func isProcessRunning(_ name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", name]
        task.standardOutput = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
