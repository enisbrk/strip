import Carbon.HIToolbox
import StripCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var manager: WindowManager
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var permission: Permission
    @EnvironmentObject private var setup: MacSetup
    @EnvironmentObject private var shortcuts: ShortcutStore
    @EnvironmentObject private var updater: Updater

    /// The shortcuts listed right in the menu; all of them are in Settings → Shortcuts.
    private static let essentials: [Command] = [
        .screenLeft, .screenRight, .editStrip, .focusLeft, .focusRight, .moveLeft, .moveRight,
        .cycleWidth, .fullWidth, .stackLeft, .popOutRight, .toggleTabbed, .toggleFloat,
    ]

    var body: some View {
        if !permission.isTrusted {
            Text(L("Accessibility permission needed"))
            Button(L("Grant Permission…")) { permission.prompt() }
            Divider()
        }

        Button(manager.isEnabled ? L("Stop Strip") : L("Start Strip")) {
            manager.perform(.toggleEnabled)
        }
        .disabled(!permission.isTrusted)
        .keyboardShortcutIfBound(shortcuts.bindings(for: .toggleEnabled).first)

        if manager.isEnabled {
            Text(L("Windows managed: %d", manager.tiledCount))
        }

        Divider()
        Picker(L("Layout"), selection: $store.settings.layout) {
            ForEach(LayoutPreset.allCases, id: \.self) { preset in
                Label { Text(L(preset.title)) } icon: { Image(nsImage: LayoutIcon.image(for: preset)) }
                    .tag(preset)
            }
        }

        Section(L("Shortcuts")) {
            ForEach(Self.essentials, id: \.id) { command in
                // Shows the key combination on the right like any menu item; clicking runs it too.
                Button(command.title) { manager.perform(command) }
                    .keyboardShortcutIfBound(shortcuts.bindings(for: command).first)
                    .disabled(!manager.isEnabled)
            }
        }

        Divider()
        if setup.problemCount > 0 {
            Text(L("Mac Setup: %d suggestions (Settings → Setup)", setup.problemCount))
        }
        Button(L("Restart Engine")) { manager.restart() }
            .disabled(!permission.isTrusted)
        Button(L("Show Welcome Tour")) { Onboarding.show() }
        Button(L("Check for Updates…")) { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)

        Divider()
        Button(L("About Strip")) { AboutWindow.show(updater: updater) }
        settingsButton
        Button(L("Quit Strip")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14, *) {
            OpenSettingsButton()
        } else {
            Button(L("Settings…")) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                SettingsWindow.bringToFront()
            }
            .keyboardShortcut(",")
        }
    }
}

@available(macOS 14, *)
private struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(L("Settings…")) {
            openSettings()
            SettingsWindow.bringToFront()
        }
        .keyboardShortcut(",")
    }
}

/// Strip is a menu bar app, so opening Settings doesn't bring it forward by itself: the window
/// could stay behind other apps or on another Space. Pull it to this Space and in front.
@MainActor
enum SettingsWindow {
    static func bringToFront() {
        // The window may only exist after SwiftUI handled the open request.
        for delay in [0.0, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { focus() }
        }
    }

    /// Clicking the menu bar icon brings an open Settings window forward when it's behind other
    /// windows, minimized or on another Space.
    static func bringForwardWhenMenuOpens() {
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                // Pop-up menus inside Settings send this too; leave a window that's already in front alone.
                guard let window = openWindow(), !(NSApp.isActive && window.isKeyWindow) else { return }
                focus()
            }
        }
    }

    private static func openWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter {
            ($0.isVisible || $0.isMiniaturized) && !($0 is NSPanel) && $0.styleMask.contains(.titled)
        }
        return candidates.first(where: { $0.identifier?.rawValue.contains("Settings") == true })
            ?? candidates.first(where: { $0.title != L("Welcome to Strip") && $0.title != L("About Strip") })
    }

    private static func focus() {
        guard let window = openWindow() else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private extension View {
    /// Attaches the binding as the menu item's key equivalent, so the menu shows it.
    @ViewBuilder
    func keyboardShortcutIfBound(_ binding: KeyBinding?) -> some View {
        if let binding, let key = binding.keyEquivalent {
            keyboardShortcut(key, modifiers: binding.eventModifiers)
        } else {
            self
        }
    }
}

extension KeyBinding {
    var eventModifiers: SwiftUI.EventModifiers {
        var m: SwiftUI.EventModifiers = []
        if control { m.insert(.control) }
        if option { m.insert(.option) }
        if shift { m.insert(.shift) }
        if command { m.insert(.command) }
        return m
    }

    /// The key as a SwiftUI key equivalent (arrows and other special keys included).
    var keyEquivalent: KeyEquivalent? {
        switch Int(keyCode) {
        case kVK_LeftArrow: return .leftArrow
        case kVK_RightArrow: return .rightArrow
        case kVK_UpArrow: return .upArrow
        case kVK_DownArrow: return .downArrow
        case kVK_Home: return .home
        case kVK_End: return .end
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        case kVK_Tab: return .tab
        case kVK_Space: return .space
        case kVK_Return: return .return
        case kVK_Escape: return .escape
        case kVK_Delete: return .delete
        case kVK_ForwardDelete: return .deleteForward
        default:
            let name = KeyBinding.keyName(keyCode)
            guard name.count == 1, let c = name.lowercased().first else { return nil }
            return KeyEquivalent(c)
        }
    }
}
