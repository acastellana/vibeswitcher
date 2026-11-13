import Foundation
import Testing
import VibeCore

/// A real Claude Code session on a terminal this test owns goes from working to needs-you to done in
/// `vibeswitcher status`, through the hooks `vibeswitcher hooks install` put in its config folder. On demand only: it
/// spends the account's usage (one short prompt, on sonnet), and needs a throwaway Claude Code config folder the user
/// logged in once (`CLAUDE_CONFIG_DIR=<folder> claude`, then `/login`; an agent never logs in or copies credentials):
/// `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=<that folder> bash scripts/test.sh --filter RealClaudeStatusTests`.
///
/// The `claude` run is the first on PATH (`VIBESWITCHER_REAL_CLAUDE` names another). Everything else is scratch: the
/// VibeSwitcher home, HOME and the project folder. In the config folder the run adds the project's trust entry to
/// `.claude.json` and the hooks to `settings.json`, and takes both out again at its end; Claude Code itself leaves the
/// session's transcript and its other per-session files there, as any session does.
///
/// It also checks that the hook finds its session from the agent's terminal on Linux, where the native `claude`'s
/// process name is its version number and argv[0] tells it apart (`ProcessTable.agent`).
struct RealClaudeStatusTests {
    private let scratch = Scratch()

    static let configFolder = ProcessInfo.processInfo.environment["VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR"]

    /// What the session is asked: one Bash command, which Claude Code asks about first (needs-you) in the manual
    /// permission mode it is started in (2.1.323's default is auto mode, which ran it unasked), then a one-word answer
    /// (done).
    static let prompt = "Use your Bash tool to run exactly this command: touch made-by-claude. Then answer with the one word: finished."

    /// The `claude` to run: `VIBESWITCHER_REAL_CLAUDE`, else the first on PATH, by the path found (a symlink to the
    /// versioned binary kept as it is, so argv[0] ends in `claude` as when the user starts it).
    static func claudeExecutable() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let given = environment["VIBESWITCHER_REAL_CLAUDE"], !given.isEmpty { return given }
        for folder in (environment["PATH"] ?? "").split(separator: ":") where folder.hasPrefix("/") {
            let candidate = "\(folder)/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    @Test(.enabled(if: configFolder != nil,
                   "spends Claude usage: set VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR to a Claude Code config folder you logged in once to run it"))
    func aRealSessionGoesFromWorkingToNeedsYouToDone() async throws {
        let config = URL(fileURLWithPath: try #require(Self.configFolder))
        try #require(FileManager.default.fileExists(atPath: config.appendingPathComponent(".claude.json").path),
                     "\(config.path) has no .claude.json: log in there once first")
        let claude = try #require(Self.claudeExecutable(), "no claude on PATH")

        let folder = scratch.url("real-claude")
        let project = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("home"), withIntermediateDirectories: true)
        let projectPath = project.resolvingSymlinksInPath().path
        let commands = scratchEnvironment(folder, ["CLAUDE_CONFIG_DIR": config.path])

        let version = try await run(URL(fileURLWithPath: claude), ["--version"], environment: Self.agentEnvironment(folder, config: config))
        print("R10: \(claude) --version: \(version.output.trimmingCharacters(in: .whitespacesAndNewlines))")

        // 1. The hooks, into the config folder given.
        let install = try await run(commandLine, ["hooks", "install", "--agent", "claude"], environment: commands)
        try #require(install.status == 0, "hooks install: \(install.output)\(install.errors)")
        var session: RealSession?
        do {
            // 2. The project trusted, or Claude Code shows its trust dialog first and no hook runs.
            try Self.trust(projectPath, in: config, true)
            // 3. Claude Code on a terminal of the test's own, its first prompt given.
            let started = try await RealSession(claude: claude, prompt: Self.prompt, in: project,
                                                environment: Self.agentEnvironment(folder, config: config))
            session = started
            try await Self.goesFromWorkingToNeedsYouToDone(started, project: project, commands: commands)
        } catch {
            await Self.cleanUp(session, project: projectPath, config: config, commands: commands)
            throw error
        }
        await Self.cleanUp(session, project: projectPath, config: config, commands: commands)
    }

    /// Steps 4 and 5: what `status` and the hook's state file say, polled, while the session works, asks and ends.
    private static func goesFromWorkingToNeedsYouToDone(_ session: RealSession, project: URL,
                                                        commands: [String: String]) async throws {
        let stateFile = URL(fileURLWithPath: commands["VIBESWITCHER_HOME"]!)
            .appendingPathComponent("state/\(session.tty).json")
        let watch = StatusWatch(tty: session.tty, stateFile: stateFile, environment: commands)
        print("R10: the session's terminal: \(session.tty)")

        // 4. Working, then needs-you (the permission prompt).
        let asked = try await watch.until(within: 120) { $0 == "needs-you" }
        try #require(asked, "never needs-you; statuses seen: \(watch.statuses); screen: \(session.screenTail())")
        let working = watch.statuses.firstIndex(of: "working")
        #expect(working != nil && working! < watch.statuses.firstIndex(of: "needs-you")!, "\(watch.statuses)")

        // 5. The prompt approved: Enter on "Yes", once its question shows; again while it still asks, 10 s after.
        let shown = await eventually(timeout: 30) { session.screen().contains("proceed") }
        print("R10: the permission question on the screen: \(shown)")
        var presses = 0
        repeat {
            session.type("\r")
            presses += 1
            _ = try await watch.until(within: 10) { $0 != "needs-you" }
        } while watch.current == "needs-you" && presses < 3
        let done = try await watch.until(within: 60) { $0 == "done" }
        print("R10: Enter pressed \(presses) time(s)")
        #expect(done, "never done; statuses seen: \(watch.statuses); screen: \(session.screenTail())")
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("made-by-claude").path))

        // 6. The record: the statuses `status` gave, in order, and each state file the hook wrote that a poll saw.
        print("R10: statuses, in order: \(watch.statuses.joined(separator: " -> "))")
        for (index, state) in watch.states.enumerated() { print("R10: state file \(index + 1): \(state)") }

        // Observed, not asserted: what the hook leaves when the session ends.
        print("R10: the session \(await session.quit())")
        let removed = await eventually(timeout: 10) { !FileManager.default.fileExists(atPath: stateFile.path) }
        print("R10: after the session ended, its state file \(removed ? "was removed" : "stayed: \((try? String(contentsOf: stateFile, encoding: .utf8)) ?? "")")")
    }

    /// The session ended, the trust entry and the hooks taken out of the config folder again.
    private static func cleanUp(_ session: RealSession?, project: String, config: URL, commands: [String: String]) async {
        await session?.quit()
        do { try trust(project, in: config, false) } catch { Issue.record("the trust entry stayed: \(error)") }
        guard let remove = try? await run(commandLine, ["hooks", "remove", "--agent", "claude"], environment: commands) else {
            Issue.record("hooks remove didn't run")
            return
        }
        #expect(remove.status == 0, "hooks remove: \(remove.output)\(remove.errors)")
    }

    /// Claude Code's environment: the scratch home's, the config folder given, a terminal it can draw on, and nothing of
    /// this process's own Claude Code or Anthropic variables (a session running these tests has some).
    static func agentEnvironment(_ folder: URL, config: URL) -> [String: String] {
        var environment = scratchEnvironment(folder)
        for key in environment.keys where key.hasPrefix("CLAUDE") || key.hasPrefix("ANTHROPIC") || key.hasPrefix("VIBESWITCHER_REAL_") {
            environment[key] = nil
        }
        return environment.merging(["CLAUDE_CONFIG_DIR": config.path, "TERM": "xterm-256color", "SHELL": "/bin/bash",
                                    "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]) { $1 }
    }

    /// Adds (`on`) or takes out the project's entry in the config folder's `.claude.json`, as
    /// `Tests/Tools/capture-claude-status-rows.py` writes it: trusted and onboarded. Not a credential. The rest of the
    /// file is kept; it is written whole beside it, 0600, and renamed into place.
    static func trust(_ project: String, in config: URL, _ on: Bool) throws {
        let url = config.appendingPathComponent(".claude.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                                  "\(url.path) isn't a JSON object")
        var projects = object["projects"] as? [String: Any] ?? [:]
        if on {
            projects[project] = ["hasTrustDialogAccepted": true, "hasCompletedProjectOnboarding": true,
                                 "allowedTools": [String]()] as [String: Any]
        } else {
            guard projects[project] != nil else { return }
            projects[project] = nil
        }
        object["projects"] = projects
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let temporary = config.appendingPathComponent(".claude.json.vibeswitcher-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// `vibeswitcher status --json` for one terminal, polled every 0.5 s: the statuses it gave, each once in a row, and the
/// hook's state file for that terminal each time it changed.
private final class StatusWatch {
    let tty: String
    let stateFile: URL
    let environment: [String: String]
    private(set) var statuses: [String] = []
    private(set) var states: [String] = []

    init(tty: String, stateFile: URL, environment: [String: String]) {
        self.tty = tty
        self.stateFile = stateFile
        self.environment = environment
    }

    /// The status the last poll saw (nil: `status` didn't list the terminal).
    private(set) var current: String?

    /// Polls until `condition` holds for the status (true) or `timeout` passes (false).
    func until(within timeout: TimeInterval, _ condition: (String?) -> Bool) async throws -> Bool {
        let deadline = MacTime.real.awake() + timeout
        while !Task.isCancelled {
            if condition(try await look()) { return true }
            if MacTime.real.awake() >= deadline { return false }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// One poll: the status now (nil when `status` doesn't list the terminal), noted.
    private func look() async throws -> String? {
        if let state = try? String(contentsOf: stateFile, encoding: .utf8), state != states.last { states.append(state) }
        let ran = try await run(commandLine, ["status", "--json"], environment: environment)
        #expect(ran.status == 0, "status --json: \(ran.errors)")
        let report = try JSONSerialization.jsonObject(with: Data(ran.output.utf8)) as? [String: Any]
        let sessions = report?["sessions"] as? [[String: Any]] ?? []
        let status = sessions.first { $0["terminal"] as? String == tty }?["status"] as? String
        if let status, status != statuses.last { statuses.append(status) }
        current = status
        return status
    }
}

/// A real `claude` on a pty of the test's own, made with `script` (util-linux's form on Linux, BSD's on the Mac) as
/// `FakeAgent` is: the test types into `script`'s stdin and reads the screen from its stdout.
private final class RealSession: @unchecked Sendable {
    let terminal = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var drawn = Data()
    private(set) var tty = ""

    init(claude: String, prompt: String, in folder: URL, environment: [String: String]) async throws {
        // A size to draw in: `script` gives the pty none when its own stdin isn't a terminal.
        let command = "stty rows 40 cols 120; cd '\(folder.path)' && exec '\(claude)' --model sonnet --permission-mode manual '\(prompt)'"
        terminal.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        #if os(Linux)
        terminal.arguments = ["-q", "-c", command, "/dev/null"]
        #else
        terminal.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
        #endif
        terminal.environment = environment
        terminal.standardInput = input
        terminal.standardOutput = output
        terminal.standardError = FileHandle.nullDevice
        try terminal.run()
        let reading = output.fileHandleForReading
        Thread { [self] in
            while true {
                let chunk = reading.availableData
                if chunk.isEmpty { return }
                lock.lock()
                drawn.append(chunk)
                lock.unlock()
            }
        }.start()
        let found = await eventually(timeout: 30) { [self] in
            for child in descendants() {
                guard let tty = ProcessTable.info(pid: child)?.tty else { continue }
                self.tty = tty
                return true
            }
            return false
        }
        if !found { await quit() }
        try #require(found, "claude never showed on a terminal")
    }

    /// What it drew so far, its escape sequences dropped.
    func screen() -> String {
        lock.lock()
        let text = String(decoding: drawn, as: UTF8.self)
        lock.unlock()
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9]*C", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[()][0-9A-Za-z]",
                                         with: "", options: .regularExpression)
    }

    /// The last of it, for a failure's message.
    func screenTail() -> String { String(screen().suffix(1500)) }

    func type(_ text: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
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

    /// Ctrl-C, and again once it says a second one ends it (Claude Code's way out); killed if it hasn't ended 15 s
    /// later. Waited for. Says which.
    @discardableResult
    func quit() async -> String {
        guard terminal.isRunning else { return "already ended" }
        let started = descendants()
        type("\u{3}")
        let asked = await eventually(timeout: 5) { [self] in
            screen().filter { !$0.isWhitespace }.contains("againtoexit") || !terminal.isRunning
        }
        type("\u{3}")
        if await exited(terminal, within: 15) { return asked ? "ended on Ctrl-C twice" : "ended on Ctrl-C, no second asked for" }
        for child in started { kill(child, SIGKILL) }
        return "still running 15 s after Ctrl-C twice: killed"
    }
}
