import MSMHost
import MSMProtocol
import SwiftUI

/// The menu bar popover.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: HostSettings
    @State private var showQRCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.screenRecordingGranted || !model.accessibilityGranted {
                permissions
            }
            if case let .failed(message) = model.nativeStatus {
                Label(L10n.tr("menu.listenerFailed", message), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            ForEach(pairingSessions) { session in
                PairingCard(session: session)
            }
            devices
            if settings.usbEnabled {
                usb
            }
            wifi
            Divider()
            modePicker
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .alert(L10n.tr("menu.error"), isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button(L10n.tr("common.ok")) { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }

    private var pairingSessions: [SessionSnapshot] {
        model.visibleSessions.filter {
            if case .pairing = $0.phase { return true }
            return false
        }
    }

    private var connectedSessions: [SessionSnapshot] {
        model.visibleSessions.filter {
            if case .pairing = $0.phase { return false }
            return true
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isStreaming ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Mac Second Monitor").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(L10n.tr("menu.settings"))
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
        }
    }

    private var statusText: String {
        let count = connectedSessions.count
        switch count {
        case 0: return L10n.tr("menu.status.waiting")
        case 1: return L10n.tr("menu.status.one")
        default: return L10n.tr("menu.status.many", count)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.screenRecordingGranted {
                PermissionRow(title: L10n.tr("permission.screenRecording.title"), detail: L10n.tr("permission.screenRecording.short")) {
                    Permissions.requestScreenRecording()
                }
            }
            if !model.accessibilityGranted {
                PermissionRow(title: L10n.tr("permission.accessibility.title"), detail: L10n.tr("permission.accessibility.short")) {
                    Permissions.requestAccessibility()
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var devices: some View {
        if !connectedSessions.isEmpty {
            SectionTitle(L10n.tr("menu.devices"))
            ForEach(connectedSessions) { session in
                SessionRow(session: session) { model.disconnect(session) }
            }
        }
    }

    private var usb: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L10n.tr("menu.usb"))
            ForEach(model.iosDevices.filter { !$0.connected }) { device in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "ipad").font(.title3).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("usb.ios.title")).font(.callout.weight(.medium))
                        Text(L10n.tr(device.paused ? "usb.ios.disconnected" : "usb.ios.openApp"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if device.paused {
                        Button(L10n.tr("usb.ios.reconnect")) { model.reconnect(device) }.controlSize(.small)
                    }
                }
            }
            if model.adbStatus == .notFound {
                HintText(L10n.tr("usb.adb.notFoundHint"))
            } else if model.usbDevices.isEmpty, model.iosDevices.isEmpty {
                HintText(model.adbStatus == .running ? L10n.tr("usb.none") : L10n.tr("usb.adb.starting"))
            }
            ForEach(model.usbDevices) { device in
                UsbDeviceRow(device: device, canInstall: model.bundledAPK != nil, installing: model.installing.contains(device.serial)) {
                    model.install(on: device)
                } launch: {
                    model.launchClient(on: device)
                }
            }
        }
    }

    private var wifi: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L10n.tr("menu.wifi"))
            if model.addresses.isEmpty {
                HintText(L10n.tr("menu.wifi.offline"))
            } else {
                ForEach(model.addresses, id: \.self) { address in
                    HStack {
                        Image(systemName: "wifi").foregroundStyle(.secondary)
                        Text(verbatim: address.address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Text(L10n.tr("menu.wifi.port", Int(MSMProtocolInfo.nativePort))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let url = model.webURL {
                    DisclosureGroup(isExpanded: $showQRCode) {
                        VStack(spacing: 6) {
                            if let image = QRCode.image(for: url, size: 160) {
                                Image(nsImage: image).interpolation(.none)
                            }
                            Text(verbatim: url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(L10n.tr("menu.web.hint")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    } label: {
                        Text(L10n.tr("menu.web.title")).font(.callout)
                    }
                }
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.tr("menu.mode"), selection: $settings.displayMode) {
                Text(L10n.tr("mode.extend")).tag(DisplayMode.extend)
                Text(L10n.tr("mode.mirror")).tag(DisplayMode.mirror)
            }
            .pickerStyle(.segmented)
            HStack {
                if connectedSessions.contains(where: { $0.mode != settings.displayMode }) {
                    Button(L10n.tr("menu.mode.apply")) { model.reconnectAll() }
                }
                Spacer()
                Button(L10n.tr("menu.arrange")) { Permissions.openDisplaySettings() }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.tr("menu.quit")) {
                // applicationWillTerminate says goodbye to connected devices.
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
            Spacer()
            Text(verbatim: "v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Rows

private struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

private struct HintText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L10n.tr("permission.allow"), action: action).controlSize(.small)
        }
    }
}

private struct PairingCard: View {
    let session: SessionSnapshot

    var body: some View {
        VStack(spacing: 6) {
            Text(L10n.tr("pairing.prompt", session.deviceName))
                .font(.callout)
                .multilineTextAlignment(.center)
            if case let .pairing(code) = session.phase {
                Text(verbatim: code.map(String.init).joined(separator: " "))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SessionRow: View {
    let session: SessionSnapshot
    let disconnect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.deviceName).font(.callout.weight(.medium)).lineLimit(1)
                    Text(session.transport.localizedName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(session.transport == .usb ? Color.green.opacity(0.2) : Color.blue.opacity(0.2), in: Capsule())
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button(action: disconnect) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.tr("menu.disconnect"))
        }
    }

    private var icon: String {
        switch session.platform {
        case "android": "ipad.landscape"
        case "ios": "ipad.and.iphone"
        case "web": "globe"
        default: "display"
        }
    }

    private var detail: String {
        switch session.phase {
        case .handshaking, .pairing: return L10n.tr("session.connecting")
        case .starting: return L10n.tr("session.starting")
        case .closed: return L10n.tr("session.closed")
        case .streaming:
            var parts = ["\(session.width)×\(session.height)", String(format: "%.0f fps", session.pipeline.fps)]
            if let latency = session.client?.latencyMs {
                parts.append(String(format: "%.0f ms", latency))
            }
            parts.append(String(format: "%.1f Mbps", session.pipeline.bitrateKbps / 1000))
            return parts.joined(separator: " · ")
        }
    }
}

private struct UsbDeviceRow: View {
    let device: AdbDevice
    let canInstall: Bool
    let installing: Bool
    let install: () -> Void
    let launch: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cable.connector").font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.callout.weight(.medium))
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if installing {
                ProgressView().controlSize(.small)
            } else if device.state == .device, device.bridge == .ready {
                if device.clientInstalled == true {
                    Button(L10n.tr("usb.open"), action: launch).controlSize(.small)
                } else if device.clientInstalled == false, canInstall {
                    Button(L10n.tr("usb.install"), action: install).controlSize(.small)
                }
            }
        }
    }

    private var status: String {
        switch device.state {
        case .unauthorized: return L10n.tr("usb.state.unauthorized")
        case .offline: return L10n.tr("usb.state.offline")
        case let .other(state): return state
        case .device:
            switch device.bridge {
            case .waiting: return L10n.tr("usb.state.preparing")
            case let .failed(message): return L10n.tr("usb.state.failed", message)
            case .ready:
                if device.clientInstalled == false {
                    return canInstall ? L10n.tr("usb.state.notInstalled") : L10n.tr("usb.state.notInstalledManual")
                }
                return L10n.tr("usb.state.ready")
            }
        }
    }
}
