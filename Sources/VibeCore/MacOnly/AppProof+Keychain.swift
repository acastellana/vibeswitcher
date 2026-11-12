#if canImport(Darwin)
import Foundation
import Security

// The app's key and the secrets you give it, in the login Keychain: what only the Mac has of `AppProof`
// (LeadVaultAppProof.swift), as it was there.
extension AppProof {
    /// The app's key in the login Keychain, made the first time (see `AppKeyStore`). The app may ask you (it has a
    /// window to ask from): a rebuild without the stable signing identity (scripts/setup-signing.sh) is another
    /// program to the Keychain. Nil when there's none to be had (you said no): the app then isn't the app to the host.
    /// Only the app makes one (AppDelegate), and besides it only the live test, run when asked for (KeychainLiveTests).
    public struct KeychainStore: AppKeyStore {
        public let service: String
        public let account: String

        public init(service: String = keychainService, account: String = "app") {
            self.service = service
            self.account = account
        }

        public func key() -> SymmetricKey? {
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                       kSecAttrAccount as String: account]
            var found: CFTypeRef?
            var query = item
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(query as CFDictionary, &found)
            if status == errSecSuccess, let data = found as? Data, data.count == keySize { return SymmetricKey(data: data) }
            // Only when there's none: one you refused stays yours (a new key would never match the host's).
            guard status == errSecItemNotFound, let access = appOnlyAccess() else { return nil }
            let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            var add = item
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "VibeSwitcher app key"
            add[kSecAttrAccess as String] = access
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? SymmetricKey(data: data) : nil
        }
    }

    /// A secret you typed in Settings (the ElevenLabs API key, the OpenAI one), in the login Keychain beside the app's key, with the
    /// same access: this program only (`appOnlyAccess`). Read only when it's used (the Brief me button, Test voice,
    /// Settings showing whether one is saved); never written anywhere else. Only the app makes one (AppDelegate);
    /// tests use `MemorySecret`.
    public struct KeychainSecret: SecretStore {
        public let service: String
        public let account: String
        /// What Keychain Access names the item.
        public let label: String

        public init(service: String = keychainService, account: String, label: String = "VibeSwitcher ElevenLabs API key") {
            self.service = service
            self.account = account
            self.label = label
        }

        private var item: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        }

        public func read() -> String? {
            var query = item
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var found: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
            return text
        }

        @discardableResult
        public func write(_ value: String?) -> Bool {
            let status = SecItemDelete(item as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { return false }
            guard let value, !value.isEmpty else { return true }
            guard let access = appOnlyAccess() else { return false }
            var add = item
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrLabel as String] = label
            add[kSecAttrAccess as String] = access
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }

    /// Who reads the item without macOS asking you: this program only (never "any application"); anything else that
    /// asks (`security find-generic-password -w` in a worker's shell) gets a prompt naming it. The access list holds
    /// this program's designated requirement: for a build signed with the local identity, its identifier and
    /// certificate, not its cdhash, so any binary signed with that identity and identifier reads it too (checked in a
    /// scratch keychain: README, "Security: the signing identity"); for an ad-hoc build, its cdhash. Being the app to
    /// the host takes its cdhash as well (`AppCode`).
    static func appOnlyAccess() -> SecAccess? {
        var me: SecTrustedApplication?
        var access: SecAccess?
        guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me,
              SecAccessCreate("VibeSwitcher app key" as CFString, [me] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
#endif
