import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A host started on a home of its caller's choosing: another process of your account starts the genuine host with
/// VIBESWITCHER_HOME, HOME or `--lock` pointing at a folder of its own, gives it an app key on stdin (a first start
/// there), fills the vault as "the app", and hopes the host seals it under the vault's real Keychain key, to copy over
/// yours. Only the account's own host (its folder the account's real home, from the user database, and that folder's
/// lock) may use the real key: `HostRole`, as `main.swift` runs it. Scratch seams only: the account's home is a Scratch
/// folder, the Keychain a reader the test counts; never the Keychain.
struct HostRoleTests {
    let temp = Scratch()
    let base: URL
    /// The account's home, as the user database would give it.
    let account: URL
    /// The key the account's host would read from the Keychain.
    let realKey = SymmetricKey(size: .bits256)
    /// The other process's app key.
    let theirs = Data(repeating: 7, count: AppProof.keySize)
    let repo = "/repos/host-role"

    init() throws {
        let made = temp.url("host-role")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // As the kernel resolves it (/tmp is /private/tmp), as the host compares folders.
        let real = try #require(realpath(made.path, nil))
        defer { free(real) }
        base = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        account = base.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: account.appendingPathComponent(".vibeswitcher"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("theirs/.vibeswitcher"), withIntermediateDirectories: true)
    }

    /// The Keychain as the account's host reads it, counting the reads.
    final class Reader {
        let key: SymmetricKey
        var reads = 0
        init(_ key: SymmetricKey) { self.key = key }
        func read() -> SymmetricKey? {
            reads += 1
            return key
        }
    }

    func role(_ environment: [String: String], lock: String? = nil, accountHome: String?? = nil) -> HostRole {
        HostRole(environment: environment, fallbackHome: account.path, lockArgument: lock, accountHome: accountHome ?? account.path)
    }

    /// What the other process does with the host `role` starts as (holding its lock, as `main.swift` takes it): its
    /// key on stdin, a first start, then a change as the app. Whether the key was read, and the vault file it left.
    func fill(_ role: HostRole) throws -> (reads: Int, file: URL) {
        let reader = Reader(realKey)
        let lockFD = try HostServer.takeLock(at: role.lockPath)
        defer { Darwin.close(lockFD) }
        let key = role.vaultKey(reader.read)
        let book = role.vault(lockFD: lockFD, key: key, handedOver: nil, logPath: nil)
        #expect(book.adoptAppKey(theirs), "a first start takes the key on stdin")
        guard case .grant = book.answer(.issue(role: .lead, root: repo, task: nil, auditing: nil), from: .app) else {
            Issue.record("the caller, as the app, got no grant")
            return (reader.reads, role.root.appendingPathComponent("lead/vault.sealed"))
        }
        return (reader.reads, role.root.appendingPathComponent("lead/vault.sealed"))
    }

    /// The host `role` describes isn't the account's: it never reads the key, and nothing sealed under it is left.
    func expectNotTheAccountsHost(_ role: HostRole, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(!role.isAccountHost, "\(role.root.path)", sourceLocation: sourceLocation)
        let (reads, file) = try fill(role)
        #expect(reads == 0, "it read the vault's Keychain key", sourceLocation: sourceLocation)
        let sealed = FileManager.default.contents(atPath: file.path)
        #expect(sealed.flatMap { SealedData.open($0, key: realKey) } == nil, "a vault the caller filled, sealed under the real key",
                sourceLocation: sourceLocation)
    }

    /// The account's own host: its home, its lock. It reads the key and seals under it (the control).
    @Test func theAccountsOwnHostSealsUnderTheKey() throws {
        let role = role(["HOME": account.path])
        #expect(role.isAccountHost && role.holdsRootLock)
        let (reads, file) = try fill(role)
        #expect(reads == 1)
        let sealed = try #require(FileManager.default.contents(atPath: file.path))
        #expect(SealedData.open(sealed, key: realKey) != nil)
    }

    /// VIBESWITCHER_HOME on a folder of the caller's: its host keeps that folder's files, on its lock, but not the key.
    @Test func aHostOnVibeswitcherHomeIsntTheAccountsHost() throws {
        let role = role(["HOME": account.path, "VIBESWITCHER_HOME": base.appendingPathComponent("theirs/.vibeswitcher").path])
        #expect(role.holdsRootLock)
        try expectNotTheAccountsHost(role)
    }

    /// HOME (and CFFIXED_USER_HOME, which comes first) on a folder of the caller's.
    @Test func aHostOnAnotherHomeIsntTheAccountsHost() throws {
        let theirs = base.appendingPathComponent("theirs").path
        try expectNotTheAccountsHost(role(["HOME": theirs]))
        try expectNotTheAccountsHost(role(["HOME": account.path, "CFFIXED_USER_HOME": theirs]))
    }

    /// `--lock` on another file than the account's lock: beside the account's host on its own home, or on the caller's
    /// home where that's the folder's own lock.
    @Test func aHostOnAnotherLockIsntTheAccountsHost() throws {
        try expectNotTheAccountsHost(role(["HOME": account.path], lock: base.appendingPathComponent("other.lock").path))
        let theirs = base.appendingPathComponent("theirs/.vibeswitcher")
        try expectNotTheAccountsHost(role(["HOME": account.path, "VIBESWITCHER_HOME": theirs.path],
                                          lock: theirs.appendingPathComponent("host.lock").path))
        // The account's own lock with another folder's files: not the account's host either.
        try expectNotTheAccountsHost(role(["HOME": account.path, "VIBESWITCHER_HOME": theirs.path],
                                          lock: account.appendingPathComponent(".vibeswitcher/host.lock").path))
    }

    /// A home reached through a link: a link into another folder, however the path is spelled, isn't the account's
    /// home (`..` after a link is the link's target's parent, as the kernel goes); a link to the account's own home is
    /// that home, the same files.
    @Test func aSymlinkedHomeIsTheHomeItLeadsTo() throws {
        let files = FileManager.default
        let elsewhere = base.appendingPathComponent("theirs/inner")
        try files.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link-home")
        try files.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("theirs"))
        try expectNotTheAccountsHost(role(["HOME": link.path]))
        // Spelled as the account's own: `<account>/link/../.vibeswitcher`, the link into the caller's folder.
        let inner = account.appendingPathComponent("link")
        try files.createSymbolicLink(at: inner, withDestinationURL: elsewhere)
        try expectNotTheAccountsHost(role(["HOME": account.path, "VIBESWITCHER_HOME": account.path + "/link/../.vibeswitcher"]))
        // The account's home through a link to it: the account's host, the same folder and lock.
        let toAccount = base.appendingPathComponent("to-account")
        try files.createSymbolicLink(at: toAccount, withDestinationURL: account)
        let own = role(["HOME": toAccount.path])
        #expect(own.isAccountHost && own.root.path == account.appendingPathComponent(".vibeswitcher").path)
    }

    /// The account's home unknown (the user database didn't answer): no host is the account's.
    @Test func noAccountHomeNoAccountsHost() throws {
        try expectNotTheAccountsHost(role(["HOME": account.path], accountHome: .some(nil)))
        #expect(HostRole.accountHome == getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) })
    }

    /// On the account's own home, a second host started beside the running one, its lock file removed first (or
    /// replaced): the first no longer holds the lock there, and saves nothing more; a host whose descriptor doesn't
    /// hold the lock at its path never opens the vault for writing, and never reads the key for it.
    @Test func aSecondHostBesideTheRunningOneLeavesOneWriter() throws {
        let role = role(["HOME": account.path])
        let file = role.root.appendingPathComponent("lead/vault.sealed")
        let first = try HostServer.takeLock(at: role.lockPath)
        defer { Darwin.close(first) }
        let log = base.appendingPathComponent("host.log")
        let running = role.vault(lockFD: first, key: realKey, handedOver: nil, logPath: log.path)
        #expect(running.adoptAppKey(Data(repeating: 1, count: AppProof.keySize)))
        let saved = try Data(contentsOf: file)

        // The lock file removed: a second host takes a new one at the same path.
        try FileManager.default.removeItem(atPath: role.lockPath)
        let second = try HostServer.takeLock(at: role.lockPath)
        defer { Darwin.close(second) }
        _ = running.answer(.issue(role: .lead, root: repo, task: nil, auditing: nil), from: .app)
        #expect(try Data(contentsOf: file) == saved, "the host that lost its lock sealed over the vault")
        let said = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(said.contains("vault: vault.sealed not saved: this host no longer holds its lock"), "\(said)")
        let beside = role.vault(lockFD: second, key: realKey, handedOver: nil, logPath: nil)
        #expect(beside.appKey?.data == Data(repeating: 1, count: AppProof.keySize))
        _ = beside.answer(.issue(role: .lead, root: repo, task: nil, auditing: nil), from: .app)
        #expect(try Data(contentsOf: file) != saved, "the host holding the lock saves")

        // A descriptor on the lock that doesn't hold it, or none: a vault in memory only.
        let unheld = open(role.lockPath, O_RDWR | O_CLOEXEC)
        defer { Darwin.close(unheld) }
        let now = try Data(contentsOf: file)
        for fd in [unheld, first, -1] {
            let book = role.vault(lockFD: fd, key: realKey, handedOver: nil, logPath: nil)
            #expect(book.appKey == nil, "lock descriptor \(fd): it opened the vault")
            _ = book.adoptAppKey(theirs)
            #expect(try Data(contentsOf: file) == now, "lock descriptor \(fd): it sealed over the vault")
        }
    }

    /// On the account's own home, its lock file made a link (to a file the caller can rename into its place later):
    /// the host doesn't start on it, so it never runs as the account's host with the key read and its vault, or a
    /// handover proof, standing on a lock that isn't the file at its path. Nor on one replaced between its taking and
    /// the check.
    @Test func aLinkedOrReplacedLockStartsNoAccountsHost() throws {
        let role = role(["HOME": account.path])
        let target = role.root.appendingPathComponent("target")
        #expect(FileManager.default.createFile(atPath: target.path, contents: nil))
        try FileManager.default.createSymbolicLink(atPath: role.lockPath, withDestinationPath: target.path)
        if let fd = try? role.takeLock() {
            Darwin.close(fd)
            Issue.record("the account's host took its lock through a link")
        }
        try FileManager.default.removeItem(atPath: role.lockPath)
        try FileManager.default.removeItem(at: target)
        // Taken, then moved aside (another file in its place): refused.
        let racer = HostRole(environment: ["HOME": account.path], fallbackHome: account.path, lockArgument: nil,
                             accountHome: account.path, afterTaking: { path in
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".aside")
            FileManager.default.createFile(atPath: path, contents: nil)
        })
        if let fd = try? racer.takeLock() {
            Darwin.close(fd)
            Issue.record("the account's host kept a lock that isn't the file at its path")
        }
    }

    /// Known, and the next task in these files (not this one's): on the account's own home, the vault file moved aside
    /// and the host started again, it's a first start once more and takes the key on stdin unasked, though the
    /// Keychain's key was there already (a vault had been sealed under it). The rule proposed: a key that was there
    /// with no vault file is a vault that started over, waiting for your confirmation through the app.
    @Test func aVaultFileMovedAsideOnTheAccountsHomeIsntAFirstStart() throws {
        let role = role(["HOME": account.path])
        let file = role.root.appendingPathComponent("lead/vault.sealed")
        do {
            let lockFD = try HostServer.takeLock(at: role.lockPath)
            defer { Darwin.close(lockFD) }
            #expect(role.vault(lockFD: lockFD, key: realKey, handedOver: nil, logPath: nil).adoptAppKey(Data(repeating: 1, count: AppProof.keySize)))
        }
        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("aside"))
        let lockFD = try HostServer.takeLock(at: role.lockPath)
        defer { Darwin.close(lockFD) }
        let restarted = role.vault(lockFD: lockFD, key: realKey, handedOver: nil, logPath: nil)
        withKnownIssue("a key that was there with no vault file still counts as a first start") {
            #expect(!restarted.adoptAppKey(theirs), "it took another process's key unasked")
        }
    }
}

/// The same through a real exec of the built host: started on a scratch home's own lock (VIBESWITCHER_HOME, HOME and
/// CFFIXED_USER_HOME there, as another process of your account would), with an app key on stdin, its caller fills the
/// vault as the app, and no vault file is sealed: the host on that home keeps its vault in memory. Safe to run only
/// with the rule in place: it asks `HostRole` first, as the binary will, and starts nothing should that host be the
/// account's (which reads the Keychain).
@Suite(hostTestLimit) struct HostOnAnotherHomeProcessTests {
    @Test func aHostStartedOnAnotherHomeSealsNothing() async throws {
        // Short: a socket's path has a 104-byte limit.
        let dir = "\(shortScratchRoot)/vshr-\(UUID().uuidString.prefix(8))"
        let home = dir + "/home", root = home + "/.vibeswitcher", socket = dir + "/h.sock", lock = root + "/host.lock"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let environment = ["HOME": home, "CFFIXED_USER_HOME": home, "VIBESWITCHER_HOME": root, "SHELL": "/bin/sh",
                           "PATH": "/usr/bin:/bin", "TMPDIR": dir + "/"]
        let role = HostRole(environment: environment, fallbackHome: home, lockArgument: lock, accountHome: HostRole.accountHome)
        try #require(role.holdsRootLock && !role.isAccountHost, "this host would be the account's: not started")

        let host = Process()
        host.executableURL = URL(fileURLWithPath: hostLauncher)
        host.arguments = ["--socket", socket, "--lock", lock, "--idle-exit", "600"]
        host.environment = environment
        FileManager.default.createFile(atPath: dir + "/host.out", contents: nil)
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: dir + "/host.out"))
        host.standardOutput = output
        host.standardError = output
        let key = try TestHosts.authorize(host)
        try TestHosts.run(host)
        defer { TestHosts.end(host) }
        #expect(await eventually { FileManager.default.fileExists(atPath: socket) })
        let app = try TestClient(socket: socket, appKey: key)
        defer { app.close() }
        let reply = app.vault(.issue(role: .lead, root: "/repos/host-role", task: nil, auditing: nil))
        guard case .grant? = reply else {
            Issue.record("the caller, as the app, got no grant: \(String(describing: reply))")
            return
        }
        // The host on that home's own lock: its folder's log, and no vault file there.
        #expect(FileManager.default.fileExists(atPath: root + "/debug/host.log"))
        #expect(!FileManager.default.fileExists(atPath: root + "/lead/vault.sealed"), "a vault the caller filled was sealed")
    }
}
