import AppKit
import Foundation
import MSMHost
import MSMProtocol

/// State shown by the menu bar UI; owns the host engine and the USB bridge.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [SessionSnapshot] = []
    @Published private(set) var usbDevices: [AdbDevice] = []
    @Published private(set) var iosDevices: [UsbmuxBridge.Device] = []
    @Published private(set) var adbStatus: AdbStatus = .disabled
    @Published private(set) var nativeStatus: ListenerStatus = .stopped
    @Published private(set) var webStatus: ListenerStatus = .stopped
    @Published private(set) var screenRecordingGranted = Permissions.screenRecording
    @Published private(set) var accessibilityGranted = Permissions.accessibility
    @Published private(set) var addresses: [NetworkInfo.Address] = []
    @Published private(set) var trustedDevices: [TrustedDevice] = []
    @Published private(set) var installing: Set<String> = []
    @Published var alert: String?

    let settings = HostSettings()
    private let engine: HostEngine
    private let adb = AdbBridge()
    private let usbmux = UsbmuxBridge()
    private var timer: Timer?
    private var notifiedPairings: Set<UUID> = []

    init() {
        engine = HostEngine(options: HostEngine.Options(hostName: Host.current().localizedName ?? "Mac"))
        settings.onChange = { [weak self] in self?.applySettings() }
        engine.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        engine.onScreenRecordingPermissionMissing = {
            Task { @MainActor in Permissions.requestScreenRecording() }
        }
        adb.onChange = { [weak self] in
            Task { @MainActor in self?.refreshUsb() }
        }
        usbmux.onChannel = { [engine] channel in engine.adopt(channel) }
        usbmux.onChange = { [weak self] in
            Task { @MainActor in self?.refreshUsb() }
        }
    }

    var isStreaming: Bool {
        sessions.contains { $0.phase == .streaming }
    }

    /// Sessions worth showing: probes that never sent HELLO are hidden.
    var visibleSessions: [SessionSnapshot] {
        sessions.filter { $0.deviceId != nil && $0.phase != .closed }
    }

    var webURL: String? {
        guard settings.webClientEnabled, let address = addresses.first else { return nil }
        return "http://\(address.address):\(MSMProtocolInfo.webPort)/"
    }

    /// The bundled Android client, if the app was packaged with one.
    var bundledAPK: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("android/MacSecondMonitor.apk")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? ProcessInfo.processInfo.environment["MSM_APK"].map(URL.init(fileURLWithPath:))
    }

    func start() {
        applySettings()
        do {
            try engine.start()
        } catch {
            alert = error.localizedDescription
        }
        refreshNetwork()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
                self?.refreshNetwork()
            }
        }
    }

    /// Called when the app quits: waits briefly so connected devices learn the Mac app closed
    /// (and wait for it) instead of treating it as a dropped connection.
    func stop() {
        adb.stop()
        usbmux.stop()
        engine.stop(waitingUpTo: 0.5)
    }

    func disconnect(_ session: SessionSnapshot) {
        engine.disconnect(session.id)
    }

    /// Clients reconnect by themselves, picking up new display settings.
    func reconnectAll() {
        for session in sessions {
            engine.disconnect(session.id, reason: "reconfigure")
        }
    }

    func forget(_ device: TrustedDevice) {
        engine.trustStore.remove(deviceId: device.deviceId)
        trustedDevices = engine.trustStore.all
    }

    func install(on device: AdbDevice) {
        guard let apk = bundledAPK else { return }
        installing.insert(device.serial)
        Task {
            do {
                try await adb.install(apk: apk, on: device.serial)
                adb.launchClient(on: device.serial)
            } catch {
                alert = L10n.tr("usb.install.failed", error.localizedDescription)
            }
            installing.remove(device.serial)
        }
    }

    func launchClient(on device: AdbDevice) {
        adb.launchClient(on: device.serial)
    }

    func reconnect(_ device: UsbmuxBridge.Device) {
        usbmux.reconnect(device.id)
    }

    func refreshPermissions() {
        screenRecordingGranted = Permissions.screenRecording
        accessibilityGranted = Permissions.accessibility
    }

    private func applySettings() {
        var options = engine.options
        options.displayMode = settings.displayMode
        options.quality = settings.quality
        options.fps = settings.fps
        options.preferHEVC = settings.preferHEVC
        options.requirePairing = settings.requirePairing
        options.enableWebServer = settings.webClientEnabled
        options.webRoot = Self.webRoot()
        engine.update(options)

        var adbOptions = AdbBridge.Options()
        adbOptions.adbPath = settings.adbPath.isEmpty ? nil : settings.adbPath
        adbOptions.launchClient = settings.usbLaunchClient
        adbOptions.secret = engine.trustStore.usbSecret
        adb.update(adbOptions)
        if settings.usbEnabled {
            adb.start()
            usbmux.start()
        } else {
            adb.stop()
            usbmux.stop()
        }
        refresh()
    }

    private func refresh() {
        sessions = engine.snapshots()
        nativeStatus = engine.nativeStatus
        webStatus = engine.webStatus
        trustedDevices = engine.trustStore.all

        // A banner with the code while a device waits; removed once pairing ends.
        let ids = Set(sessions.map(\.id))
        for session in sessions {
            if case let .pairing(code) = session.phase {
                if notifiedPairings.insert(session.id).inserted {
                    PairingNotifications.show(code: code, device: session.deviceName, id: session.id.uuidString)
                }
            } else if notifiedPairings.remove(session.id) != nil {
                PairingNotifications.clear(id: session.id.uuidString)
            }
        }
        for id in notifiedPairings.subtracting(ids) {
            notifiedPairings.remove(id)
            PairingNotifications.clear(id: id.uuidString)
        }
    }

    private func refreshUsb() {
        usbDevices = adb.devices
        adbStatus = adb.status
        iosDevices = usbmux.attachedDevices
    }

    private func refreshNetwork() {
        let current = NetworkInfo.localAddresses()
        if current != addresses { addresses = current }
    }

    /// Screenshot support; the host is not started.
    func setSampleState(sessions: [SessionSnapshot], usbDevices: [AdbDevice], addresses: [NetworkInfo.Address]) {
        self.sessions = sessions
        self.usbDevices = usbDevices
        self.addresses = addresses
        adbStatus = .running
        nativeStatus = .ready
        screenRecordingGranted = true
        accessibilityGranted = true
    }

    /// Built web client: bundled in the app, or `MSM_WEB_ROOT` during development.
    private static func webRoot() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        return ProcessInfo.processInfo.environment["MSM_WEB_ROOT"].map(URL.init(fileURLWithPath:))
    }
}
