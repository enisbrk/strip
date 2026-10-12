import Foundation

/// Languages Strip's interface is available in.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, tr, es, fr, it

    var id: String { rawValue }

    /// The language's own name, as shown in the language picker.
    var nativeName: String {
        switch self {
        case .en: "English"
        case .tr: "Türkçe"
        case .es: "Español"
        case .fr: "Français"
        case .it: "Italiano"
        }
    }

    /// The first of the user's preferred system languages that Strip speaks, else English.
    static var system: AppLanguage {
        for identifier in Locale.preferredLanguages {
            let code = String(identifier.prefix(2)).lowercased()
            if let language = AppLanguage(rawValue: code) { return language }
        }
        return .en
    }
}

/// In-app translation: English source strings are the keys, so a missing translation shows
/// English rather than a key. Tables live in Localization+<language>.swift. Switching language
/// takes effect immediately (no relaunch).
enum Localization {
    nonisolated(unsafe) private(set) static var language: AppLanguage = .system

    /// `code` is the saved setting: nil follows the system language.
    static func use(_ code: String?) {
        language = code.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    static func translate(_ key: String) -> String {
        guard let table = tables[language] else { return key }
        return table[key] ?? key
    }

    static let tables: [AppLanguage: [String: String]] = [.tr: tr, .es: es, .fr: fr, .it: it]
}

/// Localized interface string. `key` is the English text.
func L(_ key: String) -> String {
    Localization.translate(key)
}

/// Localized format string, e.g. `L("%d windows", count)`.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Localization.translate(key), locale: Locale(identifier: Localization.language.rawValue),
           arguments: arguments)
}
