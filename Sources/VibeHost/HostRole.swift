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
    private let afterTaking: ((String) -> Void)?

    /// `environment` and `fallbackHome`: as `VibePaths.root(environment:fallbackHome:)` takes them. `lockArgument`:
    /// `--lock`'s value. `accountHome`: the account's home from the user database (`accountHome`).
    ///
    /// The account's host is the one whose folder is the account's own `~/.vibeswitcher` (the user database's home,
    /// which no variable moves, as the kernel resolves both paths: a link into another folder is that folder), on that
    /// folder's own lock. Its folder and lock are then that resolved folder's. Every other host (VIBESWITCHER_HOME,
    /// HOME or CFFIXED_USER_HOME on another folder, a `--lock` of its own, the account's home unknown) is a scratch
    /// host for the vault: it never reads the Keychain's key, and keeps its vault in memory only.
    public init(environment: [String: String], fallbackHome: String, lockArgument: String?, accountHome: String?) {
        self.init(environment: environment, fallbackHome: fallbackHome, lockArgument: lockArgument, accountHome: accountHome,
                  afterTaking: nil)
    }

    /// `afterTaking`: a test's own step between the lock's taking and its check (`takeLock`).
    init(environment: [String: String], fallbackHome: String, lockArgument: String?, accountHome: String?,
         afterTaking: ((String) -> Void)?) {
        self.afterTaking = afterTaking
        let given = VibePaths.root(environment: environment, fallbackHome: fallbackHome)
        let rootLock = given.appendingPathComponent("host.lock").path
        let lockPath = lockArgument ?? rootLock
        holdsRootLock = lockPath == rootLock
        if holdsRootLock, let accountHome, let own = Self.resolved(accountHome + "/.vibeswitcher"), Self.resolved(given.path) == own {
            root = URL(fileURLWithPath: own, isDirectory: true)
            self.lockPath = root.appendingPathComponent("host.lock").path
            isAccountHost = true
        } else {
            root = given
            self.lockPath = lockPath
            isAccountHost = false
        }
    }

    /// `path` as the kernel resolves it (links followed, `..` after a link being its target's parent); nil when it
    /// isn't there.
    static func resolved(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// The account's home from the user database, which no environment variable moves; nil when it can't be read.
    public static var accountHome: String? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        return home.hasPrefix("/") ? home : nil
    }

    /// A fresh start's lock (`HostServer.takeLock` on `lockPath`, never through a link): the descriptor that holds it.
    /// `main.swift` takes it before the vault's key or file is read. The account's host takes it only when it's the
    /// file at its path once held (`Failure.notTheLock` otherwise, the descriptor closed): one that isn't runs as
    /// nothing, rather than as the account's host with its key read and its vault on a lock another host can take.
    public func takeLock() throws -> Int32 {
        let fd = try HostServer.takeLock(at: lockPath)
        afterTaking?(lockPath)
        if isAccountHost, let why = HostHandover.Lock.notHeld(fd, path: lockPath) {
            Darwin.close(fd)
            throw Failure.notTheLock(why)
        }
        return fd
    }

    public enum Failure: Error, CustomStringConvertible {
        /// The lock taken isn't the lock file at its path: why.
        case notTheLock(String)

        public var description: String {
            switch self {
            case .notTheLock(let why): return "its lock isn't the lock file at its path (\(why))"
            }
        }
    }

    /// The vault's key, `read` (the Keychain's) for the account's host alone: nil for any other, which never reads it.
    public func vaultKey(_ read: () -> SymmetricKey?) -> SymmetricKey? {
        isAccountHost ? read() : nil
    }

    /// The vault this host starts with. The account's host keeps it sealed under `key` in its root's `lead/vault.sealed`
    /// (see `VaultStorage`), as the build before handed it over (`handedOver`) or as saved, and only while it holds its
    /// lock: `lockFD` must be the descriptor holding the lock file at `lockPath` (taken before the vault is read), and
    /// each save first checks the file there is still that one (a lock file removed or replaced lets a second host start
    /// on the same folder: from then on that one keeps the vault, and this one saves nothing). Any other host, or one
    /// whose descriptor doesn't hold its lock, keeps a vault in memory only, never touching a vault file.
    public func vault(lockFD: Int32, key: SymmetricKey?, handedOver: Data?, logPath: String?) throws -> LeadVault.Book {
        guard isAccountHost, HostHandover.Lock.notHeld(lockFD, path: lockPath) == nil else { return LeadVault.Book(restoring: handedOver) }
        let lockPath = lockPath
        return VaultStorage(file: root.appendingPathComponent("lead/vault.sealed"), key: key, logPath: logPath,
                            holdsLock: { HostHandover.Lock.names(lockFD, path: lockPath) }).book(handedOver: handedOver)
    }
}
