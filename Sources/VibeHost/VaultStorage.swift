import CryptoKit
import Foundation
import Security
import VibeCore

/// Where the host keeps the lead's vault (see `LeadVault.Book`) across its restarts: one file, sealed (ChaChaPoly)
/// with a key from your login Keychain. The Keychain gives that key, without asking you, only to the binary that
/// created it (the host); anything else that asks (`security find-generic-password`, a worker's script) makes macOS
/// ask you first. A file that was changed, or sealed with another key, doesn't open: the vault starts empty, and the
/// file is kept as it was (see `book`).
public struct VaultStorage {
    public let file: URL
    /// Nil: no key (the Keychain didn't give it without asking): the vault lives in memory only.
    public let key: SymmetricKey?
    /// `key` was made on this start, the Keychain holding none before (`Key.made`): only then is a missing vault file a
    /// first start. False for a key that was there already.
    public let keyIsNew: Bool
    /// The host's log, for a save that failed (the file's name and why, never what's in it); nil logs nothing.
    private let logPath: String?
    private let sync: (Int32) -> Bool
    /// How a failed save's next try is timed; a test's own instead.
    private let retryLater: (TimeInterval, @escaping () -> Void) -> Void
    /// Whether the host still holds its lock (see `HostRole.vault`), asked before each save: false saves nothing more.
    private let holdsLock: () -> Bool

    /// `keyIsNew`: said by whoever read the key (`Key.made`), never assumed.
    public init(file: URL, key: SymmetricKey?, keyIsNew: Bool, logPath: String? = nil, holdsLock: @escaping () -> Bool = { true }) {
        self.init(file: file, key: key, keyIsNew: keyIsNew, logPath: logPath, sync: VibePaths.syncToDisk, holdsLock: holdsLock) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + $0, execute: $1)
        }
    }

    /// A test's: its key one it just made (`keyIsNew`), unless it says otherwise.
    init(file: URL, key: SymmetricKey?, logPath: String? = nil) {
        self.init(file: file, key: key, keyIsNew: true, logPath: logPath)
    }

    init(file: URL, key: SymmetricKey?, keyIsNew: Bool = true, logPath: String? = nil,
         sync: @escaping (Int32) -> Bool = VibePaths.syncToDisk, holdsLock: @escaping () -> Bool = { true },
         retryLater: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.file = file
        self.key = key
        self.keyIsNew = keyIsNew
        self.logPath = logPath
        self.sync = sync
        self.holdsLock = holdsLock
        self.retryLater = retryLater
    }

    /// The vault a handover carried (`handedOver`, the build before's memory), else as saved, else a new one (noting
    /// that it starts over when there was one it can't read); it saves itself after each change when there's a key.
    /// A vault that started over saves nothing while it waits for your answer (`Book.awaitsAppKey`): the file that
    /// didn't open stays as it was until you teach the host the app's key, and is then set aside beside it
    /// (`setAsideSuffix`), never sealed over.
    public func book(handedOver: Data? = nil) -> LeadVault.Book {
        let handedOver = handedOver.flatMap { LeadVault.Book.reads($0) ? $0 : nil }
        let opened = load()
        let saved = handedOver ?? opened
        let there = FileManager.default.fileExists(atPath: file.path)
        // Started over whenever a vault file was there and what came of it doesn't read (it didn't open, or opened as
        // something that isn't a vault): only a first start, with no file, takes the app's key unasked.
        let reads = saved.map(LeadVault.Book.reads) ?? false
        let book = LeadVault.Book(restoring: saved, startingOver: !reads && there)
        if key != nil {
            // A file there that isn't a vault under this key (a handed-over vault doesn't read it) is never saved over,
            // nor one that opens when the vault waiting for your answer came from memory (a build before without a key).
            let unopened = there && (!(opened.map(LeadVault.Book.reads) ?? false) || book.awaitsAppKey)
            let saver = Saver(storage: self, log: HostLog(path: logPath), later: retryLater, setAside: unopened)
            book.onChange = { saver.save($0) }
            // What came from memory goes to disk at once only where no vault opens (none there yet, or one that didn't
            // open, set aside first): a vault that opens is never saved over by the handover itself, only by a change
            // the vault makes afterwards (the build before saved each of its own).
            let opens = opened.map(LeadVault.Book.reads) ?? false
            if handedOver != nil, !opens { saver.save(book.serialized) }
        }
        return book
    }

    public func load() -> Data? {
        guard let key, let sealed = FileManager.default.contents(atPath: file.path) else { return nil }
        return SealedData.open(sealed, key: key)
    }

    public func save(_ data: Data) throws {
        guard let key else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try VibePaths.writePrivate(try SealedData.seal(data, key: key), to: file, syncing: sync)
    }

    /// Moves the file that's there aside, beside it, under a name that says why and when (`setAsideSuffix`): the
    /// name it took, or nil when there was none.
    func setAside(at date: Date = Date()) throws -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let name = file.lastPathComponent + Self.setAsideSuffix + Self.stamp(date)
        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent(name))
        return name
    }

    /// What follows `vault.sealed` in the name of one that didn't open, set aside once you taught the host: then the
    /// date and time it was set aside.
    public static let setAsideSuffix = ".didnt-open-"

    private static func stamp(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        return format.string(from: date)
    }

    /// How long before each next try of a save that failed; the last repeats until one goes through.
    static let retryDelays: [TimeInterval] = [1, 5, 30, 60]

    /// Saves each change as it comes (`Book.onChange`, whole vault each time). One that fails is logged, once for each
    /// reason, and tried again on `retryDelays`: only the newest is kept to try, and a later change that saves ends it.
    /// A vault that waits for your answer (`Book.awaitsAppKey`) isn't saved: kept to save once you've answered,
    /// whose change carries it all. A file there that didn't open (`setAside`) is set aside before the first save.
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
        /// The file there didn't open: set aside before anything is saved in its place.
        private var setAside: Bool
        /// A vault was seen that doesn't wait for your answer: none waits after it (the app's key is never taken out).
        private var answered = false
        private var toldHeld = false
        /// The lock was seen lost: nothing is saved from then on.
        private var lockLost = false

        init(storage: VaultStorage, log: HostLog, later: @escaping (TimeInterval, @escaping () -> Void) -> Void, setAside: Bool) {
            self.storage = storage
            self.log = log
            self.later = later
            self.setAside = setAside
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
            guard let data = unsaved, !lockLost else { return }
            // A host that no longer holds its lock (its lock file removed or replaced, and maybe a second host started
            // on this folder, which keeps the vault from then on) seals nothing more.
            guard storage.holdsLock() else {
                lockLost = true
                unsaved = nil
                log.note("vault: \(name) not saved: this host no longer holds its lock (its lock file was removed or replaced); it saves nothing more")
                return
            }
            if !answered {
                guard !LeadVault.Book.awaitsAppKey(data) else {
                    if !toldHeld { log.note("vault: \(name) didn't open; kept as it is, nothing saved until you answer") }
                    toldHeld = true
                    return
                }
                answered = true
            }
            do {
                if setAside {
                    if let aside = try storage.setAside() { log.note("vault: \(name) didn't open; set aside as \(aside)") }
                    setAside = false
                }
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

    /// The vault's key as the Keychain gave it: `made` on this read (the Keychain had no such item, and the one made
    /// was added), or there already.
    public struct Key {
        public let key: SymmetricKey
        public let made: Bool

        public init(_ key: SymmetricKey, made: Bool) {
            self.key = key
            self.made = made
        }
    }

    /// The vault's key from the login Keychain, made the first time (`Key.made`: only when the Keychain said it had
    /// none and took the new one; every other key is one that was there). Never asks you (the host has no window to
    /// ask from): nil when the Keychain won't give it without asking (a rebuilt host without the stable signing
    /// identity, see scripts/setup-signing.sh), and then nothing is saved.
    public static func keychainKey(service: String = keychainService, account: String = "vault") -> Key? {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        var found: CFTypeRef?
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data, data.count == 32 { return Key(SymmetricKey(data: data), made: false) }
        guard status == errSecItemNotFound else { return nil }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "VibeSwitcher lead vault"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? Key(SymmetricKey(data: data), made: true) : nil
    }

    public static func removeKeychainKey(service: String, account: String = "vault") {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
