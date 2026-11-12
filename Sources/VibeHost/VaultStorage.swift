import Foundation
import Security
import VibeCore

/// Where the host keeps the lead's vault (see `LeadVault.Book`) across its restarts: one file, sealed (ChaChaPoly)
/// with a key from your login Keychain. The Keychain gives that key, without asking you, only to the binary that
/// created it (the host); anything else that asks (`security find-generic-password`, a worker's script) makes macOS
/// ask you first. A file that was changed, or sealed with another key, doesn't open: the vault starts empty.
public struct VaultStorage {
    public let file: URL
    /// Nil: no key (the Keychain didn't give it without asking): the vault lives in memory only.
    public let key: SymmetricKey?
    /// The host's log, for a save that failed (the file's name and why, never what's in it); nil logs nothing.
    private let logPath: String?
    private let sync: (Int32) -> Bool
    /// How a failed save's next try is timed; a test's own instead.
    private let retryLater: (TimeInterval, @escaping () -> Void) -> Void

    public init(file: URL, key: SymmetricKey?, logPath: String? = nil) {
        self.init(file: file, key: key, logPath: logPath, sync: VibePaths.syncToDisk) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + $0, execute: $1)
        }
    }

    init(file: URL, key: SymmetricKey?, logPath: String? = nil, sync: @escaping (Int32) -> Bool = VibePaths.syncToDisk,
         retryLater: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.file = file
        self.key = key
        self.logPath = logPath
        self.sync = sync
        self.retryLater = retryLater
    }

    /// The vault a handover carried (`handedOver`, the build before's memory), else as saved, else a new one (noting
    /// that it starts over when there was one it can't read); it saves itself after each change when there's a key.
    public func book(handedOver: Data? = nil) -> LeadVault.Book {
        let handedOver = handedOver.flatMap { LeadVault.Book.reads($0) ? $0 : nil }
        let saved = handedOver ?? load()
        let book = LeadVault.Book(restoring: saved, startingOver: saved == nil && FileManager.default.fileExists(atPath: file.path))
        if key != nil {
            let saver = Saver(storage: self, log: HostLog(path: logPath), later: retryLater)
            book.onChange = { saver.save($0) }
            // What came from memory goes to disk too (the build before may have had no key to save it with).
            if handedOver != nil { saver.save(book.serialized) }
        }
        return book
    }

    public func load() -> Data? {
        guard let key, let sealed = FileManager.default.contents(atPath: file.path),
              let box = try? ChaChaPoly.SealedBox(combined: sealed) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }

    public func save(_ data: Data) throws {
        guard let key else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try VibePaths.writePrivate(try ChaChaPoly.seal(data, using: key).combined, to: file, syncing: sync)
    }

    /// How long before each next try of a save that failed; the last repeats until one goes through.
    static let retryDelays: [TimeInterval] = [1, 5, 30, 60]

    /// Saves each change as it comes (`Book.onChange`, whole vault each time). One that fails is logged, once for each
    /// reason, and tried again on `retryDelays`: only the newest is kept to try, and a later change that saves ends it.
    private final class Saver: @unchecked Sendable {
        private let storage: VaultStorage
        private let log: HostLog
        private let later: (TimeInterval, @escaping () -> Void) -> Void
        private var name: String { storage.file.lastPathComponent }
        private let lock = NSLock()
        /// The newest vault not on disk yet.
        private var unsaved: Data?
        private var retries = 0
        private var retryArmed = false
        /// Why the last try failed, as logged: an error's domain and code, which carry no path and nothing of the vault.
        private var told: String?

        init(storage: VaultStorage, log: HostLog, later: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
            self.storage = storage
            self.log = log
            self.later = later
        }

        func save(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            unsaved = data
            attempt()
        }

        private func retry() {
            lock.lock()
            defer { lock.unlock() }
            retryArmed = false
            attempt()
        }

        private func attempt() {
            guard let data = unsaved else { return }
            do {
                try storage.save(data)
                unsaved = nil
                retries = 0
                if told != nil { log.note("vault: \(name) saved after failing") }
                told = nil
            } catch {
                let error = error as NSError
                let reason = "\(error.domain) \(error.code)"
                let delay = VaultStorage.retryDelays[min(retries, VaultStorage.retryDelays.count - 1)]
                if reason != told { log.note("vault: couldn't save \(name) (\(reason)); trying again") }
                told = reason
                guard !retryArmed else { return }
                retryArmed = true
                retries += 1
                later(delay) { [weak self] in self?.retry() }
            }
        }
    }

    public static let keychainService = "dev.vibeswitcher.lead-vault"

    /// The vault's key from the login Keychain, made the first time. Never asks you (the host has no window to ask
    /// from): nil when the Keychain won't give it without asking (a rebuilt host without the stable signing
    /// identity, see scripts/setup-signing.sh), and then nothing is saved.
    public static func keychainKey(service: String = keychainService, account: String = "vault") -> SymmetricKey? {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        var found: CFTypeRef?
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { return nil }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "VibeSwitcher lead vault"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? SymmetricKey(data: data) : nil
    }

    public static func removeKeychainKey(service: String, account: String = "vault") {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
