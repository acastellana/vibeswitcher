import Foundation
import Testing
import VibeCore
import VibeNode

/// A fake `claude` on a terminal of its own: a copy of `sleep` named `claude` (the process table knows an agent by its
/// name; on the Mac signed as a program of its own, `signedAsItsOwn`, or it's killed as it starts), exec'd by a shell
/// that `script` runs on a new pty, in `folder`. The app's `FakeClaude` isn't this target's,
/// and nothing here needs more than a process that is named so and sits on a terminal.
///
/// `script` is started by `Platform.Spawn` (its stdin a close-on-exec pipe this holds open, nothing else of this
/// process inherited) and collected here by its pid with bounded waits off the pool (`SpawnedHost`, `exited`): not
/// Foundation's `Process`, whose start crashed the test process under load (`run(_:_:environment:)`'s note) and whose
/// waits the repo doesn't trust unbounded. A terminal that ends before the fake shows on it (the copy just made, held
/// open for writing by a child another test forked meanwhile, refuses its exec: "Text file busy") is started again,
/// until the guard.
final class FakeAgent {
    private var terminal = SpawnedHost(pid: 0)
    /// The writing end of `script`'s stdin, held so that it never reads an end; -1 once stopped.
    private var input: Int32 = -1
    private(set) var pid: pid_t = 0
    private(set) var tty = ""

    init(in folder: URL, scratch: URL) async throws {
        let bin = scratch.appendingPathComponent("fake-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try copyClosedOnExec(URL(fileURLWithPath: "/bin/sleep").resolvingSymlinksInPath().path, to: claude.path)
        try signedAsItsOwn(claude.path)
        let command = "cd '\(folder.path)' && exec '\(claude.path)' 600"
        let deadline = MacTime.real.awake() + 60
        while pid == 0, MacTime.real.awake() < deadline, !Task.isCancelled {
            try await start(command)
            // Until the fake is on a terminal, or the terminal has ended without it (then started again).
            _ = await eventually(timeout: max(0, deadline - MacTime.real.awake())) { [self] in
                for child in descendants() {
                    guard let info = ProcessTable.info(pid: child), info.comm == "claude", let tty = info.tty else { continue }
                    (pid, self.tty) = (child, tty)
                    return true
                }
                return !terminal.isRunning
            }
            if pid == 0 { await stop() }
        }
        try #require(pid != 0, "the fake claude never showed on a terminal")
    }

    /// `script` running `command` on a new pty, its stdin a pipe whose writing end this holds.
    private func start(_ command: String) async throws {
        var ends: [Int32] = [-1, -1]
        guard Sys.pipeClosedOnExec(&ends) == 0 else { throw Platform.Errno(code: errno) }
        #if os(Linux)
        // util-linux's script: the file last, and the command one word after -c, run by $SHELL.
        var spawn = Platform.Spawn(executable: "/usr/bin/script", arguments: ["/usr/bin/script", "-q", "-c", command, "/dev/null"])
        spawn.environment = ProcessInfo.processInfo.environment.merging(["SHELL": "/bin/sh"]) { $1 }.map { "\($0.key)=\($0.value)" }
        #else
        var spawn = Platform.Spawn(executable: "/usr/bin/script", arguments: ["/usr/bin/script", "-q", "/dev/null", "/bin/sh", "-c", command])
        #endif
        spawn.stdin = .descriptor(ends[0])
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        spawn.stderr = .path("/dev/null", flags: O_WRONLY)
        defer { Sys.close(ends[0]) }
        do {
            terminal = SpawnedHost(pid: try await startRetrying(spawn))
        } catch {
            Sys.close(ends[1])
            throw error
        }
        input = ends[1]
    }

    /// The processes under the terminal; none before it started or once it was collected (its pid may be another's).
    private func descendants() -> [pid_t] {
        guard terminal.processIdentifier > 0, terminal.waitStatus == nil else { return [] }
        var found: [pid_t] = []
        var next = [terminal.processIdentifier]
        while let parent = next.popLast() {
            let live = Platform.Processes.children(parent)
            found += live
            next += live
        }
        return found
    }

    /// Ends the fake and its terminal, and waits for the terminal (collected here, its wait bounded).
    func stop() async {
        for child in descendants() { kill(child, SIGKILL) }
        if terminal.isRunning { kill(terminal.processIdentifier, SIGKILL) }
        _ = await exited(terminal, within: 30)
        if input >= 0 { Sys.close(input) }
        input = -1
    }
}

/// `vibeswitcher status --probe`: the sessions on this machine, from the process table and the hooks' state files, run
/// as built (`vibeswitcher-cli`) in a scratch home: stage 1's `status`, its assertions kept, now under `--probe` since
/// `status` itself goes through the node's server (the engine's E1, `ServerTests.statusThroughTheServerListsWhatTheProbeLists`). Agents in other terminals on this machine (a real `claude` the user
/// runs) are listed too, as the design says: each test reads only its own fake's terminal.
struct StatusCommandTests {
    private let scratch = Scratch()

    /// The parsed `status --probe --json`, and the one session on `tty` in it.
    private func json(_ environment: [String: String], tty: String) async throws -> (report: [String: Any], session: [String: Any]) {
        let ran = try await run(commandLine, ["status", "--probe", "--json"], environment: environment)
        #expect(ran.status == 0, "status --probe --json: \(ran.errors)")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(ran.output.utf8)) as? [String: Any], "\(ran.output)")
        let sessions = try #require(report["sessions"] as? [[String: Any]], "\(ran.output)")
        let mine = sessions.filter { $0["terminal"] as? String == tty }
        #expect(mine.count == 1, "\(ran.output)")
        return (report, try #require(mine.first))
    }

    @Test func aFakeSessionIsListedWithItsStatus() async throws {
        let folder = scratch.url("status")
        let project = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fake = try await FakeAgent(in: project, scratch: folder)
        let environment = scratchEnvironment(folder)
        // What the hook writes on a permission prompt, for the fake's terminal.
        var state = HookState(agent: .claude, tty: fake.tty, lastEvent: "PermissionRequest", lastEventAt: Date().timeIntervalSince1970)
        state.agentPid = fake.pid
        state.cwd = project.path
        let states = URL(fileURLWithPath: environment["VIBESWITCHER_HOME"]!).appendingPathComponent("state")
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        try state.save(to: states.appendingPathComponent("\(fake.tty).json"))

        let (_, session) = try await json(environment, tty: fake.tty)
        let plain = try await run(commandLine, ["status", "--probe"], environment: environment)
        await fake.stop()

        #expect(session["status"] as? String == "needs-you")
        #expect(session["agent"] as? String == "claude")
        #expect(session["cwd"] as? String == project.path)
        #if os(Linux)
        #expect(fake.tty.hasPrefix("ttypts"), "\(fake.tty)")
        #endif
        #expect(plain.status == 0)
        let line = try #require(plain.output.split(separator: "\n").first { $0.hasPrefix(fake.tty + " ") }, "\(plain.output)")
        #expect(line.contains("claude") && line.contains(project.path) && line.contains("needs you"), "\(line)")
    }

    @Test func aSessionWithNoStateFileIsListedByTheTableAlone() async throws {
        let folder = scratch.url("status")
        let project = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fake = try await FakeAgent(in: project, scratch: folder)
        let (_, session) = try await json(scratchEnvironment(folder), tty: fake.tty)
        await fake.stop()

        // No hooks and no title read: its status can't be told; its folder is the agent's own.
        #expect(session["status"] as? String == "unknown")
        #expect(session["agent"] as? String == "claude")
        let cwd = try #require(session["cwd"] as? String)
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == project.resolvingSymlinksInPath().path)
    }

    /// `status` names the host's build, from its notes (`HostNotes.build`, the `build-info` its start checked), and the
    /// host's pid from its welcome, which the hello carries too (the start plan's S5).
    @Test(NodeTraits.linuxOnly) func statusNamesTheHostsBuild() async throws {
        let node = try await ScratchNode(scratch)
        #expect(try WireClient(node).hello.host.pid == node.hostPID)
        let plain = try await node.run(["status", "--long"])
        #expect(plain.status == 0, "\(plain.errors)")
        let hostLine = plain.output.split(separator: "\n").first { $0.hasPrefix("host ") }.map(String.init) ?? ""
        #expect(hostLine.contains("pid \(node.hostPID)"), "\(plain.output)")
        #expect(hostLine.contains("build \(ScratchNode.commit)"), "\(plain.output)")
        let shown = try await node.run(["status", "--json"])
        let report = try #require(try JSONSerialization.jsonObject(with: Data(shown.output.utf8)) as? [String: Any], "\(shown.output)")
        let host = try #require(report["host"] as? [String: Any])
        #expect(host["pid"] as? Int == Int(node.hostPID), "\(host)")
        #expect((host["notes"] as? [String: Any])?["build"] as? String == ScratchNode.commit, "\(host)")
    }

    @Test func theJSONCarriesFormatNodeAndId() async throws {
        let folder = scratch.url("status")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Whole seconds: ISO 8601 as written drops the fraction, and Linux gives the boot time a process's start is
        // counted from in whole seconds too.
        let before = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 2)
        let fake = try await FakeAgent(in: folder, scratch: folder)
        let (report, session) = try await json(scratchEnvironment(folder), tty: fake.tty)
        let after = Date()
        await fake.stop()

        #expect(report["format"] as? Int == 1)
        #expect(report["node"] as? String == "local")
        #expect(Set(session.keys) == ["id", "terminal", "agent", "cwd", "status", "since"])
        #expect(session["id"] as? String == "local:\(fake.tty)")
        // When it started (no hook has said anything since), as an ISO 8601 date.
        let since = try #require(session["since"] as? String)
        let date = try #require(ISO8601DateFormatter().date(from: since), "\(since)")
        #expect(before <= date && date <= after, "\(since) not between \(before) and \(after)")
    }
}
