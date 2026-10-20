import AppKit
import MSMHost
import SwiftUI

/// First-launch window: explains the two permissions and how to connect.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("onboarding.title")).font(.title2.weight(.semibold))
                    Text(L10n.tr("onboarding.subtitle")).foregroundStyle(.secondary)
                }
            }

            PermissionStep(
                granted: model.screenRecordingGranted,
                title: L10n.tr("permission.screenRecording.title"),
                detail: L10n.tr("permission.screenRecording.detail"),
                action: Permissions.requestScreenRecording
            )
            PermissionStep(
                granted: model.accessibilityGranted,
                title: L10n.tr("permission.accessibility.title"),
                detail: L10n.tr("permission.accessibility.detail"),
                action: Permissions.requestAccessibility
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("onboarding.connect.title")).font(.headline)
                Label(L10n.tr("onboarding.connect.usb"), systemImage: "cable.connector")
                Label(L10n.tr("onboarding.connect.wifi"), systemImage: "wifi")
            }
            .font(.callout)

            HStack {
                Text(L10n.tr("onboarding.menuHint")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("onboarding.done"), action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { model.refreshPermissions() }
    }
}

private struct PermissionStep: View {
    let granted: Bool
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button(L10n.tr("permission.allow"), action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Shows the onboarding window from AppKit (works on macOS 14 without scene APIs).
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView { [weak self] in
            model.settings.onboardingDone = true
            self?.window?.close()
            self?.window = nil
        }
        .environmentObject(model)
        let controller = NSHostingController(rootView: view)
        // Size once instead of letting the window track the SwiftUI size: wrapping text
        // inside a fixed width otherwise causes an endless constraint update loop.
        controller.sizingOptions = []
        let size = controller.view.fittingSize
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 520, height: max(size.height, 420)))
        window.title = "Mac Second Monitor"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
