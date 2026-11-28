import Foundation

/// App-owned state kept on disk sealed against edits by your own account's other processes: ChaChaPoly under a key from
/// your login Keychain, which the Keychain gives without asking only to the VibeSwitcher binary that made it. What
/// another process wrote, changed, or sealed under another key doesn't open. The lead's vault (`VaultStorage`, the host's
/// key) and Phone Access's paired phones (the app's key, `purposeKey`) are kept this way.
public enum SealedData {
    public static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(data, using: key).combined
    }

    /// What `seal` sealed under `key`; nil for anything else (changed, made by something else, another key's).
    public static func open(_ sealed: Data, key: SymmetricKey) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }

    /// A key for one purpose, from the app's own key (`AppProof`): the app's key itself never seals a file, and what's
    /// sealed for one purpose doesn't open as another.
    public static func purposeKey(_ purpose: String, from key: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("vibeswitcher-sealed-\(purpose)".utf8), outputByteCount: 32)
    }
}
