import Foundation
import Security

/// The summary provider's API key lives in the login keychain, never in settings.json.
enum APIKeyStore {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Roomtone",
        kSecAttrAccount as String: "ai-api-key",
    ]

    static func read() -> String {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// An empty key deletes the item. Returns false if the keychain refused the write.
    @discardableResult
    static func save(_ key: String) -> Bool {
        SecItemDelete(item as CFDictionary)
        guard !key.isEmpty else { return true }
        var add = item
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
