import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// docs/process/v2-acceptance.md, automated: each row a case named after it, run as a person runs it, on a scratch node
/// (`ScratchNode`: a scratch session host and the built server, its root and home its own, never `~/.vibeswitcher`)
/// with `FakeClaude` for every agent (no real one), through the built command line on a pty of its own with the typed
/// code (`runOnTerminal`), each asserting what the row says must happen. Where an agent would act, the fake is told
/// to (`EngineEndToEndTests.tell`) or calls its tool server as the agent would (`FakeClaude.Files.call`); what Claude
/// Code's hooks would write the case writes (`hook`). A row that truly needs a real Claude is skipped saying why.
///
/// Its cases run in parallel, about a minute in all on a 24-core machine (36 cases, 49 s, 2026-11-21), so the suite runs wherever
/// VibeNodeTests does: the Linux CI's core job, the full suite and `scripts/nightly.sh`. `scripts/e2e/node-acceptance.sh`
/// runs it alone (or one row); `VIBESWITCHER_ACCEPTANCE=0` leaves it out of a run (`NodeAcceptance.enabled`).
@Suite(NodeTraits.linuxOnly, .enabled(if: NodeAcceptance.enabled, "VIBESWITCHER_ACCEPTANCE=0 leaves the acceptance rows out"),
       .timeLimit(.minutes(10)))
struct NodeAcceptanceTests {
    private let scratch = Scratch()

    // MARK: A1-A2, the node

    @Test("A1: status shows the build, the host, the server, the sessions, the leads and the cards, with no error")
    func a1Status() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        // The default: 8 lines at most (2026-11-25, the text walk), none of the words a user can't act on.
        let short = try await node.run(["status"])
        let shortLines = short.output.split(separator: "\n")
        #expect(short.status == 0 && shortLines.count <= 8 && shortLines.first?.hasPrefix("node local: build ") == true, "\(short.output)")
        for word in ["snapshot", "seal", "vault", "hash", "guard rail", "review floor", "/non-systemd", "pid "] {
            #expect(!short.output.contains(word), "\(word): \(short.output)")
        }
        #expect(short.output.contains("more: vibeswitcher status --long"), "\(short.output)")
        let shown = try await node.run(["status", "--long"])
        #expect(shown.status == 0 && !shown.errors.lowercased().contains("error"), "\(shown.output)\(shown.errors)")
        let lines = shown.output.components(separatedBy: "\n")
        #expect(lines.contains { $0.hasPrefix("node local, server pid ") && $0.contains("build \(ScratchNode.commit)") }, "\(shown.output)")
        #expect(lines.contains { $0.hasPrefix("host pid \(node.hostPID) ") }, "\(shown.output)")
        #expect(lines.contains("No agent sessions."), "\(shown.output)")
        #expect(!shown.output.lowercased().contains("error"), "\(shown.output)")
        let status = try await node.statusJSON()
        for field in ["node", "server", "host", "sessions", "leads", "cards"] { #expect(status[field] != nil, "\(field): \(status.keys.sorted())") }
    }

    @Test("A2: config held shows a plain card, and config accept with the code clears it")
    func a2ConfigHeldAndAccept() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let held = try await node.run(["config", "held", repo.path])
        #expect(held.status == 0, "\(held.output)\(held.errors)")
        let card = try #require(ScratchNode.card(held.output, "config accept"), "\(held.output)")
        let accepted = try await node.runOnTerminal(["config", "accept", card])
        #expect(accepted.status == 0 && accepted.output.contains("accepted"), "\(accepted.output)\(accepted.errors)")
        // A receipt line (2026-11-25): what it was and whom it holds no more.
        let said = accepted.output.split(whereSeparator: \.isNewline).map { String($0).replacingOccurrences(of: "\r", with: "") }
        #expect(said.contains("accepted: nothing held") || said.contains { $0.hasPrefix("accepted: \(repo.lastPathComponent), ") && ($0.hasSuffix(" change") || $0.hasSuffix(" changes")) },
                "\(accepted.output)")
        let after = try await node.run(["config", "held", repo.path])
        #expect(after.status == 0 && (after.output.contains("nothing held") || after.output.contains("Nothing is held")), "\(after.output)\(after.errors)")
    }

    // MARK: A3, the page

    @Test("A3: web opens a page that pairs and gets the sessions, leads, cards and boards, every frame as the wire says")
    func a3Web() async throws {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let (session, _) = try await Self.newClaude(node)
        let opened = try LiveScratch.open(node)
        let page = try RawClient.ask(port: opened.port, "GET / HTTP/1.1", ["Host: 127.0.0.1:\(opened.port)"])
        #expect(page.status == 200 && String(decoding: page.body, as: UTF8.self).contains("<html"), "\(page.head)")
        #expect(page.head.contains("Content-Security-Policy: default-src 'none'"), "\(page.head)")
        let socket = try LivePage(port: opened.port)
        _ = try socket.send("auth", ["pair": .string(opened.code), "client": .string("test")])
        let hello = try #require(try socket.next())
        #expect(hello["kind"]?.string == "hello", "\(hello)")
        for (sub, collection) in [("s0", "node"), ("s1", "sessions"), ("s2", "leads"), ("s3", "cards"), ("s4", "boards")] {
            let id = try socket.send("subscribe", ["sub": .string(sub), "collection": .string(collection)])
            let reply = try #require(try socket.next())
            #expect(reply["re"]?.string == id && reply["ok"]?.bool == true, "\(collection): \(reply)")
            let snapshot = try #require(try socket.next())
            #expect(snapshot["kind"]?.string == "snapshot" && snapshot["sub"]?.string == sub, "\(snapshot)")
            if collection == "sessions" {
                #expect(snapshot["entries"]?.array?.contains { $0["id"]?.string == NodeIds.session(host: session.id) } == true, "\(snapshot)")
            }
        }
        #expect(socket.unsound.isEmpty, "\(socket.unsound)")
        // That the page renders them with no console error is a browser's to see: the WebApp's own tests render each view
        // (WebApp/tests), and the terminal's console is checked in a real Chrome by hand (the acceptance doc).
    }

    // MARK: A4-A9, a session of the user's

    @Test("A4: new starts a Claude session, listed in status")
    func a4New() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, _) = try await Self.newClaude(node, model: "haiku")
        #expect(session.command?.hasSuffix("--model 'haiku'") == true, "\(String(describing: session.command))")
        let id = NodeIds.session(host: session.id)
        #expect(await node.eventuallyStatus { Self.listed($0, id) != nil }, "\(node.said)")
        let shown = try await node.run(["status", "--long"])
        #expect(shown.output.contains(String(session.id.uuidString.lowercased().prefix(8))) || shown.output.contains(session.tty), "\(shown.output)")
    }

    @Test("A5: send types the message into the session, and the agent takes it; with a question open that takes words, it answers it")
    func a5Send() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, files) = try await Self.newClaude(node)
        let sent = try await node.runOnTerminal(["send", Self.short(session), "say hello in three words"])
        #expect(sent.status == 0 && sent.output.contains("sent: "), "\(sent.output)\(sent.errors)\n\(node.said)")
        _ = try await EngineEndToEndTests.prompt(files) { $0 == "say hello in three words" }
        // Its question that takes typed words: what's sent goes in as that answer, as the app's composer sends it.
        try EngineEndToEndTests.tell(files, ["op": "ask", "questions": [["question": "Which greeting?", "header": "Greeting",
                                                                         "options": [["label": "Hello"], ["label": "Hi"]], "multiSelect": false]]])
        try #require(await eventually(timeout: 60) { node.screen(session.id)?.contains("Type something.") == true }, "\(node.screen(session.id) ?? "")")
        let answered = try await node.runOnTerminal(["send", Self.short(session), "Howdy"])
        #expect(answered.status == 0 && answered.output.contains("answered: your words went in as the answer"), "\(answered.output)\(answered.errors)")
        #expect(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["reply"] as? String == "Thanks." }, "\(EngineEndToEndTests.state(files))")
        // The page's chat of a session is ScratchNodeTests.aPageFollowsASessionsChat's (the fake's transcript isn't in
        // Claude's own folders, where the node reads chats from).
    }

    @Test("A6: Claude's folder-trust dialog and a permission prompt each show as the session's prompt, and reply answers them")
    func a6Reply() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, files) = try await Self.newClaude(node)
        let id = NodeIds.session(host: session.id)
        try EngineEndToEndTests.tell(files, ["op": "trust"])
        try #require(await node.eventuallyStatus { Self.prompt($0, id)?.contains("Yes, I trust this folder") == true }, "\(node.said)")
        let trusted = try await node.runOnTerminal(["reply", Self.short(session), "2"])
        #expect(trusted.status == 0 && trusted.output.contains("answered: option 2"), "\(trusted.output)\(trusted.errors)")
        #expect(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["trusted"] as? Bool == true })

        try EngineEndToEndTests.tell(files, ["op": "permission", "command": "make clean"])
        try #require(await node.eventuallyStatus { Self.prompt($0, id)?.contains("Do you want to proceed?") == true }, "\(node.said)")
        // The prompt's options, each as the screen says it, in `status --json` (the acceptance run's A6 gap): what
        // `reply SESSION N` picks from.
        var options: [String]?
        _ = await node.eventuallyStatus { status in
            options = (Self.listed(status, id)?["prompt"] as? [String: Any])?["options"] as? [String]
            return options?.count == 3
        }
        #expect(options == ["Yes", "Yes, and don't ask again for this command", "No, and tell Claude what to do differently (esc)"], "\(String(describing: options))")
        let allowed = try await node.runOnTerminal(["reply", Self.short(session), "1"])
        #expect(allowed.status == 0 && allowed.output.contains("answered: option 1"), "\(allowed.output)\(allowed.errors)")
        #expect(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["reply"] as? String == "Allowed." })
        #expect(await node.eventuallyStatus { Self.listed($0, id)?["prompt"] is NSNull })
    }

    @Test("A7: send --now steers a working session mid-turn, nothing lost")
    func a7SendNow() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, files) = try await Self.newClaude(node)
        let pid = try #require((EngineEndToEndTests.state(files)["pid"] as? Int).map(Int32.init))
        try hook(node, ["hook_event_name": "UserPromptSubmit", "prompt": "Fix the parser"], tty: session.tty, pid: pid)
        let sent = try await node.runOnTerminal(["send", Self.short(session), "Use the new tokenizer", "--now"])
        #expect(sent.status == 0 && sent.output.contains("steered: "), "\(sent.output)\(sent.errors)\n\(node.said)")
        // At its next step its hook hands it over as the user's: nothing typed into its box mid-turn, nothing lost.
        let taken = leadsHookTakes(node, event: "PostToolUse", tty: session.tty, pid: pid)
        #expect(taken.messages.map(\.text) == ["Use the new tokenizer"] && taken.messages.map(\.from) == [.user], "\(taken.messages)")
        #expect(EngineEndToEndTests.prompts(files).isEmpty, "\(EngineEndToEndTests.prompts(files))")
    }

    @Test("A8: rename and pause are shown; end removes the session, and resume lists it")
    func a8RenamePauseEnd() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, _) = try await Self.newClaude(node)
        let (short, id) = (Self.short(session), NodeIds.session(host: session.id))
        let renamed = try await node.runOnTerminal(["rename", short, "Release notes"])
        #expect(renamed.status == 0, "\(renamed.output)\(renamed.errors)")
        #expect(await node.eventuallyStatus { Self.listed($0, id)?["name"] as? String == "Release notes" })
        let paused = try await node.runOnTerminal(["pause", short, "--hours", "2"])
        #expect(paused.status == 0 && paused.output.contains("paused: session \(short)"), "\(paused.output)\(paused.errors)")
        #expect(await node.eventuallyStatus { Self.listed($0, id)?["pausedUntil"] is String })
        let ended = try await node.runOnTerminal(["end", short])
        #expect(ended.status == 0 && ended.output.contains("ended: session \(short)"), "\(ended.output)\(ended.errors)")
        #expect(await node.eventuallyStatus { Self.listed($0, id) == nil })
        // Past the grace an ended session is kept for (`LeadEngine.openGrace`, 30 s), `resume` lists it.
        #expect(await Self.polled(timeout: 120) { (try? await node.run(["resume"]))?.output.contains(short) == true }, "\(node.said)")
    }

    @Test("A9: resume brings an ended session back in its conversation")
    func a9Resume() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let folder = node.root.appendingPathComponent("work").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (session, files) = try await Self.newClaude(node, folder: folder)
        let pid = try #require((EngineEndToEndTests.state(files)["pid"] as? Int).map(Int32.init))
        // Its conversation, as Claude Code's hooks name it, with its transcript in Claude's folder for the project.
        let conversation = UUID().uuidString.lowercased()
        let transcript = URL(fileURLWithPath: LeadLaunch.claudeProjectFolder(folder.path, home: node.home.path)).appendingPathComponent("\(conversation).jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (#"{"type":"user","cwd":"\#(folder.path)","sessionId":"\#(conversation)"}"# + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        try hook(node, ["hook_event_name": "SessionStart", "session_id": conversation, "transcript_path": transcript.path], tty: session.tty, pid: pid)
        try #require(await node.eventuallyStatus { Self.listed($0, NodeIds.session(host: session.id))?["agentSession"] as? String == conversation },
                     "\(node.said)")
        // The engine's record of the user's sessions (`engine.json`) has it with its conversation before it ends.
        let record = EngineState.url(root: node.root)
        try #require(await eventually(timeout: 60) { ((try? String(contentsOf: record, encoding: .utf8)) ?? "").contains(conversation) }, "\(node.said)")
        let short = Self.short(session)
        let ended = try await node.runOnTerminal(["end", short])
        #expect(ended.status == 0, "\(ended.output)\(ended.errors)")
        try #require(await Self.polled(timeout: 120) { (try? await node.run(["resume"]))?.output.contains(short) == true }, "\(node.said)")
        let resumed = try await node.runOnTerminal(["resume", short])
        #expect(resumed.status == 0, "\(resumed.output)\(resumed.errors)\n\(node.said)")
        let back = try #require(await Self.liveSession(node) { $0.id != session.id && $0.label == "Claude" }, "\(node.said)")
        #expect(back.cwd == folder.path && back.command?.hasSuffix("--resume '\(conversation)'") == true, "\(back)")
        #expect(await eventually(timeout: 60) { EngineEndToEndTests.state(node.fake.files(terminal: back.tty))["resume"] as? String == conversation })
    }

    // MARK: A10, the terminal on the page

    @Test("A10: the page's terminal of a hosted session is live and watch-only: keys go nowhere")
    func a10TerminalWatch() async throws {
        let node = try await ScratchNode(scratch, hostArguments: TerminalRelayTests.watchArguments)
        defer { node.stop() }
        let (session, files) = try await Self.newClaude(node)
        let page = try TermPage.paired(node)
        let id = try page.send("term.open", ["session": .string(NodeIds.session(host: session.id)), "cols": .int(120), "rows": .int(40)])
        let reply = try #require(try page.next()?.json, "no reply to term.open: \(node.said)")
        #expect(reply["re"]?.string == id && reply["ok"]?.bool == true && reply["result"]?["readOnly"]?.bool == true, "\(reply)")
        let stream = try #require(reply["result"]?["stream"]?.int.flatMap(UInt32.init(exactly:)), "\(reply)")
        let replay = try #require(try page.until { $0.term?.kind == 2 }, "no end of the replay: \(node.said)")
        let shown = String(decoding: replay.compactMap(\.term).filter { $0.kind == 1 }.flatMap(\.payload), as: UTF8.self)
        #expect(shown.contains("? for shortcuts"), "the session's live screen: \(shown.debugDescription)")
        // Live: what it draws next comes as it draws it.
        try EngineEndToEndTests.tell(files, ["op": "permission", "command": "make clean"])
        var live = ""
        _ = try page.until { item in
            guard let term = item.term, term.stream == stream, term.kind == 1 else { return false }
            live += String(decoding: term.payload, as: UTF8.self)
            return live.contains("Do you want to proceed?")
        }
        #expect(live.contains("Do you want to proceed?"), "\(live.debugDescription)")
        // Watch-only: a key from the page goes nowhere.
        try page.type("2", on: stream)
        try #require(await eventually(timeout: 60) { node.said.contains("terminal stream \(stream): input refused") }, "\(node.said)")
        #expect(EngineEndToEndTests.state(files)["mode"] as? String == "permission", "\(EngineEndToEndTests.state(files))")
    }

    // MARK: A11-A16, a project's lead and its team

    @Test("A11: lead with a goal starts the lead, which plans a task and starts its worker")
    func a11LeadWithAGoal() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let lead = try await Self.startLead(node, repo, goal: "add a subtract function with a test")
        #expect((EngineEndToEndTests.state(lead.tools)["prompt"] as? String)?.contains("add a subtract function with a test") == true)
        try EngineEndToEndTests.limits(node, maxSessions: 10)
        let worker = try await Self.planAndStart(node, lead, title: "Add subtract")
        #expect(worker.cwd.contains("/.vibeswitcher/worktrees/add-subtract"), "\(worker)")
        // Listed in status, and the board shows the task running.
        let listed = await node.eventuallyStatus { status in
            ((status["sessions"] as? [[String: Any]]) ?? []).contains { $0["terminal"] as? String == worker.tty }
        }
        let status = try await node.run(["status", "--long"])
        #expect(listed, "\(status.output)")
        let running = await Self.polled(timeout: 60) {
            let board = try? await node.run(["board", repo.path])
            return board?.output.contains("Add subtract") == true && board?.output.contains("1 waiting") == false
        }
        let board = try await node.run(["board", repo.path])
        #expect(running, "\(board.output)")
    }

    @Test("A12: board shows the task, and questions --wait ends with the lead's question as a card")
    func a12BoardAndQuestionsWait() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let lead = try await Self.startLead(node, repo, goal: "add a subtract function with a test")
        try lead.tools.call("add_task", ["title": "Add subtract", "goal": "Add subtract.", "acceptance": ["it builds"], "auto_advance": false])
        try #require(await eventually(timeout: 120) { lead.tools.calls().count == 2 }, "\(lead.tools.calls())")
        // The server's board is the one its refresh read (every 3 s): shown once it has.
        let shown = await Self.polled(timeout: 60) { (try? await node.run(["board", repo.path]))?.output.contains("Add subtract") == true }
        let board = try await node.run(["board", repo.path])
        #expect(shown, "\(board.output)\(board.errors)")
        async let waited = node.run(["questions", repo.path, "--wait"])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try lead.tools.call("ask_user", ["question": "Name it subtract or minus?", "options": ["subtract", "minus"]])
        let asked = try await waited
        #expect(asked.status == 0 && asked.output.contains("Name it subtract or minus?"), "\(asked.output)\(asked.errors)\n\(node.said)")
    }

    @Test("A12b: the lead's goals head its tasks on the board, and a task with none is called unsorted")
    func a12bGoalsHeadTheBoard() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let lead = try await Self.startLead(node, repo, goal: "add a subtract function with a test")
        let before = lead.tools.calls().count
        // One at a time, each answered before the next (the goal is there before a task names it).
        let calls: [(String, [String: Any])] = [
            ("add_goal", ["title": "Basic arithmetic", "done": "Add and subtract work with tests"]),
            ("add_task", ["title": "Add subtract", "goal": "Add subtract.", "acceptance": ["it builds"], "auto_advance": false, "goal_id": "basic-arithmetic"]),
            ("add_task", ["title": "Write the readme", "goal": "A readme.", "acceptance": ["it reads well"], "auto_advance": false]),
        ]
        for (index, (name, arguments)) in calls.enumerated() {
            try lead.tools.call(name, arguments)
            try #require(await eventually(timeout: 120) { lead.tools.calls().count == before + index + 1 }, "\(lead.tools.calls())")
        }
        // The last add's reply carries the reminder: one open task has no goal.
        #expect(lead.tools.text(of: lead.tools.calls()[before + 2]).contains("Goals: 1 open task has no goal (write-the-readme)"), "\(lead.tools.calls())")
        let shown = await Self.polled(timeout: 60) { (try? await node.run(["board", repo.path]))?.output.contains("Write the readme") == true }
        let board = try await node.run(["board", repo.path])
        #expect(shown, "\(board.output)\(board.errors)")
        let text = board.output
        let heading = try #require(text.range(of: "Goal: Basic arithmetic (1 to go of 1) — done means: Add and subtract work with tests"), "\(text)")
        let task = try #require(text.range(of: "Add subtract"), "\(text)")
        let unsorted = try #require(text.range(of: "Unsorted (no goal)"), "\(text)")
        let readme = try #require(text.range(of: "Write the readme"), "\(text)")
        #expect(heading.lowerBound < task.lowerBound && task.lowerBound < unsorted.lowerBound && unsorted.lowerBound < readme.lowerBound, "\(text)")
        let json = try await node.run(["board", repo.path, "--json"])
        let value = try #require(NodeWire.decode(NodeWire.Value.self, Data(json.output.utf8)), "\(json.output)")
        let first = try #require(value["boards"]?.array?.first)
        #expect(first["goals"]?.array?.first?["id"]?.string == "basic-arithmetic" && first["goals"]?.array?.first?["toGo"]?.int == 1, "\(first)")
        #expect(first["tasks"]?.array?.first { $0["slug"]?.string == "add-subtract" }?["goal"]?.string == "basic-arithmetic", "\(first)")
        #expect(WireSchema.check(first, as: "board", strict: true) == nil, "\(first)")
    }

    @Test("A12c: a task's estimate gives it a landing on the board, the same in its text and JSON")
    func a12cEstimatesLand() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let lead = try await Self.startLead(node, repo, goal: "add a subtract function with a test")
        let before = lead.tools.calls().count
        try lead.tools.call("add_task", ["title": "Add subtract", "goal": "Add subtract.", "acceptance": ["it builds"], "auto_advance": false,
                                         "likely_min": 30, "worst_min": 60])
        try #require(await eventually(timeout: 120) { lead.tools.calls().count == before + 1 }, "\(lead.tools.calls())")
        let shown = await Self.polled(timeout: 60) { (try? await node.run(["board", repo.path]))?.output.contains("Add subtract") == true }
        let board = try await node.run(["board", repo.path])
        #expect(shown && board.output.contains("Add subtract") && board.output.contains("· lands ~"), "\(board.output)\(board.errors)")
        #expect(board.output.contains("Estimates: fewer than 5 estimated merges here (0)"), "\(board.output)")
        let json = try await node.run(["board", repo.path, "--json"])
        let value = try #require(NodeWire.decode(NodeWire.Value.self, Data(json.output.utf8)), "\(json.output)")
        let first = try #require(value["boards"]?.array?.first)
        let task = try #require(first["tasks"]?.array?.first { $0["slug"]?.string == "add-subtract" }, "\(first)")
        #expect(task["estimate"]?["likelyMin"]?.int == 30 && task["estimate"]?["by"]?.string == "lead", "\(task)")
        #expect(task["forecast"]?["basis"]?.string == "estimated" && task["forecast"]?["likely"]?.string != nil, "\(task)")
        #expect(first["score"]?["enough"]?.bool == false && first["score"]?["correctionPct"]?.int == 100, "\(first)")
        #expect(WireSchema.check(first, as: "board", strict: true) == nil, "\(first)")
    }

    @Test("A13: answer and tell reach the lead, which takes them as the user's")
    func a13AnswerAndTell() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let lead = try await Self.startLead(node, repo, goal: "add a subtract function with a test")
        try lead.tools.call("ask_user", ["question": "Name it subtract or minus?", "options": ["subtract", "minus"]])
        let card = try await EngineEndToEndTests.card(node, question: "Name it subtract or minus?")
        let answered = try await node.runOnTerminal(["answer", card, "minus"])
        #expect(answered.status == 0 && answered.output.contains("answered: the lead is told"), "\(answered.output)\(answered.errors)")
        let typed = try await EngineEndToEndTests.prompt(lead.tools) { $0.hasSuffix("minus") }
        #expect(!typed.hasPrefix(LeadDelivery.prefix), "as the user's: \(typed)")
        // Its turn over (as its Stop hook would say), `tell` is typed in too, as the user's.
        try hook(node, ["hook_event_name": "Stop"], tty: lead.session.tty, pid: lead.pid)
        let told = try await node.runOnTerminal(["tell", repo.path, "Keep the tests fast"])
        #expect(told.status == 0 && told.output.contains("told: the lead"), "\(told.output)\(told.errors)")
        let took = try await EngineEndToEndTests.prompt(lead.tools) { $0.hasSuffix("Keep the tests fast") }
        #expect(!took.hasPrefix(LeadDelivery.prefix), "as the user's: \(took)")
    }

    @Test("A14: the task's audit by two finders, then its merge through the gate: the tests run, merged into main")
    func a14AuditAndMerge() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let team = try await Self.auditedTask(node, finders: 2, policy: "auto")
        #expect(team.verifiers == 2, "two finders: \(team.verifiers)")
        let merged = try await ScratchRunTests.reply(team.lead.tools, try ScratchRunTests.send(team.lead.tools, "merge", ["task": team.slug], seconds: 300),
                                                     timeout: 360)
        #expect(merged.contains("Merged \(team.slug) into main"), "\(merged)\n\(node.said)")
        #expect(try await scratchGit(team.repo.path, ["show", "main:src/parser.txt"]) == "Write the parser", "the worker's change on main")
        #expect(ScratchRunTests.ranForMerge(team.repo, task: team.slug), "the gate's tests: \(String(describing: BoardStore(root: team.repo.path).load().task(team.slug)?.receipt))")
    }

    @Test("A15: a merge touching a sensitive path waits for an approval card, and answer approves exactly the audited commit")
    func a15ApprovalCard() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let team = try await Self.auditedTask(node, finders: 1, policy: "ask_sensitive")
        let tools = team.lead.tools
        let held = try await ScratchRunTests.reply(tools, try ScratchRunTests.send(tools, "merge", ["task": team.slug]))
        let approval = LeadWorkflow.approval(of: team.commit)
        #expect(held.contains("Not merged yet") && held.contains(approval), "\(held)")
        let asking = "Merge \(team.slug) at \(team.commit.prefix(8))?"
        _ = try await ScratchRunTests.reply(tools, try ScratchRunTests.send(tools, "ask_user", ["question": asking, "options": [approval, "Not yet"],
                                                                                              "priority": "blocking", "task": team.slug]))
        let card = try await EngineEndToEndTests.card(node, question: asking)
        let shown = try await node.run(["questions"])
        #expect(shown.output.contains(card) && shown.output.contains(String(team.commit.prefix(8))), "\(shown.output)")
        let approved = try await node.runOnTerminal(["answer", card, approval])
        #expect(approved.status == 0, "\(approved.output)\(approved.errors)\n\(node.said)")
        #expect(try await ScratchRunTests.approved(node, team.repo, task: team.slug, commit: team.commit), "\(approved.output)")
        let merged = try await ScratchRunTests.reply(tools, try ScratchRunTests.send(tools, "merge", ["task": team.slug], seconds: 300), timeout: 360)
        #expect(merged.contains("Merged \(team.slug) into main"), "\(merged)\n\(node.said)")
    }

    @Test("A16: the lead's push request shows the remote without credentials; push pushes that commit, decline-push settles it")
    func a16PushAndDecline() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let origin = node.root.appendingPathComponent("origin.git").path
        for arguments in [["init", "-q", "--bare", "-b", "main", origin], ["-C", repo.path, "remote", "add", "origin", origin],
                          ["-C", repo.path, "push", "-q", "origin", "main"]] {
            _ = try await scratchGit(repo.path, arguments)
        }
        let lead = try await Self.startLead(node, repo, goal: "ship it")
        let first = try await scratchGit(repo.path, ["rev-parse", "HEAD"])
        let commit = try await Self.commitOnMain(repo, "Second")
        // The user's own commit on the base, accepted as theirs (`base show`, `base accept`), as the lead's refusal asks.
        try await node.acceptBase(repo, from: first)
        try await Self.askToPush(node, lead)
        let pushed = try await node.runOnTerminal(["push", repo.path])
        #expect(pushed.status == 0 && pushed.output.contains("Pushed"), "\(pushed.output)\(pushed.errors)\n\(node.said)")
        #expect(pushed.output.contains(origin) && !pushed.output.contains("@"), "the remote shown, no credentials: \(pushed.output)")
        #expect(Git.run(["--git-dir", origin, "rev-parse", "refs/heads/main"], in: repo.path).output == commit)

        _ = try await Self.commitOnMain(repo, "Third")
        try await node.acceptBase(repo, from: commit)
        try await Self.askToPush(node, lead)
        let declined = try await node.runOnTerminal(["decline-push", repo.path])
        #expect(declined.status == 0 && declined.output.lowercased().contains("declined"), "\(declined.output)\(declined.errors)")
        #expect(Git.run(["--git-dir", origin, "rev-parse", "refs/heads/main"], in: repo.path).output == commit, "nothing pushed")
    }

    @Test("A40: the lead fetches its remote and merges into the base what someone else pushed (fetch_remote, merge_remote)")
    func a40FetchAndMergeRemote() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        // merge_remote waits for the machine's load to drop below load_threshold before it tests (`waitForLoad`): the
        // test machine's own load isn't the case's (the CI flake of 2026-11-22: a loaded runner held it past its 300 s).
        try node.noLoadHold()
        let repo = try await Self.repository(node)
        let origin = node.root.appendingPathComponent("origin.git").path
        for arguments in [["init", "-q", "--bare", "-b", "main", origin], ["-C", repo.path, "remote", "add", "origin", origin],
                          ["-C", repo.path, "push", "-q", "origin", "main"]] {
            _ = try await scratchGit(repo.path, arguments)
        }
        let lead = try await Self.startLead(node, repo, goal: "keep up with the remote")
        // Someone else's commit on the remote: a clone of their own, pushed.
        let other = node.root.appendingPathComponent("other").path
        _ = try await scratchGit(node.root.path, ["clone", "-q", origin, other])
        _ = try await scratchGit(other, ["-c", "user.name=Other", "-c", "user.email=other@example.invalid", "commit", "-q", "--allow-empty", "-m", "Theirs"])
        _ = try await scratchGit(other, ["push", "-q", "origin", "main"])
        let theirs = try await scratchGit(other, ["rev-parse", "HEAD"])

        let fetched = try await ScratchRunTests.reply(lead.tools, try ScratchRunTests.send(lead.tools, "fetch_remote", [:]))
        #expect(!fetched.contains("Refused") && fetched.contains("1 commit"), "\(fetched)\n\(node.said)")
        let merged = try await ScratchRunTests.reply(lead.tools, try ScratchRunTests.send(lead.tools, "merge_remote", [:], seconds: 300), timeout: 360)
        #expect(merged.hasPrefix("Merged origin/main into main"), "\(merged)\n\(node.said)")
        #expect(try await scratchGit(repo.path, ["rev-parse", "main"]) == theirs, "a fast-forward: the base had nothing of its own")
        // The lead's own move: its next merge isn't refused for a base moved outside it.
        let again = try await ScratchRunTests.reply(lead.tools, try ScratchRunTests.send(lead.tools, "merge_remote", [:], seconds: 300), timeout: 360)
        #expect(!again.contains("moved"), "\(again)")
    }

    // MARK: A17, settings

    @Test("A17: settings shows a project's; set records it, the lead is told, and config held holds nothing for it")
    func a17SettingsAndSet() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let lead = try await Self.startLead(node, repo, goal: "keep going")
        let shown = try await node.run(["settings", repo.path])
        #expect(shown.status == 0 && shown.output.contains("max_workers"), "\(shown.output)\(shown.errors)")
        let set = try await node.runOnTerminal(["set", repo.path, "max_workers", "2"])
        #expect(set.status == 0 && set.output.contains("the project's lead is told"), "\(set.output)\(set.errors)\n\(node.said)")
        #expect(LeadWorkflow.load(from: ConfigHoldStore.workflowPath(root: repo.path)).maxWorkers == 2)
        // Told: typed into the idle lead, or waiting in its inbox for its next step.
        #expect(await eventually(timeout: 60) {
            node.inbox(lead.session.tty).contains { $0.agentPid == lead.pid && $0.text.contains("max_workers to 2") }
                || EngineEndToEndTests.prompts(lead.tools).contains { $0.contains("max_workers to 2") }
        }, "\(node.inbox(lead.session.tty)) \(EngineEndToEndTests.prompts(lead.tools))\n\(node.said)")
        let held = try await node.run(["config", "held", repo.path, "--long"])
        #expect(held.status == 0 && held.output.contains("nothing held"), "\(held.output)\(held.errors)")
        let rail = held.output.components(separatedBy: "\n").first { $0.contains("max_workers: 2") } ?? ""
        #expect(!rail.contains("changed since"), "set by the user, no second hold: \(held.output)")
    }

    // MARK: A18, presets

    @Test("A18: presets lists them; preset add is strict, its preset waits for config accept; new --preset starts one")
    func a18Presets() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let listed = try await node.run(["presets", repo.path])
        #expect(listed.status == 0 && listed.output.contains("Claude") && listed.output.contains("Shell"), "\(listed.output)\(listed.errors)")
        let refused = try await node.runOnTerminal(["preset", "add", "Evil", "--folder", repo.path, "--env", "LD_PRELOAD=/x.so"])
        #expect(refused.status == 77 && (refused.output + refused.errors).contains("LD_PRELOAD"), "strict: \(refused.output)\(refused.errors)")
        let added = try await node.runOnTerminal(["preset", "add", "Fast", "--folder", repo.path, "--args", "--model haiku"])
        #expect(added.status == 0 && added.output.contains("added: preset Fast"), "\(added.output)\(added.errors)")
        let early = try await node.runOnTerminal(["new", repo.path, "--preset", "Fast"])
        #expect(early.status != 0 && (early.output + early.errors).contains("accept"), "accept needed first: \(early.output)\(early.errors)")
        // A scratch node's presets file isn't where its home's seal watches (`<home>/.vibeswitcher` is a link to its root,
        // `SessionPresets.withPresetsToAccept`), so no accept covers it there: that the accepted file's preset starts is
        // SessionPresetsTests.aPresetOfTheFileStartsOnlyFromAnAcceptedFile's, on the host's own vault. A built-in preset
        // needs no accept, and starts through `new --preset`.
        let started = try await node.runOnTerminal(["new", repo.path, "--preset", "Shell"])
        #expect(started.status == 0 && started.output.contains("started: session"), "\(started.output)\(started.errors)\n\(node.said)")
        #expect(await Self.liveSession(node) { $0.label == "Shell" && $0.cwd == repo.path } != nil, "\(node.said)")
    }

    // MARK: A20, a restart

    @Test("A20: after a host restart and the accepts, lead --resume brings the lead back in its conversation and reopen the user's own sessions")
    func a20RestartResumeReopen() async throws {
        let (leadConversation, ownConversation) = (UUID().uuidString.lowercased(), UUID().uuidString.lowercased())
        let first = try await ScratchNode(scratch, holdFirstLook: true)
        let repo = try await Self.repository(first)
        let lead = try await Self.startLead(first, repo, goal: "plan the work")
        // The lead's transcript, as Claude writes it for `--name lead-repo`, its hook naming it.
        let leadTranscript = Self.transcript(first, folder: repo, conversation: leadConversation)
        try (#"{"type":"agent-name","agentName":"lead-repo","sessionId":"\#(leadConversation)"}"# + "\n").write(to: leadTranscript, atomically: true, encoding: .utf8)
        try hook(first, ["hook_event_name": "Stop", "transcript_path": leadTranscript.path], tty: lead.session.tty, pid: lead.pid)
        // A session of the user's, its conversation named by its hook.
        let folder = first.root.appendingPathComponent("proj").resolvingSymlinksInPath()
        let (own, ownFiles) = try await Self.newClaude(first, folder: folder)
        let ownPid = try #require((EngineEndToEndTests.state(ownFiles)["pid"] as? Int).map(Int32.init))
        let ownTranscript = Self.transcript(first, folder: folder, conversation: ownConversation)
        try (#"{"type":"user","sessionId":"\#(ownConversation)","cwd":"\#(folder.path)","message":{"content":"hello"}}"# + "\n")
            .write(to: ownTranscript, atomically: true, encoding: .utf8)
        try hook(first, ["hook_event_name": "Stop", "session_id": ownConversation, "transcript_path": ownTranscript.path], tty: own.tty, pid: ownPid)
        let record = EngineState.url(root: first.root)
        try #require(await eventually(timeout: 90) {
            let text = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
            return text.contains(leadConversation) && text.contains(ownConversation)
        }, "\(String(describing: try? String(contentsOf: record, encoding: .utf8)))\n\(first.said)")
        // The host goes down (`vs stop`'s end of the host, its sessions with it) and a new one starts on the same root.
        first.stop()
        let node = try await ScratchNode(scratch, holdFirstLook: true, reusing: first.root)
        defer { node.stop() }

        let status = try await node.statusJSON()
        let notices = (status["notices"] as? [String]) ?? []
        #expect(notices.contains { $0.contains("`vibeswitcher lead \(repo.path) --resume`") }, "\(notices)")
        #expect(notices.contains { $0.contains("vibeswitcher reopen") }, "\(notices)")
        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: Git.run(["rev-parse", "main"], in: repo.path).output)
        let resumed = try await node.runOnTerminal(["lead", repo.path, "--resume"])
        #expect(resumed.status == 0 && resumed.output.contains("same conversation"), "\(resumed.output)\n\(node.said)")
        let back = try #require(await Self.liveSession(node) { $0.label.hasPrefix("Lead · ") }, "\(node.said)")
        let backFiles = node.fake.files(terminal: back.tty)
        #expect(await eventually(timeout: 60) { EngineEndToEndTests.state(backFiles)["resume"] as? String == leadConversation },
                "\(EngineEndToEndTests.state(backFiles))")

        let reopened = try await node.runOnTerminal(["reopen", "all"])
        #expect(reopened.status == 0 && reopened.output.contains("reopened:"), "\(reopened.output)\n\(node.said)")
        let again = try #require(await Self.liveSession(node) { $0.label == "Claude" && $0.cwd == folder.path }, "\(node.said)")
        #expect(again.command?.hasSuffix("--resume '\(ownConversation)'") == true, "\(String(describing: again.command))")
    }

    // MARK: A21, a switch

    @Test("A21: switch to another installed build hands the node over; the user's sessions survive it, and hooks install after")
    func a21Switch() async throws {
        let (a, b) = (String(repeating: "a", count: 40), String(repeating: "b", count: 40))
        let installs = scratch.url("builds")
        let buildA = try ScratchBuilds.install(commit: a, into: installs)
        _ = try ScratchBuilds.install(commit: b, into: installs)
        let node = try await ScratchNode(scratch, build: buildA, installRoot: installs)
        defer { node.stop() }
        let (session, files) = try await Self.newClaude(node)
        let pid = EngineEndToEndTests.state(files)["pid"] as? Int
        let switched = try await node.runOnTerminal(["switch", b, "--long"])
        #expect(switched.status == 0 && switched.output.contains("handed over") && switched.output.contains("build \(b)"),
                "\(switched.output)\(switched.errors)\n\(node.said)")
        #expect(await node.eventuallyStatus { (($0["host"] as? [String: Any])?["notes"] as? [String: Any])?["build"] as? String == b }, "\(node.said)")
        // The same session, its agent the same process, and it still takes what the user sends.
        #expect(try node.sessions().contains { $0.id == session.id && $0.isLive }, "\(node.said)")
        #expect(EngineEndToEndTests.state(files)["pid"] as? Int == pid)
        let sent = try await node.runOnTerminal(["send", Self.short(session), "still here?"])
        #expect(sent.status == 0, "\(sent.output)\(sent.errors)\n\(node.said)")
        _ = try await EngineEndToEndTests.prompt(files) { $0 == "still here?" }
        let hooks = try await node.runOnTerminal(["hooks", "install", "--agent", "claude"])
        #expect(hooks.status == 0 && hooks.output.contains("Claude: hooks installed"), "\(hooks.output)\(hooks.errors)\n\(node.said)")
    }

    // MARK: A49, a switch with open cards and a paired page

    @Test("A49: vs switch with four open cards keeps each (id, version, draft), answers one by its old id after, and returns only once the new build's server answers and the paired page's listener is back")
    func a49SwitchKeepsCardsAndPage() async throws {
        let (a, b) = (String(repeating: "a", count: 40), String(repeating: "b", count: 40))
        let installs = scratch.url("builds")
        let buildA = try ScratchBuilds.install(commit: a, into: installs)
        // B's server differs by a byte, as every switch between commits: the server is replaced after the handover.
        var bytes = try Data(contentsOf: builtProducts.appendingPathComponent(BuildInfo.server))
        bytes.append(0)
        let padded = scratch.url("padded-server")
        try bytes.write(to: padded)
        _ = try ScratchBuilds.install(commit: b, into: installs, replacing: [BuildInfo.server: padded.path])
        let node = try await ScratchNode(scratch, holdFirstLook: true, build: buildA, hostArguments: LiveScratch.webArguments, installRoot: installs)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let lead = try await Self.startLead(node, repo, goal: "write the parser")
        // Four open cards: a question (with a page's draft), an approval, held config, a base move.
        try lead.tools.call("ask_user", ["question": "Which name for the parser?", "options": ["Parser", "Reader"]])
        let question = try await EngineEndToEndTests.card(node, question: "Which name for the parser?")
        let head = Git.run(["rev-parse", "main"], in: repo.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        try lead.tools.call("ask_user", ["question": "Merge the parser?", "options": ["Approve \(head)", "Not yet"]])
        let approval = try await EngineEndToEndTests.card(node, question: "Merge the parser?")
        let settings = repo.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"env":{"A49":"1"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        let held = try await node.run(["config", "held", repo.path])
        let config = try #require(ScratchNode.card(held.output, "config accept"), "\(held.output)")
        try "moved\n".write(to: repo.appendingPathComponent("moved.txt"), atomically: true, encoding: .utf8)
        _ = Git.run(["add", "moved.txt"], in: repo.path)
        _ = Git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "moved outside a team session"], in: repo.path)
        let shown = try await node.run(["base", "show", repo.path])
        let base = try #require(ScratchNode.card(shown.output, "base accept"), "\(shown.output)")
        let opened = try LiveScratch.open(node)
        let page = try LivePage(port: opened.port)
        _ = try page.send("auth", ["pair": .string(opened.code), "client": .string("test")])
        let token = try #require(try page.next()?["auth"]?["token"]?.string)
        let drafted = try page.send("draft", ["card": .string(question), "text": .string("Parser, keep Reader as an alias"), "version": .int(1)],
                                    action: UUID().uuidString.lowercased())
        let ack = try #require(try page.until { $0["re"]?.string == drafted }?.last)
        #expect(ack["ok"]?.bool == true, "\(ack)")
        let before = try #require(try await Self.cards(node))
        let ids = [question, approval, config, base]
        try #require(ids.allSatisfy { before[$0] != nil }, "\(before.keys.sorted())")
        try #require(await eventually(timeout: 60) { ids.allSatisfy { node.keptCards().contains($0) } && node.keptCards().contains("keep Reader") }, "\(node.said)")
        let serverBefore = try #require(node.serverPID)

        let switched = try await node.runOnTerminal(["switch", b, "--long"])
        #expect(switched.status == 0 && switched.output.contains("handed over") && switched.output.contains("the new build's server answers")
                && switched.output.contains("the web listener is back on port \(opened.port)"), "\(switched.output)\(switched.errors)\n\(node.said)")
        // Right after it returns, a command reaches the new build's server.
        let hello = try WireClient(node).hello
        #expect(hello.server.pid != serverBefore && hello.server.commit == b, "\(hello.server)")
        // The four cards, as they were.
        let after = try #require(try await Self.cards(node))
        for id in ids {
            let card = try #require(after[id], "\(id) not kept: \(after.keys.sorted())\n\(node.said)")
            #expect(card["code"] as? String == before[id]?["code"] as? String)
            #expect((card["question"] as? [String: Any])?["version"] as? Int == (before[id]?["question"] as? [String: Any])?["version"] as? Int)
        }
        #expect((after[question]?["draft"] as? [String: Any])?["text"] as? String == "Parser, keep Reader as an alias", "\(String(describing: after[question]))")
        #expect(!node.inbox(lead.session.tty).contains { $0.text.contains("no longer sees your open question") })
        // The page paired before the switch is let in again with its token.
        let again = try LivePage(port: opened.port)
        _ = try again.send("auth", ["token": .string(token), "client": .string("test")])
        let welcomed = try #require(try again.next())
        #expect(welcomed["kind"]?.string == "hello", "\(welcomed)")
        // Answered by its old id; the held config accepted by its old id too, and then (the seal no longer holding the
        // project's team) the lead gets the user's answer.
        let answered = try await node.runOnTerminal(["answer", question, "Parser"])
        #expect(answered.status == 0 && answered.output.contains("answered: the lead is told"), "\(answered.output)\(answered.errors)\n\(node.said)")
        let accepted = try await node.runOnTerminal(["config", "accept", config])
        #expect(accepted.status == 0 && accepted.output.contains("accepted"), "\(accepted.output)\(accepted.errors)\n\(node.said)")
        let posted = await eventually(timeout: 120) { node.inbox(lead.session.tty).contains { $0.text.hasSuffix(": Parser") && $0.from == .user } }
        #expect(posted, "\(node.inbox(lead.session.tty))\n\(node.said)")
    }

    /// The open cards `questions --json` lists, by id.
    static func cards(_ node: ScratchNode) async throws -> [String: [String: Any]]? {
        let ran = try await node.run(["questions", "--json"])
        guard ran.status == 0, let object = try? JSONSerialization.jsonObject(with: Data(ran.output.utf8)) as? [String: Any],
              let cards = object["cards"] as? [[String: Any]] else { return nil }
        return Dictionary(cards.compactMap { card in (card["id"] as? String).map { ($0, card) } }) { first, _ in first }
    }

    // MARK: A22-A23, who may act as the user

    @Test("A22: vibeswitcher answer run from inside a session is refused: not the user's voice")
    func a22AnswerFromASession() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let lead = try await Self.startLead(node, repo, goal: "ask something")
        try lead.tools.call("ask_user", ["question": "Which name for the parser?", "options": ["Parser", "Reader"]])
        let card = try await EngineEndToEndTests.card(node, question: "Which name for the parser?")
        let out = node.root.appendingPathComponent("answer.out")
        let environment = ["HOME": node.home.path, "VIBESWITCHER_HOME": node.root.path].map { "\($0.key)='\($0.value)'" }.joined(separator: " ")
        let asking = try await node.spawn("env \(environment) '\(commandLine.path)' answer \(card) the-second > '\(out.path).part' 2>&1; "
                                 + "echo \"status $?\" >> '\(out.path).part'; mv '\(out.path).part' '\(out.path)'; exec sleep 600", label: "Claude")
        // Should it ask for the card's code on the session's terminal first, it's typed there (a scratch session's), so
        // what refuses it is the voice, never a missing code.
        var code: String?
        _ = await eventually(timeout: 60) {
            code = node.screen(asking.id).flatMap { screen in
                screen.range(of: #"Type [A-Z0-9]{4,8} and Enter"#, options: .regularExpression).map {
                    String(screen[$0].dropFirst(5).prefix { $0 != " " })
                }
            }
            return code != nil || FileManager.default.fileExists(atPath: out.path)
        }
        if let code {
            _ = try await offPool { [socket = node.socket] in
                try HostCall.type(HostInput.writes(text: code, submit: true, key: nil), into: asking.id, socket: socket, appKey: nil, timeout: 10)
            }
        }
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: out.path) }, "\(node.screen(asking.id) ?? "")\n\(node.said)")
        let said = try String(contentsOf: out, encoding: .utf8)
        #expect(said.contains("status 77") && said.contains("not the user's voice") && said.contains("live session"), "\(said)")
        // Still open: the lead was told nothing.
        #expect(try await EngineEndToEndTests.listedCard(node, question: "Which name for the parser?", timeout: 5) == card)
    }

    @Test("A23: a page's token can't answer or send: refused, and it leaves only drafts")
    func a23PageTokenRefused() async throws {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let (session, files) = try await Self.newClaude(node)
        let page = try TermPage.paired(node)
        let kinds = Set(page.hello?["kinds"]?.array?.compactMap(\.string) ?? [])
        #expect(!kinds.contains("answer") && !kinds.contains("session.send") && !kinds.contains("session.reply"), "\(kinds.sorted())")
        let sessionID = NodeIds.session(host: session.id)
        for (kind, args) in [("answer", ["card": NodeWire.Value.string("0123abcd"), "answer": .string("A")]),
                             ("session.send", ["session": .string(sessionID), "text": .string("echo hi")]),
                             ("session.reply", ["session": .string(sessionID), "choice": .int(1)])] {
            let id = try page.send(kind, args, action: UUID().uuidString.lowercased())
            let reply = try #require(try page.until { $0.json?["re"]?.string == id }?.last?.json, "no reply to \(kind)")
            #expect(reply["ok"]?.bool != true && reply["error"] != nil, "\(kind): \(reply)")
        }
        // A draft it may leave: shown beside the session, nothing typed.
        let id = try page.send("session.draft", ["session": .string(sessionID), "text": .string("a draft from the page")],
                               action: UUID().uuidString.lowercased())
        let drafted = try #require(try page.until { $0.json?["re"]?.string == id }?.last?.json, "no reply to session.draft")
        #expect(drafted["ok"]?.bool == true, "\(drafted)")
        #expect(EngineEndToEndTests.prompts(files).isEmpty, "\(EngineEndToEndTests.prompts(files))")
    }

    // MARK: A26-A36, what landed on 2026-11-21

    @Test("A26: doctor lists what the node needs, each missing piece with the command to run")
    func a26Doctor() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let ran = try await node.run(["doctor"])
        #expect([0, 1].contains(ran.status) && !ran.output.isEmpty && !ran.errors.lowercased().contains("error"), "\(ran.output)\(ran.errors)")
        #expect(ran.output.contains("claude"), "it looks at Claude Code's link: \(ran.output)")
    }

    @Test("A27: brief says what happened and what is asked of you, written from the boards when no model is asked")
    func a27Brief() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let ran = try await node.run(["brief"])
        #expect(ran.status == 0, "\(ran.output)\(ran.errors)")
        #expect(ran.output.contains("No project lead is running and no session needs you.") && ran.output.contains("Nothing waits on you.")
                && ran.output.contains("(written from the boards and logs, no model asked)"), "\(ran.output)")
        let json = try await node.run(["brief", "--json"])
        let value = try #require(NodeWire.decode(NodeWire.Value.self, Data(json.output.utf8)), "\(json.output)")
        #expect(WireSchema.check(value, as: "brief.result") == nil, "\(json.output)")
    }

    @Test("A28: stats gives the week's figures with no error")
    func a28Stats() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let ran = try await node.run(["stats", "week"])
        #expect(ran.status == 0 && !ran.output.isEmpty && !ran.output.lowercased().contains("error"), "\(ran.output)\(ran.errors)")
    }

    @Test("A29: mail shows a project's messages between leads, which way each went and what became of it")
    func a29Mail() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let project = LeadMail.project(of: repo.path)
        try LeadMail.append(.init(at: Date().timeIntervalSince1970 - 60, from: "acme", to: project, kind: .question, text: "Which port?",
                                  outcome: .delivered, detail: "Delivered."), root: repo.path)
        let ran = try await node.run(["mail", repo.path])
        #expect(ran.status == 0 && ran.output.contains("Between leads · \(project) (1 message)") && ran.output.contains("from the lead of acme")
                && ran.output.contains("Which port?"), "\(ran.output)\(ran.errors)")
    }

    @Test("A30: settings --find keeps the settings holding every word, under the node's names")
    func a30SettingsFind() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let ran = try await node.run(["settings", "--find", "team sessions"])
        #expect(ran.status == 0 && ran.output.contains("node_max_sessions") && ran.output.contains("boost_max_sessions")
                && !ran.output.contains("lead_mail") && !ran.output.contains("mac_max_sessions"), "\(ran.output)\(ran.errors)")
        let none = try await node.run(["settings", "--find", "nothing-like-this"])
        #expect(none.status == 0 && none.output.contains("No setting matches"), "status \(none.status): \(none.output)\(none.errors)\n\(node.said)")
    }

    @Test("A31: new --agent codex starts the user's own Codex by its link (a stand-in here), labelled Codex")
    func a31Codex() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let folder = node.root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = try await node.runOnTerminal(["new", folder.path, "--agent", "codex"])
        #expect(missing.status != 0 && missing.output.contains("v2/test/codex") && missing.output.contains("ln -s"), "\(missing.output)\(missing.errors)")
        let standIn = node.root.appendingPathComponent("stand-in-codex")
        // Copied through a close-on-exec descriptor, so no child another test forks holds it open ("Text file busy").
        let text = node.root.appendingPathComponent("stand-in-codex.txt")
        try Data("#!/bin/sh\necho \"stand-in codex $*\"\nexec sleep 600\n".utf8).write(to: text)
        try copyClosedOnExec(text.path, to: standIn.path)
        let link = node.root.appendingPathComponent("v2/test/codex")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: standIn.path)
        let started = try await node.runOnTerminal(["new", folder.path, "--agent", "codex"])
        #expect(started.status == 0 && started.output.contains("started: session"), "\(started.output)\(started.errors)\n\(node.said)")
        let session = try #require(await Self.liveSession(node) { $0.label == "Codex" }, "\(node.said)")
        #expect(session.agent == "codex", "\(session)")
        #expect(await eventually(timeout: 60) { node.screen(session.id)?.contains("stand-in codex") == true }, "\(node.screen(session.id) ?? "")")
    }

    @Test("A32: a session is found by the terminal status prints and by the name you gave it")
    func a32SessionByTerminalOrName() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, _) = try await Self.newClaude(node)
        let id = NodeIds.session(host: session.id)
        let renamed = try await node.runOnTerminal(["rename", session.tty, "Release notes"])
        #expect(renamed.status == 0, "by its terminal: \(renamed.output)\(renamed.errors)")
        #expect(await node.eventuallyStatus { Self.listed($0, id)?["name"] as? String == "Release notes" })
        let paused = try await node.runOnTerminal(["pause", "release NOTES", "--hours", "1"])
        #expect(paused.status == 0 && paused.output.contains("paused: session \(Self.short(session))"), "by its name: \(paused.output)\(paused.errors)")
        #expect(await node.eventuallyStatus { Self.listed($0, id)?["pausedUntil"] is String })
    }

    @Test("A33: resume right after end says the session ended N s ago and when it is listed")
    func a33ResumeGrace() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, _) = try await Self.newClaude(node)
        let ended = try await node.runOnTerminal(["end", Self.short(session)])
        #expect(ended.status == 0, "\(ended.output)\(ended.errors)")
        #expect(await node.eventuallyStatus { (($0["ending"] as? [[String: Any]]) ?? []).isEmpty == false }, "\(node.said)")
        let resume = try await node.run(["resume"])
        #expect(resume.status == 0 && resume.output.contains("a session ended ") && resume.output.contains("it is listed in ")
                && !resume.output.contains("no session of yours ended lately"), "\(resume.output)\(resume.errors)")
    }

    @Test("A34: switch says at once that it can't run while a worker runs, naming it, with no code asked")
    func a34SwitchBlocked() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let worker = try await node.spawn("sleep 600", label: "Worker: task-1")
        #expect(await node.eventuallyStatus { (($0["switchBlockers"] as? [String]) ?? []).count == 1 }, "\(node.said)")
        let refused = try await node.runOnTerminal(["switch", String(repeating: "a", count: 40)])
        #expect(refused.status == 77 && refused.output.contains("switch can't run now") && refused.output.contains(worker.tty)
                && refused.output.contains("Nothing was asked or switched."), "\(refused.output)\(refused.errors)")
        #expect(!refused.output.contains("Type "), "no code asked: \(refused.output)")
    }

    @Test("A35: a page reads recent, brief, board.task, board.image, session.usage and chat.image; a session's process can't ask the user's reads")
    func a35PageReads() async throws {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let (session, _) = try await Self.newClaude(node)
        let page = try TermPage.paired(node)
        let kinds = Set(page.hello?["kinds"]?.array?.compactMap(\.string) ?? [])
        for kind in ["recent", "brief", "mail", "board.task", "board.image", "session.usage", "chat.image"] { #expect(kinds.contains(kind), "\(kind): \(kinds.sorted())") }
        let sessionID = NodeIds.session(host: session.id)
        func ask(_ kind: String, _ args: [String: NodeWire.Value]) throws -> NodeWire.Value? {
            let id = try page.send(kind, args)
            return try page.until { $0.json?["re"]?.string == id }?.last?.json
        }
        for kind in ["recent", "brief"] {
            let reply = try #require(try ask(kind, [:]), "no reply to \(kind)")
            #expect(reply["ok"]?.bool == true && WireSchema.check(reply["result"] ?? .null, as: "\(kind).result") == nil, "\(kind): \(reply)")
        }
        // Each read is answered as a read: what it names isn't there (no lead, no image), never a voice refusal.
        for (kind, args) in [("board.task", ["project": NodeWire.Value.string("local:project:none"), "task": .string("x")]),
                             ("board.image", ["project": .string("local:project:none"), "update": .string("u"), "index": .int(0)]),
                             ("session.usage", ["session": .string(sessionID)]),
                             ("chat.image", ["session": .string(sessionID), "id": .string("img")])] {
            let reply = try #require(try ask(kind, args), "no reply to \(kind)")
            #expect(reply["error"]?["code"]?.string != "voice", "\(kind): \(reply)")
        }
        // From a session's process (an agent), the user's own reads are refused.
        let environment = ["HOME": node.home.path, "VIBESWITCHER_HOME": node.root.path].map { "\($0.key)='\($0.value)'" }.joined(separator: " ")
        for kind in ["brief", "mail"] {
            let out = node.root.appendingPathComponent("\(kind).out")
            _ = try await node.spawn("env \(environment) '\(commandLine.path)' \(kind) > '\(out.path).part' 2>&1; echo \"status $?\" >> '\(out.path).part'; "
                                     + "mv '\(out.path).part' '\(out.path)'; exec sleep 600", label: "Claude")
            try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: out.path) }, "\(kind) never finished")
            let said = try String(contentsOf: out, encoding: .utf8)
            #expect(said.contains("not the user's voice") && said.contains("status 77"), "\(kind): \(said)")
        }
    }

    @Test("A36: status --health gives the server's health digest")
    func a36Health() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let ran = try await node.run(["status", "--health"])
        // What it says depends on the machine (a loaded one has slow refreshes, a long TMPDIR an unwatched state folder):
        // each of its lines is there.
        #expect(ran.status == 0 && ran.output.contains("health since the server started") && ran.output.contains("freezes:")
                && ran.output.contains("slow refreshes:") && ran.output.contains("the server's last errors"), "\(ran.output)\(ran.errors)")
        let json = try await node.run(["status", "--health", "--json"])
        let value = try #require(NodeWire.decode(NodeWire.Value.self, Data(json.output.utf8)), "\(json.output)")
        #expect(value["since"]?.string != nil, "\(json.output)")
    }

    @Test("A37: vs status --check-updates asks now: the newer green build and its install line, then none, then why it couldn't")
    func a37CheckUpdates() async throws {
        let sha = { (c: Character) in String(repeating: c, count: 40) }
        let (running, newer) = (sha("a"), sha("b"))
        let answers = scratch.url("update-answers.json")
        func answer(_ given: UpdateWatch.Answers) throws { try JSONEncoder().encode(given).write(to: answers) }
        let runs = [UpdateWatch.Run(databaseId: 1, workflowName: "v2 linux", headSha: newer, status: "completed", conclusion: "success"),
                    UpdateWatch.Run(databaseId: 2, workflowName: "v2 macos", headSha: newer, status: "completed", conclusion: "success")]
        try answer(.init(running: running, runs: runs, compare: ["\(running)...\(newer)": .init(status: "ahead", aheadBy: 2),
                                                                 "\(newer)...v2": .init(status: "identical")]))
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testUpdateAnswersFlag + answers.path])
        defer { node.stop() }
        let found = try await node.run(["status", "--check-updates"])
        #expect(found.status == 0 && found.output.contains("a newer build is on v2: \(newer) (2 commits ahead)")
                && found.output.contains(UpdateWatch.installLine(newer)), "\(found.output)\(found.errors)")
        // The answer is kept: `status` says it too.
        let status = try await node.run(["status", "--long"])
        #expect(status.output.contains("notice: a newer build is on v2: \(newer)"), "\(status.output)")
        // The running build is the newest: none.
        try answer(.init(running: running, runs: runs.map { var run = $0; run.headSha = running; return run }))
        let none = try await node.run(["status", "--check-updates", "--json"])
        let value = try #require(NodeWire.decode(NodeWire.Value.self, Data(none.output.utf8)), "\(none.output)\(none.errors)")
        #expect(none.status == 0 && value["commit"] == .null && value["checkedAt"]?.string != nil && value["running"]?.string == running, "\(none.output)")
        // GitHub can't be asked: why, and exit 1.
        try answer(.init(problem: "gh isn't installed (/usr/bin/gh)"))
        let failed = try await node.run(["status", "--check-updates"])
        #expect(failed.status == 1 && failed.output.contains("couldn't check v2 for a newer build (gh isn't installed (/usr/bin/gh))"), "\(failed.output)\(failed.errors)")
    }

    @Test("A38: vs switch with an idle worker parks it (said before the code), hands over, keeps the lead, and tells it")
    func a38SwitchParksIdleWorkers() async throws {
        let (a, b) = (String(repeating: "a", count: 40), String(repeating: "b", count: 40))
        let installs = scratch.url("builds")
        let buildA = try ScratchBuilds.install(commit: a, into: installs)
        _ = try ScratchBuilds.install(commit: b, into: installs)
        let node = try await ScratchNode(scratch, holdFirstLook: true, build: buildA, installRoot: installs)
        try node.noLoadHold()  // a worker starts: the runner's own load isn't the case's
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let lead = try await Self.startLead(node, repo, goal: "write the parser")
        let worker = try await Self.planAndStart(node, lead, title: "Write the parser")
        let files = node.fake.files(terminal: worker.tty)
        let pid = try #require((EngineEndToEndTests.state(files)["pid"] as? Int).map(Int32.init))
        try files.call("report", ["task": "write-the-parser", "status": "blocked", "summary": "it needs the grammar"])
        try #require(await eventually(timeout: 120) { files.calls().count == 2 }, "\(node.said)")
        try hook(node, ["hook_event_name": "Stop"], tty: worker.tty, pid: pid)
        try #require(await node.eventuallyStatus { (($0["switchParks"] as? [String]) ?? []).contains { $0.contains(worker.tty) } }, "\(node.said)")
        let switched = try await node.runOnTerminal(["switch", b, "--long"])
        #expect(switched.status == 0 && switched.output.contains("it parks first the workers that only wait on their lead")
                && switched.output.contains("parked first") && switched.output.contains(worker.tty) && switched.output.contains("handed over"),
                "\(switched.output)\(switched.errors)\n\(node.said)")
        #expect(try node.sessions().contains { $0.id == lead.session.id && $0.isLive })
        #expect(try !node.sessions().contains { $0.id == worker.id && $0.isLive })
        #expect(await eventually(timeout: 120) { node.inbox(lead.session.tty).contains { $0.text.contains("start_worker continues there") } }, "\(node.said)")
    }

    @Test("A39: vs approve leaves rails to record to you, then shows held config plainly, asks one code, accepts it, recorded and journaled")
    func a39Approve() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        // A fresh node: the home's accept would record its guard rails, so it is the user's own, named with its command.
        let first = try await node.runOnTerminal(["approve", "--only", "config"])
        #expect(first.status == 0 && first.output.contains("rules to record")
                && first.output.contains("vibeswitcher config accept local:card:") && first.output.contains("Nothing a plain accept settles"),
                "\(first.output)\(first.errors)\n\(node.said)")
        let held = try await node.run(["config", "held", node.home.path])
        let card = try #require(ScratchNode.card(held.output, "config accept"), "\(held.output)")
        let accepted = try await node.runOnTerminal(["config", "accept", card])
        #expect(accepted.status == 0, "\(accepted.output)\(accepted.errors)")
        // A change since: a plain accept, in the batch, its recap right above the one code.
        let settings = node.home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"env":{"A39":"1"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        let approved = try await node.runOnTerminal(["approve", "--only", "config"])
        // Plain (2026-11-25): a line a card (whose, what it names), one line for the batch, a receipt line per card.
        #expect(approved.status == 0 && approved.output.contains("1. your home folder's config: ") && approved.output.contains("~/.claude/settings.json: env added")
                && approved.output.contains("One code accepts it") && !approved.output.contains("hash ")
                && approved.output.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("accepted: your home folder's config, ") }
                && approved.output.contains("all 1 done"), "\(approved.output)\(approved.errors)\n\(node.said)")
        // Nothing left, and every accepted request (the batch's, its item's) is in the journal.
        let again = try await node.runOnTerminal(["approve", "--only", "config"])
        #expect(again.status == 0 && again.output.contains("Nothing a plain accept settles is waiting on you."), "\(again.output)\(again.errors)")
        let status = try await node.run(["status", "--long"])
        #expect(!status.output.contains("the journal has no entry for it"), "\(status.output)")
        let kinds = ((try await node.statusJSON())["accepted"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        #expect(kinds.contains("approve") && kinds.filter { $0 == "config.accept" }.count == 2, "\(kinds)")
    }

    /// `vs-shell` in a session of `node` (the tool server's filing mode, as Resources/bin/vs-shell runs it) with `arguments`:
    /// what it printed and its status, once it ended.
    static func vsShell(_ node: ScratchNode, _ arguments: String, name: String) async throws -> (session: HostSession, said: String) {
        let out = node.root.appendingPathComponent("\(name).out")
        let mcp = builtProducts.appendingPathComponent("vibeswitcher-mcp").path
        let session = try await node.spawn("env VIBESWITCHER_HOME='\(node.root.path)' '\(mcp)' --shell-request \(arguments) > '\(out.path).part' 2>&1; "
                                           + "echo \"status $?\" >> '\(out.path).part'; mv '\(out.path).part' '\(out.path)'; exec sleep 600", label: "Asker")
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: out.path) }, "\(node.screen(session.id) ?? "")\n\(node.said)")
        return (session, try String(contentsOf: out, encoding: .utf8))
    }

    @Test("A41: vs plugin list shows shell requests on; plugin off shell (its code typed) turns it off, recorded, and vs-shell then files nothing; plugin on shell brings it back")
    func a41Plugins() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let listed = try await node.run(["plugin", "list"])
        #expect(listed.status == 0 && listed.output.contains("shell  Shell requests  on (at its default") && listed.output.contains("adds for agents: vs-shell"),
                "\(listed.output)\(listed.errors)\n\(node.said)")
        let off = try await node.runOnTerminal(["plugin", "off", "shell"])
        #expect(off.status == 0 && off.output.contains("This turns Shell requests off") && off.output.contains("shell is off"), "\(off.output)\(off.errors)")
        let kinds = ((try await node.statusJSON())["accepted"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        #expect(kinds.contains("plugin.off"), "\(kinds)")
        let mirror = node.root.appendingPathComponent("plugins.json")
        try #require(await eventually(timeout: 30) { PluginGate.mirror(at: mirror)?.on == [] }, "\(String(describing: PluginGate.mirror(at: mirror)))")
        let refused = try await Self.vsShell(node, "run -- echo a40", name: "a40-off")
        #expect(refused.said.contains("vs-shell: this node doesn't have shell on") && refused.said.contains("status 1"), "\(refused.said)")
        let asked = node.root.appendingPathComponent("shell-requests/asked")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: asked.path)) ?? []).isEmpty, "nothing filed")
        let status = try await node.run(["status", "--long"])
        #expect(status.output.contains("plugins on: none"), "\(status.output)")

        let on = try await node.runOnTerminal(["plugin", "on", "shell"])
        #expect(on.status == 0 && on.output.contains("shell is on"), "\(on.output)\(on.errors)")
        let again = try await node.run(["plugin", "list"])
        #expect(again.output.contains("shell  Shell requests  on (its default)"), "\(again.output)")
        #expect(try await node.run(["status", "--long"]).output.contains("plugins on: shell"))
    }

    @Test("A42: an agent's vs-shell request through the shell plugin: its card lists the folder and the command whole, and answer CARD run with the code starts the shell that runs it")
    func a42ShellThroughThePlugin() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let filed = try await Self.vsShell(node, "run --label a41 -- echo a41-ran", name: "a41")
        #expect(filed.said.contains("Filed shell request") && filed.said.contains("status 0"), "\(filed.said)")
        // The node's look (every 15 s) draws it: the shell plugin's card.
        let waited = try await node.run(["questions", "--wait", "--json"])
        let cards = ((try? JSONSerialization.jsonObject(with: Data(waited.output.utf8)) as? [String: Any])?["cards"] as? [[String: Any]]) ?? []
        let card = cards.first { ($0["plugin"] as? [String: Any])?["plugin"] as? String == "shell" }
        let id = try #require(card?["id"] as? String, "\(node.said)")
        #expect(card?["kind"] as? String == "plugin")
        let shown = try await node.run(["questions"])
        #expect(shown.output.contains(id) && shown.output.contains("  in the folder: \(node.home.path)") && shown.output.contains("    | echo a41-ran")
                && shown.output.contains("  named (the agent's words): \u{201C}Shell: a41\u{201D}"), "\(shown.output)")
        let ran = try await node.runOnTerminal(["answer", id, "run"])
        #expect(ran.status == 0 && ran.output.contains("This runs the command above (1 line, 12 bytes), exactly as shown")
                && ran.output.contains("started: a new shell session"), "\(ran.output)\(ran.errors)\n\(node.said)")
        let sessions = try node.sessions()
        let shell = try #require(sessions.first { $0.label == "Shell: a41" && $0.isLive }, "\(sessions.map(\.label))")
        #expect(shell.cwd == node.home.path)
        #expect(await eventually(timeout: 60) { node.screen(shell.id)?.contains("a41-ran") == true }, "\(node.screen(shell.id) ?? "")")
        let again = try await node.runOnTerminal(["answer", id, "run"])
        #expect(again.status != 0, "\(again.output)")
        #expect(try node.sessions().filter { $0.label == "Shell: a41" }.count == 1)
    }

    @Test("A43: an external plugin (the test plugin): plugin add shows its program and SHA-256 and takes the code, plugin on runs it, an agent's vs-ask files a request the host stamps, its card is answered run, plugin remove forgets it")
    func a43ExternalPlugin() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let folder = ExternalPluginsTests.probe
        let added = try await node.runOnTerminal(["plugin", "add", folder])
        #expect(added.status == 0 && added.output.contains("This adds the plugin probe") && added.output.contains("its program's SHA-256:")
                && added.output.contains("added probe, off"), "\(added.output)\(added.errors)\n\(node.said)")
        let on = try await node.runOnTerminal(["plugin", "on", "probe"])
        #expect(on.status == 0 && on.output.contains("probe is on"), "\(on.output)\(on.errors)")
        let mirror = node.root.appendingPathComponent("plugins.json")
        try #require(await eventually(timeout: 30) { PluginGate.mirror(at: mirror)?.on.contains("probe") == true })

        let out = node.root.appendingPathComponent("a43.out")
        let mcp = builtProducts.appendingPathComponent("vibeswitcher-mcp").path
        let asker = try await node.spawn("env VIBESWITCHER_HOME='\(node.root.path)' '\(mcp)' --ask probe -- normal a43 > '\(out.path).part' 2>&1; "
                                         + "echo \"status $?\" >> '\(out.path).part'; mv '\(out.path).part' '\(out.path)'; exec sleep 600", label: "Asker")
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: out.path) }, "\(node.screen(asker.id) ?? "")")
        let filed = try String(contentsOf: out, encoding: .utf8)
        #expect(filed.contains("Filed Probe request") && filed.contains("status 0"), "\(filed)\n\(node.said)")
        let waited = try await node.run(["questions", "--wait", "--json"])
        let cards = ((try? JSONSerialization.jsonObject(with: Data(waited.output.utf8)) as? [String: Any])?["cards"] as? [[String: Any]]) ?? []
        let id = try #require(cards.first { ($0["plugin"] as? [String: Any])?["plugin"] as? String == "probe" }?["id"] as? String, "\(waited.output)")
        let shown = try await node.run(["questions"])
        #expect(shown.output.contains("  the probe plugin says, depth: 1") && shown.output.contains("    | normal a43"), "\(shown.output)")
        let ran = try await node.runOnTerminal(["answer", id, "run"])
        #expect(ran.status == 0 && ran.output.contains("This runs the probe") && ran.output.contains("Ran the probe"), "\(ran.output)\(ran.errors)\n\(node.said)")

        let removed = try await node.runOnTerminal(["plugin", "remove", "probe"])
        #expect(removed.status == 0 && removed.output.contains("removed probe"), "\(removed.output)\(removed.errors)")
        let listed = try await node.run(["plugin", "list"])
        #expect(!listed.output.contains("probe  Probe"), "\(listed.output)")
    }

    // MARK: The rows a scratch node can't run

    @Test("A19: the page notifies of a question or prompt, and its title counts them",
          .disabled("needs a browser's Notification API and a page shown: WebApp/tests/notify.test.mjs covers what the page decides"))
    func a19Notifications() {}

    @Test("A24: scripts/nightly.sh on the merged v2 passes the full suite",
          .disabled("the nightly run itself, which runs this suite; not a case inside it"))
    func a24Nightly() {}

    @Test("A25: VibeSwitcher's own lead on its clone merges its tasks through the gate and keeps a goal list",
          .disabled("needs a real Claude Code lead working on a real clone, run on the user's go-ahead"))
    func a25SelfImprovement() {}
}

/// The suite's gate and helpers.
enum NodeAcceptance {
    /// Whether the acceptance suite runs: unless `VIBESWITCHER_ACCEPTANCE=0`.
    static let enabled = ProcessInfo.processInfo.environment["VIBESWITCHER_ACCEPTANCE"] != "0"
}

extension NodeAcceptanceTests {
    /// A scratch repository under the node's root with one commit and a workflow.md whose test command passes.
    static func repository(_ node: ScratchNode, name: String = "repo") async throws -> URL {
        let repo = node.root.appendingPathComponent(name)
        try await scratchRepository(repo)
        try EngineEndToEndTests.workflow(repo)
        return repo
    }

    /// A lead the user started: `repo`'s config and base accepted (the first look the scratch node holds), then
    /// `lead FOLDER --goal GOAL`, each with the code typed; its fake up and between turns (its Stop hook written).
    struct Lead {
        var session: HostSession
        var tools: FakeClaude.Files
        var pid: Int32
    }

    static func startLead(_ node: ScratchNode, _ repo: URL, goal: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Lead {
        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: Git.run(["rev-parse", "main"], in: repo.path).output)
        let started = try await node.runOnTerminal(["lead", repo.path, "--goal", goal])
        try #require(started.status == 0 && started.output.contains("the lead started"), "\(started.output)\n\(node.said)", sourceLocation: sourceLocation)
        let session = try #require(try node.sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") }, "\(node.said)", sourceLocation: sourceLocation)
        let tools = node.fake.files(terminal: session.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(tools)["pid"] != nil }, "\(node.said)", sourceLocation: sourceLocation)
        let pid = try #require((EngineEndToEndTests.state(tools)["pid"] as? Int).map(Int32.init), sourceLocation: sourceLocation)
        // Its tool server up, as Claude Code starts its MCP servers at its start: the vault binds the lead's role at its
        // first call, and only a lead it binds is delivered to.
        try tools.call("status", [:])
        try #require(await eventually(timeout: 120) { tools.calls().count == 1 }, "\(node.said)", sourceLocation: sourceLocation)
        try hook(node, ["hook_event_name": "Stop"], tty: session.tty, pid: pid)
        return Lead(session: session, tools: tools, pid: pid)
    }

    /// `title` added to `lead`'s board and its worker started (its tool server connected, as Claude Code's starts): the
    /// worker's session.
    static func planAndStart(_ node: ScratchNode, _ lead: Lead, title: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> HostSession {
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        let before = lead.tools.calls().count
        try lead.tools.call("add_task", ["title": title, "goal": "\(title).", "acceptance": ["it builds"], "auto_advance": false])
        try #require(await eventually(timeout: 120) { lead.tools.calls().count == before + 1 }, "\(lead.tools.calls())", sourceLocation: sourceLocation)
        try lead.tools.call("start_worker", ["task": slug])
        let worker = try await EngineEndToEndTests.connected(node, label: "Worker: \(title)", calling: "progress", ["task": slug, "text": "starting"])
        try #require(await eventually(timeout: 120) { lead.tools.calls().count == before + 2 }, "\(lead.tools.calls())", sourceLocation: sourceLocation)
        #expect(lead.tools.text(of: lead.tools.calls()[before + 1]).contains("Worker started on \(slug)"), "\(lead.tools.calls())",
                sourceLocation: sourceLocation)
        return worker
    }

    /// A team through its audit: ScratchRunTests' repository (src/, check.sh as the test command) with `finders` finders
    /// and `policy` as the merge policy over src/**, its lead started, one task whose worker commits src/parser.txt in
    /// its worktree, audited by the finders, each giving a passing verdict through its own tool server.
    struct AuditedTask {
        var repo: URL
        var lead: Lead
        var slug: String
        var commit: String
        var verifiers: Int
    }

    static func auditedTask(_ node: ScratchNode, finders: Int, policy: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> AuditedTask {
        let repo = node.root.appendingPathComponent("repo")
        _ = try await ScratchRunTests.scratchRepository(in: repo)
        try """
            ---
            test_command: sh ./check.sh
            merge_policy: \(policy)
            sensitive_paths: src/**
            audit_finders: \(finders)
            ---

            """.write(toFile: ConfigHoldStore.workflowPath(root: repo.path), atomically: true, encoding: .utf8)
        let lead = try await startLead(node, repo, goal: "add the parser")
        try node.noLoadHold(maxSessions: 6)
        _ = try await planAndStart(node, lead, title: "Write the parser", sourceLocation: sourceLocation)
        let slug = "write-the-parser"
        let worktree = Worktrees.path(root: repo.path, slug: slug)
        try "Write the parser\n".write(toFile: (worktree as NSString).appendingPathComponent("src/parser.txt"), atomically: true, encoding: .utf8)
        try await scratchGit(worktree, ["add", "--", "src/parser.txt"])
        try await scratchGit(worktree, ["commit", "-q", "-m", "Write the parser"])
        let commit = try await scratchGit(worktree, ["rev-parse", "HEAD"])
        let auditSent = try ScratchRunTests.send(lead.tools, "audit", ["task": slug])
        // Each finder's session, its tool server up (its first call) as it comes: a panel starts its finders one after
        // another, each once the one before has connected. Then each gives its verdict.
        var verifiers: [HostSession] = []
        let connected = await eventually(timeout: 240) {
            for verifier in ((try? node.sessions()) ?? []) where verifier.isLive && verifier.label.hasPrefix("Verifier: Write the parser")
                && !verifiers.contains(where: { $0.id == verifier.id }) {
                let files = node.fake.files(terminal: verifier.tty)
                guard EngineEndToEndTests.state(files)["pid"] != nil, (try? files.call("board", ["task": slug])) != nil else { continue }
                verifiers.append(verifier)
            }
            return verifiers.count == finders
        }
        try #require(connected, "\(verifiers.map(\.label)) \(lead.tools.calls().dropFirst(auditSent).map { lead.tools.text(of: $0) })\n\(node.said)",
                     sourceLocation: sourceLocation)
        _ = try await ScratchRunTests.reply(lead.tools, auditSent, sourceLocation: sourceLocation)
        for verifier in verifiers {
            let files = node.fake.files(terminal: verifier.tty)
            let sent = try ScratchRunTests.send(files, "submit_audit", ["task": slug, "completion": "complete", "integrity": "clean",
                                                                       "summary": "src/parser.txt is there; sh ./check.sh passed", "tests": "passed"])
            _ = try await ScratchRunTests.reply(files, sent, sourceLocation: sourceLocation)
        }
        let verdict = try #require(try await ScratchRunTests.verdict(node, repo, task: slug), "no verdict: \(node.said)", sourceLocation: sourceLocation)
        #expect(verdict.commit == commit && verdict.passes, "\(verdict)", sourceLocation: sourceLocation)
        return AuditedTask(repo: repo, lead: lead, slug: slug, commit: commit, verifiers: verifiers.count)
    }

    /// Where Claude Code writes `conversation`'s transcript for `folder`, under the node's home (its folder made).
    static func transcript(_ node: ScratchNode, folder: URL, conversation: String) -> URL {
        let url = node.home.appendingPathComponent(".claude/projects")
            .appendingPathComponent(RecentProjects.claudeSlug(for: folder.resolvingSymlinksInPath().path)).appendingPathComponent("\(conversation).jsonl")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// An empty commit on `repo`'s main (the base moves on): its hash.
    static func commitOnMain(_ repo: URL, _ subject: String) async throws -> String {
        try await scratchGit(repo.path, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-q", "--allow-empty", "-m", subject])
        return try await scratchGit(repo.path, ["rev-parse", "HEAD"])
    }

    /// The lead fetches its remote and asks to push its base (fetch_remote, push_remote), and the node sees the request.
    static func askToPush(_ node: ScratchNode, _ lead: Lead, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let fetched = try await ScratchRunTests.reply(lead.tools, try ScratchRunTests.send(lead.tools, "fetch_remote", [:]), sourceLocation: sourceLocation)
        #expect(!fetched.contains("Refused"), "\(fetched)", sourceLocation: sourceLocation)
        let asked = try await ScratchRunTests.reply(lead.tools, try ScratchRunTests.send(lead.tools, "push_remote", [:]), sourceLocation: sourceLocation)
        #expect(asked.lowercased().contains("push request"), "\(asked)", sourceLocation: sourceLocation)
        try #require(await node.eventuallyStatus { status in
            ((status["leads"] as? [[String: Any]]) ?? []).contains { $0["push"] is [String: Any] }
        }, "\(asked)\n\(node.said)", sourceLocation: sourceLocation)
    }

    /// `new FOLDER [--model M]` on a terminal, the code typed: the session it started, its fake up.
    static func newClaude(_ node: ScratchNode, folder: URL? = nil, model: String? = nil,
                          sourceLocation: SourceLocation = #_sourceLocation) async throws -> (HostSession, FakeClaude.Files) {
        let folder = folder ?? node.root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = try await node.runOnTerminal(["new", folder.path] + (model.map { ["--model", $0] } ?? []))
        try #require(started.status == 0 && started.output.contains("started: session"), "\(started.output)\(started.errors)\n\(node.said)",
                     sourceLocation: sourceLocation)
        let short = try #require(started.output.components(separatedBy: "started: session ").last?.prefix(8)).description
        let session = try #require(try node.sessions().first { $0.id.uuidString.lowercased().hasPrefix(short) && $0.isLive }, "\(node.said)",
                                   sourceLocation: sourceLocation)
        let files = node.fake.files(terminal: session.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["pid"] != nil }, "\(node.said)", sourceLocation: sourceLocation)
        // Listed by the node's session scan (every 2 s, slower on a loaded machine): what a page's draft, rename, pause and
        // end find a session by. A case that drafts or marks it right after `new` raced the scan.
        try #require(await node.eventuallyStatus { listed($0, NodeIds.session(host: session.id)) != nil }, "\(node.said)", sourceLocation: sourceLocation)
        return (session, files)
    }

    /// Asks `condition` (a command run) until it holds or `timeout` passes, half a second between asks.
    static func polled(timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return await condition()
    }

    static func short(_ session: HostSession) -> String { String(session.id.uuidString.lowercased().prefix(8)) }

    /// `status --json`'s entry for the session `id` (the node's), if listed.
    static func listed(_ status: [String: Any], _ id: String) -> [String: Any]? {
        (status["sessions"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    /// The question of the session `id`'s prompt in `status --json`, with its options.
    static func prompt(_ status: [String: Any], _ id: String) -> String? {
        guard let prompt = listed(status, id)?["prompt"] as? [String: Any] else { return nil }
        return ([prompt["question"] as? String ?? ""] + ((prompt["options"] as? [String]) ?? [])).joined(separator: "\n")
    }

    /// The first live session the host lists that `matches`, once it does.
    static func liveSession(_ node: ScratchNode, timeout: TimeInterval = 60, _ matches: @escaping (HostSession) -> Bool) async -> HostSession? {
        var found: HostSession?
        _ = await eventually(timeout: timeout) {
            found = (try? node.sessions())?.first { $0.isLive && matches($0) }
            return found != nil
        }
        return found
    }
}
