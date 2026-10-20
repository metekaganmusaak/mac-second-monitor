import Foundation

enum SettingsKey {
    static let showStats = "settings.showStats"
    static let keepScreenOn = "settings.keepScreenOn"
    static let language = "settings.language"
}

/// App language override. iOS reads `AppleLanguages` at launch, so a change applies after a restart.
enum LanguageOverride: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case turkish = "tr"

    /// The selection the running process was started with.
    static let atLaunch = LanguageOverride(rawValue: UserDefaults.standard.string(forKey: SettingsKey.language) ?? "") ?? .system

    var id: String { rawValue }

    /// Language names are shown in their own language, as in iOS Settings.
    var title: String {
        switch self {
        case .system:
            String(localized: "settings.language.system")
        case .english, .turkish:
            Locale(identifier: rawValue).localizedString(forLanguageCode: rawValue)?.localizedCapitalized ?? rawValue
        }
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
