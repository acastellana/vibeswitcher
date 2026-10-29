import CryptoKit
import Foundation
import Security

/// How the app proves to the session host that it's the app, on each connection: the host's welcome carries a fresh
/// challenge for that connection, and the app answers it with an HMAC under a key only it and the host hold (the app
/// keeps it in your login Keychain, which gives it without asking only to the app; the host keeps it in its vault).
/// Until a connection has answered, the host takes nothing from it as the app's: so no process that merely shares the
/// app's binary, or a connection to the host, passes for the app, whatever the kernel names as its peer when the host
/// reads it.
public enum AppProof {
    public static let keySize = 32
    /// What the app starts the host with when it gives it the key on stdin.
    public static let hostStdinFlag = "--app-key-stdin"

    /// A fresh challenge for one connection.
    public static func challenge() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    /// The answer to `challenge` under `key`.
    public static func answer(_ challenge: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("vibeswitcher-app-proof\0".utf8) + challenge, using: key))
    }

    public static func isValid(_ answer: Data, to challenge: Data, key: SymmetricKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(answer, authenticating: Data("vibeswitcher-app-proof\0".utf8) + challenge, using: key)
    }

    public static let keychainService = "dev.vibeswitcher.app-proof"

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

    /// The app's key in memory, made the first time as the Keychain makes it (or the one given): the store every
    /// test uses in place of `KeychainStore`.
    public final class MemoryStore: AppKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var held: SymmetricKey?

        public init(key: SymmetricKey? = nil) { held = key }

        public func key() -> SymmetricKey? {
            lock.withLock {
                if held == nil { held = SymmetricKey(size: .bits256) }
                return held
            }
        }
    }

    /// Where the ElevenLabs API key for the spoken briefing is kept (Settings › General › Briefing).
    public static let elevenLabsAccount = "elevenlabs-api-key"
    /// Where the OpenAI API key for dictation is kept (Settings › General › Dictation).
    public static let openAIAccount = "openai-api-key"

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

    /// A secret in memory: the store every test uses in place of `KeychainSecret`.
    public final class MemorySecret: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var held: String?
        /// How many times it was read (for tests: the key is read only when it's used).
        public private(set) var reads = 0

        public init(_ value: String? = nil) { held = value }

        public func read() -> String? {
            lock.withLock {
                reads += 1
                return held
            }
        }

        @discardableResult
        public func write(_ value: String?) -> Bool {
            lock.withLock { held = value?.isEmpty == false ? value : nil }
            return true
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

/// Where the app keeps the key it proves itself with (see `AppProof`): the login Keychain in the app
/// (`AppProof.KeychainStore`), memory in tests (`AppProof.MemoryStore`). No test reaches the Keychain: under a scratch
/// HOME (every worker's and verifier's `swift test`) there's no login keychain, and macOS answers a SecItem call for
/// one with a "Keychain Not Found" dialog in your face, not an error.
public protocol AppKeyStore: Sendable {
    func key() -> SymmetricKey?
}

/// Where the app keeps a secret you gave it (the ElevenLabs API key): the login Keychain in the app
/// (`AppProof.KeychainSecret`), memory in tests (`AppProof.MemorySecret`), for the same reason as `AppKeyStore`.
public protocol SecretStore: Sendable {
    /// The secret, or nil when none is saved.
    func read() -> String?
    /// Saves it (nil or empty: removes it); false when the Keychain refused.
    @discardableResult func write(_ value: String?) -> Bool
}

extension SymmetricKey {
    /// The key's bytes (to hand the session host).
    public var data: Data { withUnsafeBytes { Data($0) } }
}
