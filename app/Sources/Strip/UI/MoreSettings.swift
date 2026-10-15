import AppKit
import StripCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Apps

struct AppRulesSettings: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        Form {
            Section {
                if store.settings.appRules.isEmpty {
                    Text(L("No rules: every app's windows join the strip next to the focused window."))
                        .foregroundStyle(.secondary)
                }
                ForEach($store.settings.appRules) { $rule in
                    AppRuleRow(rule: $rule) {
                        store.settings.appRules.removeAll { $0.bundleID == rule.bundleID }
                    }
                }
            } header: {
                HStack {
                    Text(L("App rules"))
                    Spacer()
                    addMenu
                }
            } footer: {
                Text(L("Windows that can't be resized and dialogs always float. ⌃⌥T floats any window by hand."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var addMenu: some View {
        Menu(L("Add App")) {
            let ruled = Set(store.settings.appRules.map(\.bundleID))
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !ruled.contains($0.bundleIdentifier!) }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            ForEach(apps, id: \.processIdentifier) { app in
                Button(app.localizedName ?? app.bundleIdentifier!) { add(app.bundleIdentifier!, name: app.localizedName) }
            }
            Divider()
            Button(L("Other…")) { chooseApp() }
        }
        .fixedSize()
    }

    private func add(_ bundleID: String, name: String?) {
        guard !store.settings.appRules.contains(where: { $0.bundleID == bundleID }) else { return }
        store.settings.appRules.append(AppRule(bundleID: bundleID, appName: name ?? bundleID))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier else { return }
        add(id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
    }
}

private struct AppRuleRow: View {
    @Binding var rule: AppRule
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: AppIcons.icon(for: rule.bundleID)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppIcons.name(for: rule.bundleID) ?? rule.appName).lineLimit(1)
                Text(rule.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("", selection: $rule.float) {
                Text(L("Tile")).tag(false)
                Text(L("Float")).tag(true)
            }
            .labelsHidden()
            .fixedSize()
            if !rule.float {
                Picker("", selection: $rule.width) {
                    Text(L("Default width")).tag(CGFloat?.none)
                    ForEach([1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 1.0], id: \.self) { w in
                        Text("\(Int((w * 100).rounded()))%").tag(CGFloat?(w))
                    }
                }
                .labelsHidden()
                .fixedSize()
                Picker("", selection: $rule.position) {
                    Text(L("Next to focused")).tag(AppPosition.nextToFocus)
                    Text(L("Always first")).tag(AppPosition.first)
                    Text(L("Always last")).tag(AppPosition.last)
                }
                .labelsHidden()
                .fixedSize()
            }
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(L("Delete rule"))
        }
    }
}

enum AppIcons {
    @MainActor
    static func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    /// The app's name in the system language.
    @MainActor
    static func name(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

// MARK: - Displays

struct DisplaysSettings: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(NSScreen.screens, id: \.self) { screen in
                    let uuid = Self.uuid(of: screen)
                    Toggle(isOn: Binding(
                        get: { !store.settings.disabledDisplays.contains(uuid) },
                        set: { managed in
                            if managed {
                                store.settings.disabledDisplays.removeAll { $0 == uuid }
                            } else if !store.settings.disabledDisplays.contains(uuid) {
                                store.settings.disabledDisplays.append(uuid)
                            }
                        }
                    )) {
                        VStack(alignment: .leading) {
                            Text(screen.localizedName + (screen == NSScreen.screens.first ? " " + L("(main display)") : ""))
                            Text("\(Int(screen.frame.width)) × \(Int(screen.frame.height)) pt")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(L("Displays Strip manages"))
            } footer: {
                Text(L("Strip leaves windows on a display you turn off alone. Drag a window from there to a managed display and it joins the strip. Each display has its own strip; ⌃⌥N sends the focused window to the next display."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    static func uuid(of screen: NSScreen) -> String {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return "" }
        return Spaces.displayUUID(CGDirectDisplayID(n.uint32Value)) ?? String(n.uint32Value)
    }
}

// MARK: - Setup

struct SetupSettings: View {
    @EnvironmentObject private var setup: MacSetup
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var manager: WindowManager
    @State private var automationMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(setup.checks) { check in
                    SetupCheckRow(check: check)
                }
            } header: {
                HStack {
                    Text(L("Mac Setup"))
                    Spacer()
                    Button(L("Check Again")) { refresh() }.controlSize(.small)
                }
            }

            Section(L("Automation")) {
                LabeledContent(L("Command-line tool")) {
                    Button(L("Install")) {
                        do {
                            let url = try Automation.installCommandLineTool()
                            automationMessage = Automation.isCommandLineToolOnPath
                                ? L("Installed: %@. Example: strip focus-right", url.path)
                                : L("Installed: %@. Add ~/.local/bin to your shell's PATH.", url.path)
                        } catch {
                            automationMessage = L("Could not install: %@", error.localizedDescription)
                        }
                    }
                }
                LabeledContent(L("Raycast commands")) {
                    Button(L("Create and Show")) {
                        do {
                            let url = try Automation.exportRaycastScripts()
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                            automationMessage = L("In Raycast, add this folder under Extensions → Script Commands → Add Directories.")
                        } catch {
                            automationMessage = L("Could not create: %@", error.localizedDescription)
                        }
                    }
                }
                Text(L("URL scheme: %@", "strip://run/focus-left, strip://run/stack-right, strip://restart"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let automationMessage {
                    Text(automationMessage).font(.caption).textSelection(.enabled)
                }
            }

            UpdateSettingsSection()

            Section(L("Engine")) {
                LabeledContent(L("Status")) {
                    Text(manager.isEnabled ? L("Running") : L("Stopped"))
                        .foregroundStyle(manager.isEnabled ? .green : .secondary)
                }
                HStack {
                    Button(L("Restart Engine")) { manager.restart() }
                    Button(L("Open Log")) { NSWorkspace.shared.open(Log.url) }
                    Button(L("Show Welcome Tour")) { Onboarding.show() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func refresh() {
        setup.refresh(trackpadFingers: store.settings.trackpadFingers ?? TrackpadSwipe.defaultFingerCount())
    }
}

struct SetupCheckRow: View {
    let check: MacSetup.Check

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let title = check.fixTitle, let fix = check.fix {
                Button(title, action: fix).controlSize(.small)
            }
        }
    }

    private var icon: String {
        switch check.status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch check.status {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        }
    }
}
