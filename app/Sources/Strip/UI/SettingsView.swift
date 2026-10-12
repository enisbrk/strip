import ServiceManagement
import StripCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(L("General"), systemImage: "gearshape") }
            AppRulesSettings().tabItem { Label(L("Apps"), systemImage: "app.badge") }
            DisplaysSettings().tabItem { Label(L("Displays"), systemImage: "display.2") }
            ShortcutsSettings().tabItem { Label(L("Shortcuts"), systemImage: "keyboard") }
            SetupSettings().tabItem { Label(L("Setup"), systemImage: "checkmark.shield") }
        }
        // Rebuild every view when the language changes, so all text switches at once.
        .id(store.settings.language ?? "system")
        .frame(width: 600, height: 560)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section(L("Language")) {
                Picker(L("Language"), selection: $store.settings.language) {
                    Text(L("System (%@)", AppLanguage.system.nativeName)).tag(String?.none)
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(String?(language.rawValue))
                    }
                }
            }
            Section(L("Layout")) {
                Picker(L("Layout"), selection: $store.settings.layout) {
                    ForEach(LayoutPreset.allCases, id: \.self) { preset in
                        Label { Text(L(preset.title)) } icon: { Image(nsImage: LayoutIcon.image(for: preset)) }
                            .tag(preset)
                    }
                }
                LabeledSlider(title: L("Gap between windows"), value: $store.settings.innerGap, range: 0...40)
                LabeledSlider(title: L("Gap at screen edges"), value: $store.settings.outerGap, range: 0...40)
                Picker(L("New window width"), selection: $store.settings.defaultWidth) {
                    ForEach(store.settings.presetWidths, id: \.self) { w in
                        Text("\(Int((w * 100).rounded()))%").tag(w)
                    }
                }
                Picker(L("Centering"), selection: $store.settings.centerMode) {
                    Text(L("Never")).tag(CenterMode.never)
                    Text(L("When the strip overflows")).tag(CenterMode.onOverflow)
                    Text(L("Always")).tag(CenterMode.always)
                }
            }
            Section(L("Appearance")) {
                Toggle(L("Focus border"), isOn: $store.settings.focusBorder)
                Toggle(L("Dim inactive windows"), isOn: $store.settings.dimInactive)
                if store.settings.dimInactive {
                    Slider(value: $store.settings.dimAmount, in: 0.1...0.6) { Text(L("Dimming")) }
                }
                Toggle(L("Show minimap while navigating"), isOn: $store.settings.minimap)
                Toggle(L("Show the shortcut you pressed"), isOn: $store.settings.shortcutHUD)
            }
            Section(L("Mouse")) {
                Toggle(L("Focus follows mouse"), isOn: $store.settings.focusFollowsMouse)
                Toggle(L("Mouse follows focus"), isOn: $store.settings.mouseFollowsFocus)
            }
            Section(L("Behavior")) {
                Toggle(L("Scroll animation"), isOn: $store.settings.animate)
                Picker(L("Trackpad swipe"), selection: $store.settings.trackpadFingers) {
                    Text(L("Automatic (%d fingers)", TrackpadSwipe.defaultFingerCount())).tag(Int?.none)
                    Text(L("3 fingers")).tag(Int?(3))
                    Text(L("4 fingers")).tag(Int?(4))
                    Text(L("Off")).tag(Int?(0))
                }
                .help(L("Don't pick the finger count macOS uses to swipe between Spaces."))
                Toggle(L("Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            Log.error("Launch at login failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range, step: 1)
            Text("\(Int(value)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}
