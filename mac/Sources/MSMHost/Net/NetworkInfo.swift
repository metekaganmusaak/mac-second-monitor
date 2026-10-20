import Darwin
import Foundation

public enum NetworkInfo {
    public struct Address: Sendable, Equatable, Hashable {
        public var interface: String
        public var address: String

        public init(interface: String, address: String) {
            self.interface = interface
            self.address = address
        }
    }

    /// IPv4 addresses of active, non-loopback interfaces (what a client on the LAN would type).
    public static func localAddresses() -> [Address] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var result: [Address] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            // Skip virtual interfaces (VPN tunnels, AirDrop, bridges).
            guard name.hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !ip.hasPrefix("169.254.") {
                    result.append(Address(interface: name, address: ip))
                }
            }
        }
        return result
    }
}
