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
