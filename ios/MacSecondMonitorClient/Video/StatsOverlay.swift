import SwiftUI

/// Small diagnostics panel over the stream.
struct StatsOverlay: View {
    let stats: StreamStats
    let videoSize: CGSize
    let isUSB: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.format(String(localized: "stats.fps"), stats.fps))
            if let latency = stats.latencyMs {
                Text(L10n.format(String(localized: "stats.latency"), latency))
            }
            if let rtt = stats.rttMs {
                Text(L10n.format(String(localized: "stats.rtt"), rtt))
            }
            if let kbps = stats.bitrateKbps {
                Text(L10n.format(String(localized: "stats.bitrate"), kbps / 1000))
            }
            if stats.droppedFrames > 0 {
                Text(L10n.format(String(localized: "stats.dropped"), stats.droppedFrames))
            }
            // Pixel counts as plain digits: a locale's grouping separator would read "1.668 × 2.420".
            Text(L10n.format(String(localized: "stats.video"), String(Int(videoSize.width)), String(Int(videoSize.height)), transport))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
    }

    private var transport: String {
        isUSB ? String(localized: "stats.transport.usb") : String(localized: "stats.transport.network")
    }
}
