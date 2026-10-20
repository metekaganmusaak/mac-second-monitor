import MSMHost
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: HostSettings

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label(L10n.tr("settings.general"), systemImage: "gearshape") }
            VideoSettings(settings: settings)
                .tabItem { Label(L10n.tr("settings.video"), systemImage: "film") }
            UsbSettings(settings: settings)
                .tabItem { Label(L10n.tr("settings.usb"), systemImage: "cable.connector") }
            DevicesSettings()
                .tabItem { Label(L10n.tr("settings.devices"), systemImage: "ipad.and.iphone") }
        }
        .frame(width: 520, height: 400)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var settings: HostSettings
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var language: String = "system"
    @State private var languageChanged = false
    @State private var error: String?

    var body: some View {
        Form {
            Toggle(L10n.tr("settings.launchAtLogin"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        try LaunchAtLogin.set(enabled)
                    } catch {
                        self.error = error.localizedDescription
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                }
            Picker(L10n.tr("settings.language"), selection: $language) {
                Text(L10n.tr("settings.language.system")).tag("system")
                Text(verbatim: "English").tag("en")
                Text(verbatim: "Türkçe").tag("tr")
            }
            .onChange(of: language) { _, value in
                guard value != (settings.language ?? "system") else { return }
                settings.language = value == "system" ? nil : value
                languageChanged = true
            }
            if languageChanged {
                HStack {
                    Text(L10n.tr("settings.language.restart")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("settings.language.restartNow")) { relaunch() }
                }
            }
            Section(L10n.tr("settings.security")) {
                Toggle(L10n.tr("settings.requirePairing"), isOn: $settings.requirePairing)
                Text(L10n.tr("settings.requirePairing.detail")).font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.tr("settings.webClient"), isOn: $settings.webClientEnabled)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear { language = settings.language ?? "system" }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

private struct VideoSettings: View {
    @ObservedObject var settings: HostSettings

    var body: some View {
        Form {
            Picker(L10n.tr("settings.mode"), selection: $settings.displayMode) {
                Text(L10n.tr("mode.extend")).tag(DisplayMode.extend)
                Text(L10n.tr("mode.mirror")).tag(DisplayMode.mirror)
            }
            Picker(L10n.tr("settings.quality"), selection: $settings.quality) {
                Text(L10n.tr("quality.low")).tag(StreamQuality.low)
                Text(L10n.tr("quality.balanced")).tag(StreamQuality.balanced)
                Text(L10n.tr("quality.high")).tag(StreamQuality.high)
            }
            Picker(L10n.tr("settings.fps"), selection: $settings.fps) {
                Text(verbatim: "30").tag(30)
                Text(verbatim: "60").tag(60)
                Text(verbatim: "120").tag(120)
            }
            Text(L10n.tr("settings.fps.detail")).font(.caption).foregroundStyle(.secondary)
            Toggle(L10n.tr("settings.hevc"), isOn: $settings.preferHEVC)
            Text(L10n.tr("settings.hevc.detail")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.tr("settings.video.nextConnection")).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct UsbSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: HostSettings

    var body: some View {
        Form {
            Toggle(L10n.tr("settings.usb.enabled"), isOn: $settings.usbEnabled)
            Toggle(L10n.tr("settings.usb.launch"), isOn: $settings.usbLaunchClient)
                .disabled(!settings.usbEnabled)
            TextField(L10n.tr("settings.usb.adbPath"), text: $settings.adbPath, prompt: Text(verbatim: "/opt/homebrew/bin/adb"))
                .disabled(!settings.usbEnabled)
            Text(L10n.tr("settings.usb.detail")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if case .notFound = model.adbStatus {
                Text(L10n.tr("usb.adb.notFoundHint")).font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DevicesSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.trustedDevices.isEmpty {
                    Text(L10n.tr("settings.devices.none")).foregroundStyle(.secondary)
                }
                ForEach(model.trustedDevices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(L10n.tr("settings.devices.lastSeen", device.lastSeen.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.tr("settings.devices.forget"), role: .destructive) { model.forget(device) }
                    }
                }
            } footer: {
                Text(L10n.tr("settings.devices.detail")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
