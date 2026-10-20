import Foundation

enum SettingsKey {
    static let showStats = "settings.showStats"
    static let keepScreenOn = "settings.keepScreenOn"
    static let language = "settings.language"
}

/// App language override. iOS reads `AppleLanguages` at launch, so a change applies after a restart.
/// Raw values are Apple language codes, stored in `AppleLanguages`; the case order is the picker order.
enum LanguageOverride: String, CaseIterable, Identifiable {
    case system
    case german = "de"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case portugueseBrazil = "pt-BR"
    case turkish = "tr"
    case russian = "ru"
    case arabic = "ar"
    case chineseSimplified = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"

    /// The selection the running process was started with.
    static let atLaunch = LanguageOverride(rawValue: UserDefaults.standard.string(forKey: SettingsKey.language) ?? "") ?? .system

    var id: String { rawValue }

    /// Language names are shown in their own language, as in iOS Settings.
    var title: String {
        switch self {
        case .system: String(localized: "settings.language.system")
        case .german: "Deutsch"
        case .english: "English"
        case .spanish: "Español"
        case .french: "Français"
        case .italian: "Italiano"
        case .portugueseBrazil: "Português (Brasil)"
        case .turkish: "Türkçe"
        case .russian: "Русский"
        case .arabic: "العربية"
        case .chineseSimplified: "简体中文"
        case .japanese: "日本語"
        case .korean: "한국어"
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
