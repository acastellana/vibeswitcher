#if canImport(Darwin)
import Foundation
import Security

// The Mac's Keychain: the session host's `VaultStorage.keychainKey` and `removeKeychainKey` bodies
// (Sources/VibeHost/VaultStorage.swift), moved here unchanged but for the key's type: bytes here, made by the caller
// (`make`), which holds CryptoKit's `SymmetricKey`. `read` is main's of 2026-11-27 (its status and whether the key was
// made on this read, `VaultStorage.KeyRead`), moved here the same way.
extension Platform.Keychain {
    enum System {
        static let notAKey: Int32 = errSecDecode

        static func read(service: String, account: String, label: String, size: Int, make: () -> Data) -> Read? {
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(true) }
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                       kSecAttrAccount as String: account]
            var found: CFTypeRef?
            var query = item
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(query as CFDictionary, &found)
            if status == errSecSuccess {
                guard let data = found as? Data, data.count == size else { return .unreadable(notAKey) }
                return .found(data, made: false)
            }
            guard status == errSecItemNotFound else { return .unreadable(status) }
            let data = make()
            var add = item
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            let added = SecItemAdd(add as CFDictionary, nil)
            return added == errSecSuccess ? .found(data, made: true) : .unreadable(added)
        }

        static func remove(service: String, account: String) {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: account] as CFDictionary)
        }
    }
}
#endif
