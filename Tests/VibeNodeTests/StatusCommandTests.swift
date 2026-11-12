import Foundation
import Testing
import VibeCore

/// A fake `claude` on a terminal of its own: a copy of `sleep` named `claude` (the process table knows an agent by its
/// name), exec'd by a shell that `script` runs on a new pty, in `folder`. The app's `FakeClaude` isn't this target's,
/// and nothing here needs more than a process that is named so and sits on a terminal.
final class FakeAgent {
    let terminal = Process()
    private let input = Pipe()
    private(set) var pid: pid_t = 0
    private(set) var tty = ""

    init(in folder: URL, scratch: URL) async throws {
        let bin = scratch.appendingPathComponent("fake-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep").resolvingSymlinksInPath(), to: claude)
        let command = "cd '\(folder.path)' && exec '\(claude.path)' 600"
        terminal.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        #if os(Linux)
        // util-linux's script: the file last, and the command one word after -c, run by $SHELL.
        terminal.arguments = ["-q", "-c", command, "/dev/null"]
        terminal.environment = ProcessInfo.processInfo.environment.merging(["SHELL": "/bin/sh"]) { $1 }
        #else
        terminal.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
        #endif
        terminal.standardInput = input
        terminal.standardOutput = FileHandle.nullDevice
        terminal.standardError = FileHandle.nullDevice
        try terminal.run()
        let found = await eventually(timeout: 30) { [self] in
            for child in descendants() {
                guard let info = ProcessTable.info(pid: child), info.comm == "claude", let tty = info.tty else { continue }
                (pid, self.tty) = (child, tty)
                return true
            }
            return false
        }
        if !found { await stop() }
        try #require(found, "the fake claude never showed on a terminal")
    }

    private func descendants() -> [pid_t] {
        var found: [pid_t] = []
        var next = [terminal.processIdentifier]
        while let parent = next.popLast() {
            let live = Platform.Processes.children(parent)
            found += live
            next += live
        }
        return found
    }

    /// Ends the fake and its terminal, and waits for both.
    func stop() async {
        for child in descendants() { kill(child, SIGKILL) }
        if terminal.isRunning { kill(terminal.processIdentifier, SIGKILL) }
        _ = await exited(terminal, within: 30)
    }
}

/// `vibeswitcher status`: the sessions on this machine, from the process table and the hooks' state files, run as
/// built (`vibeswitcher-cli`) in a scratch home. Agents in other terminals on this machine (a real `claude` the user
/// runs) are listed too, as the design says: each test reads only its own fake's terminal.
struct StatusCommandTests {
    private let scratch = Scratch()

    /// The parsed `status --json`, and the one session on `tty` in it.
    private func json(_ environment: [String: String], tty: String) async throws -> (report: [String: Any], session: [String: Any]) {
        let ran = try await run(commandLine, ["status", "--json"], environment: environment)
        #expect(ran.status == 0, "status --json: \(ran.errors)")
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
        let plain = try await run(commandLine, ["status"], environment: environment)
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
