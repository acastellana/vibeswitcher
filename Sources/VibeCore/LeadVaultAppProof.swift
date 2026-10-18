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

    /// The app's key from the login Keychain, made the first time. The app may ask you (it has a window to ask from):
    /// a rebuild without the stable signing identity (scripts/setup-signing.sh) is another program to the Keychain.
    /// Nil when there's none to be had (you said no): the app then isn't the app to the host.
    /// `keychain`: another keychain than the login one (tests).
    public static func keychainKey(service: String = keychainService, account: String = "app", keychain: SecKeychain? = nil) -> SymmetricKey? {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        var found: CFTypeRef?
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data, data.count == keySize { return SymmetricKey(data: data) }
        // Only when there's none: one you refused stays yours (a new key would never match the host's).
        guard status == errSecItemNotFound, let access = appOnlyAccess() else { return nil }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "VibeSwitcher app key"
        add[kSecAttrAccess as String] = access
        if let keychain { add[kSecUseKeychain as String] = keychain }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? SymmetricKey(data: data) : nil
    }

    /// Who reads the item without macOS asking you: this program's code only (never "any application"); anything
    /// else that asks (`security find-generic-password -w` in a worker's shell) gets a prompt naming it.
    static func appOnlyAccess() -> SecAccess? {
        var me: SecTrustedApplication?
        var access: SecAccess?
        guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me,
              SecAccessCreate("VibeSwitcher app key" as CFString, [me] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}

extension SymmetricKey {
    /// The key's bytes (to hand the session host).
    public var data: Data { withUnsafeBytes { Data($0) } }
}
