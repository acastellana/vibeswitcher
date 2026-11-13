import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// One real Codex worker through the session host, on demand only (it spends the Codex account's usage):
/// `VIBESWITCHER_REAL_CODEX_HOME=<your Codex home> bash scripts/test.sh --filter CodexWorkerHostRunTests`.
/// As `WorkerToolsTests`: a scratch host, the real `vibeswitcher-mcp` as the lead in its session, and the project's
/// Codex preset the real Codex CLI, in a scratch Codex home (`<scratch home>/.codex`) that has only your Codex home's
/// sign-in (auth.json, copied) and VibeSwitcher's Codex hooks, run from this build (`vibeswitcher-hook codex`) and trusted
/// the way the app trusts them (`codex app-server`: hooks/list, config/batchWrite). The lead adds a codex task and
/// starts it; Codex, trusted on its command line, gets its tools, calls progress and reports done. Then, idle (its
/// hooks say its turn is over, its composer reads empty), it's messaged and must call progress with what the message
/// asks; and a message left in its inbox is typed in by the app's flush (`LeadController.flush`, done here as it does
/// it) and acted on too. Its idle screen is kept in `.build/codex-capture/idle-screen.json` (text and styled runs),
/// for `LeadDelivery`'s Codex composer tests.
///
/// Until 2026-11-01 (Codex CLI 0.160.0) it failed at start_worker: every hosted session started on a 0×0 terminal (the
/// host closed its slave before the program reopened it, which clears the size on macOS), where Codex's TUI draws only
/// blank frames; and Codex never applied the `projects."<path>".trust_level` key, so it sat on its trust prompt and
/// started no MCP server (see `PTYSpawn.spawn`, `LeadLaunch.prepareCodex`). Its hooks then wrote nothing: this test's
/// host runs under the Claude Code session that runs the tests, which the hook took for an outer agent (see
/// `HookOwner.lineage`). Codex runs straight on the session's terminal (a `script` in between would hide it from the
/// agent scan); the wrapper records the terminal's settings, printed with the screen and the tool servers' logs on a
/// failed start.
@Suite(.serialized) struct CodexWorkerHostRunTests {
    let temp = Scratch()

    static let codexHome = ProcessInfo.processInfo.environment["VIBESWITCHER_REAL_CODEX_HOME"]

    @Test(.enabled(if: codexHome != nil, "spends Codex usage: set VIBESWITCHER_REAL_CODEX_HOME to run it"))
    func aRealCodexWorkerGetsItsToolsReportsAndTakesAMessageWhileIdle() async throws {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        let made = temp.adopt(URL(fileURLWithPath: "\(shortScratchRoot)/vscx-\(UUID().uuidString.prefix(8))"))
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        let dir = made.resolvingSymlinksInPath().path
        let home = dir + "/home", vibe = home + "/.vibeswitcher", root = dir + "/repo", lead = dir + "/lead"
        for folder in [vibe, root + "/.vibeswitcher", lead] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }

        let book = LeadVault.Book()
        let host = try TestHost(vault: book)
        let app = try TestClient(host)
        try FileManager.default.createSymbolicLink(atPath: vibe + "/host.sock", withDestinationPath: host.socket)
        try JSONEncoder().encode(MacLimits(maxSessions: 10, loadThreshold: 100_000)).write(to: URL(fileURLWithPath: vibe + "/mac-limits.json"))
        // Codex workers are refused unless the lead's tool server says otherwise (`LeadLaunch.codexWorkersUsable`).
        let env = "HOME='\(home)' CFFIXED_USER_HOME='\(home)' VIBESWITCHER_HOME='\(vibe)' VIBESWITCHER_CODEX_WORKERS=1"

        // The scratch Codex home: your sign-in, and VibeSwitcher's hooks from this build, trusted.
        let codexHome = home + "/.codex"
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: try #require(Self.codexHome) + "/auth.json", toPath: codexHome + "/auth.json")
        chmod(codexHome + "/auth.json", 0o600)
        let hook = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-hook").path
        try #require(FileManager.default.isExecutableFile(atPath: hook), "vibeswitcher-hook isn't built beside the host")
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]
        let handler: [String: Any] = ["type": "command", "command": "\(hook) codex", "timeout": 5]
        let hooks = ["hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [["hooks": [handler]]]) })]
        try JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: codexHome + "/hooks.json"))
        let trusted = try Self.trustHooks(codexHome: codexHome, cwd: root)
        try #require(trusted == events.count, "trusted \(trusted) of \(events.count) hooks")

        // The project's Codex command: the real CLI, with the scratch Codex home and Homebrew's node on PATH.
        let codex = dir + "/codex"
        // The session's environment is the host's: the scratch home goes in here, as the fake claude's does in WorkerToolsTests.
        try "#!/bin/sh\nexport \(env) CODEX_HOME='\(codexHome)' PATH=\"/opt/homebrew/bin:$PATH\"\n/bin/stty -a > '\(dir)/stty.log' 2>&1; /usr/bin/env | /usr/bin/grep -E '^(TERM|COLORTERM|TERM_PROGRAM|COLUMNS|LINES|NO_COLOR)=' > '\(dir)/env.log'\nexec /opt/homebrew/bin/codex \"$@\"\n"
            .write(toFile: codex, atomically: true, encoding: .utf8)
        chmod(codex, 0o755)
        try LaunchPresets(global: [], byProject: [root: [LaunchPreset(name: "Codex", kind: .codex, command: codex)]])
            .save(to: URL(fileURLWithPath: vibe + "/presets.json"))

        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        try "---\nauto_advance: false\n---\n".write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)

        FileManager.default.createFile(atPath: lead + "/a.in", contents: nil)
        let leadSession = try await app.spawn("set +m; export \(env); cd '\(root)'; while [ ! -f '\(lead)/go' ]; do sleep 0.05; done; "
            + "tail -n +1 -f '\(lead)/a.in' | '\(mcp)' --root '\(root)' --role lead > '\(lead)/a.out' 2> '\(lead)/a.err' & wait", cwd: root)
        guard case .grant(let grant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no lead grant"); return
        }
        #expect(book.answer(.bind(grant: grant, root: root, session: leadSession.id.uuidString), from: .app) == .ok)
        FileManager.default.createFile(atPath: lead + "/go", contents: nil)

        let server = LeadToolServerHandoverTests.Server(folder: lead, name: "a")
        await #expect(try server.ask(1, "initialize", ["protocolVersion": "2025-06-18"]) != nil, "stderr: \(server.errors)")
        guard let added = try await server.call(3, "add_task", [
            "title": "Add hello", "goal": "hello.txt holds the line `hi`, committed on this branch.", "agent": "codex",
            "acceptance": ["`git show HEAD:hello.txt` prints hi"], "boundaries": ["hello.txt only"],
            "context": "A scratch repository: no tests, no lints, no load runs, no screenshots. Your blind check: say in blind_check that you skipped it (a scratch task). "
                + "After you report, wait: the lead may message you."]) else {
            Issue.record("add_task didn't answer: \(server.errors)"); return
        }
        #expect(!added.isError, "\(added.text)")
        // The worker's session, and its screen as the host draws it, asked as the app (the test's own process is no
        // session's, so the host answers it nothing).
        let workerSession = { () -> UUID? in
            var found: UUID?
            app.with { client in
                for event in client.allEvents.reversed() {
                    if case .sessionChanged(let session) = event, session.label.hasPrefix("Worker:") { found = session.id; break }
                }
            }
            return found
        }
        let styled = { (id: UUID) -> LeadDelivery.Screen? in
            let seq = app.send(.styledScreen(id: id))
            guard eventuallyBlocking(timeout: 10, { app.reply(to: seq) != nil }) else { return nil }
            switch app.reply(to: seq) {
            case .styledScreenText(_, let text, let runs, let focus)?: return LeadDelivery.Screen(text: text, runs: runs, focusEvents: focus)
            case .screenText(_, let text)?: return LeadDelivery.Screen(text: text)
            default: return nil
            }
        }
        // What it shows while it starts, kept for a start that fails (its session is ended then).
        nonisolated(unsafe) var seen = ""
        // A task of its own, pausing between looks.
        let watching = Task {
            let until = Date().addingTimeInterval(55)
            while Date() < until {
                if let id = workerSession(), let text = styled(id)?.text { seen = text }
                await pause(1)
            }
        }
        defer { watching.cancel() }
        let started = try await server.call(4, "start_worker", ["task": "add-hello"])
        if started?.isError != false {
            print("CODEX SCREEN WHILE STARTING:\n\(seen)")
            let logs = FileManager.default.enumerator(atPath: vibe)?.compactMap { $0 as? String }.filter { $0.contains("mcp") && !$0.hasSuffix(".sock") } ?? []
            for file in logs { print("TOOL SERVER LOG \(file):\n" + ((try? String(contentsOfFile: vibe + "/" + file, encoding: .utf8)).map { String($0.suffix(1500)) } ?? "(folder)")) }
            print("CODEX TERMINAL: " + ((try? String(contentsOfFile: dir + "/stty.log", encoding: .utf8)) ?? "none"))
            print("CODEX ENVIRONMENT: " + ((try? String(contentsOfFile: dir + "/env.log", encoding: .utf8)) ?? "none"))
        }
        // Its tools connected within the tool server's 45 s, or start_worker says it ended it.
        #expect(started?.isError == false, "start_worker: \(started?.text ?? "no answer"); stderr: \(server.errors)")
        let board = { BoardStore(root: root).load().task("add-hello") }
        let worker = try #require(board()?.worker.flatMap(UUID.init(uuidString:)), "no worker on the board")
        defer { _ = app.send(.kill(id: worker)) }
        // Until its report is on the board (10 minutes at most): the board's file is the event, read as it changes.
        let reported = await eventually(timeout: 600) { board()?.report != nil }
        let screen = { styled(worker) }
        print("CODEX WORKER BOARD: status \(board()?.status.rawValue ?? "?"), checkpoints \(board()?.checkpoints?.map(\.text) ?? []), report \(board()?.report ?? "none")")
        print("CODEX SCREEN AFTER REPORT:\n\(screen()?.text ?? "none")")
        #expect(reported, "no report; screen:\n\(screen()?.text ?? "none")")
        #expect(Git.run(["show", "agent/add-hello:hello.txt"], in: root).output == "hi")
        #expect(board()?.checkpoints?.isEmpty == false, "no progress call")

        // Its session, its agent and what the tool server reads its turn by (its hooks' state, in the scratch home).
        var tty = "", hosted: HostSession?
        app.with { client in
            for event in client.allEvents.reversed() {
                if case .sessionChanged(let session) = event, session.id == worker { tty = session.tty; hosted = session; break }
            }
        }
        let session = try #require(hosted)
        let inbox = URL(fileURLWithPath: vibe)
        let observer = LeadObserver(home: home, stateFile: { URL(fileURLWithPath: vibe + "/state/\($0).json") })
        let agentPid = { ProcessTable.trySnapshot()?.values.filter { $0.tty == tty && $0.agent != nil }.min { $0.startTime < $1.startTime }?.pid }
        let pid = try #require(agentPid(), "no agent on \(tty)")
        // Idle once its hooks say its turn is over (its composer is drawn while it works too, so its box alone doesn't say).
        let idle = { observer.activity(session, agentPid: pid).betweenTurns && (screen().map { LeadDelivery.box(in: $0) == .empty } ?? false) }
        let wentIdle = await eventually(timeout: 120, idle)
        let hookState = { (try? String(contentsOfFile: vibe + "/state/\(tty).json", encoding: .utf8)) ?? "none" }
        #expect(wentIdle, "not between turns with an empty box: \(observer.activity(session, agentPid: pid).text); hooks: \(hookState())")
        // Its screen kept for the composer tests.
        if let shown = screen() {
            let capture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/codex-capture")
            try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
            try JSONEncoder().encode(CapturedScreen(text: shown.text, runs: shown.runs)).write(to: capture.appendingPathComponent("idle-screen.json"))
            #expect(LeadDelivery.box(in: shown) == .empty, "Codex's idle box isn't read as empty:\n\(shown.text)")
        }
        // A message to it while idle is typed in as its next prompt, and it acts on it.
        let before = board()?.checkpoints?.count ?? 0
        let sent = try await server.call(5, "message", ["task": "add-hello", "text": "Call progress once with exactly the text PONG-42, then stop."])
        print("CODEX MESSAGE: \(sent?.text ?? "no answer")")
        if sent?.text.contains("Typed") != true {
            let agents = ProcessTable.trySnapshot()?.values.filter { $0.tty == tty }.map { "\($0.pid) \($0.comm) agent \($0.agent.map { "\($0)" } ?? "none")" } ?? []
            print("CODEX TERMINAL \(tty) PROCESSES: \(agents)")
            print("CODEX HOOK STATE: " + hookState())
        }
        #expect(sent?.isError == false && sent?.text.contains("Typed") == true, "\(sent?.text ?? "no answer")")
        let answered = await eventually(timeout: 300) { (board()?.checkpoints ?? []).dropFirst(before).contains { $0.text.contains("PONG-42") } }
        #expect(answered, "no PONG-42 progress; screen:\n\(screen()?.text ?? "none")")

        // A message left in its inbox (sent while it worked, say) is typed in once it's idle, as the app's flush does it
        // (`LeadController.flush`): between turns by its hooks, its box empty, then `LeadDelivery.flush`.
        let checkpoints = board()?.checkpoints?.count ?? 0
        try SteerInbox.post(SteerMessage(text: "Call progress once with exactly the text PING-7, then stop.", from: .lead("lead"), agentPid: pid),
                            tty: tty, root: inbox)
        let flushed = await eventually(timeout: 120) {
            guard observer.activity(session, agentPid: pid).betweenTurns, let shown = screen(), LeadDelivery.box(in: shown) == .empty else { return false }
            var typed: String?
            LeadDelivery.flush(LeadAgent(pid: pid, tty: tty, session: worker.uuidString), betweenTurns: true, inputIsEmpty: { true },
                               typeInto: { typed = $0; return true }, root: inbox)
            guard let typed else { return false }
            _ = app.send(.inputUnit(id: worker, writes: ComposerText.writes(typed, bracketed: true), more: false))
            return true
        }
        #expect(flushed, "never between turns with an empty box: \(observer.activity(session, agentPid: pid).text); screen:\n\(screen()?.text ?? "none")")
        let pinged = await eventually(timeout: 300) { (board()?.checkpoints ?? []).dropFirst(checkpoints).contains { $0.text.contains("PING-7") } }
        #expect(pinged, "no PING-7 progress; screen:\n\(screen()?.text ?? "none")")
    }

    /// Trusts every hook in `codexHome` as the app trusts its own (`CodexTrust`): `codex app-server` lists them with
    /// their hashes, and their trust is written to that home's config. Returns how many it trusted.
    static func trustHooks(codexHome: String, cwd: String) throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome
        environment["PATH"] = "/opt/homebrew/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        Platform.Sockets.noSigPipe(input.fileHandleForWriting.fileDescriptor)
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        var buffer = Data()
        func send(_ message: [String: Any]) throws {
            try input.fileHandleForWriting.write(contentsOf: try JSONSerialization.data(withJSONObject: message) + Data([0x0A]))
        }
        func call(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            while true {
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], message["id"] as? Int == id else { continue }
                    if let error = message["error"] { throw CodexTrustFailure(text: "\(method): \(error)") }
                    return message["result"] as? [String: Any] ?? [:]
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw CodexTrustFailure(text: "codex app-server quit during \(method)") }
                buffer.append(chunk)
            }
        }
        _ = try call(1, "initialize", ["clientInfo": ["name": "vibeswitcher-tests", "title": "VibeSwitcher tests", "version": "0"]])
        try send(["jsonrpc": "2.0", "method": "initialized"])
        let listing = try call(2, "hooks/list", ["cwds": [cwd]])
        var trust: [String: Any] = [:]
        for entry in (listing["data"] as? [[String: Any]]) ?? [] {
            for hook in (entry["hooks"] as? [[String: Any]]) ?? [] {
                guard let key = hook["key"] as? String, let hash = hook["currentHash"] as? String,
                      ["untrusted", "modified"].contains(hook["trustStatus"] as? String ?? "") else { continue }
                trust[key] = ["trusted_hash": hash]
            }
        }
        guard !trust.isEmpty else { return 0 }
        _ = try call(3, "config/batchWrite", ["edits": [["keyPath": "hooks.state", "value": trust, "mergeStrategy": "upsert"]], "reloadUserConfig": true])
        return trust.count
    }

    struct CodexTrustFailure: Error, CustomStringConvertible {
        var text: String
        var description: String { text }
    }

    struct CapturedScreen: Codable {
        var text: String
        var runs: [ScreenRun]?
    }
}
