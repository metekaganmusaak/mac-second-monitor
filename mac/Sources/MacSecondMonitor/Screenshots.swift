import AppKit
import MSMHost
import MSMProtocol
import SwiftUI

/// `MacSecondMonitor --render-screenshots DIR` renders the main views with sample data into
/// PNG files (used for the README). Rendering happens offscreen, so no permissions are needed.
@MainActor
enum Screenshots {
    static func renderIfRequested(model: AppModel) -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-screenshots"), index + 1 < arguments.count else { return false }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        model.loadSampleState()
        let suffix = arguments.contains("--light") ? "light" : "dark"
        render(MenuBarView(settings: model.settings).environmentObject(model), to: directory.appendingPathComponent("menu-\(suffix).png"), dark: suffix == "dark")
        render(OnboardingView(done: {}).environmentObject(model).frame(width: 520), to: directory.appendingPathComponent("onboarding-\(suffix).png"), dark: suffix == "dark")
        return true
    }

    private static func render(_ view: some View, to url: URL, dark: Bool) {
        let content = view
            .fixedSize()
            .background(dark ? Color(white: 0.15) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

extension AppModel {
    /// Plausible state for screenshots: an Android tablet over USB, a browser and a pairing iPad.
    func loadSampleState() {
        setSampleState(
            sessions: [
                SessionSnapshot(deviceId: "1", deviceName: "Galaxy Tab S9", platform: "android", transport: .usb, width: 2560, height: 1600, mode: .extend, phase: .streaming,
                                pipeline: PipelineStats(fps: 60, bitrateKbps: 14_800, encodeMs: 8.9),
                                client: ClientStats(fps: 60, decodeMs: 4.1, latencyMs: 24, rttMs: 0.9, droppedFrames: 0, bitrateKbps: 14_800)),
                SessionSnapshot(deviceId: "2", deviceName: "Chrome on Windows", platform: "web", transport: .wifi, width: 1920, height: 1080, mode: .extend, phase: .streaming,
                                pipeline: PipelineStats(fps: 60, bitrateKbps: 6_200, encodeMs: 6.1),
                                client: ClientStats(fps: 60, decodeMs: 3.0, latencyMs: 41, rttMs: 3.8, droppedFrames: 0, bitrateKbps: 6_200)),
                SessionSnapshot(deviceId: "3", deviceName: "iPad Air", platform: "ios", transport: .wifi, width: 2360, height: 1640, mode: .extend, phase: .pairing(code: "482913")),
            ],
            usbDevices: [AdbDevice(serial: "R52W70ABCDE", state: .device, model: "SM_X710", bridge: .ready, clientInstalled: true)],
            addresses: [NetworkInfo.Address(interface: "en0", address: "192.168.1.20")]
        )
    }
}
