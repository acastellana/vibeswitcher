import CryptoKit
import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import VibeCore
@testable import VibeHost

/// A real `vibeswitcher-host` process on a scratch home, socket and lock (a handover replaces the process's image, so it
/// can't run inside the test runner the way `TestHost` does). Two builds of it: copies of the built host with their
/// own modification times, which is what tells builds apart.
final class ScratchHostProcess {
    let dir: String
    let home: String
    let socket: String
    let lock: String
    let oldBinary: String
    let newBinary: String
    let oldBuild: Int
    let newBuild: Int
    /// The session log (see `HostLog`), the same file through every build.
    let sessionLog: String
    let process = Process()
    /// The app's key, as the app hands it to the host it starts.
    let appKey = SymmetricKey(size: .bits256)

    init(arguments extra: [String] = []) throws {
        // Short: a socket's path has a 104-byte limit.
        dir = "\(shortScratchRoot)/vsho-\(UUID().uuidString.prefix(8))"
        home = dir + "/home"
        socket = dir + "/h.sock"
        lock = dir + "/h.lock"
        oldBinary = dir + "/old/vibeswitcher-host"
        newBinary = dir + "/new/vibeswitcher-host"
        sessionLog = dir + "/session.log"
        let files = FileManager.default
        for folder in [home, dir + "/old", dir + "/new"] { try files.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        // APFS clones: no extra disk for the copies.
        try files.copyItem(atPath: hostLauncher, toPath: oldBinary)
        try files.copyItem(atPath: hostLauncher, toPath: newBinary)
        // The app beside each build is this test process's own binary (the same code, so the same cdhash): its
        // clients are the app once they answer the challenge with `appKey`, given to the host on stdin as the app does.
        let runner = try #require(HostServer.executable(of: getpid()))
        for folder in ["old", "new"] { try files.copyItem(atPath: runner, toPath: dir + "/\(folder)/VibeSwitcher") }
        let now = Date().timeIntervalSince1970.rounded(.down)
        try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - 2_000)], ofItemAtPath: oldBinary)
        try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - 1_000)], ofItemAtPath: newBinary)
        oldBuild = HostBuild.id(ofExecutableAt: oldBinary)
        newBuild = HostBuild.id(ofExecutableAt: newBinary)

        process.executableURL = URL(fileURLWithPath: oldBinary)
        process.arguments = ["--socket", socket, "--lock", lock, "--idle-exit", "600", "--log", sessionLog, AppProof.hostStdinFlag] + extra
        process.environment = ["HOME": home, "CFFIXED_USER_HOME": home, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin",
                               "TMPDIR": dir + "/"]
        files.createFile(atPath: dir + "/host.log", contents: nil)
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: dir + "/host.log"))
        process.standardOutput = log
        process.standardError = log
        let stdin = Pipe()
        stdin.fileHandleForWriting.write(appKey.data)
        try stdin.fileHandleForWriting.close()
        process.standardInput = stdin
        try TestHosts.run(process)
        #expect(eventually { (try? UnixSocket.connect(path: socket)).map { Darwin.close($0); return true } ?? false })
    }

    var pid: pid_t { process.processIdentifier }
    var log: String { (try? String(contentsOfFile: dir + "/host.log", encoding: .utf8)) ?? "" }

    /// The executable the host's process runs now.
    var runningExecutable: String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    /// A script standing in for a build: `body` is its shell code.
    func script(_ name: String, _ body: String) -> String {
        let path = dir + "/" + name
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n\(body)\n".utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    /// Ends the host (by its pid) and removes its files. Also when this goes, so a test that throws or fails before
    /// it stops its host (or never stops it) leaves none running.
    func stop() {
        TestHosts.end(process)
        try? FileManager.default.removeItem(atPath: dir)
    }

    deinit { stop() }
}

extension TestClient {
    /// Connects and waits for the welcome.
    static func welcomed(_ socket: String, appKey: SymmetricKey? = nil) throws -> (TestClient, protocolVersion: Int, build: Int, sessions: [HostSession], capabilities: [String]?,
                                                     pid: Int32?, startedAt: Date?) {
        var connected: TestClient?
        #expect(eventually { connected = try? TestClient(socket: socket, appKey: appKey); return connected != nil })
        guard let client = connected else { throw CancellationError() }
        let seq = client.send(.hello(protocolVersion: HostProtocol.version, app: "test"))
        #expect(eventually { client.reply(to: seq) != nil })
        guard case .welcome(let version, let build, let sessions, let capabilities, let pid, let startedAt) = client.reply(to: seq) else {
            throw CancellationError()
        }
        return (client, version, build, sessions, capabilities, pid, startedAt)
    }

    func exitStatus(_ id: UUID) -> Int32? {
        var status: Int32?
        with { client in
            for case .sessionChanged(let session) in client.allEvents where session.id == id { status = session.exit?.status ?? status }
        }
        return status
    }
}

/// The counter's numbers, in the order printed.
func counted(_ text: String) -> [Int] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
        guard let range = line.range(of: "n=") else { return nil }
        return Int(line[range.upperBound...].prefix { $0.isNumber })
    }
}

/// `true` when the numbers run 1, 2, 3… with none missing or repeated.
func isUnbroken(_ numbers: [Int]) -> Bool { !numbers.isEmpty && numbers == Array(1...numbers.count) }

/// The screen a view shows after attaching: the replay fed to a fresh terminal.
func viewScreen(_ replay: String, cols: Int = 80, rows: Int = 24) -> String {
    let terminal = Terminal(delegate: HeadlessDelegate(), options: TerminalOptions(cols: cols, rows: rows, scrollback: 5_000))
    terminal.feed(buffer: Array(replay.utf8)[...])
    return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
}

@Suite(.serialized) struct HostHandoverTests {
    static let counter = "i=0; while :; do i=$((i+1)); echo n=$i; sleep 0.1; done"
    /// A job in a process group of its own (job control), then a line read and a telling exit status.
    static let job = "set -m; \(keepRunning) & echo bg=$!; read line; echo got:$line; exit 7"
    /// A full-screen program's screen: drawn with cursor moves, then left as it is.
    static let painted = "printf '\\033[2J\\033[H\\033[5;10HBOX\\033[10;1Hstatus line'; \(keepRunning)"

    struct Scene {
        let host: ScratchHostProcess
        let client: TestClient
        let counter: HostSession, shell: HostSession, job: HostSession, painted: HostSession
        /// Ended before the handover.
        let done: HostSession
        let background: pid_t
        let startedAt: Date?

        var all: [HostSession] { [counter, shell, job, painted, done] }
        var live: [HostSession] { [counter, shell, job, painted] }
    }

    func scene(arguments: [String] = []) throws -> Scene {
        let host = try ScratchHostProcess(arguments: arguments)
        let (client, _, build, _, capabilities, pid, startedAt) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(build == host.oldBuild && pid == host.pid && startedAt != nil)
        #expect(capabilities?.contains(HostProtocol.Capability.handover) == true)
        let counter = try client.spawn(Self.counter)
        let shell = try client.spawn(nil)
        let job = try client.spawn(Self.job)
        let painted = try client.spawn(Self.painted)
        let done = try client.spawn("echo finished-early; exit 3")
        #expect(eventually { client.exitStatus(done.id) == 3 })
        #expect(eventually { counted(client.screen(counter.id) ?? "").last ?? 0 >= 5 })
        #expect(eventually { client.screen(shell.id)?.contains("$") == true })
        #expect(eventually { client.screen(job.id)?.contains("bg=") == true })
        #expect(eventually { client.screen(painted.id)?.contains("status line") == true })
        let line = client.screen(job.id)?.split(separator: "\n").first { $0.hasPrefix("bg=") }
        let background = pid_t(line.map { String($0.dropFirst(3)) } ?? "") ?? 0
        #expect(background > 0 && getpgid(background) == background && background != job.childPID)
        return Scene(host: host, client: client, counter: counter, shell: shell, job: job, painted: painted, done: done, background: background,
                     startedAt: startedAt)
    }

    func end(_ scene: Scene) {
        if scene.background > 0 { kill(scene.background, SIGKILL) }
        for session in scene.live where kill(session.childPID, 0) == 0 { kill(-session.childPID, SIGKILL) }
        scene.host.stop()
    }

    /// After a handover (or one that went back): the same process, every session as it was, the counter unbroken,
    /// input reaching each session, and a session ending with its real status.
    func expectCarriedOn(_ scene: Scene, build: Int, screens: [UUID: String], counterBefore: Int) throws {
        let (client, _, welcomeBuild, sessions, _, pid, startedAt) = try TestClient.welcomed(scene.host.socket, appKey: scene.host.appKey)
        #expect(welcomeBuild == build)
        // The same host: its process, started when it was.
        #expect(pid == scene.host.pid && startedAt == scene.startedAt)
        #expect(scene.host.process.isRunning)
        #expect(sessions.map(\.id) == scene.all.map(\.id))
        #expect(sessions.filter { $0.isLive }.map(\.id) == scene.live.map(\.id))
        #expect(sessions.first { $0.id == scene.done.id }?.exit?.status == 3)
        #expect(sessions.map(\.childPID) == scene.all.map(\.childPID))
        #expect(sessions.map(\.tty) == scene.all.map(\.tty))
        // The screens are rebuilt from what each session printed.
        for (id, before) in screens { #expect(client.screen(id) == before) }
        #expect(screens[scene.done.id]?.contains("finished-early") == true && screens[scene.painted.id]?.contains("BOX") == true)

        client.attach(scene.counter.id)
        #expect(eventually { counted(client.text(scene.counter.id)).last ?? 0 >= counterBefore + 15 })
        let numbers = counted(client.text(scene.counter.id))
        #expect(isUnbroken(numbers), "the counter's output after reattach: \(numbers)")
        #expect(numbers.count > counterBefore)

        // A view attaching sees the same last screen.
        client.attach(scene.painted.id)
        #expect(viewScreen(client.text(scene.painted.id)) == screens[scene.painted.id])

        client.attach(scene.shell.id)
        client.attach(scene.job.id)
        client.send(.input(id: scene.shell.id, bytes: Data("echo idle-$((6*7))\r".utf8), reply: false))
        client.send(.input(id: scene.counter.id, bytes: Data("typed-into-counter".utf8), reply: false))
        client.send(.input(id: scene.painted.id, bytes: Data("typed-into-painted".utf8), reply: false))
        client.send(.input(id: scene.job.id, bytes: Data("hello\r".utf8), reply: false))
        #expect(eventually { client.text(scene.shell.id).contains("idle-42") })
        #expect(eventually { client.text(scene.counter.id).contains("typed-into-counter") })
        #expect(eventually { client.text(scene.painted.id).contains("typed-into-painted") })
        #expect(eventually { client.text(scene.job.id).contains("got:hello") })
        // Reaped by the host (still its parent): the program's own status.
        #expect(eventually { client.exitStatus(scene.job.id) == 7 })
        // The job in its own process group carried on too.
        #expect(kill(scene.background, 0) == 0 && getpgid(scene.background) == scene.background)
        // Nothing left on disk.
        // Removed once the restored host has started serving, not before: a client can get here first.
        #expect(eventually { !FileManager.default.fileExists(atPath: scene.host.lock + ".handover") })
    }

    @Test func aHandoverKeepsEverySession() throws {
        let scene = try scene()
        defer { end(scene) }
        let pid = scene.host.pid
        let screens = Dictionary(uniqueKeysWithValues: [scene.shell, scene.job, scene.painted, scene.done].map { ($0.id, scene.client.screen($0.id) ?? "") })
        scene.client.attach(scene.counter.id)
        let counterBefore = counted(scene.client.text(scene.counter.id)).last ?? 0

        let seq = scene.client.send(.handover(executable: scene.host.newBinary))
        #expect(eventually { scene.client.reply(to: seq) != nil })
        #expect(scene.client.reply(to: seq) == .ok, "\(scene.host.log)")
        #expect(eventually { scene.client.closed })

        try expectCarriedOn(scene, build: scene.host.newBuild, screens: screens, counterBefore: counterBefore)
        #expect(scene.host.pid == pid)
        #expect(scene.host.runningExecutable == URL(fileURLWithPath: scene.host.newBinary).resolvingSymlinksInPath().path)
        #expect(eventually { scene.host.log.contains("took over 5 sessions") }, "\(scene.host.log)")
    }

    /// A session carried over by a handover still ends in the session log, and with its signal, as one started by
    /// the new build would; a kill names who asked.
    @Test func aRestoredSessionsEndIsLoggedWithItsSignal() throws {
        let scene = try scene()
        defer { end(scene) }
        let signalled = try scene.client.spawn("exec sleep 600"), killed = try scene.client.spawn("sleep 600")
        #expect(eventually { (ProcessTable.info(pid: signalled.childPID)?.comm ?? "") == "sleep" })
        let seq = scene.client.send(.handover(executable: scene.host.newBinary))
        #expect(eventually { scene.client.reply(to: seq) != nil })
        #expect(scene.client.reply(to: seq) == .ok, "\(scene.host.log)")
        #expect(eventually { scene.host.log.contains("took over") })

        let (client, _, build, _, _, _, _) = try TestClient.welcomed(scene.host.socket, appKey: scene.host.appKey)
        #expect(build == scene.host.newBuild)
        kill(signalled.childPID, SIGTERM)
        client.send(.kill(id: killed.id))
        #expect(eventually { client.latest(signalled.id)?.exit != nil && client.latest(killed.id)?.exit != nil })
        let death = try #require(client.latest(signalled.id)?.exit), kill = try #require(client.latest(killed.id)?.exit)
        #expect(death.status == 143 && death.signal == SIGTERM && death.cause == "killed by SIGTERM")
        #expect(kill.signal == SIGHUP && kill.killedBy == getpid())
        let lines = { (try? String(contentsOfFile: scene.host.sessionLog, encoding: .utf8)) ?? "" }
        #expect(eventually { lines().components(separatedBy: "\n").filter { $0.contains("exit ") }.count >= 3 })
        let all = lines().components(separatedBy: "\n")
        // Started before the handover, ended after it: both in the one log.
        #expect(all.contains { $0.contains("spawn") && $0.contains("pid \(signalled.childPID)") })
        #expect(all.filter { $0.contains("host: started") }.count == 2)
        #expect(all.contains { $0.contains("exit ") && $0.contains("pid \(signalled.childPID)") && $0.contains("signal 15 (SIGTERM)") })
        #expect(all.contains { $0.contains("kill ") && $0.contains("pid \(killed.childPID)") && $0.contains("peer pid \(getpid())") })
        #expect(all.contains { $0.contains("exit ") && $0.contains("pid \(killed.childPID)") && $0.contains("after a kill from peer pid \(getpid())") })
    }

    @Test func aBuildThatCantStartLeavesTheHostAsItWas() throws {
        let scene = try scene()
        defer { end(scene) }
        let screens = Dictionary(uniqueKeysWithValues: [scene.shell, scene.job, scene.painted, scene.done].map { ($0.id, scene.client.screen($0.id) ?? "") })
        let broken = scene.host.script("broken-host", "echo 'dyld: missing symbol' >&2; exit 3")
        for target in [broken, scene.host.dir + "/no-such-host", "/etc/hosts"] {
            let seq = scene.client.send(.handover(executable: target))
            #expect(eventually { scene.client.reply(to: seq) != nil })
            guard case .error(let message)? = scene.client.reply(to: seq) else {
                Issue.record("handover to \(target): \(String(describing: scene.client.reply(to: seq)))")
                continue
            }
            #expect(message.contains("Couldn't hand over"))
        }
        #expect(!scene.client.closed)
        scene.client.attach(scene.counter.id)
        let counterBefore = counted(scene.client.text(scene.counter.id)).last ?? 0
        scene.client.close()
        try expectCarriedOn(scene, build: scene.host.oldBuild, screens: screens, counterBefore: counterBefore)
        #expect(scene.host.runningExecutable == URL(fileURLWithPath: scene.host.oldBinary).resolvingSymlinksInPath().path)
    }

    /// What the host keeps in memory reaches the new build through the inherited channel, never through the state file.
    @Test func secretsReachTheNewBuildAndNeverTheStateFile() throws {
        let secret = "secret-\(UUID().uuidString)"
        let scene = try scene(arguments: ["--handover-test-secret", secret])
        defer { end(scene) }
        let copy = scene.host.dir + "/state-as-handed-over"
        // The new build, keeping a copy of the state it's handed.
        let copying = scene.host.script("copying-host", """
            case " $* " in *" --handover-probe "*) exec '\(scene.host.newBinary)' "$@";; esac
            next=0; for word in "$@"; do [ $next = 1 ] && cp "$word" '\(copy)'; next=0; [ "$word" = --handover ] && next=1; done
            exec '\(scene.host.newBinary)' "$@"
            """)
        let seq = scene.client.send(.handover(executable: copying))
        #expect(eventually { scene.client.reply(to: seq) != nil })
        #expect(scene.client.reply(to: seq) == .ok, "\(scene.host.log)")
        #expect(eventually { scene.host.log.contains("took over") })
        #expect(scene.host.log.contains("test secret carried: yes"))
        #expect(scene.host.log.contains("and \(secret.utf8.count) bytes of secrets"))
        let handedOver = FileManager.default.contents(atPath: copy) ?? Data()
        #expect(!handedOver.isEmpty)
        #expect(handedOver.range(of: Data(secret.utf8)) == nil)
        let state = try HostHandover.read(from: copy)
        #expect(state.secretFD != nil && state.sessions.count == 5)
    }

    /// The new build passes the probe, then can't restore: it executes the old build's own copy, which does.
    @Test func aBuildThatCantRestoreGoesBackToTheOldOne() throws {
        let scene = try scene()
        defer { end(scene) }
        let pid = scene.host.pid
        let screens = Dictionary(uniqueKeysWithValues: [scene.shell, scene.job, scene.painted, scene.done].map { ($0.id, scene.client.screen($0.id) ?? "") })
        let failing = scene.host.script("failing-host", """
            case " $* " in *" --handover-probe "*) exec '\(scene.host.newBinary)' "$@";; esac
            exec '\(scene.host.newBinary)' "$@" --handover-fail-restore
            """)
        scene.client.attach(scene.counter.id)
        let counterBefore = counted(scene.client.text(scene.counter.id)).last ?? 0
        let seq = scene.client.send(.handover(executable: failing))
        #expect(eventually { scene.client.reply(to: seq) != nil })
        #expect(scene.client.reply(to: seq) == .ok, "\(scene.host.log)")
        #expect(eventually { scene.client.closed })

        try expectCarriedOn(scene, build: scene.host.oldBuild, screens: screens, counterBefore: counterBefore)
        #expect(scene.host.pid == pid)
        #expect(scene.host.log.contains("couldn't take over"))
        #expect(eventually { scene.host.log.contains("took over 5 sessions") }, "\(scene.host.log)")
        // The old build's own copy, the one it started its sessions with.
        #expect(scene.host.runningExecutable?.hasSuffix("/.vibeswitcher/host/launcher-\(scene.host.oldBuild)") == true)
    }
}

struct HostHandoverStateTests {
    @Test func theStateFileIsPrivateAndReadBack() throws {
        let path = "\(shortScratchRoot)/vsho-state-\(UUID().uuidString.prefix(8))"
        defer { unlink(path) }
        let info = HostSession(id: UUID(), tty: "ttys009", childPID: 123, cwd: "/tmp", command: "claude", label: "Claude", agent: "claude",
                               title: "⠋ Fix", startedAt: Date(timeIntervalSince1970: 1_000), cols: 100, rows: 30, exit: nil)
        let state = HostHandover.State(fromBuild: 7, startedAt: Date(timeIntervalSince1970: 2_000), lockFD: 3, listenFD: 4, secretFD: nil,
                                       sessions: [.init(info: info, masterFD: 9, output: Data([0, 1, 0x1b, 0xff]), pendingInput: Data("x".utf8))])
        try HostHandover.write(state, to: path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try HostHandover.read(from: path) == state)
        #expect(state.descriptors == [3, 4, 9])
    }

    @Test func aStateOfAnotherFormatIsRefused() throws {
        let path = "\(shortScratchRoot)/vsho-state-\(UUID().uuidString.prefix(8))"
        defer { unlink(path) }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(["format": 99]).write(to: URL(fileURLWithPath: path))
        #expect(throws: HostHandover.Failure.wrongFormat(99)) { try HostHandover.read(from: path) }
        try Data("junk".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: HostHandover.Failure.self) { try HostHandover.read(from: path) }
    }

    @Test func secretsGoThroughAChannelAndNowhereElse() throws {
        let secret = Data((0..<300_000).map { UInt8($0 % 251) })
        let fd = try HostHandover.SecretChannel.make(secret)
        #expect(HostHandover.isOpen(fd))
        let channel = Self.identity(fd)
        #expect(HostHandover.SecretChannel.take(fd) == secret)
        // Closed: the number may already be another test's descriptor (they run in parallel), but not the channel.
        #expect(!HostHandover.isOpen(fd) || Self.identity(fd) != channel)
    }

    /// What the descriptor is open on (device and inode), nil when it's closed.
    static func identity(_ fd: Int32) -> [UInt64]? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return [UInt64(UInt32(bitPattern: info.st_dev)), info.st_ino]
    }
}
