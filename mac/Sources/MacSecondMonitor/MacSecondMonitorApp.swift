import AppKit
import MSMHost
import SwiftUI

@main
struct MacSecondMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(settings: delegate.model.settings)
                .environmentObject(delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: delegate.model.settings)
                .environmentObject(delegate.model)
        }
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.isStreaming ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
            .accessibilityLabel(Text(verbatim: "Mac Second Monitor"))
    }
}

/// Starts the host at launch, before the menu is ever opened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let onboarding = OnboardingWindowController()

    func applicationDidFinishLaunching(_: Notification) {
        if Screenshots.renderIfRequested(model: model) {
            NSApp.terminate(nil)
            return
        }
        model.start()
        if !model.settings.onboardingDone || !Permissions.screenRecording || !Permissions.accessibility {
            onboarding.show(model: model)
        }
    }

    func applicationWillTerminate(_: Notification) {
        model.stop()
    }
}
