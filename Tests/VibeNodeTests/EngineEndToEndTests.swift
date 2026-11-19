import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The engine's proof (the engine plan's E9; the outline's "Proves" as a test): under a scratch host started from the
/// build (`ScratchNode`, its server the built `vibeswitcher-server`), everything driven through the built command line
/// on a pty of its own (`script`), as the user drives it. A scratch repository with a commit and its `workflow.md`; the
/// host holds its fresh vault's first look, as the user's host does, so the lead starts only once the user accepted the
/// config and recorded the base. The lead is `FakeClaude` (the scratch node's `<root>/v2/test/claude`), and so are the
/// workers and verifiers its tool server starts (`VIBESWITCHER_CLAUDE`, EN-D13); the fake runs no hooks, so the test
/// writes what Claude Code's hooks would (`hook(_:_:pid:)`) and takes the lead's inbox as its prompt's hook does
/// (`promptHookTakes`). `anAnswerBeforeTheTurnEndsIsTakenByTheLeadsHookAsTheUsers` is the other way an answer reaches a
/// lead: mid-turn, handed over by its own hook. `aRealLeadOnSonnetAsksAndIsAnswered` shows both with a real Claude Code
/// on Sonnet, gated on the user's throwaway config folder (the security document's decision 16).
@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(15)))
struct EngineEndToEndTests {
    private let scratch = Scratch()

    /// A lead started from the command line asks the user a question through its tool server and is answered from the
    /// command line: the answer is recorded in the vault, then typed into the lead as the user's. Then its team: a
    /// `start_worker` refused for the machine's room is followed by one message once the limits are raised; a worker's
    /// report reaches the idle lead with one wake prompt; a verifier waiting on a permission prompt no one answers is
    /// declined after the wait, and the lead told once.
    @Test func aLeadStartedFromTheCommandLineAsksAndIsAnswered() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = node.root.appendingPathComponent("repo")
        try await scratchRepository(repo)
        try Self.workflow(repo)
        let head = Git.run(["rev-parse", "main"], in: repo.path).output

        // 1. The two accepts the first look asks for, then the lead, each on a terminal, the code typed.
        let refused = try await node.runOnTerminal(["lead", repo.path, "--goal", "say hi"])
        #expect(refused.status == 77 && refused.output.contains("config held"), "\(refused.output)")
        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: head)
        let started = try await node.runOnTerminal(["lead", repo.path, "--goal", "say hi"])
        try #require(started.status == 0 && started.output.contains("the lead started"), "\(started.output)\n\(node.said)")
        #expect(started.output.contains(node.fake.launcher.resolvingSymlinksInPath().path), "the program by its resolved path: \(started.output)")
        let lead = try #require(try node.sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") }, "\(node.said)")
        let tools = node.fake.files(terminal: lead.tty)
        try #require(await eventually(timeout: 60) { Self.state(tools)["pid"] != nil }, "\(node.said)")
        let pid = try #require((Self.state(tools)["pid"] as? Int).map(Int32.init))
        #expect((Self.state(tools)["prompt"] as? String)?.contains("say hi") == true, "\(Self.state(tools))")
        // Between turns, as its Stop hook would say: what waits for it is typed in.
        try hook(node, ["hook_event_name": "Stop"], tty: lead.tty, pid: pid)

        // 2. It asks, with two options; `questions` lists the card; the user answers it, the card's code typed.
        try tools.call("ask_user", ["question": "Which name for the parser?", "options": ["Parser", "Reader"]])
        try #require(await eventually(timeout: 120) { tools.calls().count == 1 }, "\(node.said)")
        let card = try await Self.card(node, question: "Which name for the parser?")
        let listed = try await node.runOnTerminal(["questions"])
        #expect(listed.status == 0 && listed.output.contains("Which name for the parser?") && listed.output.contains(card), "\(listed.output)")
        let answered = try await node.runOnTerminal(["answer", card, "the second"])
        #expect(answered.status == 0 && answered.output.contains("answered: the lead is told"), "\(answered.output)\n\(node.said)")
        // In the vault (the request, and the message's digest under the same action), then typed in as the user's: its
        // prompt is the message as it is, ending with the answer.
        let vault = LeadVaultV2Client { [socket = node.socket] request in
            guard case .vaultV2(let reply) = try HostCall.request(.vaultV2(request), socket: socket, appKey: nil, timeout: 10) else {
                throw LeadVaultV2Client.Refused("the host answered something else")
            }
            return reply
        }
        let typed = try await Self.prompt(tools) { $0.hasSuffix("the second") }
        let actions = try await offPool { try vault.userActions() }
        let answer = try #require(actions.first { $0.kind == "answer" && $0.subject == card }, "\(actions)")
        let message = try #require(actions.first { $0.kind == "message" && $0.action == answer.action }, "\(actions)")
        #expect(message.digest == LeadVaultV2.digest(typed), "\(typed)")
        #expect(answer.at <= message.at)
        #expect(!typed.hasPrefix(LeadDelivery.prefix), "typed as the user's, not as a system's: \(typed)")
        #expect(BoardStore(root: repo.path).load().questions.first { $0.text == "Which name for the parser?" }?.answer == "the second")

        // 3. Its team, on a machine with room for one team session: the first worker starts, the second is refused for
        // the room (and waits, recorded under the root, for one message once there's room).
        try Self.limits(node, maxSessions: 1)
        for title in ["Write the parser", "Write the lexer"] {
            try tools.call("add_task", ["title": title, "goal": "\(title).", "acceptance": ["it builds"], "auto_advance": false])
        }
        try #require(await eventually(timeout: 120) { tools.calls().count == 3 }, "\(tools.calls())")
        // `start_worker` waits for the worker's tools to connect: the fake starts its tool server at its first call.
        try tools.call("start_worker", ["task": "write-the-parser"])
        let worker = try await Self.connected(node, label: "Worker: Write the parser", calling: "progress",
                                              ["task": "write-the-parser", "text": "starting"])
        try #require(await eventually(timeout: 120) { tools.calls().count == 4 }, "\(tools.calls())")
        #expect(tools.text(of: tools.calls()[3]).contains("Worker started on write-the-parser"), "\(tools.calls()[3])")
        try tools.call("start_worker", ["task": "write-the-lexer"])
        try #require(await eventually(timeout: 120) { tools.calls().count == 5 }, "\(tools.calls())")
        let roomRefusal = tools.text(of: tools.calls()[4])
        #expect(roomRefusal.contains("Not started") && roomRefusal.contains("mac_max_sessions")
                && roomRefusal.contains("one message once there's room again"), "\(roomRefusal)")

        // 4. The worker reports: one wake prompt for the idle lead, and its prompt's hook hands the report over.
        let workerTools = node.fake.files(terminal: worker.tty)
        try workerTools.call("report", ["task": "write-the-parser", "status": "blocked", "summary": "it needs the grammar"])
        try #require(await eventually(timeout: 120) { workerTools.calls().count == 2 }, "\(node.said)")
        #expect(workerTools.text(of: workerTools.calls()[1]).contains("Reported"), "\(workerTools.calls())")
        let woken = try await Self.prompt(tools) { $0.contains("worker write-the-parser blocked") }
        #expect(woken.contains("1 new report"), "\(woken)")
        var handedAll = promptHookTakes(node, tty: lead.tty, pid: pid)
        #expect(handedAll.contains("The worker on write-the-parser is blocked: it needs the grammar"), "\(handedAll)")

        // 5. The limits raised: one message from the room watch (its look is once a minute), one wake prompt for it.
        try Self.limits(node, maxSessions: 10)
        let room = "room again for what was refused: start_worker(write-the-lexer)"
        let roomWoken = { (prompt: String) in prompt.contains("1 new report (witness: The Mac has room again") }
        _ = try await Self.prompt(tools, timeout: 180, roomWoken)
        let roomHanded = promptHookTakes(node, tty: lead.tty, pid: pid)
        #expect(roomHanded.contains(room), "\(roomHanded)")
        handedAll += roomHanded

        // 6. An audit: its verifier waits on a permission prompt no one answers (as its hooks would say), and after the
        // wait (`LeadWitness.promptWait`, real time) it's declined with the reason, and the lead told once.
        try tools.call("audit", ["task": "write-the-parser"])
        let verifier = try await Self.connected(node, label: "Verifier: Write the parser", calling: "board", ["task": "write-the-parser"])
        try #require(await eventually(timeout: 120) { tools.calls().count == 6 }, "\(tools.calls())")
        #expect(!(tools.calls()[5]["reply"] as? [String: Any] ?? [:]).isEmpty, "\(tools.calls()[5])")
        let verifierFiles = node.fake.files(terminal: verifier.tty)
        let verifierPid = try #require((Self.state(verifierFiles)["pid"] as? Int).map(Int32.init))
        let command = "git config --get remote.origin.url"
        try Self.tell(verifierFiles, ["op": "permission", "command": command, "ui": "2.1.316"])
        #expect(await eventually(timeout: 60) { node.screen(verifier.id)?.contains("Do you want to proceed?") == true }, "\(node.screen(verifier.id) ?? "")")
        let asked = Date()
        try hook(node, ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": command]], tty: verifier.tty, pid: verifierPid)
        let declined = await eventually(timeout: 300) {
            Self.state(verifierFiles)["declined"] as? String == LeadWitness.declineReason
        }
        #expect(declined, "\(Self.state(verifierFiles))\n\(node.said)")
        #expect(Date().timeIntervalSince(asked) >= LeadWitness.promptWait - 5, "declined only after the wait")
        let told = try await Self.prompt(tools) { $0.contains("verifier write-the-parser had a prompt declined") }
        #expect(told.contains("1 new report"), "\(told)")
        let handed = promptHookTakes(node, tty: lead.tty, pid: pid)
        #expect(handed.contains("permission prompt no one answers") && handed.contains(LeadWitness.declineReason), "\(handed)")
        handedAll += handed

        // Each once: the answer, the report, the room's message, the decline; each wake prompt once.
        try await node.looks(2, at: repo)
        let prompts = Self.prompts(tools)
        #expect(prompts.filter { $0.hasSuffix("the second") }.count == 1, "\(prompts)")
        #expect(prompts.filter { $0.contains("worker write-the-parser blocked") }.count == 1, "\(prompts)")
        #expect(prompts.filter(roomWoken).count == 1, "\(prompts)")
        #expect(prompts.filter { $0.contains("had a prompt declined") }.count == 1, "\(prompts)")
        // What the prompts' hooks handed over, each once, and nothing of it waits still.
        handedAll += promptHookTakes(node, tty: lead.tty, pid: pid)
        for told in [room, "permission prompt no one answers", "The worker on write-the-parser is blocked"] {
            #expect(handedAll.components(separatedBy: told).count == 2, "\(told): \(handedAll)")
        }
        #expect(SteerInbox.pending(tty: lead.tty, root: node.root).filter { $0.agentPid == pid }.isEmpty)
    }

    /// The start plan's ST-D19, measured: a lead starts a worker, and each session writes its shell snapshot into
    /// `~/.claude/shell-snapshots` as Claude Code does (`FakeClaude`), and the role's start its launch files into
    /// `~/.vibeswitcher/lead/run`. The next look (`config held`, the app's) holds nothing, and the lead's own look (what a
    /// merge's tests and every role's start ask, `checkConfig`) isn't refused for the seal: a second worker starts.
    @Test func aWorkersStartDoesNotHoldItsTeam() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = node.root.appendingPathComponent("repo")
        try await scratchRepository(repo)
        try Self.workflow(repo)
        // A hook of the user's: the guard's baseline (at its first git) copies it and writes its shim, which comes as no
        // change (`LinuxSealList.hookEntryMayCome`).
        try ScratchNode.script("#!/bin/sh\nexit 0\n", at: repo.appendingPathComponent(".git/hooks/pre-commit"))
        let head = Git.run(["rev-parse", "main"], in: repo.path).output
        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: head)
        let started = try await node.runOnTerminal(["lead", repo.path, "--goal", "two workers"])
        try #require(started.status == 0 && started.output.contains("the lead started"), "\(started.output)\n\(node.said)")
        let lead = try #require(try node.sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") }, "\(node.said)")
        let tools = node.fake.files(terminal: lead.tty)
        try #require(await eventually(timeout: 60) { Self.state(tools)["pid"] != nil }, "\(node.said)")
        let snapshots = node.home.appendingPathComponent(".claude/shell-snapshots").path
        let written = { ((try? FileManager.default.contentsOfDirectory(atPath: snapshots)) ?? []).filter { $0.hasPrefix("snapshot-bash-") } }
        try #require(await eventually(timeout: 60) { written().count == 1 }, "the lead's snapshot: \(written())")

        try Self.limits(node, maxSessions: 10)
        for title in ["Write the parser", "Write the lexer"] {
            try tools.call("add_task", ["title": title, "goal": "\(title).", "acceptance": ["it builds"], "auto_advance": false])
        }
        try #require(await eventually(timeout: 120) { tools.calls().count == 2 }, "\(tools.calls())")
        // Each start is the lead's look first: refused for the seal, its reply comes at once and no worker starts.
        for (index, task, label) in [(2, "write-the-parser", "Worker: Write the parser"), (3, "write-the-lexer", "Worker: Write the lexer")] {
            try tools.call("start_worker", ["task": task])
            try #require(await eventually(timeout: 120) {
                tools.calls().count > index || ((try? node.sessions()) ?? []).contains { $0.isLive && $0.label == label }
            }, "\(tools.calls())\n\(node.said)")
            // A start's reply waits for its worker's tools, which connect only at the call below: a reply now is a refusal.
            if tools.calls().count > index {
                Issue.record("the start was refused: \(tools.text(of: tools.calls()[index]))")
                return
            }
            _ = try await Self.connected(node, label: label, calling: "progress", ["task": task, "text": "starting"])
            try #require(await eventually(timeout: 120) { tools.calls().count == index + 1 }, "\(tools.calls())")
            #expect(tools.text(of: tools.calls()[index]).contains("Worker started on \(task)"), "\(tools.calls()[index])")
            try #require(await eventually(timeout: 60) { written().count == index }, "the worker's snapshot: \(written())")
            #expect(FileManager.default.fileExists(atPath: node.root.appendingPathComponent("lead/run").path))
            let stores = (try? FileManager.default.contentsOfDirectory(atPath: node.root.appendingPathComponent("lead/git-hooks").path)) ?? []
            #expect(stores.contains { FileManager.default.fileExists(atPath: node.root.appendingPathComponent("lead/git-hooks/\($0)/copy/hooks/pre-commit").path) },
                    "the baseline's shim: \(stores)")

            // The next look, the app's: nothing held.
            let held = try await node.run(["config", "held", repo.path])
            #expect(held.status == 0, "\(held.output)\(held.errors)")
            #expect(!held.output.contains("shell-snapshots") && !held.output.contains("lead/run"), "\(held.output)")
            #expect(!held.output.components(separatedBy: "\n").contains { $0.hasPrefix("    ~/") }, "\(held.output)")
        }

        // A second repository's first guarded git (here `base show`'s, refused after it for its unaccepted base), after
        // the seal's record: the guard's baseline of its hook, a new store with a shim, comes as no change either.
        let other = node.root.appendingPathComponent("other")
        try await scratchRepository(other)
        try Self.workflow(other)
        try ScratchNode.script("#!/bin/sh\nexit 0\n", at: other.appendingPathComponent(".git/hooks/pre-commit"))
        let stores = { ((try? FileManager.default.contentsOfDirectory(atPath: node.root.appendingPathComponent("lead/git-hooks").path)) ?? []).count }
        let before = stores()
        let shown = try await node.run(["base", "show", other.path, "--from", Git.run(["rev-parse", "main"], in: other.path).output])
        #expect(shown.status == 77 && (shown.output + shown.errors).contains("base branch isn't accepted"), "\(shown.output)\(shown.errors)")
        #expect(stores() == before + 1, "the second repository's baseline")
        let held = try await node.run(["config", "held", repo.path])
        #expect(held.status == 0, "\(held.output)\(held.errors)")
        #expect(!held.output.components(separatedBy: "\n").contains { $0.hasPrefix("    ~/") }, "\(held.output)")
    }

    /// The other way an answer reaches its lead (the real lead's first gated run, 2026-11-17: answered 0.1 s after it
    /// asked, its turn still running): nothing is typed into a lead mid-turn; the answer waits in its inbox as the
    /// user's, sealed by the host, and its own hook hands it over at the turn's end (Stop), under the user's sender
    /// line, the message as it is, once. The fake runs no hooks, so the case takes the inbox as the lead's Stop hook does
    /// (`leadsHookTakes`: its seals checked by the node's host's vault, as `vibeswitcher-hook` checks them).
    @Test func anAnswerBeforeTheTurnEndsIsTakenByTheLeadsHookAsTheUsers() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        // A lead mid-turn (its hooks said PreToolUse) that asked through its tool server, answered at once.
        let lead = try await node.askingLead("Which name for the parser?", options: ["Parser", "Reader"])
        let tools = node.fake.files(terminal: lead.session.tty)
        let answered = try await node.runOnTerminal(["answer", lead.card, "Reader"])
        #expect(answered.status == 0 && answered.output.contains("answered: the lead is told"), "\(answered.output)\n\(node.said)")
        let message = try await Self.usersMessage(node, card: lead.card)
        // It waits in the lead's inbox as the user's, with a seal the vault takes.
        var found: SteerMessage?
        _ = await eventually(timeout: 60) {
            found = node.inbox(lead.session.tty).first { $0.from == .user && LeadVaultV2.digest($0.text) == message.digest }
            return found != nil
        }
        let waiting = try #require(found, "no answer in the lead's inbox: \(node.inbox(lead.session.tty))\n\(node.said)")
        #expect(waiting.text.hasSuffix(": Reader") && waiting.agentPid == lead.agentPid, "\(waiting)")
        #expect(waiting.seal != nil && node.verifies(waiting) == true)
        // A look or two on, its turn still running: nothing typed, and it waits still.
        try await node.looks(2, at: lead.repo)
        #expect(!Self.prompts(tools).contains { $0.contains("Reader") }, "\(Self.prompts(tools))")
        #expect(node.inbox(lead.session.tty).contains { $0.id == waiting.id })

        // Its turn ends: its Stop hook hands it over, as the user's, the message as it is.
        let taken = leadsHookTakes(node, event: "Stop", tty: lead.session.tty, pid: lead.agentPid)
        #expect(taken.messages.map(\.id) == [waiting.id] && taken.messages.first?.from == .user, "\(taken.messages)")
        let said = SteerReply.messages(inContext: taken.context)
        #expect(said.count == 1 && said.first?.fromLead == false && said.first?.text == waiting.text, "\(taken.context)")
        #expect(taken.context.contains(SteerReply.userMarker) && !taken.context.contains(SteerReply.systemMarker), "\(taken.context)")
        #expect(!waiting.text.hasPrefix(LeadDelivery.prefix), "handed as the user's, not as a system's: \(waiting.text)")
        // The node's record of it: out of the inbox, in its delivered record.
        #expect(SteerInbox.delivered(tty: lead.session.tty, root: node.root).contains(waiting.id))
        #expect(!node.inbox(lead.session.tty).contains { $0.id == waiting.id })

        // Between turns now: the server sees it taken (its seal retired), and types it in no more.
        try hook(node, ["hook_event_name": "Stop"], tty: lead.session.tty, pid: lead.agentPid)
        #expect(await eventually(timeout: 60) { node.verifies(waiting) == false }, "\(node.said)")
        try await node.looks(2, at: lead.repo)
        #expect(!Self.prompts(tools).contains { $0.contains("Reader") }, "\(Self.prompts(tools))")
        #expect(leadsHookTakes(node, event: "Stop", tty: lead.session.tty, pid: lead.agentPid).messages.isEmpty)
    }

    /// The first real node's deaf lead (2026-11-19): the node starts the lead, and its tool server the workers, by the
    /// path `~/.local/bin/claude` resolves to (EN-D13), Claude Code's native installer's `~/.local/share/claude/versions/
    /// 2.1.328`, so the process's `comm` and `argv[0]` are its version, never `claude`. The process table took it for no
    /// agent: every answer the user gave was held ("no lead the vault binds runs there"), and each worker's `ask_lead`
    /// was told there's no lead running. Here the fake runs by such a name: the answer reaches the lead's inbox as the
    /// user's, and a worker's question reaches it too.
    @Test func aLeadRunByClaudeCodesVersionedBinaryHearsTheUserAndItsWorkers() async throws {
        let node = try await ScratchNode(scratch, claudeProgram: "share/claude/versions/2.1.328")
        defer { node.stop() }
        let lead = try await node.askingLead("Which name for the parser?", options: ["Parser", "Reader"])
        let agent = try #require(ProcessTable.info(pid: lead.agentPid))
        #expect(agent.comm == "2.1.328" && agent.tty == lead.session.tty, "the fake runs by its version: \(agent)")
        let answered = try await node.runOnTerminal(["answer", lead.card, "Reader"])
        #expect(answered.status == 0 && answered.output.contains("answered: the lead is told"), "\(answered.output)\n\(node.said)")
        let message = try await Self.usersMessage(node, card: lead.card)
        let reached = await eventually(timeout: 60) {
            node.inbox(lead.session.tty).contains { $0.from == .user && LeadVaultV2.digest($0.text) == message.digest }
        }
        #expect(reached, "the answer isn't in the lead's inbox: \(node.inbox(lead.session.tty))\n\(node.said)")
        #expect(!node.said.contains("holding a message"), "\(node.said)")

        // A worker it starts (by the same program, `VIBESWITCHER_CLAUDE`) asks it something: the question reaches it.
        let tools = node.fake.files(terminal: lead.session.tty)
        let before = tools.calls().count
        try Self.limits(node, maxSessions: 10)
        try tools.call("add_task", ["title": "Write the parser", "goal": "Write the parser.", "acceptance": ["it builds"], "auto_advance": false])
        try #require(await eventually(timeout: 120) { tools.calls().count == before + 1 }, "\(tools.calls())")
        try tools.call("start_worker", ["task": "write-the-parser"])
        let worker = try await Self.connected(node, label: "Worker: Write the parser", calling: "progress",
                                              ["task": "write-the-parser", "text": "starting"])
        try #require(await eventually(timeout: 120) { tools.calls().count == before + 2 }, "\(tools.calls())")
        #expect(tools.text(of: tools.calls()[before + 1]).contains("Worker started on write-the-parser"), "\(tools.calls()[before + 1])")
        let workerTools = node.fake.files(terminal: worker.tty)
        try workerTools.call("ask_lead", ["task": "write-the-parser", "question": "Which grammar?"])
        try #require(await eventually(timeout: 120) { workerTools.calls().count == 2 }, "\(node.said)")
        let asked = workerTools.text(of: workerTools.calls()[1])
        #expect(!asked.contains("no lead running"), "\(asked)")
        let handed = await eventually(timeout: 60) {
            node.inbox(lead.session.tty).contains { $0.text.contains("Which grammar?") && $0.agentPid == lead.agentPid }
        }
        #expect(handed, "the question isn't in the lead's inbox: \(node.inbox(lead.session.tty))\n\(node.said)")
    }

    // MARK: A real lead

    /// The user's throwaway Claude Code config folder, named on the run's command line only.
    static let configFolder = ProcessInfo.processInfo.environment["VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR"]

    /// What the real lead is asked: one question through its tool, then, once answered, a second; nothing else.
    static let realGoal = "A scripted run: do exactly this and nothing more, with no other tool and no file. "
        + "1. Use your ask_user tool now to ask the user exactly one question: which of two names to use for the project's parser, "
        + "with exactly two options, Parser and Reader. Then end your turn and wait: the answer comes as a message. "
        + "2. Once that answer has come, use ask_user once more to ask which of two names to use for the project's lexer, with exactly "
        + "two options, Lexer and Scanner, and end your turn. "
        + "3. Once that answer has come, say the two names the user chose in one line, and stop."

    /// The same with a real Claude Code on Sonnet as the lead (the scratch node's `<root>/v2/test/claude` a script that
    /// runs the account's `claude` with the config folder given and `--model sonnet`), both ways an answer reaches it:
    ///
    /// 1. It asks which of two names to use and ends its turn; `questions` lists the card. The user answers once the lead
    ///    is idle (its Stop hook said so: waited for, the realistic order), and the answer, recorded in the vault, is
    ///    typed in as its next prompt, the message as it is (its transcript's prompt has the digest the vault records).
    /// 2. Told the answer, it asks a second question, answered at once, its turn still running: nothing is typed, and its
    ///    own hook hands the answer over at its next step or its turn's end, under the user's sender line (which the
    ///    hook gives only a message whose seal the node's vault took), the inbox's delivered record gaining it, and what
    ///    it says next names the answer. A lead that asks no second question shows only the first (said, not failed:
    ///    what the model does next isn't the node's).
    ///
    /// Either answer is checked by the way it went (`reached`): a real lead's turn can end, or go on, a moment before or
    /// after the answer. Each step's time is printed (`E9:` lines) for the inventory.
    @Test(.enabled(if: configFolder != nil,
                   "starts a real Claude Code lead and spends a few prompts of the account's usage: set VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR to a Claude Code config folder you logged in once to run it"))
    func aRealLeadOnSonnetAsksAndIsAnswered() async throws {
        let config = URL(fileURLWithPath: try #require(Self.configFolder))
        try #require(FileManager.default.fileExists(atPath: config.appendingPathComponent(".claude.json").path),
                     "\(config.path) has no .claude.json: log in there once first")
        let claude = try #require(RealClaudeStatusTests.claudeExecutable(), "no claude on PATH")
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        let repo = node.root.appendingPathComponent("repo")
        // What the case writes into the user's folder, undone on every way out once it may have been written: the hooks
        // (`hooks install` may write before it fails) and the project's trust entry.
        var hooksWritten = false, trustWritten = false
        defer {
            node.stop()
            if trustWritten {
                do { try RealClaudeStatusTests.trust(repo.resolvingSymlinksInPath().path, in: config, false) } catch { Issue.record("the trust entry stayed: \(error)") }
            }
            if hooksWritten {
                do { try HookInstaller.uninstall(agent: .claude, at: config.appendingPathComponent("settings.json")) } catch {
                    Issue.record("the hooks stayed in \(config.path)/settings.json: \(error)")
                }
            }
        }
        try await scratchRepository(repo)
        try Self.workflow(repo)
        let project = repo.resolvingSymlinksInPath().path
        let version = try await run(URL(fileURLWithPath: claude), ["--version"],
                                    environment: RealClaudeStatusTests.agentEnvironment(node.root, config: config))
        print("E9: \(claude) --version: \(version.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        // The node's `claude`: a script running the account's, with the folder given, on Sonnet (its argv[0] stays a
        // path ending in claude, so the process table sees it as Claude).
        let quote = FakeClaude.quoted
        let script = node.testFolder.appendingPathComponent("real-claude")
        try ScratchNode.script("""
            #!/bin/sh
            export CLAUDE_CONFIG_DIR=\(quote(config.path)) DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
            exec \(quote(claude)) --model sonnet "$@"

            """, at: script)
        let link = node.testFolder.appendingPathComponent("claude")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: script.path)
        // Its status hooks (the user's settings' on the user's node, `hooks install`): in the config folder, written here
        // with `HookInstaller` (`hooks install` writes the node's own home only, the start plan's ST-D17), running this
        // node's build's hook, which writes the lead's state under the node's root (the lead has its
        // `VIBESWITCHER_HOME`). Without them the engine never sees the lead between turns, and types nothing into it.
        hooksWritten = true
        try HookInstaller.install(agent: .claude, at: config.appendingPathComponent("settings.json"),
                                  hookBinary: node.nodeRoot.appendingPathComponent("bin/vibeswitcher-hook").path)
        trustWritten = true
        try RealClaudeStatusTests.trust(project, in: config, true)

        let began = MacTime.real.awake()
        var mark = began
        func step(_ what: String) {
            let now = MacTime.real.awake()
            print(String(format: "E9: %@: %.1f s (%.1f s in all)", what, now - mark, now - began))
            mark = now
        }
        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: Git.run(["rev-parse", "main"], in: repo.path).output)
        step("1, config held and accepted, base shown and accepted")
        let started = try await node.runOnTerminal(["lead", repo.path, "--goal", Self.realGoal])
        try #require(started.status == 0 && started.output.contains("the lead started"), "\(started.output)\n\(node.said)")
        #expect(started.output.contains(script.resolvingSymlinksInPath().path), "\(started.output)")
        let lead = try #require(try node.sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") }, "\(node.said)")
        print("E9: the lead's terminal: \(lead.tty)")
        step("2, lead started")
        let stateFile = node.root.appendingPathComponent("state/\(lead.tty).json")
        let hooks = { HookState.load(from: stateFile) }
        let said = { node.said.replacingOccurrences(of: "\u{0}", with: " ") }
        // What the lead is at, for the record and for a run that fails: its screen (empty cells as spaces), its hooks'
        // last event, the board's questions.
        func look(_ when: String) {
            let screen = Platform.lines((node.screen(lead.id) ?? "no screen").replacingOccurrences(of: "\u{0}", with: " "))
                .map { String($0.reversed().drop { $0 == " " }.reversed()) }.filter { !$0.isEmpty }.joined(separator: "\n")
            let hook = hooks().map { "\($0.lastEvent) \($0.toolName ?? "") \($0.request ?? $0.notice ?? "")" } ?? "none"
            let questions = BoardStore(root: repo.path).load().questions.map { "\($0.text) \($0.options)" }
            print("E9: \(when): hook \(hook); board questions \(questions); the lead's screen:\n\(screen)")
        }
        /// The card of a question the lead asked (one not in `answered`), once `questions` lists it within `minutes`.
        func asked(besides answered: Set<String>, minutes: Int) async throws -> String? {
            var card: String?
            for wait in 0..<(2 * minutes) where card == nil {
                card = try await Self.listedCard(node, question: nil, besides: answered, timeout: 30)
                if card == nil { look("\(30 * (wait + 1)) s on, no card yet") }
            }
            return card
        }
        /// `answer CARD OPTION`, its code typed: the vault's record of the message it sends the lead, and how that
        /// message reached the lead (nil: not within 5 minutes).
        func answer(_ card: String, _ option: String) async throws -> (message: LeadVaultV2.UserAction, taken: Int, went: Reached?) {
            let taken = SteerInbox.delivered(tty: lead.tty, root: node.root).count
            let answered = try await node.runOnTerminal(["answer", card, option])
            #expect(answered.status == 0 && answered.output.contains("answered: the lead is told"), "\(answered.output)\n\(said())")
            let message = try await Self.usersMessage(node, card: card)
            let went = await Self.reached(digest: message.digest, transcript: { hooks()?.transcriptPath }, timeout: 300)
            return (message, taken, went)
        }
        /// What `went` must be, either way: the message as it is (the digest the vault records is its text's), the user's.
        func check(_ went: Reached?, _ answered: (message: LeadVaultV2.UserAction, taken: Int, went: Reached?), option: String) {
            switch went {
            case .typed(let prompt)?:
                #expect(prompt.hasPrefix("Answer to your question") && prompt.hasSuffix(": \(option)"), "\(prompt)")
                #expect(!prompt.hasPrefix(LeadDelivery.prefix), "typed as the user's, not as a system's: \(prompt)")
            case .handed(let text, let fromLead)?:
                // The user's sender line: the hook gives it only a message whose seal the node's vault took.
                #expect(!fromLead, "handed over as the user's: \(text)")
                #expect(text.hasPrefix("Answer to your question") && text.hasSuffix(": \(option)") && !text.hasPrefix(LeadDelivery.prefix), "\(text)")
                // The node's record: its inbox's delivered record gained it, and it waits there no more.
                #expect(SteerInbox.delivered(tty: lead.tty, root: node.root).count > answered.taken)
                #expect(!node.inbox(lead.tty).contains { LeadVaultV2.digest($0.text) == answered.message.digest }, "\(node.inbox(lead.tty))")
            case nil:
                look("5 min after the answer, it reached the lead neither way")
                Issue.record("the answer \(option) reached the lead neither as its prompt nor through its hook: \(String(describing: hooks()))\n\(said())")
            }
        }

        // 1. It asks and ends its turn; the user answers the idle lead: typed in as its next prompt.
        guard let first = try await asked(besides: [], minutes: 5) else {
            Issue.record("no card in 5 min: \(said())")
            return
        }
        look("the card listed")
        let listed = try await node.runOnTerminal(["questions"])
        print("E9: questions:\n" + listed.output.trimmingCharacters(in: .whitespacesAndNewlines))
        let question = try #require(BoardStore(root: repo.path).load().questions.first, "the board has no question")
        #expect(question.options.contains { $0.contains("Parser") } && question.options.contains { $0.contains("Reader") }, "\(question)")
        step("3, the lead asked; questions lists the card")
        let idle = await eventually(timeout: 180) { hooks()?.lastEvent == "Stop" }
        if !idle { look("3 min after it asked, its turn hasn't ended") }
        try #require(idle, "the lead's turn never ended after it asked: \(String(describing: hooks()))\n\(said())")
        step("4, its turn ended (its Stop hook)")
        let one = try await answer(first, "Reader")
        step("5, answered, the code typed; the answer \(Self.word(one.went))")
        check(one.went, one, option: "Reader")
        if case .typed? = one.went {
            // Its own UserPromptSubmit hook recorded the prompt.
            #expect(await eventually(timeout: 30) { (hooks()?.lastPrompt ?? "").hasPrefix("Answer to your question") }, "\(String(describing: hooks()))")
        }
        if case .typed? = one.went {} else { print("E9: the idle lead's answer wasn't typed in as its prompt") }

        // 2. Told the answer, it asks again; answered at once, mid-turn: its own hook hands it over.
        let second = try await asked(besides: [first], minutes: 3)
        if let second {
            look("the second card listed")
            step("6, the lead asked again")
            let two = try await answer(second, "Scanner")
            step("7, answered at once, the code typed; the answer \(Self.word(two.went))")
            check(two.went, two, option: "Scanner")
            if two.went != nil {
                // What it says next names the answer: its own words after the answer in its transcript (the message its
                // Stop hook reported as it handed the answer over came before it, and names both options).
                var next: [String] = []
                let deadline = MacTime.real.awake() + 180
                while !next.contains(where: { $0.localizedCaseInsensitiveContains("Scanner") }), MacTime.real.awake() < deadline {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    next = hooks()?.transcriptPath.map { Self.said(after: two.message.digest, transcript: $0) } ?? []
                }
                #expect(next.contains { $0.localizedCaseInsensitiveContains("Scanner") }, "what it said after the answer: \(next)")
                print("E9: what it said after the second answer: \(next.joined(separator: " / "))")
                let seen = Date().timeIntervalSince1970
                _ = await eventually(timeout: 60) { hooks().map { $0.lastEvent == "Stop" && $0.lastEventAt >= seen - 1 } == true }
                step("8, it named the answer, and its turn ended")
            }
            // Each answer once, one way or the other.
            let transcript = hooks()?.transcriptPath.map(Self.reached(transcript:))
            for answered in [one, two] {
                let times = (transcript?.prompts.filter { LeadVaultV2.digest($0) == answered.message.digest }.count ?? 0)
                    + (transcript?.handed.filter { LeadVaultV2.digest($0.text) == answered.message.digest }.count ?? 0)
                #expect(times == 1 || answered.went == nil, "an answer reached the lead \(times) times")
            }
        } else {
            print("E9: the lead asked no second question in 3 min: this run shows only the answer typed into the idle lead")
        }
        print("E9: its last message: \(hooks()?.lastMessage ?? "none")")
        look("at the end")
    }

    // MARK: Helpers

    /// The vault's record of the message the user's answer to `card` sends its lead, once it's there: the `answer`
    /// request's action first, then the message's digest under the same action (kind `message`).
    static func usersMessage(_ node: ScratchNode, card: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> LeadVaultV2.UserAction {
        var actions: [LeadVaultV2.UserAction] = []
        var found: (answer: LeadVaultV2.UserAction, message: LeadVaultV2.UserAction)?
        let deadline = MacTime.real.awake() + 60
        while found == nil, MacTime.real.awake() < deadline {
            actions = (try? await ScratchRunTests.userActions(node)) ?? []
            if let answer = actions.first(where: { $0.kind == "answer" && $0.subject == card }),
               let message = actions.first(where: { $0.kind == "message" && $0.action == answer.action }) {
                found = (answer, message)
            } else {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let recorded = try #require(found, "the vault holds no answer to \(card) with its message: \(actions)", sourceLocation: sourceLocation)
        #expect(recorded.answer.at <= recorded.message.at, sourceLocation: sourceLocation)
        return recorded.message
    }

    /// How a message reached a lead, as its Claude Code transcript records it.
    enum Reached: Equatable {
        /// Typed in as its prompt: the prompt.
        case typed(String)
        /// Handed over by its hook (the hook's added context): the message's text, and whether its sender line is a
        /// lead's or VibeSwitcher's (false: the user's).
        case handed(String, fromLead: Bool)
    }

    static func word(_ went: Reached?) -> String {
        switch went {
        case .typed?: return "typed into the lead as its prompt"
        case .handed?: return "handed over by the lead's own hook"
        case nil: return "reached the lead neither way"
        }
    }

    /// What reached the agent whose Claude Code transcript is at `path`: the prompts typed in (its user lines whose
    /// content is text) and the messages its hooks handed over (`hook_additional_context`, each context as the hook
    /// wrote it: `SteerReply.messages(inContext:)`). Claude Code's larger lines (its requests) are neither.
    static func reached(transcript path: String) -> (prompts: [String], handed: [(text: String, fromLead: Bool)]) {
        var prompts: [String] = [], handed: [(text: String, fromLead: Bool)] = []
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") where line.utf8.count < 100_000 {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["type"] as? String == "user", let prompt = (object["message"] as? [String: Any])?["content"] as? String { prompts.append(prompt) }
            if let attachment = object["attachment"] as? [String: Any], attachment["type"] as? String == "hook_additional_context" {
                for context in attachment["content"] as? [String] ?? [] { handed += SteerReply.messages(inContext: context) }
            }
        }
        return (prompts, handed)
    }

    /// The agent's own words after the message whose text has `digest` reached it, typed in or handed over by its hook:
    /// the text of its transcript's assistant lines after that line.
    static func said(after digest: String, transcript path: String) -> [String] {
        var reached = false, said: [String] = []
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") where line.utf8.count < 100_000 {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let message = object["message"] as? [String: Any]
            if object["type"] as? String == "user", let prompt = message?["content"] as? String,
               LeadVaultV2.digest(prompt.trimmingCharacters(in: .whitespacesAndNewlines)) == digest { reached = true }
            if let attachment = object["attachment"] as? [String: Any], attachment["type"] as? String == "hook_additional_context",
               (attachment["content"] as? [String] ?? []).contains(where: { SteerReply.messages(inContext: $0).contains { LeadVaultV2.digest($0.text) == digest } }) {
                reached = true
            }
            guard reached, object["type"] as? String == "assistant" else { continue }
            said += (message?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
        }
        return said
    }

    /// How the message whose text has `digest` (the vault's record of it) reached the lead, once its transcript shows
    /// it within `timeout`: typed in as a prompt, or handed over by its hook; nil when neither.
    static func reached(digest: String, transcript: () -> String?, timeout: TimeInterval) async -> Reached? {
        let deadline = MacTime.real.awake() + timeout
        while MacTime.real.awake() < deadline {
            if let path = transcript() {
                let reached = reached(transcript: path)
                // As Claude Code kept it: a paste's last line break may be gone.
                let prompts = reached.prompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let prompt = prompts.first(where: { LeadVaultV2.digest($0) == digest }) { return .typed(prompt) }
                if let handed = reached.handed.first(where: { LeadVaultV2.digest($0.text) == digest }) { return .handed(handed.text, fromLead: handed.fromLead) }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    /// `repo`'s workflow.md: one finder (one verifier, no test run before it), a test command that passes.
    static func workflow(_ repo: URL) throws {
        let path = ConfigHoldStore.workflowPath(root: repo.path)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "---\ntest_command: true\nmerge_policy: ask_all\naudit_finders: 1\n---\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The machine's limits under the node's root (`mac-limits.json`, which the leads' tool servers and the room watch
    /// read): `maxSessions` team sessions at most, and no load or memory hold (the test machine's own load isn't the
    /// case's).
    static func limits(_ node: ScratchNode, maxSessions: Int) throws {
        try node.noLoadHold(maxSessions: maxSessions)
    }

    /// A fake's state file, read now.
    static func state(_ files: FakeClaude.Files) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: files.state))) as? [String: Any] ?? [:]
    }

    /// Appends `command` to a fake's control file.
    static func tell(_ files: FakeClaude.Files, _ command: [String: Any]) throws {
        let handle = try FileHandle(forWritingTo: files.control)
        handle.seekToEndOfFile()
        handle.write(try JSONSerialization.data(withJSONObject: command) + Data("\n".utf8))
        try handle.close()
    }

    /// The prompts a fake took: its transcript's user lines whose content is text.
    static func prompts(_ files: FakeClaude.Files) -> [String] {
        let text = (try? String(contentsOf: files.transcript, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any] else { return nil }
            return message["content"] as? String
        }
    }

    /// The first prompt the fake took that `matches`, once it comes.
    static func prompt(_ files: FakeClaude.Files, timeout: TimeInterval = 120, sourceLocation: SourceLocation = #_sourceLocation,
                       _ matches: @escaping (String) -> Bool) async throws -> String {
        _ = await eventually(timeout: timeout) { prompts(files).contains(where: matches) }
        return try #require(prompts(files).first(where: matches), "no such prompt; the prompts: \(prompts(files))", sourceLocation: sourceLocation)
    }

    /// The live session labelled `label`, once the host lists it.
    static func session(_ node: ScratchNode, label: String, detail: String = "") async throws -> HostSession {
        var found: HostSession?
        _ = await eventually(timeout: 60) {
            found = (try? node.sessions())?.first { $0.isLive && $0.label == label }
            return found != nil
        }
        return try #require(found, "no live session \(label): \(detail)\n\(node.said)")
    }

    /// The live session labelled `label` once the host lists it, its fake's tool server started by a call of `tool`
    /// (as Claude Code starts its MCP servers as it starts: the role's start waits for that).
    static func connected(_ node: ScratchNode, label: String, calling tool: String, _ arguments: [String: Any]) async throws -> HostSession {
        let session = try await session(node, label: label)
        let files = node.fake.files(terminal: session.tty)
        try #require(await eventually(timeout: 60) { state(files)["pid"] != nil }, "\(node.said)")
        try files.call(tool, arguments)
        try #require(await eventually(timeout: 60) { files.calls().count == 1 }, "\(state(files))")
        return session
    }

    /// The id of the card the server's `questions` lists for `question` (any question's when nil), once it does: asked
    /// over the wire, one connection a look (no child process each time), and then `questions --json` from the command
    /// line lists it too.
    static func card(_ node: ScratchNode, question: String?, timeout: TimeInterval = 60) async throws -> String {
        let card = try #require(try await listedCard(node, question: question, timeout: timeout), "no card for \(question ?? "a question"): \(node.said)")
        let ran = try await node.run(["questions", "--json"])
        #expect(ran.status == 0 && ran.output.contains(card), "\(ran.output)\(ran.errors)")
        return card
    }

    /// The id of the card the server's `questions` lists for `question` (any question's when nil; never one of
    /// `besides`), once it does within `timeout`; nil when none does.
    static func listedCard(_ node: ScratchNode, question: String?, besides: Set<String> = [], timeout: TimeInterval) async throws -> String? {
        var listed: String?
        let deadline = MacTime.real.awake() + timeout
        while listed == nil, MacTime.real.awake() < deadline {
            listed = await offPool { () -> String? in
                guard let client = try? WireClient(node), let reply = WireClient.reply(client.request("questions", action: nil, timeout: 10)),
                      let cards = reply.result?["cards"]?.array else { return nil }
                return cards.first { card in
                    (question == nil || card["question"]?["text"]?.string == question) && card["id"]?.string.map(besides.contains) == false
                }?["id"]?.string
            }
            if listed == nil { try await Task.sleep(nanoseconds: 300_000_000) }
        }
        return listed
    }
}

/// What Claude Code's hook would write for `payload` (`HookState.reduce`, as `vibeswitcher-hook` folds it) in the node's
/// state folder, for the agent `pid` on `tty`, now.
func hook(_ node: ScratchNode, _ payload: [String: Any], tty: String, pid: Int32) throws {
    let file = node.root.appendingPathComponent("state/\(tty).json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard case .write(let state) = HookState.reduce(current: HookState.load(from: file), payload: payload, agent: .claude, tty: tty,
                                                    agentPid: pid, now: Date().timeIntervalSince1970) else {
        throw HostCall.Failure(description: "the hook wouldn't write \(payload)")
    }
    try state.save(to: file)
}

/// The lead's prompt's hook (UserPromptSubmit, as `vibeswitcher-hook` answers it against the node's root): it takes what
/// waits in the lead's inbox, the reports a wake-up was typed for with it. What it handed over ("" when nothing).
func promptHookTakes(_ node: ScratchNode, tty: String, pid: Int32) -> String {
    var handed = ""
    SteerReply.answer(["hook_event_name": "UserPromptSubmit"], tty: tty, agentPid: pid, root: node.root) { data in
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        handed = ((reply?["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String) ?? ""
        return true
    }
    return handed
}

/// The lead's hook at `event` (Stop, PostToolUse: as `vibeswitcher-hook` answers it on the node, `SteerReply.answer`),
/// its seals checked by the node's host's vault as the hook's are there: the messages it handed over, each as the vault
/// lets it be delivered (one with no valid seal demoted to an unverified sender's), and the context it printed for
/// Claude Code ("" when nothing).
func leadsHookTakes(_ node: ScratchNode, event: String, tty: String, pid: Int32) -> (messages: [SteerMessage], context: String) {
    let socket = node.socket
    let sealer = SteerSeal(seal: { _ in throw LeadVault.Refused("the test seals nothing") }, verify: { messages in
        guard case .verified(let valid)? = try? HostCall.vault(.verify(messages), socket: socket) else { return nil }
        return valid
    })
    var handed: [SteerMessage] = []
    SteerInbox.deliver(tty: tty, agentPid: pid, root: node.root, sealer: sealer, check: { SteerInbox.writeCheck($0, ids: $1) }, inParts: true,
                       holding: Date().timeIntervalSince1970, wakingOnly: true) { messages in
        guard SteerReply.output(event: event, messages: messages) != nil else { return 0 }
        handed = messages
        return messages.count
    }
    return (handed, handed.isEmpty ? "" : SteerReply.context(handed))
}

extension ScratchNode {
    /// A session's screen as the host draws it now (one round trip; nil when it didn't answer).
    func screen(_ id: UUID) -> String? { HostCall.styledScreen(id, socket: socket, appKey: nil)?.text }
}
