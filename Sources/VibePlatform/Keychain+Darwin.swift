#if canImport(Darwin)
import Foundation
import Security

// The Mac's Keychain: the session host's `VaultStorage.keychainKey` and `removeKeychainKey` bodies
// (Sources/VibeHost/VaultStorage.swift), moved here unchanged but for the key's type: bytes here, made by the caller
// (`make`), which holds CryptoKit's `SymmetricKey`.
extension Platform.Keychain {
    enum System {
        static func key(service: String, account: String, label: String, size: Int, make: () -> Data) -> Data? {
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(true) }
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                       kSecAttrAccount as String: account]
            var found: CFTypeRef?
            var query = item
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(query as CFDictionary, &found)
            if status == errSecSuccess, let data = found as? Data, data.count == size { return data }
            guard status == errSecItemNotFound else { return nil }
            let data = make()
            var add = item
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? data : nil
        }

        static func remove(service: String, account: String) {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: account] as CFDictionary)
        }
    }
}
#endif
