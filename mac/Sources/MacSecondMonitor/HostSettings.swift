import Foundation
import MSMHost

/// User preferences, stored in UserDefaults. Changes are applied to the running host.
@MainActor
final class HostSettings: ObservableObject {
    private let defaults = UserDefaults.standard
    var onChange: (() -> Void)?

    @Published var displayMode: DisplayMode { didSet { save(displayMode.rawValue, "displayMode") } }
    @Published var quality: StreamQuality { didSet { save(quality.rawValue, "quality") } }
    @Published var fps: Int { didSet { save(fps, "fps") } }
    @Published var preferHEVC: Bool { didSet { save(preferHEVC, "preferHEVC") } }
    @Published var requirePairing: Bool { didSet { save(requirePairing, "requirePairing") } }
    @Published var webClientEnabled: Bool { didSet { save(webClientEnabled, "webClientEnabled") } }
    @Published var usbEnabled: Bool { didSet { save(usbEnabled, "usbEnabled") } }
    @Published var usbLaunchClient: Bool { didSet { save(usbLaunchClient, "usbLaunchClient") } }
    @Published var adbPath: String { didSet { save(adbPath, "adbPath") } }
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }

    init() {
        defaults.register(defaults: [
            "displayMode": DisplayMode.extend.rawValue,
            "quality": StreamQuality.balanced.rawValue,
            "fps": 60,
            "preferHEVC": false,
            "requirePairing": true,
            "webClientEnabled": true,
            "usbEnabled": true,
            "usbLaunchClient": true,
            "adbPath": "",
            "onboardingDone": false,
        ])
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .extend
        quality = StreamQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .balanced
        fps = defaults.integer(forKey: "fps")
        preferHEVC = defaults.bool(forKey: "preferHEVC")
        requirePairing = defaults.bool(forKey: "requirePairing")
        webClientEnabled = defaults.bool(forKey: "webClientEnabled")
        usbEnabled = defaults.bool(forKey: "usbEnabled")
        usbLaunchClient = defaults.bool(forKey: "usbLaunchClient")
        adbPath = defaults.string(forKey: "adbPath") ?? ""
        onboardingDone = defaults.bool(forKey: "onboardingDone")
    }

    /// Language override (`en`, `tr`); `nil` follows the system. Takes effect after a relaunch.
    var language: String? {
        get { defaults.string(forKey: "languageOverride") }
        set {
            defaults.set(newValue, forKey: "languageOverride")
            if let newValue {
                defaults.set([newValue], forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
            objectWillChange.send()
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}
