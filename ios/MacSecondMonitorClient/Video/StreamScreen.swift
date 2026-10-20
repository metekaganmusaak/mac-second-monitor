import SwiftUI
import UIKit

/// Full-screen view of the Mac's extra display.
struct StreamScreen: View {
    @EnvironmentObject private var session: SessionController
    @AppStorage(SettingsKey.showStats) private var showsStats = false
    @AppStorage(SettingsKey.keepScreenOn) private var keepScreenOn = true
    @State private var showsKeyboard = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            StreamSurface(
                output: session.videoOutput,
                videoSize: session.videoSize,
                showsKeyboard: $showsKeyboard,
                send: { session.send($0) },
                onPixelSizeChange: { session.surfaceSizeChanged($0) }
            )
            .ignoresSafeArea()

            if case let .reconnecting(_, attempt) = session.phase {
                ReconnectingView(attempt: attempt) { session.disconnect() }
            } else if !session.hasPicture {
                WaitingForPictureView()
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsStats, let stats = session.stats {
                StatsOverlay(stats: stats, videoSize: session.videoSize, isUSB: session.route == .usb)
                    .padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            StreamControls(showsKeyboard: $showsKeyboard, showsStats: $showsStats) {
                session.disconnect()
            }
            .padding(8)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // Edge swipes reach the Mac first; a second swipe still opens Control Center / Home.
        .defersSystemGestures(on: .all)
        .onAppear {
            updateIdleTimer()
            session.streamViewAppeared()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: keepScreenOn) { _ in updateIdleTimer() }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }
}
