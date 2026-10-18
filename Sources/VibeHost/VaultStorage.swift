import CryptoKit
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

    public init(file: URL, key: SymmetricKey?) {
        self.file = file
        self.key = key
    }

    /// The vault as saved, or a new one; it saves itself after each change when there's a key.
    public func book() -> LeadVault.Book {
        let book = LeadVault.Book(restoring: load())
        if key != nil { book.onChange = { data in try? self.save(data) } }
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
        try LeadVault.writePrivate(try ChaChaPoly.seal(data, using: key).combined, to: file)
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
