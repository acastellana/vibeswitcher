import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// One real Codex worker through the session host, on demand only (it spends the Codex account's usage):
/// `VIBESWITCHER_REAL_CODEX_HOME=<your Codex home> bash scripts/test.sh --filter CodexWorkerHostRunTests`.
/// As `WorkerToolsTests`: a scratch host, the real `vibeswitcher-mcp` as the lead in its session, and the project's
/// Codex preset the real Codex CLI (through a wrapper that points it at your Codex home). The lead adds a codex task and
/// starts it; Codex, trusted on its command line, gets its tools, calls progress and reports done; then, idle, it's
/// messaged, and must call progress with what the message asks. Its idle screen is kept in
/// `.build/codex-capture/idle-screen.json` (text and styled runs), for `LeadDelivery`'s Codex composer tests.
///
/// As of 2026-11-01 (Codex CLI 0.160.0) it fails at start_worker: under the host, with no view attached, Codex's TUI
/// answers its terminal queries' replies, enters the alternate screen and redraws, but every frame is blank and it
/// starts no MCP server within the tool server's 45 s (no worker tool-server log at all), so start_worker ends it. On
/// failure it prints the screen, Codex's raw output (recorded by `script` in the wrapper) and the tool servers' logs.
@Suite(.serialized) struct CodexWorkerHostRunTests {
    let temp = Scratch()

    static let codexHome = ProcessInfo.processInfo.environment["VIBESWITCHER_REAL_CODEX_HOME"]

    @Test(.enabled(if: codexHome != nil, "spends Codex usage: set VIBESWITCHER_REAL_CODEX_HOME to run it"))
    func aRealCodexWorkerGetsItsToolsReportsAndTakesAMessageWhileIdle() throws {
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

        // The project's Codex command: the real CLI, with your Codex home (its sign-in) and Homebrew's node on PATH.
        let codex = dir + "/codex"
        // The session's environment is the host's: the scratch home goes in here, as the fake claude's does in WorkerToolsTests.
        try "#!/bin/sh\nexport \(env) CODEX_HOME='\(try #require(Self.codexHome))' PATH=\"/opt/homebrew/bin:$PATH\"\nexec /usr/bin/script -q '\(dir)/codex-tty.log' /opt/homebrew/bin/codex \"$@\"\n"
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
        let leadSession = try app.spawn("set +m; export \(env); cd '\(root)'; while [ ! -f '\(lead)/go' ]; do sleep 0.05; done; "
            + "tail -n +1 -f '\(lead)/a.in' | '\(mcp)' --root '\(root)' --role lead > '\(lead)/a.out' 2> '\(lead)/a.err' & wait", cwd: root)
        guard case .grant(let grant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no lead grant"); return
        }
        #expect(book.answer(.bind(grant: grant, root: root, session: leadSession.id.uuidString), from: .app) == .ok)
        FileManager.default.createFile(atPath: lead + "/go", contents: nil)

        let server = LeadToolServerHandoverTests.Server(folder: lead, name: "a")
        #expect(try server.ask(1, "initialize", ["protocolVersion": "2025-06-18"]) != nil, "stderr: \(server.errors)")
        guard let added = try server.call(3, "add_task", [
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
            guard eventually(timeout: 10, { app.reply(to: seq) != nil }) else { return nil }
            switch app.reply(to: seq) {
            case .styledScreenText(_, let text, let runs, let focus)?: return LeadDelivery.Screen(text: text, runs: runs, focusEvents: focus)
            case .screenText(_, let text)?: return LeadDelivery.Screen(text: text)
            default: return nil
            }
        }
        // What it shows while it starts, kept for a start that fails (its session is ended then).
        nonisolated(unsafe) var seen = ""
        let watching = Thread {
            let until = Date().addingTimeInterval(55)
            while Date() < until {
                if let id = workerSession(), let text = styled(id)?.text { seen = text }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        watching.start()
        let started = try server.call(4, "start_worker", ["task": "add-hello"])
        if started?.isError != false {
            print("CODEX SCREEN WHILE STARTING:\n\(seen)")
            let raw = (try? Data(contentsOf: URL(fileURLWithPath: dir + "/codex-tty.log"))) ?? Data()
            let logs = FileManager.default.enumerator(atPath: vibe)?.compactMap { $0 as? String }.filter { $0.contains("mcp") && !$0.hasSuffix(".sock") } ?? []
            for file in logs { print("TOOL SERVER LOG \(file):\n" + ((try? String(contentsOfFile: vibe + "/" + file, encoding: .utf8)).map { String($0.suffix(1500)) } ?? "(folder)")) }
            print("CODEX RAW OUTPUT (\(raw.count) bytes): \(String(decoding: raw.prefix(3000), as: UTF8.self).debugDescription)")
        }
        // Its tools connected within the tool server's 45 s, or start_worker says it ended it.
        #expect(started?.isError == false, "start_worker: \(started?.text ?? "no answer"); stderr: \(server.errors)")
        let board = { BoardStore(root: root).load().task("add-hello") }
        let worker = try #require(board()?.worker.flatMap(UUID.init(uuidString:)), "no worker on the board")
        defer { _ = app.send(.kill(id: worker)) }
        // Until its report is on the board (10 minutes at most): the board's file is the event, read as it changes.
        let reported = eventually(timeout: 600) { board()?.report != nil }
        let screen = { styled(worker) }
        print("CODEX WORKER BOARD: status \(board()?.status.rawValue ?? "?"), checkpoints \(board()?.checkpoints?.map(\.text) ?? []), report \(board()?.report ?? "none")")
        print("CODEX SCREEN AFTER REPORT:\n\(screen()?.text ?? "none")")
        #expect(reported, "no report; screen:\n\(screen()?.text ?? "none")")
        #expect(Git.run(["show", "agent/add-hello:hello.txt"], in: root).output == "hi")
        #expect(board()?.checkpoints?.isEmpty == false, "no progress call")

        // Idle once its turn is over: its screen kept for the composer tests.
        _ = eventually(timeout: 60) { screen().map { LeadDelivery.box(in: $0) == .empty } ?? false }
        if let shown = screen() {
            let capture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/codex-capture")
            try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
            try JSONEncoder().encode(CapturedScreen(text: shown.text, runs: shown.runs)).write(to: capture.appendingPathComponent("idle-screen.json"))
            #expect(LeadDelivery.box(in: shown) == .empty, "Codex's idle box isn't read as empty:\n\(shown.text)")
        }
        // A message to it while idle is typed in as its next prompt, and it acts on it.
        let before = board()?.checkpoints?.count ?? 0
        let sent = try server.call(5, "message", ["task": "add-hello", "text": "Call progress once with exactly the text PONG-42, then stop."])
        print("CODEX MESSAGE: \(sent?.text ?? "no answer")")
        #expect(sent?.isError == false && sent?.text.contains("Typed") == true, "\(sent?.text ?? "no answer")")
        let answered = eventually(timeout: 300) { (board()?.checkpoints ?? []).dropFirst(before).contains { $0.text.contains("PONG-42") } }
        #expect(answered, "no PONG-42 progress; screen:\n\(screen()?.text ?? "none")")
    }

    struct CapturedScreen: Codable {
        var text: String
        var runs: [ScreenRun]?
    }
}
