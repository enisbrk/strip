import Foundation
import StripCore

/// Persists `Settings` as JSON in UserDefaults and publishes changes so they apply instantly.
@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "settings.v1"

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
            onChange?(settings)
        }
    }

    var onChange: ((Settings) -> Void)?

    init() {
        Self.migrateLegacyDefaults()
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        } else {
            settings = Settings()
        }
    }

    /// Builds before 1.0.0 used the bundle ID com.local.strip. Copy their preferences once, so
    /// settings, shortcuts and the saved session survive the move to the new identifier.
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        let marker = "migratedLegacyDefaults"
        guard !defaults.bool(forKey: marker) else { return }
        if defaults.data(forKey: key) == nil,
           let legacy = defaults.persistentDomain(forName: "com.local.strip") {
            for (name, value) in legacy { defaults.set(value, forKey: name) }
        }
        defaults.set(true, forKey: marker)
    }
}
