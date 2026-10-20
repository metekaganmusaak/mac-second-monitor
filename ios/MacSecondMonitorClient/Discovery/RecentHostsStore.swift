import Foundation

struct RecentHost: Codable, Hashable, Identifiable {
    var target: HostTarget
    /// Name the Mac reported in WELCOME.
    var hostName: String?
    var lastConnected: Date

    var id: HostTarget { target }
    var title: String { hostName ?? target.displayName }

    /// The address, when the title is the Mac's name.
    var subtitle: String? {
        guard hostName != nil, case .address = target else { return nil }
        return target.displayName
    }
}

/// Hosts that accepted a session, most recent first.
@MainActor
final class RecentHostsStore: ObservableObject {
    static let limit = 6
    private static let key = "recentHosts"

    @Published private(set) var hosts: [RecentHost] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let hosts = try? JSONDecoder().decode([RecentHost].self, from: data) {
            self.hosts = hosts
        }
    }

    func record(_ target: HostTarget, hostName: String) {
        hosts.removeAll { $0.target == target }
        hosts.insert(RecentHost(target: target, hostName: hostName, lastConnected: Date()), at: 0)
        hosts = Array(hosts.prefix(Self.limit))
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        hosts.remove(atOffsets: offsets)
        save()
    }

    func hostName(for target: HostTarget) -> String? {
        hosts.first { $0.target == target }?.hostName
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
