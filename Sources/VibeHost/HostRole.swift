import CryptoKit
import Darwin
import Foundation
import VibeCore

/// Which host this process is, decided once at its start (`main.swift`): the folder it keeps its files in, the lock it
/// runs on, and whether it's the account's own host, the one that may use the vault's Keychain item.
public struct HostRole {
    /// VibeSwitcher's folder this host keeps its files in.
    public let root: URL
    /// The lock it runs on: `--lock`, else its root's `host.lock`.
    public let lockPath: String
    /// On its root's own lock: the one host of that folder, which keeps that folder's files (its launchers, its log)
    /// and sweeps its orphaned tool servers. A scratch host on a lock of its own runs beside it and leaves them alone.
    public let holdsRootLock: Bool
    /// The account's own host: the only one that reads the vault's Keychain item and seals the vault under it.
    public let isAccountHost: Bool

    /// `environment` and `fallbackHome`: as `VibePaths.root(environment:fallbackHome:)` takes them. `lockArgument`:
    /// `--lock`'s value. `accountHome`: the account's home from the user database (`accountHome`).
    public init(environment: [String: String], fallbackHome: String, lockArgument: String?, accountHome: String?) {
        let root = VibePaths.root(environment: environment, fallbackHome: fallbackHome)
        let rootLock = root.appendingPathComponent("host.lock").path
        self.root = root
        lockPath = lockArgument ?? rootLock
        holdsRootLock = lockPath == rootLock
        isAccountHost = holdsRootLock
    }

    /// The account's home from the user database, which no environment variable moves; nil when it can't be read.
    public static var accountHome: String? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        return home.hasPrefix("/") ? home : nil
    }

    /// The vault's key, `read` (the Keychain's) for the account's host alone: nil for any other, which never reads it.
    public func vaultKey(_ read: () -> SymmetricKey?) -> SymmetricKey? {
        isAccountHost ? read() : nil
    }

    /// The vault this host starts with. The account's host keeps it sealed under `key` in its root's `lead/vault.sealed`
    /// (see `VaultStorage`), as the build before handed it over (`handedOver`) or as saved; any other host keeps one in
    /// memory only, never touching a vault file. `lockFD`: the descriptor this host holds its lock through.
    public func vault(lockFD: Int32, key: SymmetricKey?, handedOver: Data?, logPath: String?) -> LeadVault.Book {
        guard isAccountHost else { return LeadVault.Book(restoring: handedOver) }
        return VaultStorage(file: root.appendingPathComponent("lead/vault.sealed"), key: key, logPath: logPath).book(handedOver: handedOver)
    }
}
