import Foundation
import MSMClientKit
import MSMProtocol
import Network

/// A Mac reachable over the network: found with Bonjour or typed in by the user.
enum HostTarget: Hashable, Codable, Sendable {
    case bonjour(name: String, domain: String)
    case address(host: String, port: UInt16)

    /// Parses `host`, `host:port`, `[ipv6]:port` or a bare IPv6 address.
    init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        var host = trimmed
        var port = MSMProtocolInfo.nativePort
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let value = UInt16(rest.dropFirst()), value > 0 else { return nil }
                port = value
            }
        } else if trimmed.filter({ $0 == ":" }).count == 1 {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard let value = UInt16(parts[1]), value > 0 else { return nil }
            host = String(parts[0])
            port = value
        }
        guard !host.isEmpty else { return nil }
        self = .address(host: host, port: port)
    }

    var displayName: String {
        switch self {
        case let .bonjour(name, _):
            return name
        case let .address(host, port):
            if port == MSMProtocolInfo.nativePort { return host }
            return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        }
    }

    var serviceName: String? {
        if case let .bonjour(name, _) = self { return name }
        return nil
    }

    /// Keychain account for the pairing token of this target.
    var tokenKey: String {
        switch self {
        case let .bonjour(name, domain): "bonjour:\(name).\(domain)"
        case let .address(host, port): "address:\(host):\(port)"
        }
    }

    /// Lets a token from a Bonjour connection be reused for the same Mac typed in by address.
    static func tokenKey(hostName: String) -> String {
        "host:\(hostName)"
    }

    func makeConnection(hello: Hello) -> ClientConnection {
        switch self {
        case let .address(host, port):
            return ClientConnection(host: host, port: port, hello: hello)
        case let .bonjour(name, domain):
            let endpoint = NWEndpoint.service(name: name, type: MSMProtocolInfo.bonjourServiceType, domain: domain, interface: nil)
            return ClientConnection(connection: NWConnection(to: endpoint, using: ClientConnection.parameters()), hello: hello)
        }
    }
}
