import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A session's terminal is named as everything else names it (the stage 2 plan's Task 6a): `HostSession.tty` is the
/// name `ProcessTable` gives the program's controlling terminal (`Platform.Terminals.name`: "ttys003" on the Mac,
/// "ttypts3" on Linux), so a match by terminal (`session(of:)`'s fallback, the hook's state file, the steer inbox)
/// finds the session, and the state file sits directly in `state/`.
///
/// On Linux a session's terminal is its own from the start, and its program is matched by token (Task 6b, the security
/// architecture document's S4; see `SessionIdentityChecks`): a process that took the terminal first is no session's,
/// and its launcher exits 127 without running its program; a chain whose program has the pid of a session's but
/// another start, or whose ancestor started after its child, is no session's; and a program reaped is no session's
/// before the session's queue hears of it.
@Suite(hostTestLimit) struct HostedSessionTerminalTests {
    let temp = Scratch()

    /// A scratch host's session running `command`, once its program has its terminal as its own (the launcher makes
    /// it so before it execs): the session, and the name `ProcessTable` gives that terminal.
    private func session(of host: TestHost, running command: String) async throws -> (session: HostSession, tty: String) {
        let client = try TestClient(host)
        let session = try await client.spawn(command)
        #expect(await eventually { ProcessTable.info(pid: session.childPID)?.tty != nil })
        let tty = try #require(ProcessTable.info(pid: session.childPID)?.tty)
        return (session, tty)
    }

    @Test func aSessionsTerminalIsTheTablesName() async throws {
        let host = try TestHost()
        let (session, tty) = try await session(of: host, running: "sleep 30")
        #expect(session.tty == tty)
        if !Platform.CodeIdentity.isAvailable { #expect(session.tty.hasPrefix("ttypts")) }
    }

    /// A process on the session's terminal that isn't under its program (one that left it: a double fork, so its parent
    /// is whatever takes this process's orphans) is the session's by its terminal.
    @Test func aProcessOnTheSessionsTerminalIsThatSessions() async throws {
        let host = try TestHost()
        let pidFile = temp.url("orphan-pid").path
        let (session, tty) = try await session(of: host, running:
            "(sh -c 'echo $$ > \(pidFile).partial && mv \(pidFile).partial \(pidFile); exec sleep 30' &); \(keepRunning)")
        #expect(await eventually { FileManager.default.fileExists(atPath: pidFile) })
        let text = try String(contentsOfFile: pidFile, encoding: .utf8)
        let orphan = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(orphan, SIGKILL) }
        // Not under the program: only its terminal makes it the session's.
        #expect(await eventually { ProcessTable.ancestry(of: orphan).map { !$0.map(\.pid).contains(session.childPID) } == true })
        #expect(ProcessTable.info(pid: orphan)?.tty == tty)
        #expect(host.server.queue.sync { host.server.session(of: orphan) } == session.id.uuidString)
    }

    @Test func theHookStateFileOfASessionIsDirectlyInState() async throws {
        let host = try TestHost()
        let (session, _) = try await session(of: host, running: "sleep 30")
        let file = VibePaths.stateFile(tty: session.tty)
        #expect(file.deletingLastPathComponent().standardizedFileURL.path == VibePaths.stateDir.standardizedFileURL.path)
        #expect(file.lastPathComponent == session.tty + ".json")
    }

    // MARK: Linux: the terminal its own, the program by token (Task 6b)

    typealias Link = Platform.Processes.Link

    /// A pid no process has (past any `pid_max`): a fixture chain's process under a session's program.
    static let below: pid_t = .max - 1

    /// A table of links for `session(of:reading:)`: `below`, started `childTicks`, under `program`, read as started
    /// `programTicks`, whose parent is pid 1.
    static func table(program: Link, programTicks: UInt64, childTicks: UInt64) -> (pid_t) -> Link? {
        let links = [below: Link(pid: below, parent: program.pid, startTicks: childTicks, terminal: nil),
                     program.pid: Link(pid: program.pid, parent: 1, startTicks: programTicks, terminal: nil)]
        return { links[$0] }
    }

    /// A process in a session of its own that opens `device` without `O_NOCTTY`, so it becomes its controlling
    /// terminal if no session has it yet: its pid, once it has opened it.
    private func takeTerminal(_ device: String) async throws -> pid_t {
        let marker = temp.url("thief").path
        var thief = Platform.Spawn(executable: "/bin/sh", arguments: [
            "/bin/sh", "-c", "exec 3<>\(device) && echo $$ > \(marker).partial && mv \(marker).partial \(marker); exec \(keepRunning)"])
        thief.stdin = .path("/dev/null", flags: O_RDWR)
        thief.stdout = .sameAsStdin
        thief.stderr = .sameAsStdin
        thief.group = .ownSession
        guard case .success(let pid) = thief.start() else { throw CancellationError() }
        guard await eventually({ FileManager.default.fileExists(atPath: marker) }) else {
            end(pid)
            throw CancellationError()
        }
        return pid
    }

    /// Ends and reaps a child of this process.
    private func end(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        _ = eventuallyBlocking { waitpid(pid, &status, WNOHANG) != 0 }
    }

    /// An escaped worker (a process that left its session with `setsid`) opens a new session's terminal while the
    /// session's launcher is still starting (the launcher's test delay holds that window open): it is no session's,
    /// neither while the launcher waits nor after, and to the vault an unknown caller; the launcher finds the terminal
    /// another session's, says so on it and exits 127, its program never run.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's launcher check and live rule; the Mac's are unchanged"))
    func aProcessThatTookASessionsTerminalFirstIsNotThatSession() async throws {
        let host = try TestHost(launcherTestDelay: 5)
        let client = try TestClient(host)
        let ran = temp.url("ran").path
        let session = try await client.spawn("touch \(ran); \(keepRunning)")
        await client.attach(session.id)
        let device = "/dev/pts/" + session.tty.dropFirst("ttypts".count)
        let thief = try await takeTerminal(device)
        defer { end(thief) }
        // It holds the terminal as its own, while the launcher still waits.
        #expect(ProcessTable.info(pid: thief)?.tty == session.tty)
        #expect(client.latest(session.id)?.exit == nil)
        #expect(host.server.queue.sync { host.server.session(of: thief) } == nil)
        #expect(host.server.queue.sync { host.server.identify(Platform.Processes.token(thief)) } == .unknown)
        // The launcher, its wait over, can't take the terminal: the session ends 127, saying why (well within two
        // minutes of its 5 s wait; a launcher that ran the program instead never ends it).
        try #require(await eventually(timeout: 120) { client.latest(session.id)?.exit != nil })
        #expect(client.latest(session.id)?.exit?.status == 127)
        #expect(await eventually { client.text(session.id).contains("this session's terminal isn't its own") })
        #expect(!FileManager.default.fileExists(atPath: ran))
        #expect(host.server.queue.sync { host.server.session(of: thief) } == nil)
    }

    /// The launcher run on a terminal another session already controls exits 127 before it runs its program.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's launcher check; the Mac's launcher is unchanged"))
    func aLauncherThatCantTakeItsTerminalExits() async throws {
        guard case .success(let terminal) = Platform.Terminals.open(rows: 24, cols: 80) else {
            Issue.record("no pseudo-terminal")
            return
        }
        defer { Sys.close(terminal.master) }
        Sys.close(terminal.slave)
        let thief = try await takeTerminal(terminal.devicePath)
        defer { end(thief) }
        #expect(ProcessTable.info(pid: thief)?.tty == terminal.name)

        let ran = temp.url("ran").path
        var launch = Platform.Spawn(executable: hostLauncher, arguments: [hostLauncher, "--pty-exec", "/bin/sh", "-c", "touch \(ran)"])
        launch.stdin = .path(terminal.devicePath, flags: Platform.Terminals.launcherOpenFlags)
        launch.stdout = .sameAsStdin
        launch.stderr = .sameAsStdin
        launch.group = .ownSession
        guard case .success(let launcher) = launch.start() else {
            Issue.record("the launcher didn't start")
            return
        }
        var status: Int32 = 0
        #expect(await eventually { waitpid(launcher, &status, WNOHANG) == launcher })
        #expect(status & 0x7f == 0 && (status >> 8) & 0xff == 127)
        #expect(!FileManager.default.fileExists(atPath: ran))
    }

    /// A chain whose entry has a session program's pid but another start (the pid given again) is no session's; the
    /// same chain with the program's own start is the session's.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's tokens; the Mac matches by pid, as always"))
    func aReusedProgramPidIsNotTheSession() async throws {
        let host = try TestHost()
        let (session, _) = try await session(of: host, running: "sleep 30")
        let program = try #require(Platform.Processes.link(session.childPID))
        let itself = Self.table(program: program, programTicks: program.startTicks, childTicks: program.startTicks + 100)
        let reused = Self.table(program: program, programTicks: program.startTicks + 1, childTicks: program.startTicks + 100)
        #expect(host.server.queue.sync { host.server.session(of: Self.below, reading: itself) } == session.id.uuidString)
        #expect(host.server.queue.sync { host.server.session(of: Self.below, reading: reused) } == nil)
    }

    /// A chain where an ancestor started after its child (its number given again since) is no session's.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's chain check; the Mac's ancestry is unchanged"))
    func anAncestorYoungerThanItsChildBreaksTheChain() async throws {
        let host = try TestHost()
        let (session, _) = try await session(of: host, running: "sleep 30")
        let program = try #require(Platform.Processes.link(session.childPID))
        let older = Self.table(program: program, programTicks: program.startTicks, childTicks: program.startTicks + 100)
        let younger = Self.table(program: program, programTicks: program.startTicks, childTicks: program.startTicks - 1)
        #expect(host.server.queue.sync { host.server.session(of: Self.below, reading: older) } == session.id.uuidString)
        #expect(host.server.queue.sync { host.server.session(of: Self.below, reading: younger) } == nil)
    }

    /// A child found with another parent, or as another process, when it is read again after its parent breaks the
    /// chain: it was reparented between the two reads, so the parent read may be someone new.
    @Test func aChildReparentedWhileItsChainIsReadBreaksIt() {
        let parent = Link(pid: 500, parent: 1, startTicks: 10, terminal: nil)
        let child = Link(pid: 600, parent: 500, startTicks: 20, terminal: nil)
        #expect(SessionIdentityChecks.chain(of: 600, reading: { [500: parent, 600: child][$0] }) == [child, parent])
        var reads = 0
        let reparented = SessionIdentityChecks.chain(of: 600) { pid in
            guard pid == 600 else { return [500: parent][pid] }
            reads += 1
            return reads == 1 ? child : Link(pid: 600, parent: 1, startTicks: 20, terminal: nil)
        }
        #expect(reparented == nil)
        let another = SessionIdentityChecks.chain(of: 600) { pid in
            guard pid == 600 else { return [500: parent][pid] }
            reads += 1
            return reads == 3 ? child : Link(pid: 600, parent: 500, startTicks: 30, terminal: nil)
        }
        #expect(another == nil)
    }

    /// A program reaped by `HostedSession.reap(_:until:)` (on its own queue), its session's queue not having heard, is
    /// no session's program: asked while the host's queue is held, a chain through it is no session's. Held by
    /// `TIOCGSID` on the master (`SessionIdentityChecks.holdsIdentity`): the program led its session, and a session
    /// leader that exits leaves its terminal with no session.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's live rule; the Mac's is unchanged"))
    func aReapedSessionIsNotLive() async throws {
        let host = try TestHost()
        let (session, _) = try await session(of: host, running: "sleep 30")
        let program = try #require(Platform.Processes.link(session.childPID))
        let chain = Self.table(program: program, programTicks: program.startTicks, childTicks: program.startTicks + 100)
        #expect(host.server.queue.sync { host.server.session(of: Self.below, reading: chain) } == session.id.uuidString)
        let answer: String?? = await offPool {
            host.server.queue.sync {
                kill(program.pid, SIGKILL)
                // Reaped once its process has gone from the table (a zombie's link is still its own).
                let reaped = eventuallyBlocking {
                    HostedSession.reap([program.pid], until: .distantPast)
                    return Platform.Processes.link(program.pid)?.startTicks != program.startTicks
                }
                return reaped ? .some(host.server.session(of: Self.below, reading: chain)) : .none
            }
        }
        #expect(answer == .some(nil))
    }
}

