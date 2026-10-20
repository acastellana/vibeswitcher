import Foundation
import Testing
@testable import VibeCore

/// 2026-10-19 and 20: a worker on an interactive listing, then a verifier on a scratch script, each stalled on a
/// permission prompt, and the lead only had the start of it ("Run: S=/private/var/folders/…/scratchpad; H=/Users/albert/
/// dev/vibeswitcher/.vibeswitcher/wo…") and read_session had no prompt at all. Now the prompt is told in full.
struct PendingPromptTests {
    /// The verifier's scratch script, as long as it was (several lines, past the old cut).
    static let script = """
    S=/private/var/folders/claude-501/-Users-albert-dev-vibeswitcher--vibeswitcher-worktrees-a-role-session-s/8cc3f75f/scratchpad; \
    H=/Users/albert/dev/vibeswitcher/.vibeswitcher/worktrees/a-role-session-s
    cd "$H" && bash scripts/test.sh --filter PendingPrompt > "$S/run1.txt" 2>&1
    grep -E "passed|failed" "$S/run1.txt" | tail -3
    """

    static func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    static func call(_ id: String, _ name: String, _ input: [String: Any], at: String) -> String {
        line(["type": "assistant", "isSidechain": false, "timestamp": at,
              "message": ["role": "assistant", "stop_reason": "tool_use", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }

    static func result(_ id: String, at: String) -> String {
        line(["type": "user", "isSidechain": false, "timestamp": at,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])
    }

    static let prompt = line(["type": "user", "isSidechain": false, "timestamp": "2026-10-20T07:40:00.000Z",
                              "message": ["role": "user", "content": "Start on your task"]])

    static func transcript(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    // MARK: The transcript's pending call

    @Test func theCallWithNoResultIsPendingInFull() throws {
        let data = Self.transcript([Self.prompt, Self.call("t1", "Read", ["file_path": "/a"], at: "2026-10-20T07:41:00.000Z"),
                                    Self.result("t1", at: "2026-10-20T07:41:01.000Z"),
                                    Self.call("t2", "Bash", ["command": Self.script, "description": "Run the suite"], at: "2026-10-20T07:52:10.000Z")])
        let tail = try #require(TranscriptTail.read(data))
        #expect(tail.state == .toolCall)
        let pending = try #require(tail.pending)
        #expect(pending.text == "Run: " + Self.script)
        #expect(pending.since == ChatReader.date("2026-10-20T07:52:10.000Z")?.timeIntervalSince1970)
    }

    /// Calls made together: one answered, the other still waiting on its prompt.
    @Test func ofCallsMadeTogetherTheUnansweredOneIsPending() throws {
        let data = Self.transcript([Self.prompt, Self.call("t1", "Bash", ["command": "ls /var/log"], at: "2026-10-20T07:52:00.000Z"),
                                    Self.call("t2", "Bash", ["command": "rm -rf build"], at: "2026-10-20T07:52:00.100Z"),
                                    Self.result("t2", at: "2026-10-20T07:52:01.000Z")])
        let tail = try #require(TranscriptTail.read(data))
        #expect(tail.pending?.text == "Run: ls /var/log")
    }

    @Test func nothingIsPendingOnceAnsweredOrBetweenTurns() throws {
        let answered = Self.transcript([Self.prompt, Self.call("t1", "Bash", ["command": "ls"], at: "2026-10-20T07:52:00.000Z"),
                                        Self.result("t1", at: "2026-10-20T07:52:01.000Z")])
        #expect(try #require(TranscriptTail.read(answered)).pending == nil)
        #expect(try #require(TranscriptTail.read(Data(Recorded.finishedTranscript.utf8))).pending == nil)
        // A call from an earlier turn, its result never written (the turn was interrupted), isn't this turn's.
        let earlier = Self.transcript([Self.call("t1", "Bash", ["command": "ls"], at: "2026-10-20T07:50:00.000Z"), Self.prompt])
        #expect(try #require(TranscriptTail.read(earlier)).pending == nil)
    }

    @Test func eachKindOfPromptInWords() {
        #expect(PendingPrompt.text(toolName: "Bash", input: ["command": "ls /var/log", "description": "List"]) == "Run: ls /var/log")
        let question = PendingPrompt.text(toolName: "AskUserQuestion", input: ["questions": [
            ["question": "Which listing?", "options": [["label": "Long", "description": "ls -l"], ["label": "Short"]]],
            ["question": "Hidden files too?", "options": [["label": "Yes"], ["label": "No"]]],
        ]])
        #expect(question == "Which listing?\n  - Long: ls -l\n  - Short\nHidden files too?\n  - Yes\n  - No")
        #expect(PendingPrompt.text(toolName: "ExitPlanMode", input: ["plan": "# Plan\n1. a"]) == "Plan ready:\n# Plan\n1. a")
        #expect(PendingPrompt.text(toolName: "mcp__vibeswitcher__merge", input: ["task": "x"]) == "Allow: merge (vibeswitcher)\n{\"task\":\"x\"}")
    }

    // MARK: How it's quoted

    @Test func aShortOneIsQuotedInlineALongOneFencedAndCutPast2000() {
        #expect(PendingPrompt(text: "Run: ls /var/log").quoted == "“Run: ls /var/log”")
        let script = PendingPrompt(text: "Run: " + Self.script).quoted
        #expect(script == "```\nRun: \(Self.script)\n```")
        // One line, but long.
        let long = "Run: echo " + String(repeating: "word ", count: 60)
        #expect(PendingPrompt(text: long).quoted.hasPrefix("```\nRun: echo word"))
        // Backticks inside: the fence is longer than any run of them.
        #expect(PendingPrompt(text: "Run: echo ```x```\nls").quoted.hasPrefix("````\n"))
        // Past 2,000 characters: cut at a word, with a note.
        let huge = PendingPrompt(text: "Run: " + String(repeating: "abcdefghi ", count: 300)).quoted
        let body = huge.components(separatedBy: "\n```\n")[0].dropFirst(4)
        #expect(body.count <= 2_000 && body.count > 1_980)
        #expect(huge.hasSuffix("\n(cut at 2000 characters; \(3_004 - body.count) more not shown)"), "\(huge.suffix(80))")
        // At 2,000 exactly, nothing is cut.
        let exact = "Run: " + String(repeating: "x", count: 1_995)
        #expect(!PendingPrompt(text: exact).quoted.contains("cut at"))
    }

    @Test func credentialsInItAreMasked() {
        let quoted = PendingPrompt(text: "Run: curl -H 'Authorization: Bearer sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789' x").quoted
        #expect(!quoted.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    @Test func sinceWhenAndTheMarker() {
        let since = Date(timeIntervalSince1970: 1_792_489_920)
        let prompt = PendingPrompt(text: "Run: ls", since: since.timeIntervalSince1970)
        #expect(prompt.waited(now: since + 6 * 60 + 30) == "since \(LeadBoard.clock(since.timeIntervalSince1970)) (6 min)")
        #expect(prompt.marker(now: since + 6 * 60 + 30) == "waiting for input (6 min)")
        #expect(PendingPrompt(text: "x").waited(now: since) == nil)
        #expect(PendingPrompt(text: "x").marker(now: since) == "waiting for input")
    }

    // MARK: The witness's report

    func board(_ status: LeadTask.Status, worker: String? = nil, verifier: String? = nil) -> LeadBoard {
        var task = LeadTask(slug: "scratch", title: "scratch", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = status
        task.worker = worker
        task.verifier = verifier
        var board = LeadBoard()
        board.tasks = [task]
        return board
    }

    @Test func theWitnessQuotesTheWholeCommandAndSaysSinceWhen() throws {
        let since = Date(timeIntervalSince1970: 1_792_489_920)
        let now = since + 7 * 60
        let cut = "Run: S=/private/var/folders/…/scratchpad; H=/Users/albert/dev/vibeswitcher/.vibeswitcher/wo…"
        let pending = PendingPrompt(text: "Run: " + Self.script, since: since.timeIntervalSince1970 - 3)
        let seen = LeadWitness.Seen(live: true, status: .needsInput, since: since, detail: cut, pending: pending, activity: .needsInput(cut))
        for (board, who) in [(board(.running, worker: "w1"), "worker"), (board(.review, worker: "w0", verifier: "w1"), "verifier")] {
            let event = try #require(LeadWitness.events(board: board, seen: ["w1": seen], now: now).first)
            #expect(event.text.hasPrefix("The \(who) on scratch is waiting for input since \(LeadBoard.clock(since.timeIntervalSince1970)) (7 min). It waits on:\n```\n"))
            #expect(event.text.contains("Run: " + Self.script))
            #expect(!event.text.contains("…"))
            #expect(LeadWake.short(SteerMessage(text: event.text, from: .system("witness"), agentPid: 1)) == "\(who) scratch waits for input")
        }
    }

    @Test func aShortOneInline() throws {
        let since = Date(timeIntervalSince1970: 1_792_489_920)
        let seen = LeadWitness.Seen(live: true, status: .needsInput, since: since, detail: "Run: ls",
                                    pending: PendingPrompt(text: "Run: ls -la /var/log"))
        let event = try #require(LeadWitness.events(board: board(.running, worker: "w1"), seen: ["w1": seen], now: since + 60).first)
        #expect(event.text == "The worker on scratch is waiting for input since \(LeadBoard.clock(since.timeIntervalSince1970)) (1 min): “Run: ls -la /var/log”. Answer it with message, or ask the user if it's theirs to decide.")
    }

    /// No transcript call to quote (a Codex question asked without waiting, a session whose transcript can't be read):
    /// what its hooks said, or that it's a question or a permission.
    @Test func withoutTheCallWhatTheHooksSaid() throws {
        let since = Date(timeIntervalSince1970: 1_792_489_920)
        for (detail, shown) in [("Which branch?", "“Which branch?”"), (nil, "“a question or a permission”")] as [(String?, String)] {
            let seen = LeadWitness.Seen(live: true, status: .needsInput, since: since, detail: detail)
            let event = try #require(LeadWitness.events(board: board(.running, worker: "w1"), seen: ["w1": seen], now: since + 60).first)
            #expect(event.text.contains(": \(shown). Answer it"), "\(event.text)")
        }
    }

    // MARK: What the lead's tools read

    @Test func theObserverTakesTheCallFromTheTranscriptAndTheTimeFromTheHooks() {
        var hook = HookState(agent: .claude, tty: "ttys006", lastEvent: "PermissionRequest", lastEventAt: 1_792_489_925)
        hook.request = "Run: S=/private/var/folders/…"
        let tail = TranscriptTail(state: .toolCall, at: 1_792_489_920, pending: PendingPrompt(text: "Run: " + Self.script, since: 1_792_489_920))
        let activity = LeadActivity.resolve(hook: hook, transcript: tail)
        #expect(LeadObserver.waiting(activity, hook: hook, tail: tail, program: nil) == PendingPrompt(text: "Run: " + Self.script, since: 1_792_489_925))
        // Working: nothing waits.
        #expect(LeadObserver.waiting(.working("Bash"), hook: nil, tail: tail, program: nil) == nil)
        // No hooks, but its program says it's blocked (OSC 7501).
        let program = ProgramStatus(state: .blocked, kind: "permission", message: "Bash command", since: Date(timeIntervalSince1970: 1_792_489_930))
        #expect(LeadObserver.waiting(.working(nil), hook: nil, tail: tail, program: program) == PendingPrompt(text: "Run: " + Self.script, since: 1_792_489_930))
        #expect(LeadObserver.waiting(.working(nil), hook: nil, tail: nil, program: program) == PendingPrompt(text: "Asks permission: Bash command", since: 1_792_489_930))
        // With hooks, they decide.
        #expect(LeadObserver.waiting(.working(nil), hook: hook, tail: tail, program: program) == nil)
    }

    @Test func sessionsAndStatusMarkIt() {
        let now = Date(timeIntervalSince1970: 1_792_489_920 + 8 * 60)
        var info = LeadSessionInfo(id: "s", cwd: "/r", label: "Worker: X", live: true, status: "needs input: Run: S=/private/var/folders/…", tty: nil,
                                   waiting: PendingPrompt(text: "Run: " + Self.script, since: 1_792_489_920))
        #expect(info.state(now: now, prompt: 40).hasPrefix("waiting for input (8 min): “Run: S=/private/var/folders/claude-501/"))
        #expect(info.state(now: now, prompt: 40).hasSuffix("…”"))
        info.waiting = nil
        #expect(info.state(now: now) == "needs input: Run: S=/private/var/folders/…")
        info.live = false
        #expect(info.state(now: now) == "ended")
    }

    @Test func readSessionsLastSection() {
        let since = 1_792_489_920.0
        let section = LeadToolset.waitingSection(PendingPrompt(text: "Run: " + Self.script, since: since), now: Date(timeIntervalSince1970: since + 120))
        #expect(section == "Waiting on: since \(LeadBoard.clock(since)) (2 min), the prompt it shows:\n```\nRun: \(Self.script)\n```")
    }
}

/// read_session, sessions and status over a fake host: a worker waiting on a prompt.
struct PendingPromptToolTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    @Test func readSessionEndsWithWhatItWaitsOnAndSessionsAndStatusMarkIt() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "one"])
        let worker = try #require(BoardStore(root: root).load().task("one")?.worker)
        // Its transcript, where the agents' transcripts are (the test's own home).
        let folder = URL(fileURLWithPath: VibePaths.home).appendingPathComponent(".claude/projects/pending-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("\(UUID().uuidString).jsonl")
        try PendingPromptTests.transcript([PendingPromptTests.prompt,
                                           PendingPromptTests.call("t1", "Bash", ["command": PendingPromptTests.script], at: "2026-10-20T07:52:10.000Z")])
            .write(to: file)
        runtime.transcripts[worker] = file.path

        // Not waiting: no section.
        let working = lead.call("read_session", ["task": "one"]).text
        #expect(!working.contains("Waiting on:"), "\(working)")

        let since = Date().timeIntervalSince1970 - 5 * 60 - 10
        runtime.waiting[worker] = PendingPrompt(text: "Run: " + PendingPromptTests.script, since: since)
        let read = lead.call("read_session", ["task": "one"]).text
        #expect(read.hasSuffix("\n\nWaiting on: since \(LeadBoard.clock(since)) (5 min), the prompt it shows:\n```\nRun: \(PendingPromptTests.script)\n```"), "\(read)")
        #expect(lead.call("sessions", [:]).text.contains("\(worker): Worker: One — waiting for input (5 min): “Run: S=/private/var/folders/"))
        #expect(lead.call("status", [:]).text.contains("worker waiting for input (5 min)"))

        // No conversation yet: the section still comes.
        runtime.transcripts[worker] = nil
        let none = lead.call("read_session", ["task": "one"]).text
        #expect(none.hasPrefix("No conversation yet") && none.contains("\n\nWaiting on: since"), "\(none)")

        // Its task finished two hours ago and it still waits: its line says both (see RoleSessionsEndTests).
        runtime.statuses[worker] = "needs input: Run: S=/private/var/folders/…"
        try BoardStore(root: root).update { board in
            guard let index = board.taskIndex("one") else { return }
            board.tasks[index].status = .abandoned
        }
        try BoardStore(root: root).update { board in
            guard let index = board.taskIndex("one") else { return }
            board.tasks[index].since = Date().timeIntervalSince1970 - 7_200
        }
        let line = try #require(lead.call("sessions", [:]).text.split(separator: "\n").first { $0.contains(worker) })
        #expect(line.contains("— waiting for input (5 min): “Run: S=/private/var/folders/") && line.hasSuffix(" — stranded (task finished 2.0 h ago)"), "\(line)")
    }
}
