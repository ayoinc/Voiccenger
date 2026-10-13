import Foundation
import Security

/// Generic-password items in the login keychain, service "com.voiccenger.app".
public enum KeychainStore {
    public static let service = "com.voiccenger.app"

    public struct Failure: LocalizedError, Sendable, Equatable {
        public let status: OSStatus
        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error \(status): \(message)"
        }
    }

    /// Stores `value`, replacing any existing item; `nil` or an empty string deletes the item.
    public static func set(_ value: String?, account: String) throws {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query(account: account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Voiccenger: \(account)"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure(status: status) }
        default:
            throw Failure(status: update)
        }
    }

    public static func get(account: String) -> String? {
        var item = query(account: account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
