import AppKit
import ApplicationServices
import CoreImage.CIFilterBuiltins
import MSMHost
import ServiceManagement
import UserNotifications

/// Screen Recording and Accessibility permissions.
enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt the first time; afterwards macOS only lists the app in Settings.
    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open("Privacy_ScreenCapture")
        }
    }

    static func requestAccessibility() {
        // The value of kAXTrustedCheckOptionPrompt; the global itself isn't concurrency-safe in Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open("Privacy_Accessibility")
        }
    }

    static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum QRCode {
    static func image(for text: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

/// Banner with the pairing code, so the user sees it without opening the menu.
enum PairingNotifications {
    static func show(code: String, device: String, id: String) {
        // UNUserNotificationCenter needs a real app bundle (not `swift run`).
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.tr("pairing.notification.title", device)
            content.body = L10n.tr("pairing.notification.body", code)
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pairing-\(id)", content: content, trigger: nil))
        }
    }

    static func clear(id: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["pairing-\(id)"])
    }
}
