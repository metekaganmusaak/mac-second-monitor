import SwiftUI

@main
struct MacSecondMonitorClientApp: App {
    @StateObject private var recents: RecentHostsStore
    @StateObject private var session: SessionController

    init() {
        // Remember the language the app was started with, so Settings can ask for a restart.
        _ = LanguageOverride.atLaunch
        let recents = RecentHostsStore()
        _recents = StateObject(wrappedValue: recents)
        _session = StateObject(wrappedValue: SessionController(recents: recents))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(recents)
        }
    }
}
