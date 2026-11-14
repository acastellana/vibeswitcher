import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The test binary as any process that hardens itself (`PR_SET_DUMPABLE 0` needs no privilege): started again with
/// `HardenedHelper.variable` set, it hardens, says "hardened true" (or false) on its stdout, and ends (0) at its
/// stdin's end. Never the test process itself, which other tests read.
enum HardenedHelper {
    static let variable = "VIBE_HARDENED_TEST_HELPER"

    static func serveIfAsked() {
        guard getenv(variable) != nil else { return }
        let line = "hardened \(Platform.ProcessSelf.harden())\n"
        _ = write(STDOUT_FILENO, line, line.utf8.count)
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, 1)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
        }
        _exit(0)
    }

    /// A helper started, once it said it has hardened: its pid, the write end of its stdin (closed: it ends), and
    /// its first line.
    static func start() throws -> (pid: pid_t, stdin: Int32, said: String) {
        let binary = try #require(Bundle.main.executablePath)
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&input) == 0 && Sys.pipeClosedOnExec(&output) == 0)
        var spawn = Platform.Spawn(executable: binary, arguments: [binary])
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(variable)=1"]
        spawn.stdin = .descriptor(input[0])
        spawn.stdout = .descriptor(output[1])
        spawn.keep = []
        let started = spawn.start()
        Sys.close(input[0])
        Sys.close(output[1])
        defer { Sys.close(output[0]) }
        guard case .success(let pid) = started else {
            Sys.close(input[1])
            throw CancellationError()
        }
        var said: [UInt8] = []
        var byte: UInt8 = 0
        while said.last != UInt8(ascii: "\n") {
            let count = read(output[0], &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { break }
            said.append(byte)
        }
        return (pid, input[1], String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Ends a helper `start` gave, and reaps it.
    static func end(_ helper: (pid: pid_t, stdin: Int32, said: String)) {
        Sys.close(helper.stdin)
        var status: Int32 = 0
        while waitpid(helper.pid, &status, 0) < 0, errno == EINTR {}
    }
}

// Runs as the test bundle loads, as the home guard does (TestSupport.swift).
#if os(Linux)
@_used @_section(".init_array")
private let serveAsAHardenedProcess: @convention(c) () -> Void = { HardenedHelper.serveIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let serveAsAHardenedProcess: @convention(c) () -> Void = { HardenedHelper.serveIfAsked() }
#endif

/// The host hardened from its first statement, the user's lock told by its identity, the test-only flags, and who an
/// unreadable process is (the stage 2 plan's Task 9a; S2-D5; the security architecture document's S6 and S8). Every
/// hardened process is a scratch host or a helper, never this test process.
///
/// Serialized: one test sets `UnreadableProcesses.isOurs` in this process, and one holds a sealed copy of this binary.
@Suite(hostTestLimit, .serialized) struct HostHardeningTests {
    /// `open("/proc/<pid>/mem")` by this process: 0 when it opened, else its errno.
    static func openMemory(of pid: pid_t) -> Int32 {
        let fd = open("/proc/\(pid)/mem", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        Sys.close(fd)
        return 0
    }

    /// A scratch folder holding a home whose VibeSwitcher folder exists: its user's lock is `<home>/.vibeswitcher/host.lock`.
    static func home() throws -> (dir: String, root: String, usersLock: String) {
        let dir = "\(shortScratchRoot)/vshh-\(UUID().uuidString.prefix(8))"
        let root = dir + "/home/.vibeswitcher"
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        return (dir, root, root + "/host.lock")
    }

    // MARK: The user's lock, by its identity

    /// The user's lock however its path is spelled (`//`, `/./`, `..`) is the user's lock; a symbolic link to it is
    /// refused as a lock; a host that took itself for a scratch host may not hold the user's lock, the user's host may.
    /// A host started on a second spelling of its home's lock is that home's user's host (it refuses a test-only flag);
    /// one started on a link to it doesn't start.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's lock by identity; the Mac compares the paths"))
    func aSecondSpellingOfTheUsersLockIsTheUsersLock() async throws {
        let (dir, root, usersLock) = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for spelling in [usersLock, root + "//host.lock", root + "/./host.lock", root + "/sub/../host.lock"] {
            #expect(HostHardening.lock(spelling, usersLock: usersLock) == .users, "\(spelling)")
        }
        #expect(symlink(usersLock, dir + "/link.lock") == 0)
        #expect(HostHardening.lock(dir + "/link.lock", usersLock: usersLock) == .link)

        let held = open(usersLock, O_RDWR | O_CLOEXEC)
        try #require(held >= 0)
        defer { Sys.close(held) }
        #expect(HostHardening.heldLockIsAllowed(ownsLaunchers: false, usersLock: usersLock)?(held) == false)
        #expect(HostHardening.heldLockIsAllowed(ownsLaunchers: true, usersLock: usersLock)?(held) == true)

        // As processes: `//` makes the user's host, a link no host.
        func host(lock: String, extra: [String]) throws -> (Process, String) {
            let output = dir + "/out-\(UUID().uuidString.prefix(6))"
            FileManager.default.createFile(atPath: output, contents: nil)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: hostLauncher)
            process.arguments = ["--socket", dir + "/h-\(UUID().uuidString.prefix(6)).sock", "--lock", lock, "--idle-exit", "600",
                                 "--log", dir + "/session.log"] + extra
            process.environment = ["HOME": dir + "/home", "CFFIXED_USER_HOME": dir + "/home", "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin",
                                   "TMPDIR": dir + "/"]
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
            process.standardOutput = handle
            process.standardError = handle
            process.standardInput = FileHandle.nullDevice
            try TestHosts.run(process)
            return (process, output)
        }
        func said(_ output: String) -> String { (try? String(contentsOfFile: output, encoding: .utf8)) ?? "" }

        let (linked, linkedSaid) = try host(lock: dir + "/link.lock", extra: [])
        #expect(await eventually { !linked.isRunning }, "\(said(linkedSaid))")
        #expect(linked.terminationStatus == 1)
        #expect(said(linkedSaid).contains("not started: the lock \(dir)/link.lock is a symbolic link"), "\(said(linkedSaid))")
        TestHosts.end(linked)

        let (spelled, spelledSaid) = try host(lock: root + "//host.lock", extra: ["--handover-test-secret", "s"])
        defer { TestHosts.end(spelled) }
        #expect(await eventually { said(spelledSaid).contains("started") }, "\(said(spelledSaid))")
        #expect(said(spelledSaid).contains("refused test-only flags (the user's host takes none): --handover-test-secret"),
                "\(said(spelledSaid))")
    }

    /// A lock of its own, made or found, is a scratch host's; its held lock is allowed.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's lock by identity; the Mac compares the paths"))
    func aScratchLockIsNotTheUsers() throws {
        let (dir, _, usersLock) = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: usersLock, contents: nil)
        let scratch = dir + "/h.lock"
        #expect(HostHardening.lock(scratch, usersLock: usersLock) == .scratch)
        #expect(FileManager.default.fileExists(atPath: scratch), "made as the host makes it")
        #expect(HostHardening.lock(scratch, usersLock: usersLock) == .scratch)
        // The user's lock not made yet: a scratch lock is still not it.
        try FileManager.default.removeItem(atPath: usersLock)
        #expect(HostHardening.lock(scratch, usersLock: usersLock) == .scratch)
        let held = open(scratch, O_RDWR | O_CLOEXEC)
        try #require(held >= 0)
        defer { Sys.close(held) }
        #expect(HostHardening.heldLockIsAllowed(ownsLaunchers: false, usersLock: usersLock)?(held) == true)
        // The user's host holding a scratch lock (its path changed after it decided): not allowed.
        FileManager.default.createFile(atPath: usersLock, contents: nil)
        #expect(HostHardening.heldLockIsAllowed(ownsLaunchers: true, usersLock: usersLock)?(held) == false)
    }

    /// A lock that can't be opened (no right to it) fails closed: the user's lock, by its entry or its spelling, is
    /// still the user's (the more restricted host); another is a scratch lock.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable && geteuid() != 0, "Linux's lock by identity; root opens any file"))
    func aLockThatCantBeOpenedIsStillTheUsers() throws {
        let (dir, root, usersLock) = try Self.home()
        defer {
            chmod(usersLock, 0o600)
            try? FileManager.default.removeItem(atPath: dir)
        }
        FileManager.default.createFile(atPath: usersLock, contents: nil)
        let scratch = dir + "/h.lock"
        FileManager.default.createFile(atPath: scratch, contents: nil)
        try #require(chmod(usersLock, 0) == 0 && chmod(scratch, 0) == 0)
        try #require(open(usersLock, O_RDWR | O_CLOEXEC) < 0 && errno == EACCES)
        #expect(HostHardening.lock(usersLock, usersLock: usersLock) == .users)
        #expect(HostHardening.lock(root + "//host.lock", usersLock: usersLock) == .users)
        #expect(HostHardening.lock(root + "/sub/../host.lock", usersLock: usersLock) == .users)
        #expect(HostHardening.lock(scratch, usersLock: usersLock) == .scratch)
        chmod(scratch, 0o600)
    }

    /// A host's held lock decides, both ways, through `HostServer.Config.heldLockIsAllowed`: a host that took itself for
    /// the user's but holds another lock, and one that took itself for a scratch host but holds the user's, don't
    /// start (the lock released, no socket bound); the two that match do.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's lock by identity; the Mac asks nothing"))
    func aHostStartsOnlyOnTheLockItTookItselfFor() throws {
        let (dir, _, usersLock) = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: usersLock, contents: nil)
        let scratch = dir + "/h.lock"
        for (lock, ownsLaunchers, starts) in [(scratch, true, false), (usersLock, false, false), (usersLock, true, true), (scratch, false, true)] {
            let socket = scratchSocketPath()
            defer { unlink(socket) }
            let server = HostServer(config: Self.config(socket: socket, lock: lock,
                                                        heldLockIsAllowed: HostHardening.heldLockIsAllowed(ownsLaunchers: ownsLaunchers, usersLock: usersLock)))
            if starts {
                #expect(throws: Never.self, "\(lock) \(ownsLaunchers)") { try server.start() }
                server.stop(terminateSessions: true)
            } else {
                #expect(throws: HostServer.Failure.lock(EPERM), "\(lock) \(ownsLaunchers)") { try server.start() }
                Self.expectNotHeld(lock, socket: socket, server: server)
            }
        }
    }

    /// A host whose held lock isn't allowed doesn't start: `start()` throws, the lock released and no socket bound;
    /// `start(restoring:)` throws, having taken neither inherited descriptor. Either platform: the Mac's host sets no
    /// check, but the server asks one it is given.
    @Test func aHeldLockNotAllowedRefusesTheStart() throws {
        let socket = scratchSocketPath()
        let lock = socket + ".lock"
        defer { unlink(socket); unlink(lock) }
        let config = Self.config(socket: socket, lock: lock, heldLockIsAllowed: { _ in false })
        let server = HostServer(config: config)
        #expect(throws: HostServer.Failure.lock(EPERM)) { try server.start() }
        Self.expectNotHeld(lock, socket: socket, server: server)

        let lockFD = open(lock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        defer { Sys.close(lockFD) }
        let listenFD = try UnixSocket.listen(path: socket)
        defer { Sys.close(listenFD) }
        let restored = HostServer(config: config)
        #expect(throws: (any Error).self) {
            _ = try restored.start(restoring: HostHandover.State(fromBuild: 41, startedAt: Date(), lockFD: lockFD, listenFD: listenFD,
                                                                 secretFD: nil, sessions: []))
        }
        #expect(restored.listenFD == -1 && restored.acceptSource == nil)
        #expect(HostHandover.isOpen(lockFD) && HostHandover.isOpen(listenFD))
    }

    /// A scratch host's config on `socket` and `lock`, its held lock asked of `heldLockIsAllowed`.
    static func config(socket: String, lock: String, heldLockIsAllowed: ((Int32) -> Bool)?) -> HostServer.Config {
        var config = HostServer.Config(socketPath: socket, lockPath: lock, shell: "/bin/sh", launcher: hostLauncher,
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], hostBuild: 42)
        config.idleExit = nil
        config.heldLockIsAllowed = heldLockIsAllowed
        return config
    }

    /// After a refused `start()`: `lock` free for another to take at once, nothing listening at `socket`.
    static func expectNotHeld(_ lock: String, socket: String, server: HostServer, sourceLocation: SourceLocation = #_sourceLocation) {
        let other = open(lock, O_RDWR | O_CLOEXEC)
        #expect(other >= 0, sourceLocation: sourceLocation)
        #expect(flock(other, LOCK_EX | LOCK_NB) == 0, "the lock is still held", sourceLocation: sourceLocation)
        Sys.close(other)
        #expect(server.listenFD == -1 && server.acceptSource == nil, sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: socket), "a socket was bound", sourceLocation: sourceLocation)
    }

    /// A host refused at its start doesn't start unless it is a new image of a handover given its state (which goes
    /// back instead): a `--handover` with nothing after it is no handover. Nothing refused, it goes on.
    @Test func aRefusedHostStartsOnlyAsAHandoverWithItsState() {
        let refused = HostHardening.Start.refused("traced by pid 9")
        #expect(HostHardening.refusal(refused, arguments: ["host"]) == "traced by pid 9")
        #expect(HostHardening.refusal(refused, arguments: ["host", "--lock", "l", "--handover"]) == "traced by pid 9")
        #expect(HostHardening.refusal(refused, arguments: ["host", "--handover-fallback", "f"]) == "traced by pid 9")
        #expect(HostHardening.refusal(refused, arguments: ["host", "--handover", "/s/host.lock.handover"]) == nil)
        #expect(HostHardening.handover(in: ["host", "--handover", "/s/host.lock.handover"]) == "/s/host.lock.handover")
        #expect(HostHardening.handover(in: ["host", "--handover"]) == nil)
        for start in [HostHardening.Start.hardened, .nothing] {
            #expect(HostHardening.refusal(start, arguments: ["host"]) == nil)
            #expect(HostHardening.refusal(start, arguments: ["host", "--handover"]) == nil)
        }
    }

    /// The Mac keeps today's rules: the lock's path compared as a string, every test-only flag taken by any host and
    /// carried across a handover (so the user's host there still hands a test secret over, as at `47636aaf`), nothing
    /// hardened, no lock checked.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's forms; Linux's are tested above"))
    func theMacsUsersHostKeepsTodaysTestSecret() throws {
        #expect(HostHardening.lock("/a/b/host.lock", usersLock: "/a/b/host.lock") == .users)
        #expect(HostHardening.lock("/a/b//host.lock", usersLock: "/a/b/host.lock") == .scratch)
        #expect(HostHardening.heldLockIsAllowed(ownsLaunchers: false, usersLock: "/a/b/host.lock") == nil)
        #expect(HostHardening.takesTestFlags(ownsLaunchers: true))
        let arguments = ["--log", "l", "--handover-test-secret", "x", "--parser-test-hooks"]
        #expect(HostHardening.withoutTestFlags(arguments) == arguments)
        #expect(HostHardening.refused(in: arguments, ownsLaunchers: true).isEmpty)
        #expect(HostHardening.atStart(mode: .parser) == .nothing)
    }

    /// On Linux the user's host refuses every test-only flag, a scratch host takes them; what a build either hands over
    /// to is started with keeps only those a scratch host carries.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's rules; the Mac's are today's"))
    func theTestFlagsAreAScratchHostsAndNotCarried() {
        let arguments = ["--log", "l", "--handover-test-secret", "x", "--handover-test-secret-file", "f", "--handover-test-traced",
                         "--install-root", "r", "--parser-test-hooks", "--server-arg", "a", "--hold-first-look",
                         "--test-user-seal-life", "9", HostHardening.staysDumpableFlag, "--idle-exit", "600"]
        #expect(!HostHardening.takesTestFlags(ownsLaunchers: true))
        #expect(HostHardening.takesTestFlags(ownsLaunchers: false))
        #expect(HostHardening.refused(in: arguments, ownsLaunchers: false).isEmpty)
        #expect(HostHardening.refused(in: arguments + ["--handover-test-traced"], ownsLaunchers: true)
                == ["--handover-test-secret", "--handover-test-secret-file", "--handover-test-traced", "--install-root", "--parser-test-hooks",
                    "--server-arg", "--hold-first-look", "--test-user-seal-life", HostHardening.staysDumpableFlag])
        #expect(HostHardening.withoutTestFlags(arguments)
                == ["--log", "l", "--server-arg", "a", "--hold-first-look", "--test-user-seal-life", "9", "--idle-exit", "600"])
    }

    // MARK: Hardened at start

    /// A scratch host's memory is closed to this process from its start, and again after a handover to the same build
    /// (the new image hardens at its own start). The parsers it starts are too; the session's program isn't.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's hardening; the Mac's does nothing"))
    func theHostIsNotDumpableAfterStartAndAfterAHandover() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        #expect(Self.openMemory(of: host.pid) == EACCES)
        #expect(Platform.Processes.isDumpable(host.pid) == false)
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("printf 'up\\n'; exec sleep 600")
        #expect(await eventually { client.screen(session.id)?.contains("up") == true })
        let seq = client.send(.handover(executable: host.newBinary))
        #expect(await eventually { client.reply(to: seq) != nil })
        #expect(client.reply(to: seq) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("took over 1 sessions") }, "\(host.log)")
        #expect(Self.openMemory(of: host.pid) == EACCES)
        #expect(Platform.Processes.isDumpable(host.pid) == false)
        kill(session.childPID, SIGKILL)
    }

    /// A session's program is dumpable as any program is (the launcher doesn't harden, and execs it from a file it
    /// can read).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's hardening; the Mac's does nothing"))
    func aSessionsProgramIsDumpableAsUsual() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("printf 'up\\n'; exec sleep 600")
        defer { kill(session.childPID, SIGKILL) }
        #expect(await eventually { client.screen(session.id)?.contains("up") == true })
        #expect(Platform.Processes.isDumpable(session.childPID) == true)
        #expect(Self.openMemory(of: session.childPID) == 0)
    }

    /// A session's parser hardens at its start: it holds the session's screen.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's hardening; the Mac's does nothing"))
    func aParserIsNotDumpable() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("printf 'up\\n'; exec sleep 600")
        defer { kill(session.childPID, SIGKILL) }
        #expect(await eventually { client.screen(session.id)?.contains("up") == true })
        #expect(await eventually { !OrphanSweepTests.parsers(of: host.pid).isEmpty })
        for parser in OrphanSweepTests.parsers(of: host.pid) {
            #expect(Platform.Processes.isDumpable(parser) == false, "parser \(parser)")
            #expect(Self.openMemory(of: parser) == EACCES, "parser \(parser)")
        }
    }

    // MARK: Who an unreadable process is

    /// A hardened scratch host is still running to every reader in this process, never gone: its record, `SessionStrays`'
    /// running check, `UnreadableProcesses` (unknown here); its program and folder unknown, so the orphan sweep leaves
    /// it alone. The host's own `isOurs` (its token recorded, as its start records it) names it the host.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's hardening; the Mac's does nothing"))
    func anUnreadableHostIsTheHostNeverGone() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        try Self.expectUnknownStillRunning(host.pid)
        let token = try #require(Platform.Processes.token(host.pid))
        defer { HostHardening.forget() }
        HostHardening.recordOwn(token)
        UnreadableProcesses.isOurs = { HostHardening.isOurs($0) }
        #expect(HostHardening.isOurs(token))
        #expect(UnreadableProcesses.reading(host.pid) == .ours)
        // Any other process is not the host: this one, for one.
        #expect(!HostHardening.isOurs(try #require(Platform.Processes.token(getpid()))))
    }

    /// A helper that hardens itself (any process may) is "unknown, still running" to every reader, never the host, even
    /// in a process whose `isOurs` names a host.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's hardening; the Mac's does nothing"))
    func anotherHardenedProcessIsNotTakenForTheHost() async throws {
        let helper = try HardenedHelper.start()
        defer { HardenedHelper.end(helper) }
        #expect(helper.said == "hardened true")
        #expect(Self.openMemory(of: helper.pid) == EACCES)
        try Self.expectUnknownStillRunning(helper.pid)
        defer { HostHardening.forget() }
        HostHardening.recordOwn(Platform.Processes.token(getpid()))
        UnreadableProcesses.isOurs = { HostHardening.isOurs($0) }
        let token = try #require(Platform.Processes.token(helper.pid))
        #expect(!HostHardening.isOurs(token))
        #expect(UnreadableProcesses.reading(helper.pid) == .unknown)
        // Spared by no session's kill as the host's would be: it carries no session, and isn't ours.
        let found = try #require(Self.found(helper.pid))
        #expect(SessionStrays.of(session: UUID(), started: [found]).map(\.pid) == [helper.pid])
    }

    /// What each reader in this process makes of `pid`, a hardened process that runs: still running, its program,
    /// folder and environment unknown.
    static func expectUnknownStillRunning(_ pid: pid_t, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(Platform.Processes.isDumpable(pid) == false, sourceLocation: sourceLocation)
        #expect(ProcessTable.info(pid: pid) != nil, sourceLocation: sourceLocation)
        let found = try #require(found(pid), sourceLocation: sourceLocation)
        #expect(SessionStrays.isRunning(found), sourceLocation: sourceLocation)
        #expect(ProcessTable.cwd(pid: pid) == nil && ProcessTable.environment(pid: pid) == nil, sourceLocation: sourceLocation)
        #expect(HostServer.executable(of: pid) == nil, sourceLocation: sourceLocation)
        #expect(!HostProcesses.isOrphan(parent: 1, uid: geteuid(), running: "/any", parents: [1]) { HostServer.executable(of: pid) },
                sourceLocation: sourceLocation)
        #expect(UnreadableProcesses.reading(pid) == .unknown, sourceLocation: sourceLocation)
    }

    /// `pid` as `SessionStrays` finds a process: its group and start.
    static func found(_ pid: pid_t) -> SessionStrays.Found? {
        guard case .record(let record) = Platform.Processes.record(pid) else { return nil }
        return SessionStrays.Found(pid: pid, group: record.pgid,
                                   start: UInt64(record.start.tv_sec) * 1_000_000 + UInt64(record.start.tv_usec))
    }

    // MARK: Nothing secret in the open

    /// The host's arguments, which anyone reads (`cmdline` stays readable when it is hardened), carry no test secret
    /// after a handover and no app key at all, and the secret is in none of what it said; its environment is what it
    /// was started with.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child and test flags"))
    func nothingSecretIsInTheHostsArgumentsOrEnvironment() async throws {
        let secret = "secret-\(UUID().uuidString)"
        let host = try await ServerChildHost(actions: ["call census"], extra: ["--handover-test-secret", secret])
        defer { host.stop() }
        let given = try #require(host.process.arguments)
        let helper = try #require(await host.firstHelper(), "\(host.said)")
        #expect(await eventually { host.lines(of: helper).contains("census ok") }, "\(host.results)\n\(host.said)")
        // Before the handover: what the test gave it, and nothing more.
        #expect(Array(Platform.Processes.arguments(host.pid).dropFirst()) == given)
        try host.append(["handover \(hostLauncher)"])
        #expect(await eventually { host.lines(of: helper).contains { $0.hasPrefix("handover") } }, "\(host.results)\n\(host.said)")
        #expect(await eventually { host.said.contains("took over") }, "\(host.said)")
        let after = Platform.Processes.arguments(host.pid)
        #expect(!after.isEmpty)
        #expect(!after.contains(secret) && !after.contains("--handover-test-secret"), "\(after)")
        #expect(!after.contains(HostStart.appKeyFlag) && !after.contains(AppProof.hostStdinFlag), "\(after)")
        #expect(!host.said.contains(secret) && !host.noted.contains(secret))
        #expect(host.process.environment?.values.contains { $0.contains(secret) } == false)
        // The new image hardened at its own start.
        #expect(Self.openMemory(of: host.pid) == EACCES)
    }

    /// A host in a scratch home with no `--lock` is that home's user's host: given every test-only flag that touches a
    /// secret or the app, it hands over its real vault (not the test secret's bytes), takes no install root, reports no
    /// tracer and opens no test connector; its log names each flag refused, and none is in the arguments it hands over
    /// with. Its app is the server helper, which asks for the handover (nothing in the test can be the app: the host
    /// refuses `--test-app-pid`).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's rules; the Mac's user's host keeps today's"))
    func theUsersHostIgnoresTestSecretFlags() async throws {
        let secret = String(repeating: "s", count: 1000)
        let flags = ["--handover-test-secret", "--handover-test-secret-file", "--install-root", "--handover-test-traced", TestAppPrincipal.pidFlag]
        let host = try await ServerChildHost(actions: ["call census", "handover \(hostLauncher)"],
                                             extra: ["--handover-test-secret", secret, "--handover-test-secret-file", "/nonexistent/secret",
                                                     "--install-root", "/nonexistent/root", "--handover-test-traced",
                                                     TestAppPrincipal.pidFlag, String(getpid())],
                                             usersHost: true)
        defer { host.stop() }
        let helper = try #require(await host.firstHelper(), "\(host.said)")
        #expect(await eventually { host.lines(of: helper).count >= 3 }, "\(host.results)\n\(host.said)")
        #expect(Array(host.lines(of: helper).dropFirst()) == ["census ok", "handover ok"], "\(host.results)\n\(host.said)")
        #expect(await eventually { host.said.contains("took over") }, "\(host.said)")
        let refused = "refused test-only flags (the user's host takes none): " + flags.joined(separator: ", ")
        #expect(host.said.contains(refused), "\(host.said)")
        #expect(host.noted.contains(refused), "\(host.noted)")
        #expect(host.said.contains("refused \(TestAppPrincipal.pidFlag)"), "\(host.said)")
        #expect(!host.said.contains("test stand-in for the app: connector"), "\(host.said)")
        #expect(!host.said.contains("test secret carried"), "\(host.said)")
        #expect(host.said.contains("bytes of secrets") && !host.said.contains("and \(secret.utf8.count) bytes of secrets"), "\(host.said)")
        #expect(!host.said.contains("traced by") && !host.said.contains("/nonexistent/root"), "\(host.said)")
        let after = Platform.Processes.arguments(host.pid)
        #expect(!after.isEmpty)
        for flag in flags { #expect(!after.contains(flag), "\(flag) in \(after)") }
        #expect(!after.contains(secret))
    }
}

// MARK: Task 9c: a traced new image

extension HostHardeningTests {
    /// A new image after a handover that finds itself traced (a scratch host's `--handover-test-traced`, which the new
    /// build is given) goes back without reading the secrets: the build before, back through its sealed copy, reads them
    /// and serves on with its own vault (a lead grant issued before is still bound to its session).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's hardening and sealed memory; the Mac's does nothing"))
    func aTracedNewImageGoesBackWithoutTheVault() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (app, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let bound = try await BoundGrant(app)
        defer { kill(bound.session.childPID, SIGKILL) }
        #expect(await host.handOver(to: host.failingBuild("--handover-test-traced"), through: app) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("took over 1 sessions") }, "\(host.log)")
        let log = host.log
        #expect(log.contains("couldn't take over: traced by pid") && log.contains("(--handover-test-traced)"), "\(log)")
        #expect(log.contains("going back to /proc/self/fd/"), "\(log)")
        // The traced image said nothing of secrets: the only image that took them is the one back.
        let traced = try #require(log.range(of: "couldn't take over: traced by pid"))
        let back = try #require(log.range(of: "took over 1 sessions"))
        #expect(!log[traced.upperBound..<back.lowerBound].contains("bytes of secrets"), "\(log)")
        #expect(log[back.lowerBound...].contains("bytes of secrets"), "\(log)")
        let (again, _, build, _, _, pid, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(build == host.oldBuild && pid == host.pid)
        #expect(bound.isBound(in: again), "\(log)")
    }
}

// MARK: Task 9b: the host's own sealed copy, its launcher and parsers, --node

/// The host runs its sessions' launchers and parsers from its own sealed copy, which no program of a session holds; a
/// session's program is the OOM killer's first pick; `--node` and the account's own lock; the build's folders (the
/// stage 2 plan's Task 9b, S2-D5, S2-D7; the security architecture document's S6 and S9).
extension HostHardeningTests {
    /// A scratch host started (as a handover's exec will start one, Task 9c) from a sealed copy of a build's file, so
    /// that no process runs the file and it can be rewritten in place, with `--image-path` naming the file. After the
    /// rewrite, a session it starts still runs this build: its launcher is the host's own copy, not the file, and no
    /// launcher copy was written under the scratch home's `host/`.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's sealed copies; the Mac keeps its launcher copies"))
    func aSessionStartedAfterTheHostsFileWasReplacedRunsThisBuild() async throws {
        let dir = "\(shortScratchRoot)/vshi-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/home", socket = dir + "/h.sock", image = dir + "/build/vibeswitcher-host", output = dir + "/host.out"
        for folder in [home, dir + "/build"] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        try FileManager.default.copyItem(atPath: hostLauncher, toPath: image)
        let copy = try Platform.ProcessSelf.sealedCopy(of: image, name: "vibeswitcher-host").get()
        defer { Sys.close(copy.fd) }
        // This process is the host's app through a connector, as `TestHosts.connectAsApp` makes one.
        let (hostEnd, testEnd) = try #require(Platform.Sockets.pair(type: Platform.Sockets.seqpacket))
        Platform.Sockets.enableCredentials(hostEnd)
        HostConnection.register(connector: testEnd, for: socket)
        defer {
            HostConnection.unregister(path: socket)
            Sys.close(testEnd)
        }
        let said = open(output, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
        try #require(said >= 0)
        var spawn = Platform.Spawn(executable: copy.path,
                                   arguments: [image, "--socket", socket, "--lock", dir + "/h.lock", "--idle-exit", "600", "--log", dir + "/session.log",
                                               "--image-path", image, "--exit-with", String(getpid()),
                                               TestAppPrincipal.pidFlag, String(getpid()), TestAppPrincipal.connectorFlag, "0"])
        spawn.environment = ["HOME=\(home)", "CFFIXED_USER_HOME=\(home)", "SHELL=/bin/sh", "PATH=/usr/bin:/bin", "TMPDIR=\(dir)/",
                             "\(Platform.ProcessSelf.imageVariable)=\(copy.fd)"]
        spawn.stdin = .descriptor(hostEnd)
        spawn.stdout = .descriptor(said)
        spawn.stderr = .descriptor(said)
        spawn.keep = [copy.fd]
        spawn.group = .ownGroup
        let started = spawn.start()
        Sys.close(hostEnd)
        Sys.close(said)
        let host = try started.get()
        defer { Self.end(host) }
        func log() -> String { (try? String(contentsOfFile: output, encoding: .utf8)) ?? "" }
        _ = await eventually { log().contains("vibeswitcher-host: started") || log().contains("not started") }
        try #require(log().contains("vibeswitcher-host: started"), "\(log())")

        // Rewritten in place with another program: no process runs the file, so no ETXTBSY.
        let file = open(image, O_WRONLY | O_TRUNC | O_CLOEXEC)
        try #require(file >= 0, "errno \(errno)")
        let other = Array("#!/bin/sh\necho replaced-build\n".utf8)
        #expect(write(file, other, other.count) == other.count)
        Sys.close(file)

        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(socket, appKey: SymmetricKey(size: .bits256))
        let session = try await client.spawn("printf 'this-build\\n'; exec sleep 600")
        defer { kill(session.childPID, SIGKILL) }
        #expect(await eventually { client.screen(session.id)?.contains("this-build") == true }, "\(client.screen(session.id) ?? "")\n\(log())")
        #expect(client.screen(session.id)?.contains("replaced-build") == false)
        let launchers = (try? FileManager.default.contentsOfDirectory(atPath: home + "/.vibeswitcher/host")) ?? []
        #expect(!launchers.contains { $0.hasPrefix("launcher-") }, "\(launchers)")
    }

    /// Ends a host this suite started itself (SIGTERM, then SIGKILL), and reaps it.
    static func end(_ pid: pid_t) {
        kill(pid, SIGTERM)
        var status: Int32 = 0
        if !eventuallyBlocking(timeout: 10, { waitpid(pid, &status, WNOHANG) == pid }) {
            kill(pid, SIGKILL)
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }
    }

    /// A session's program holds no copy of the host's image: no `memfd:` among its descriptors, and no
    /// `VIBESWITCHER_IMAGE_FD` in its environment (its launcher, started from the host's copy, closed it first).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's sealed copies; the Mac has none"))
    func aSessionsProgramHoldsNoImageDescriptor() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("""
            printf 'memfd=%s image=%s\\n' "$(ls -l /proc/self/fd | grep -c memfd)" "$(env | grep -c \(Platform.ProcessSelf.imageVariable))"; exec sleep 600
            """)
        defer { kill(session.childPID, SIGKILL) }
        #expect(await eventually { client.screen(session.id)?.contains("image=") == true }, "\(client.screen(session.id) ?? "")\n\(host.log)")
        #expect(client.screen(session.id)?.contains("memfd=0 image=0") == true, "\(client.screen(session.id) ?? "")")
        // Its parser was started from the copy too.
        #expect(await eventually { !OrphanSweepTests.parsers(of: host.pid).isEmpty })
        #expect(Platform.Processes.arguments(OrphanSweepTests.parsers(of: host.pid)[0]).first?.hasPrefix("/proc/self/fd/") == true)
    }

    /// A session's launcher makes itself dumpable before it execs the session's program, and while it is, any process
    /// of the user can `chmod` the image it runs through `/proc/<launcher>/exe` (the seals don't stop a `chmod`). That
    /// image is the launchers' own copy, never the one the host's parsers start from: the parsers' copy stays `0111`,
    /// so a parser started after it is still non-dumpable from its exec; and the host puts the launchers' copy back to
    /// `0111` before the next launcher starts from it. The launchers are held after `HostImages.beforeProgram`
    /// (`--launcher-test-hold`) until the test lets them go; the host is left dumpable (`--test-stays-dumpable`) so
    /// that the test can read its copy's mode. Without the launchers' own copy the `chmod` lands on the parsers' copy.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's sealed copies; the Mac has none"))
    func aLaunchersImageChangedFromOutsideNeverReachesTheParsers() async throws {
        let hold = "\(shortScratchRoot)/vshl-\(UUID().uuidString.prefix(8))"
        defer { unlink(hold) }
        let host = try await ScratchHostProcess(arguments: [HostImages.launcherTestHoldFlag, hold, HostHardening.staysDumpableFlag])
        defer { host.stop() }
        func mode(_ path: String) -> mode_t? {
            var info = stat()
            return stat(path, &info) == 0 ? info.st_mode & 0o7777 : nil
        }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let first = try await client.spawn("printf 'first-up\\n'; exec sleep 600")
        defer { kill(first.childPID, SIGKILL) }
        // Held after `beforeProgram`: dumpable, and still running the launcher's image.
        #expect(await eventually { Platform.Processes.isDumpable(first.childPID) == true }, "\(host.log)")
        let exe = "/proc/\(first.childPID)/exe"
        let image = (try? FileManager.default.destinationOfSymbolicLink(atPath: exe)) ?? ""
        try #require(image.contains("memfd:"), "\(image)")
        #expect(chmod(exe, 0o755) == 0, "errno \(errno)")
        #expect(mode(exe) == 0o755)

        // The parsers' copy, as the host holds it (a parser's first argument names its descriptor): still unreadable.
        #expect(await eventually { !OrphanSweepTests.parsers(of: host.pid).isEmpty })
        let parsersImage = try #require(Platform.Processes.arguments(OrphanSweepTests.parsers(of: host.pid)[0]).first)
        try #require(parsersImage.hasPrefix("/proc/self/fd/"), "\(parsersImage)")
        let held = "/proc/\(host.pid)/fd/" + parsersImage.dropFirst("/proc/self/fd/".count)
        #expect(mode(held) == 0o111, "\(held)")

        // The next launcher is started from a copy put back to `0111`, and its parser is out of reach.
        let second = try await client.spawn("printf 'second-up\\n'; exec sleep 600")
        defer { kill(second.childPID, SIGKILL) }
        #expect(await eventually { Platform.Processes.isDumpable(second.childPID) == true }, "\(host.log)")
        #expect(mode("/proc/\(second.childPID)/exe") == 0o111)
        #expect(await eventually { OrphanSweepTests.parsers(of: host.pid).count == 2 })
        for parser in OrphanSweepTests.parsers(of: host.pid) {
            #expect(Platform.Processes.isDumpable(parser) == false, "parser \(parser)")
            #expect(Self.openMemory(of: parser) == EACCES, "parser \(parser)")
        }
        #expect(mode(held) == 0o111, "\(held)")

        // Let go, both programs run.
        #expect(FileManager.default.createFile(atPath: hold, contents: nil))
        #expect(await eventually { client.screen(first.id)?.contains("first-up") == true }, "\(client.screen(first.id) ?? "")\n\(host.log)")
        #expect(await eventually { client.screen(second.id)?.contains("second-up") == true }, "\(client.screen(second.id) ?? "")")
    }

    /// A session's program's `oom_score_adj` is the host's plus 500 (at most 1000), so the OOM killer picks it before
    /// the host, and nothing about it is on the session's terminal: the launcher, non-dumpable from its exec, made
    /// itself dumpable again before it wrote its own (its /proc files root's otherwise: `EACCES`, said on the terminal).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's oom_score_adj; the Mac has none"))
    func aSessionsProgramIsTheOOMKillersFirstPick() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("printf 'oom=%s\\n' \"$(cat /proc/self/oom_score_adj)\"; exec sleep 600")
        defer { kill(session.childPID, SIGKILL) }
        #expect(await eventually { client.screen(session.id)?.contains("oom=") == true }, "\(client.screen(session.id) ?? "")\n\(host.log)")
        let hosts = try #require(Int((try String(contentsOfFile: "/proc/\(host.pid)/oom_score_adj", encoding: .utf8))
                                        .trimmingCharacters(in: .whitespacesAndNewlines)))
        let screen = client.screen(session.id) ?? ""
        #expect(screen.contains("oom=\(min(1000, hosts + HostImages.oomRaise))"), "\(screen)")
        #expect(!screen.contains("oom_score_adj"), "\(screen)")
        let program = try String(contentsOfFile: "/proc/\(session.childPID)/oom_score_adj", encoding: .utf8)
        #expect(Int(program.trimmingCharacters(in: .whitespacesAndNewlines)) == min(1000, hosts + HostImages.oomRaise))
    }

    /// The account's own lock (by the user database, here a scratch folder standing for it) is taken by the node's host
    /// and only by it, however it is spelled; a scratch home's lock isn't the account's, and the node's host takes none.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's --node; the Mac has none"))
    func aHostOnTheAccountsOwnHomeNeedsNode() throws {
        let (dir, root, accountLock) = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for spelling in [accountLock, root + "//host.lock", root + "/sub/../host.lock"] {
            #expect(HostImages.mayStart(lockPath: spelling, accountRoot: root, node: false)?.contains("is the account's own") == true, "\(spelling)")
            #expect(HostImages.mayStart(lockPath: spelling, accountRoot: root, node: true) == nil, "\(spelling)")
        }
        let scratch = dir + "/scratch-home/.vibeswitcher"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        #expect(HostImages.mayStart(lockPath: scratch + "/host.lock", accountRoot: root, node: false) == nil)
        #expect(HostImages.mayStart(lockPath: scratch + "/host.lock", accountRoot: root, node: true)?.contains("takes only the account's own lock") == true)
        #expect(symlink(accountLock, dir + "/link.lock") == 0)
        #expect(HostImages.mayStart(lockPath: dir + "/link.lock", accountRoot: root, node: false)?.contains("symbolic link") == true)
        #expect(HostImages.mayStart(lockPath: dir + "/link.lock", accountRoot: root, node: true)?.contains("symbolic link") == true)
    }

    /// The node's environment: `HOME` the account's, and neither `VIBESWITCHER_HOME` nor `CFFIXED_USER_HOME`, whatever
    /// it was given; the rest as given. No `--node` host is started in a test: it would be the user's, on their own
    /// `~/.vibeswitcher`.
    @Test func theNodesRootIsNeverFromTheEnvironment() {
        let given = ["HOME": "/scratch/home", "VIBESWITCHER_HOME": "/scratch/root", "CFFIXED_USER_HOME": "/scratch/fixed",
                     "PATH": "/usr/bin:/bin", "SHELL": "/bin/bash"]
        let node = HostImages.nodeEnvironment(given, accountHome: "/home/someone")
        #expect(node == ["HOME": "/home/someone", "PATH": "/usr/bin:/bin", "SHELL": "/bin/bash"])
        #expect(VibePaths.root(environment: node, fallbackHome: "/elsewhere").path == "/home/someone/.vibeswitcher")
        #expect(HostImages.accountHome == VibePaths.accountHome)
        // And --node is refused without its node root and its own server, before anything is changed.
        #expect(HostImages.startAsNode(arguments: ["host"]) == nil)
        if !Platform.CodeIdentity.isAvailable {
            #expect(HostImages.startAsNode(arguments: ["host", "--node"])?.contains("needs --node-root") == true)
            #expect(HostImages.startAsNode(arguments: ["host", "--node", "--node-root", "/nonexistent/build"])?.contains("needs --server") == true)
            #expect(HostImages.startAsNode(arguments: ["host", "--node", "--node-root", "/nonexistent/build", "--server", "/etc/passwd"])?
                .contains("isn't") == true)
        }
    }

    /// With `--node-root` and `--image-path` naming different folders, the build's files are the node root's: its
    /// `bin/vibeswitcher-host` (the build id's), `bin/vibeswitcher-mcp`, its command folder, its app; with
    /// `--image-path` alone, that image's folder's; with neither, the executable's, as before.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's --node-root; the Mac's folders are its executable's"))
    func theNodeTakesItsFoldersFromNodeRootNotItsExecutable() throws {
        let dir = "\(shortScratchRoot)/vshf-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let node = dir + "/node", other = dir + "/other"
        for root in [node, other] {
            try FileManager.default.createDirectory(atPath: root + "/bin", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: root + "/Resources/bin", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root + "/Resources/bin/" + TestLock.command, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        let folders = HostImages.folders(arguments: ["host", "--image-path", other + "/bin/vibeswitcher-host", "--node-root", node],
                                         executable: "/elsewhere/bin/vibeswitcher-host")
        #expect(folders.image == node + "/bin/vibeswitcher-host")
        #expect(folders.installFolder == node)
        #expect(folders.toolServer == node + "/bin/vibeswitcher-mcp")
        #expect(folders.commandFolder == node + "/Resources/bin")
        #expect(folders.appExecutable == node + "/bin/VibeSwitcher")

        let imaged = HostImages.folders(arguments: ["host", "--image-path", other + "/bin/vibeswitcher-host"], executable: "/elsewhere/bin/vibeswitcher-host")
        #expect(imaged.image == other + "/bin/vibeswitcher-host" && imaged.installFolder == other + "/bin")
        #expect(imaged.toolServer == other + "/bin/vibeswitcher-mcp" && imaged.commandFolder == other + "/Resources/bin")

        let plain = HostImages.folders(arguments: ["host"], executable: "/elsewhere/bin/vibeswitcher-host")
        #expect(plain.image == "/elsewhere/bin/vibeswitcher-host" && plain.installFolder == "/elsewhere/bin")
        #expect(plain.toolServer == "/elsewhere/bin/vibeswitcher-mcp" && plain.commandFolder == nil)
    }

    /// The node's host takes no `--server` but its build's own, `<node-root>/bin/vibeswitcher-server`, compared once
    /// both are resolved: a second spelling of it is it; another file, a symbolic link to it, a link in its place, or
    /// a server that isn't there is refused.
    @Test func theUsersHostTakesOnlyItsInstallsServer() throws {
        let dir = "\(shortScratchRoot)/vshs-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let node = dir + "/node"
        try FileManager.default.createDirectory(atPath: node + "/bin", withIntermediateDirectories: true)
        let own = node + "/bin/vibeswitcher-server"
        #expect(HostImages.serverRefusal(server: own, nodeRoot: node)?.contains("isn't there") == true)
        FileManager.default.createFile(atPath: own, contents: Data("server".utf8), attributes: [.posixPermissions: 0o755])
        #expect(HostImages.serverRefusal(server: own, nodeRoot: node) == nil)
        #expect(HostImages.serverRefusal(server: node + "//bin/./vibeswitcher-server", nodeRoot: node) == nil)
        #expect(HostImages.serverRefusal(server: own, nodeRoot: node + "/") == nil)
        let elsewhere = dir + "/vibeswitcher-server"
        FileManager.default.createFile(atPath: elsewhere, contents: Data("server".utf8), attributes: [.posixPermissions: 0o755])
        #expect(HostImages.serverRefusal(server: elsewhere, nodeRoot: node)?.contains("isn't the node's own") == true)
        #expect(symlink(own, dir + "/link") == 0)
        #expect(HostImages.serverRefusal(server: dir + "/link", nodeRoot: node)?.contains("symbolic link") == true)
        try FileManager.default.removeItem(atPath: own)
        #expect(symlink(elsewhere, own) == 0)
        #expect(HostImages.serverRefusal(server: own, nodeRoot: node)?.contains("symbolic link") == true)
    }
}
