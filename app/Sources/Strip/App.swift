import AppKit
import ApplicationServices
import StripCore
import SwiftUI

@main
struct StripApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Strip", systemImage: "rectangle.split.3x1") {
            MenuView()
                .environmentObject(delegate.manager)
                .environmentObject(delegate.permission)
                .environmentObject(delegate.settings)
                .environmentObject(delegate.setup)
                .environmentObject(delegate.shortcuts)
                .environmentObject(delegate.updater)
        }
        Settings {
            SettingsView()
                .environmentObject(delegate.settings)
                .environmentObject(delegate.shortcuts)
                .environmentObject(delegate.recorder)
                .environmentObject(delegate.setup)
                .environmentObject(delegate.manager)
                .environmentObject(delegate.updater)
        }
    }
}

@MainActor
final class Permission: ObservableObject {
    @Published var isTrusted = AXIsProcessTrusted()

    func prompt() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        isTrusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    let permission = Permission()
    let shortcuts = ShortcutStore()
    let recorder = ShortcutRecorder()
    let setup = MacSetup()
    let updater = Updater()
    lazy var manager = WindowManager(settingsStore: settings)
    private var permissionTimer: Timer?
    private var watchdog: Timer?
    /// A strip:// request that arrived before window management was running.
    private var pendingURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--diagnose") {
            Diagnostics.run()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-overview"), i + 1 < CommandLine.arguments.count {
            Diagnostics.renderOverview(to: CommandLine.arguments[i + 1], settings: settings.settings)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--fullscreen"), i + 2 < CommandLine.arguments.count,
           let id = WindowID(CommandLine.arguments[i + 1]) {
            Diagnostics.setFullscreen(windowID: id, on: CommandLine.arguments[i + 2] == "on")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--print-strings"), i + 1 < CommandLine.arguments.count {
            // Test hook: writes a few interface strings in one language to the diagnose report.
            Localization.use(CommandLine.arguments[i + 1])
            let lines = [Command.screenRight.title, Command.focusIndex(2).title, L("Windows managed: %d", 7),
                         L("%@ now runs this instead of “%@”.", "⌃⌥H", Command.focusLeft.title),
                         L("System (%@)", AppLanguage.system.nativeName)]
            try? lines.joined(separator: "\n").write(to: Diagnostics.reportURL, atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--export-automation"), i + 1 < CommandLine.arguments.count {
            // Test hook: writes the CLI and Raycast scripts into a folder instead of installing them.
            let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            _ = try? Automation.installCommandLineTool(at: folder.appendingPathComponent("strip"))
            _ = try? Automation.exportRaycastScripts(to: folder.appendingPathComponent("Raycast"))
            exit(0)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.info("Strip \(version) launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        Localization.use(settings.settings.language)
        Onboarding.configure(self)
        SettingsWindow.bringForwardWhenMenuOpens()
        settings.onChange = { [weak self] new in
            Localization.use(new.language)
            self?.manager.settingsChanged()
        }
        shortcuts.onChange = { [weak self] in self?.registerHotkeys() }
        recorder.onRecordingChange = { [weak self] recording in
            if recording { Hotkeys.shared.unregisterAll() } else { self?.registerHotkeys() }
        }
        registerHotkeys()

        if permission.isTrusted {
            startEngine()
        } else {
            waitForPermission()
        }
        if !Onboarding.hasBeenSeen || !permission.isTrusted { Onboarding.show() }
        refreshSetup()
        startWatchdog()
    }

    private func refreshSetup() {
        setup.refresh(trackpadFingers: settings.settings.trackpadFingers ?? TrackpadSwipe.defaultFingerCount())
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave windows parked off screen.
        manager.stop()
        Log.info("Strip quit")
    }

    // MARK: - Engine

    private func startEngine() {
        manager.start()
        if let url = pendingURL {
            pendingURL = nil
            handle(url)
        }
    }

    private func waitForPermission() {
        permission.prompt()
        permissionTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                Log.info("Accessibility permission granted")
                self.permission.isTrusted = true
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                if self.manager.wantsEnabled { self.startEngine() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    /// Self-healing: pauses when the Accessibility permission goes away, and restarts the engine
    /// if it stopped or stopped answering while the user still wants it on.
    private func startWatchdog() {
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private var healthTicks = 0

    private func checkHealth() {
        healthTicks += 1
        if healthTicks % 12 == 0 { refreshSetup() }
        guard permissionTimer == nil else { return }
        guard AXIsProcessTrusted() else {
            Log.error("Accessibility permission was revoked; pausing until it is granted again")
            if manager.isEnabled { manager.stop() }
            permission.isTrusted = false
            waitForPermission()
            return
        }
        if manager.wantsEnabled && !manager.isEnabled {
            Log.warning("Engine was not running; starting it again")
            manager.start()
        } else if !manager.isHealthy() {
            Log.error("Engine stopped responding; restarting it")
            manager.restart()
        }
    }

    // MARK: - Shortcuts

    private func registerHotkeys() {
        Hotkeys.shared.unregisterAll()
        for command in Command.all {
            for binding in shortcuts.bindings(for: command) {
                Hotkeys.shared.register(binding) { [weak self] in self?.manager.perform(command, via: binding) }
            }
        }
    }

    // MARK: - strip:// URLs

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        handle(url)
    }

    private func handle(_ url: URL) {
        guard let action = Automation.action(for: url) else {
            Log.warning("Unknown URL \(url.absoluteString)")
            return
        }
        Log.info("URL \(url.absoluteString)")
        switch action {
        case .enable:
            if !manager.isEnabled { manager.perform(.toggleEnabled) }
        case .disable:
            if manager.isEnabled { manager.perform(.toggleEnabled) }
        case .restart:
            manager.restart()
        case .run(let command):
            guard manager.isEnabled || command == .toggleEnabled else {
                pendingURL = permission.isTrusted ? nil : url
                return
            }
            manager.perform(command)
        }
    }
}
