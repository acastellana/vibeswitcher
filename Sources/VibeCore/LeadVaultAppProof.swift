import Foundation

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

    /// Where the ElevenLabs API key for the spoken briefing is kept (Settings › Dictation & Briefing › Spoken briefing).
    public static let elevenLabsAccount = "elevenlabs-api-key"
    /// Where the OpenAI API key for dictation is kept (Settings › Dictation & Briefing › Dictation).
    public static let openAIAccount = "openai-api-key"

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
