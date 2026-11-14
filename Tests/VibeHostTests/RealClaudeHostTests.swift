import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A real Claude Code session under a scratch host (the stage 2 plan's Task 12a): a real `vibeswitcher-host` on a scratch
/// home, socket and lock (`ScratchHostProcess`), with this test as its app, runs `claude` as a session's program and
/// keeps it through its client quitting, a handover and a killed parser. On demand only: it starts a real Claude Code
/// session (no prompt is sent, so it spends next to nothing of the account's usage), and needs a throwaway Claude Code
/// config folder the user logged in once (`CLAUDE_CONFIG_DIR=<folder> claude`, then `/login`; an agent never logs in or
/// copies credentials), named on the run's command line (the user's decision 16):
/// `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=<that folder> bash scripts/test.sh --filter RealClaudeHostTests`.
///
/// The `claude` run is the first on PATH (`VIBESWITCHER_REAL_CLAUDE` names another), by its full path: the session's
/// PATH is the scratch host's. The config folder reaches the session through the spawn's `env` (`CLAUDE_CONFIG_DIR`,
/// which the app's spawn may set: `SpawnEnvironment`), never through the host's environment. In the folder the run adds
/// the scratch project's trust entry to `.claude.json` and takes it out again once Claude Code has ended; Claude Code
/// leaves its own per-session files there, as any session does (stage 1's R10: `RealClaudeStatusTests`).
@Suite(.serialized, hostTestLimit) struct RealClaudeHostTests {
    static let configFolder = ProcessInfo.processInfo.environment["VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR"]

    /// The `claude` to run: `VIBESWITCHER_REAL_CLAUDE`, else the first on PATH, by the path found (a link to the
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

    /// Whether Claude Code's input box is on `screen` (its prompt: empty, or holding a draft), not a dialog.
    static func promptShows(_ screen: String?) -> Bool {
        guard let screen else { return false }
        if case .dialog = LeadDelivery.box(in: screen) { return false }
        return true
    }

    /// The lines of a screen with their trailing blanks dropped, for comparing two reads of it.
    static func rows(_ screen: String?) -> [String] {
        Platform.lines(screen ?? "").map { String($0.reversed().drop { $0 == " " || $0 == "\u{0}" }.reversed()) }
    }

    @Test(.enabled(if: configFolder != nil,
                   "starts a real Claude Code: set VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR to a Claude Code config folder you logged in once to run it"))
    func aClaudeSessionSurvivesItsClientAHandoverAndAKilledParser() async throws {
        let config = URL(fileURLWithPath: try #require(Self.configFolder))
        try #require(FileManager.default.fileExists(atPath: config.appendingPathComponent(".claude.json").path),
                     "\(config.path) has no .claude.json: log in there once first")
        let claude = try #require(Self.claudeExecutable(), "no claude on PATH")

        let host = try await ScratchHostProcess()
        // A scratch repository, trusted in the config folder (else Claude Code shows its trust dialog first).
        let project = host.dir + "/project"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: project) }
        let projectPath = URL(fileURLWithPath: project).resolvingSymlinksInPath().path
        print("R12a: \(claude) --version: \(Self.version(of: claude, home: host.home, config: config))")
        try Self.trust(projectPath, in: config, true)
        var session: HostSession?
        defer {
            if let session, kill(session.childPID, 0) == 0 {
                kill(-session.childPID, SIGKILL)
                _ = eventuallyBlocking(timeout: 15) { kill(session.childPID, 0) != 0 }
            }
            host.stop()
            do { try Self.trust(projectPath, in: config, false) } catch { Issue.record("the trust entry stayed: \(error)") }
        }

        let started = MacTime.real.awake()
        var mark = started
        func step(_ what: String) {
            let now = MacTime.real.awake()
            print(String(format: "R12a: %@: %.1f s (%.1f s from the spawn)", what, now - mark, now - started))
            mark = now
        }

        // The session: claude, with the config folder through the request's env, in manual permission mode (named, as
        // every role's is: 2.1.323 starts in auto mode unless told).
        let (first, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let quote = RecentProjects.shellQuote
        let seq = first.send(.spawn(SpawnRequest(cwd: projectPath,
                                                 command: "exec \(quote(claude)) --model sonnet --permission-mode manual",
                                                 env: ["CLAUDE_CONFIG_DIR": config.path, "DISABLE_AUTOUPDATER": "1",
                                                       "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"],
                                                 cols: 80, rows: 24, keepShell: false, label: "Claude", agent: "claude")))
        #expect(await eventually { first.reply(to: seq) != nil })
        guard case .spawned(let spawned)? = first.reply(to: seq) else {
            Issue.record("no session: \(String(describing: first.reply(to: seq))); \(host.log)"); return
        }
        session = spawned
        let id = spawned.id
        print("R12a: the session's terminal: \(spawned.tty)")

        // 1. A client reads the screen until Claude Code's prompt shows, and disconnects.
        var screen: String?
        let prompted = await eventually(timeout: 90) { screen = first.screen(id); return Self.promptShows(screen) }
        try #require(prompted, "no prompt: \(screen ?? "no screen")\n\(host.log)")
        // Its screen settled: its prompt still shown, and every read for a second the same (no event says a program is
        // done drawing: the screen is read as often as `eventually` looks, and the second counts from its last change).
        var settled = Self.rows(screen)
        var changed = MacTime.real.awake()
        let quiet = await eventually(timeout: 20) {
            let now = first.screen(id)
            let again = Self.rows(now)
            if again != settled { settled = again; changed = MacTime.real.awake() }
            return MacTime.real.awake() - changed >= 1 && Self.promptShows(now)
        }
        try #require(quiet, "the screen never settled with its prompt shown: \(settled.joined(separator: "\n"))\n\(host.log)")
        first.close()
        print("R12a: the screen:\n" + settled.filter { !$0.isEmpty }.joined(separator: "\n"))
        step("1, the prompt shown, the first client gone")

        // 2. A new client attaches, and the same screen is there.
        let (second, _, _, listed, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(listed.first { $0.id == id }?.isLive == true, "\(listed)")
        await second.attach(id)
        var seen: [String] = []
        #expect(await eventually(timeout: 10) { seen = Self.rows(second.screen(id)); return seen == settled },
                "before: \(settled.joined(separator: "\n"))\nafter: \(seen.joined(separator: "\n"))")
        step("2, the same screen to a new client")

        // 3. A handover to the same code's build, through sealed memory on Linux: the session is listed with the same id
        // and terminal, its program still running, its prompt still there.
        #expect(await host.handOver(to: host.newBinary, through: second) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("took over 1 sessions") }, "\(host.log)")
        let (third, _, build, after, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(build == host.newBuild)
        let kept = after.first { $0.id == id }
        #expect(kept?.tty == spawned.tty && kept?.isLive == true, "\(after)")
        #expect(kill(spawned.childPID, 0) == 0)
        #expect(await eventually(timeout: 10) { seen = Self.rows(third.screen(id)); return seen == settled },
                "before: \(settled.joined(separator: "\n"))\nafter: \(seen.joined(separator: "\n"))")
        step("3, handed over, the session kept")

        // 4. The session's parser killed: a new parser's screen matches within 10 s.
        let parsers = OrphanSweepTests.parsers(of: host.pid)
        try #require(parsers.count == 1, "parsers: \(parsers)")
        let sessionLog = { (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "" }
        let watchdogLines = sessionLog().components(separatedBy: "watchdog:").count
        kill(parsers[0], SIGKILL)
        #expect(await eventually(timeout: 10) { sessionLog().components(separatedBy: "watchdog:").count > watchdogLines },
                "\(sessionLog())")
        let replaced = await eventually(timeout: 10) {
            let now = OrphanSweepTests.parsers(of: host.pid)
            return now.count == 1 && now[0] != parsers[0]
        }
        #expect(replaced, "parsers: \(OrphanSweepTests.parsers(of: host.pid))")
        #expect(await eventually(timeout: 10) { seen = Self.rows(third.screen(id)); return seen == settled },
                "before: \(settled.joined(separator: "\n"))\nafter: \(seen.joined(separator: "\n"))")
        step("4, the parser killed, the screen rebuilt")

        // 5. /exit, sent as an input unit (its text, then Enter a moment later), and the session's exit recorded.
        let typed = third.send(.inputUnit(id: id, writes: HostInput.writes(text: "/exit", submit: true, key: nil), more: false))
        #expect(await eventually { third.reply(to: typed) != nil })
        #expect(third.reply(to: typed) == .ok)
        let exited = await eventually(timeout: 30) { third.latest(id)?.exit != nil }
        #expect(exited, "no exit: \(third.screen(id) ?? "no screen")")
        let (fourth, _, _, last, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        _ = fourth
        let exit = last.first { $0.id == id }?.exit
        #expect(exit != nil, "\(last)")
        print("R12a: the session ended: \(exit?.cause ?? "not recorded")")
        step("5, /exit, its exit recorded")

        // 6. No parser reply dropped (the stage 2 plan's Task 9e), in either log, but the one 9e leaves out on purpose:
        // the answer to Claude Code's kitty graphics probe as it starts (`APC G i=31,…,a=q;… ST`), which the headless
        // terminal answers `APC G i=31;OK ST` (`ParserReplies.swiftTermResponders`: kitty graphics, left out). Each
        // drop is in the log: a line a second at most; those the once-a-second limit held back are counted as "and N
        // more" on the next line, or, when the parser stops first (before the handover's exec, as the session ends),
        // in a line of their own naming the first four (`ParserReplies.flushDropped`). So the session's parser is
        // waited out first; a line counting drops it doesn't name fails, and each drop named must be a kitty graphics
        // reply.
        #expect(await eventually(timeout: 10) { OrphanSweepTests.parsers(of: host.pid).isEmpty },
                "parsers: \(OrphanSweepTests.parsers(of: host.pid))")
        let dropped = (sessionLog() + host.log).components(separatedBy: "\n").filter { $0.contains("reply dropped") || $0.contains("more dropped") }
        #expect(dropped.allSatisfy(Self.onlyKittyGraphicsDropped), "\(sessionLog())\n\(host.log)")
        print("R12a: replies dropped: \(dropped.isEmpty ? "none" : dropped.joined(separator: "; "))")
        print("R12a: the session log's watchdog lines: \(sessionLog().components(separatedBy: "\n").filter { $0.contains("watchdog:") })")
    }

    /// Whether a log line about dropped parser replies names kitty graphics replies (`APC G …`, which Task 9e leaves
    /// out) and nothing else: one drop's line, or `flushDropped`'s naming every drop it counts. A line with
    /// "(and N more …)", or a flush with drops it doesn't name ("…"), is not.
    static func onlyKittyGraphicsDropped(_ line: String) -> Bool {
        let kitty = { (drop: Substring) in drop.contains("reply dropped, it is no reply: ") && drop.contains("ESC_Gi=") }
        let flush = "more dropped since the last line, as its parser stopped: "
        guard let named = line.range(of: flush) else { return !line.contains("more dropped") && kitty(Substring(line)) }
        let drops = line[named.upperBound...].components(separatedBy: "; ").map { Substring($0) }
        guard let count = line.range(of: #"parser replies: \d+ "#, options: .regularExpression)
            .flatMap({ Int(line[$0].dropFirst("parser replies: ".count).dropLast()) }) else { return false }
        return drops.count == count && drops.allSatisfy(kitty)
    }

    @Test func onlyKittyGraphicsDropsPass() {
        let kitty = "parser (pid 9) reply dropped, it is no reply: 12 bytes, ESC_Gi=31;OKESC\\"
        #expect(Self.onlyKittyGraphicsDropped("12:00 watchdog: session X's " + kitty))
        #expect(!Self.onlyKittyGraphicsDropped("12:00 watchdog: session X's " + kitty + " (and 1 more dropped since the last line)"))
        #expect(!Self.onlyKittyGraphicsDropped("12:00 watchdog: session X's parser (pid 9) reply dropped, no cursor position query is pending: 6 bytes, ESC[1;1R"))
        let flush = "12:00 watchdog: session X's parser replies: 2 more dropped since the last line, as its parser stopped: "
        #expect(Self.onlyKittyGraphicsDropped(flush + kitty + "; " + kitty))
        #expect(!Self.onlyKittyGraphicsDropped(flush + kitty + "; parser (pid 9) reply dropped, it is no reply: 3 bytes, ESC[I"))
        #expect(!Self.onlyKittyGraphicsDropped(flush + kitty))
        #expect(!Self.onlyKittyGraphicsDropped(flush.replacingOccurrences(of: ": 2 ", with: ": 5 ") + [kitty, kitty, kitty, kitty, "…"].joined(separator: "; ")))
    }

    /// `claude --version`, in the scratch home with the config folder: what it prints, or why it printed nothing.
    static func version(of claude: String, home: String, config: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["--version"]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": config.path, "DISABLE_AUTOUPDATER": "1"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "didn't start" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard waitForEnd(process, within: 60) else { return "didn't end" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds (`on`) or takes out the project's entry in the config folder's `.claude.json`, as
    /// `RealClaudeStatusTests.trust` does: trusted and onboarded. Not a credential. The rest of the file is kept; it is
    /// written whole beside it, 0600, and renamed into place.
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
