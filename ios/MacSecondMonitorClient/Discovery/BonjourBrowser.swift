import Foundation
import MSMProtocol
import Network

/// Finds Macs advertising `_macsecondmon._tcp` on the local network.
@MainActor
final class BonjourBrowser: ObservableObject {
    struct Service: Identifiable, Hashable {
        let name: String
        let domain: String
        /// From the TXT record `v`; nil when the host did not publish one.
        let protocolVersion: Int?

        var id: String { "\(name).\(domain)" }
        var isCompatible: Bool { protocolVersion.map { $0 == MSMProtocolInfo.version } ?? true }
        var target: HostTarget { .bonjour(name: name, domain: domain) }
    }

    enum State: Equatable {
        case idle
        case searching
        /// The user declined Local Network access.
        case denied
    }

    @Published private(set) var services: [Service] = []
    @Published private(set) var state = State.idle

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: MSMProtocolInfo.bonjourServiceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.browserChanged(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.resultsChanged(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
        state = .searching
    }

    func stop() {
        browser?.cancel()
        browser = nil
        state = .idle
    }

    private func browserChanged(_ newState: NWBrowser.State) {
        switch newState {
        case let .waiting(error), let .failed(error):
            state = Self.isPolicyDenied(error) ? .denied : .searching
            if case .failed = newState {
                // A failed browser never recovers; start a fresh one shortly.
                browser?.cancel()
                browser = nil
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if self?.state != .idle { self?.start() }
                }
            }
        case .ready:
            state = .searching
        default:
            break
        }
    }

    private func resultsChanged(_ results: Set<NWBrowser.Result>) {
        var found: [String: Service] = [:]
        for result in results {
            guard case let .service(name, _, domain, _) = result.endpoint else { continue }
            var version: Int?
            if case let .bonjour(txt) = result.metadata, let value = txt["v"] {
                version = Int(value)
            }
            let service = Service(name: name, domain: domain, protocolVersion: version)
            // The same Mac shows up once per interface.
            found[service.id] = service
        }
        services = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        // kDNSServiceErr_PolicyDenied
        if case let .dns(code) = error { return code == -65570 }
        return false
    }
}
