import Foundation
import Security
import OpenFilesCore

/// The model provider API key lives only in the Keychain, like cloud registration fields.
/// It never enters library.json, UserDefaults or logs.
enum AgentKeychain {
    private static let service = "com.openfiles.desktop.agent"
    private static let account = "model-api-key"

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            let added = SecItemAdd(insertion as CFDictionary, nil)
            guard added == errSecSuccess else { throw OpenFilesError.message("Keychain refused the save (OSStatus \(added)).") }
        } else if status != errSecSuccess {
            throw OpenFilesError.message("Keychain refused the update (OSStatus \(status)).")
        }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
