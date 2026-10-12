import Sparkle
import SwiftUI

/// Automatic updates through Sparkle. The feed (SUFeedURL) and the EdDSA public key (SUPublicEDKey)
/// are in Info.plist; new versions are listed in appcast.xml on the website.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false

    /// False when running outside Strip.app (swift run), where there is no Info.plist to read the feed from.
    let isAvailable = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: isAvailable, updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { objectWillChange.send(); controller.updater.automaticallyDownloadsUpdates = newValue }
    }
}

struct UpdateSettingsSection: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        Section(L("Updates")) {
            LabeledContent(L("Version %@", updater.version)) {
                Button(L("Check for Updates…")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            Toggle(L("Check for updates automatically"), isOn: $updater.automaticallyChecks)
            Toggle(L("Download and install updates automatically"), isOn: $updater.automaticallyDownloads)
                .disabled(!updater.automaticallyChecks)
        }
        .disabled(!updater.isAvailable)
    }
}
