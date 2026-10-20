import SwiftUI

/// Shows the connect screen, or the full-screen stream once the Mac accepted the session.
struct RootView: View {
    @EnvironmentObject private var session: SessionController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.showsStream {
                StreamScreen()
                    .transition(.opacity)
            } else {
                ConnectView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.showsStream)
        .onChange(of: scenePhase) { session.scenePhaseChanged($0) }
        .task { session.launch() }
    }
}
