import Foundation
import Security

/// Pairing tokens per host, kept in the Keychain. Falls back to UserDefaults only where the
/// Keychain refuses to store items (e.g. unsigned simulator builds without entitlements).
enum TokenStore {
    private static let service = "com.macsecondmonitor.client.ios.pairing"
    private static let fallbackKey = "pairing.tokens"

    static func token(for keys: [String]) -> String? {
        keys.lazy.compactMap(read).first
    }

    static func save(_ token: String, for keys: [String]) {
        keys.forEach { write(token, account: $0) }
    }

    private static func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        return fallback[account]
    }

    private static func write(_ token: String, account: String) {
        let data = Data(token.utf8)
        let query = baseQuery(account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        var stored = fallback
        stored[account] = status == errSecSuccess ? nil : token
        UserDefaults.standard.set(stored, forKey: fallbackKey)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static var fallback: [String: String] {
        UserDefaults.standard.dictionary(forKey: fallbackKey) as? [String: String] ?? [:]
    }
}
