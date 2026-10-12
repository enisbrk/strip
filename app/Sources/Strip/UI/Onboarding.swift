import AppKit
import StripCore
import SwiftUI

/// Guided first run: what the strip is, the permission, Mac Setup and the core shortcuts.
@MainActor
enum Onboarding {
    private static let seenKey = "onboarding.seen.v1"
    private static var window: NSWindow?
    private static var environment: AppDelegate?

    static func configure(_ delegate: AppDelegate) { environment = delegate }

    static var hasBeenSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    static func show() {
        guard let env = environment else { return }
        if let window {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(close: { close() })
            .environmentObject(env.permission)
            .environmentObject(env.setup)
            .environmentObject(env.shortcuts)
            .environmentObject(env.settings)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.title = L("Welcome to Strip")
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.contentView = NSHostingView(rootView: view)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        UserDefaults.standard.set(true, forKey: seenKey)
        window?.close()
        window = nil
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var permission: Permission
    @EnvironmentObject private var setup: MacSetup
    @EnvironmentObject private var shortcuts: ShortcutStore
    @EnvironmentObject private var settings: SettingsStore
    let close: () -> Void
    @State private var page = 0
    private let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: permissionPage
                case 2: setupPage
                case 3: shortcutsPage
                default: finalPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)
            .padding(.top, 36)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 { Button(L("Back")) { page -= 1 } }
                if page < pageCount - 1 {
                    Button(L("Next")) { page += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Get Started")) { close() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 620, height: 480)
        .onAppear { refreshSetup() }
        .onChange(of: page) { _ in refreshSetup() }
    }

    private func refreshSetup() {
        setup.refresh(trackpadFingers: settings.settings.trackpadFingers ?? TrackpadSwipe.defaultFingerCount())
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(L("Windows side by side, not piled up")).font(.title2.bold()).multilineTextAlignment(.center)
            Text(L("Strip turns every window into a column on a horizontal strip that runs past the edges of your screen. New windows open next to the focused one, the rest keep their size, and the strip scrolls just enough to show the focused window."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            StripAnimation().frame(height: 90)
        }
    }

    private var permissionPage: some View {
        VStack(spacing: 18) {
            Image(systemName: permission.isTrusted ? "checkmark.shield.fill" : "hand.raised.fill")
                .font(.system(size: 48)).foregroundStyle(permission.isTrusted ? .green : .orange)
            Text(L("Accessibility permission")).font(.title2.bold())
            Text(L("This is the only permission Strip needs to move and resize other apps' windows. Strip doesn't record or send anything."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if permission.isTrusted {
                Label(L("Permission granted"), systemImage: "checkmark").foregroundStyle(.green)
            } else {
                Button(L("Grant Permission…")) { permission.prompt() }.controlSize(.large)
                Text(L("Turn Strip on in System Settings → Privacy & Security → Accessibility; this page updates by itself once it's allowed."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var setupPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Mac Setup")).font(.title2.bold())
            Text(L("We checked the macOS settings and apps that affect how well Strip works."))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(setup.checks) { SetupCheckRow(check: $0) }
                }
            }
        }
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Essential shortcuts")).font(.title2.bold())
            Text(L("They all start with Control + Option. Change them in Settings → Shortcuts.")).foregroundStyle(.secondary)
            let items: [Command] = [.screenLeft, .screenRight, .focusLeft, .focusRight, .moveLeft, .cycleWidth,
                                    .fullWidth, .stackLeft, .popOutRight, .toggleTabbed, .toggleFloat, .toggleEnabled]
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(items, id: \.id) { command in
                    HStack {
                        Text(shortcuts.bindings(for: command).first?.display ?? "—")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(minWidth: 64, alignment: .leading)
                        Text(command.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }

    private var finalPage: some View {
        let fingers = settings.settings.trackpadFingers ?? TrackpadSwipe.defaultFingerCount()
        return VStack(spacing: 18) {
            Image(systemName: "hand.draw.fill").font(.system(size: 48)).foregroundStyle(Color.accentColor)
            Text(L("You're all set")).font(.title2.bold())
            Text(fingers > 0
                 ? L("Swipe left or right with %d fingers on the trackpad to move the strip; it settles on the nearest column when you let go.", fingers)
                 : L("Trackpad swiping is off; you can turn it on in Settings."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(L("Use the Strip icon in the menu bar to change the layout, see the main shortcuts, open Settings or stop Strip."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

/// Three columns sliding along, the focused one highlighted.
private struct StripAnimation: View {
    @State private var phase = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / 3.2
            HStack(spacing: 8) {
                ForEach(0..<5) { i in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(i == (phase ? 2 : 1) ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.25))
                        .frame(width: w, height: geo.size.height)
                }
            }
            .offset(x: phase ? -w * 1.1 : 0)
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).repeatForever(autoreverses: true).delay(0.6)) {
                phase = true
            }
        }
    }
}
