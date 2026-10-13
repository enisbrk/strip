import AppKit
import SwiftUI

/// "About Strip": icon, version, links and the update check, in a small window of its own.
@MainActor
enum AboutWindow {
    static let website = URL(string: "https://enisbrk.github.io/strip/")!
    static let repository = URL(string: "https://github.com/enisbrk/strip")!
    static let releases = URL(string: "https://github.com/enisbrk/strip/releases")!

    private static var window: NSWindow?

    static func show(updater: Updater) {
        if let window {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = L("About Strip")
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.contentView = NSHostingView(rootView: AboutView().environmentObject(updater))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AboutView: View {
    @EnvironmentObject private var updater: Updater

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return L("Version %@ (%@)", short, build)
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.top, 34)
            Text("Strip")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .padding(.top, 10)
            Text(version)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
            Text(L("Scrolling window manager for macOS"))
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .padding(.horizontal, 24)

            HStack(spacing: 8) {
                Link(L("Website"), destination: AboutWindow.website)
                Text("·").foregroundStyle(.tertiary)
                Link("GitHub", destination: AboutWindow.repository)
                Text("·").foregroundStyle(.tertiary)
                Link(L("Release Notes"), destination: AboutWindow.releases)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.top, 16)

            Button(L("Check for Updates…")) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
                .padding(.top, 18)

            Spacer(minLength: 18)
            Text(copyright)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)
        }
        .frame(width: 340, height: 420)
    }
}
