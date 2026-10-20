import MSMProtocol
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.showStats) private var showsStats = false
    @AppStorage(SettingsKey.keepScreenOn) private var keepScreenOn = true
    @AppStorage(SettingsKey.language) private var language = LanguageOverride.system

    var body: some View {
        NavigationStack {
            Form {
                Section("settings.section.display") {
                    Toggle("settings.showStats", isOn: $showsStats)
                    Toggle("settings.keepScreenOn", isOn: $keepScreenOn)
                }

                Section {
                    Picker("settings.language", selection: $language) {
                        ForEach(LanguageOverride.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } header: {
                    Text("settings.section.language")
                } footer: {
                    if language != LanguageOverride.atLaunch {
                        Text("settings.language.restart")
                    }
                }

                Section("settings.section.about") {
                    LabeledContent("settings.about.version", value: DeviceProfile.appVersion)
                    LabeledContent("settings.about.protocol", value: String(MSMProtocolInfo.version))
                }
            }
            .navigationTitle("settings.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
            .onChange(of: language) { $0.apply() }
        }
    }
}
