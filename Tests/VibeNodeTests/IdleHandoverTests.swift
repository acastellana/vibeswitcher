import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The idle handover (main's `26923f7c`; the app's `LeadRotationTests` idle cases restated on the engine): a lead idle
/// past `handover_idle_min` with at least `handover_tokens` of context and a cold prompt cache goes to a fresh lead with
/// VibeSwitcher's note. On a scratch host in the test process (`NodeTestHost`), the lead a `FakeClaude` bound to the
/// lead's role and named on the board, its transcript one the test writes under the scratch home, the engine's clock
/// injected (`handoverNow`) and each look a refresh waited on through `handoverEvent`. Asking a warm lead for its own
/// note is owed with rotation, so a warm idle stays here.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct IdleHandoverTests {
    private let scratch = Scratch()

    final class World: @unchecked Sendable {
        let host: NodeTestHost
        let fake: FakeClaude.Install
        let repo: String
        let link: HostLink
        let engine: LeadEngine
        let queue = DispatchQueue(label: "idle-handover-tests.engine")
        let spawns = Locked<[SpawnRequest]>([])
        let events = Locked<[String]>([])
        /// The engine's now: past its start's two-minute quiet.
        let clock = Locked(Date().addingTimeInterval(5 * 60))
        var lead: NodeHarness!
        var transcript: URL!

        init(_ scratch: Scratch) async throws {
            host = try NodeTestHost(scratch)
            fake = try FakeClaude.install(in: host.folder.appendingPathComponent("fake", isDirectory: true))
            let folder = host.folder.appendingPathComponent("repo", isDirectory: true)
            try await scratchRepository(folder)
            repo = folder.resolvingSymlinksInPath().path
            let nodeRoot = host.folder.appendingPathComponent("build", isDirectory: true)
            try FileManager.default.createDirectory(at: nodeRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: nodeRoot.appendingPathComponent("bin/vibeswitcher-mcp").path,
                                                       withDestinationPath: builtProducts.appendingPathComponent("vibeswitcher-mcp").path)
            let claudeLink = host.folder.appendingPathComponent("claude-link").path
            try FileManager.default.createSymbolicLink(atPath: claudeLink, withDestinationPath: fake.launcher.path)
            var options = LeadEngine.Options()
            options.claudeLink = claudeLink
            options.answersTrust = false
            options.home = host.home.path
            link = HostLink(dialer: host.dialer, root: host.root, queue: queue)
            engine = LeadEngine(root: host.root, nodeRoot: nodeRoot, link: link, clock: nil, options: options)
            let (engine, spawns, events, clock) = (engine, spawns, events, clock)
            link.onWelcome = { _, _ in engine.welcomed() }
            queue.sync {
                engine.freeSpace = { _ in nil }
                engine.spawning = { request in spawns.mutate { $0.append(request) } }
                engine.handoverNow = { clock.value }
                engine.handoverEvent = { event in events.mutate { $0.append(event) } }
            }
            link.start()
            _ = await eventually(timeout: 60) { self.queue.sync { self.link.state == .connected } }
            try await startLead()
        }

        var project: String { NodeIds.project(root: repo) }
        var name: String { (repo as NSString).lastPathComponent }
        var now: Date { clock.value }
        func stop() { host.stop() }

        /// The session the vault binds the lead's role to.
        func holder() -> String? { host.vault.current(.lead, root: repo, task: nil)?.session }

        /// The fake as the repository's lead: its role bound, the board naming it, its hooks between turns with the
        /// transcript the test writes.
        private func startLead() async throws {
            lead = try await NodeHarness.start(on: host, fake: fake, cwd: repo, label: "Lead · \(name)")
            let pid = try #require(lead.agentPid)
            let (vault, repo, id, tty) = (host.vault, repo, lead.session.id, lead.session.tty)
            try await offPool {
                let grant = try vault.startLead(root: repo, branch: "main")
                try vault.bind(grant, root: repo, session: id.uuidString)
                try BoardStore(root: repo).prepare()
                try BoardStore(root: repo).update { board in
                    board.leadSession = id.uuidString
                    board.leadPid = pid
                    board.leadTTY = tty
                    var open = LeadQuestion(id: "open", text: "Which colour?", options: ["red", "blue"])
                    open.askedAt = Date().timeIntervalSince1970 - 3 * 3600
                    board.questions = [open]
                }
            }
            let projects = host.home.appendingPathComponent(".claude/projects/repo", isDirectory: true)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            transcript = projects.appendingPathComponent("\(UUID().uuidString).jsonl")
            try hook("Stop")
            _ = await eventually(timeout: 60) { self.queue.sync { self.engine.leads.leads[self.project]?.session == id } }
        }

        /// The lead's hooks said `event`, its transcript where the test writes it.
        func hook(_ event: String) throws {
            var state = HookState(agent: .claude, tty: lead.session.tty, lastEvent: event, lastEventAt: Date().timeIntervalSince1970)
            state.agentPid = lead.agentPid
            state.transcriptPath = transcript.path
            let file = host.root.appendingPathComponent("state/\(lead.session.tty).json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try state.save(to: file)
        }

        /// The lead's transcript: the user's turn and its reply `age` before now with `tokens` of context, and a
        /// compaction after it when `compacted`.
        func write(tokens: Int = 238_000, age: TimeInterval, compacted: Bool = false) throws {
            func line(_ object: [String: Any]) throws -> String {
                String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
            }
            let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))
            var text = try line(["type": "user", "uuid": "u", "timestamp": stamp, "message": ["role": "user", "content": "keep my promise"]])
            text += try line(["type": "assistant", "uuid": "reply", "timestamp": stamp,
                              "message": ["role": "assistant", "model": "claude-opus-4-6", "stop_reason": "end_turn",
                                          "usage": ["input_tokens": tokens],
                                          "content": [["type": "text", "text": "I promised a result."]]]])
            if compacted {
                text += try line(["type": "system", "subtype": "compact_boundary", "timestamp": ISO8601DateFormatter().string(from: now),
                                  "compactMetadata": ["trigger": "auto", "preTokens": tokens, "postTokens": 40000]])
            }
            try text.write(to: transcript, atomically: true, encoding: .utf8)
        }

        /// One refresh, waited on until the idle look it makes ends: the event it ended with.
        func look() async -> String? {
            let before = events.value.count
            engine.refresh()
            _ = await eventually(timeout: 180) { self.events.value.count > before }
            return events.value.dropFirst(before).first
        }

        /// One refresh that hands the lead over: the fresh lead's session, once the role is its.
        func handedOver(sourceLocation: SourceLocation = #_sourceLocation) async throws -> UUID {
            let event = await look()
            #expect(event == "handed over", "the look ended: \(event ?? "never")", sourceLocation: sourceLocation)
            return try #require(holder().flatMap(UUID.init(uuidString:)).flatMap { $0 == lead.session.id ? nil : $0 },
                                sourceLocation: sourceLocation)
        }
    }

    @Test func pastTheCacheLifetimeAFreshLeadGetsVibeSwitchersNoteAndTheLastTurns() async throws {
        let world = try await World(scratch)
        defer { world.stop() }
        let store = BoardStore(root: world.repo)
        try store.update { board in
            board.tasks = [LeadTask(slug: "running-task", title: "Still running",
                                    contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))]
        }
        try store.appendDecision("Keep the board across handovers", why: "The fresh lead starts from it")
        try world.write(age: 70 * 60)
        let fresh = try await world.handedOver()
        let board = store.load()
        #expect(board.leadSession == fresh.uuidString, "The next delivery goes to the board's lead: the fresh one")
        let note = try String(contentsOfFile: store.folder + "/scheduled-lead-handover.md", encoding: .utf8)
        #expect(note.contains("VibeSwitcher wrote this note") && note.contains("idle 70 minutes with 238k tokens"))
        let turns = try String(contentsOfFile: LeadLaunch.turnsFile(root: world.repo), encoding: .utf8)
        #expect(turns.contains("keep my promise"), "The fresh lead still gets the last turns with the user")
        let spawn = try #require(world.spawns.value.last)
        #expect(spawn.label == "Lead · \(world.name)" && spawn.command?.contains("scheduled-lead-handover.md") == true)
        // On the run the app gives a lead (`LeadLaunch.leadRun`): workflow.md names none, so Fable.
        #expect(spawn.command?.contains("--model 'fable'") == true, "\(spawn.command?.prefix(400) ?? "")")
        let said = try #require(world.queue.sync { world.engine.leads.leads[world.project]?.lastStart })
        #expect(said.contains("Started a fresh lead session at ") && said.contains("prompt cache had expired"))
        // The lead's records carry over untouched: the board's tasks and open questions, the decisions.
        #expect(board.tasks.map(\.slug) == ["running-task"])
        #expect(board.openQuestions.map(\.id) == ["open"])
        let decisions = try String(contentsOfFile: store.recordPath("decisions.md"), encoding: .utf8)
        #expect(decisions.contains("Keep the board across handovers"))
        let progress = try String(contentsOfFile: store.recordPath("progress.md"), encoding: .utf8)
        #expect(progress.contains("Handed the lead over to a fresh session: the last one had been idle 70 minutes with 238k tokens of context"))
        // The old session runs on as a replaced lead, without the role.
        #expect(await eventually(timeout: 60) { world.queue.sync { world.engine.leads.leads[world.project]?.replaced[world.lead.session.id] != nil } })
    }

    @Test func beforeTheThresholdOrWhileTheCacheIsWarmTheLeadStays() async throws {
        let world = try await World(scratch)
        defer { world.stop() }
        try world.write(age: 49 * 60)
        #expect(await world.look() == "checked")
        #expect(world.holder() == world.lead.session.id.uuidString && world.spawns.value.isEmpty, "49 minutes idle: the lead keeps its context")
        try world.write(age: 52 * 60)
        #expect(await world.look() == "checked")
        #expect(world.spawns.value.isEmpty, "Past the threshold on a warm cache: asking for the lead's own note is owed with rotation")
        try world.write(age: 56 * 60)
        _ = try await world.handedOver()
    }

    @Test func aSmallContextStaysWithTheLeadHoweverLongItIdles() async throws {
        let world = try await World(scratch)
        defer { world.stop() }
        try world.write(tokens: 120_000, age: 70 * 60)
        #expect(await world.look() == "checked")
        #expect(world.spawns.value.isEmpty && world.holder() == world.lead.session.id.uuidString)
    }

    @Test func aQuestionJustAskedOrARunningTurnKeepsTheLead() async throws {
        let world = try await World(scratch)
        defer { world.stop() }
        let store = BoardStore(root: world.repo)
        let now = world.now.timeIntervalSince1970
        try store.update { board in
            var question = LeadQuestion(id: "fresh", text: "Ship it?", options: ["yes", "no"])
            question.askedAt = now - 5 * 60
            board.questions.append(question)
        }
        try world.write(age: 70 * 60)
        #expect(await world.look() == "checked")
        #expect(world.spawns.value.isEmpty, "A question to the user 5 minutes old and unanswered: the conversation is open")
        try store.update { board in board.questions = board.questions.filter { $0.id != "fresh" } }
        try world.hook("PreToolUse")
        #expect(await world.look() == "checked")
        #expect(world.spawns.value.isEmpty, "The lead's turn is running")
        try world.hook("Stop")
        _ = try await world.handedOver()
    }

    @Test func aLeadClaudeCodeAlreadyCompactedIsLeftAlone() async throws {
        let world = try await World(scratch)
        defer { world.stop() }
        try world.write(age: 70 * 60, compacted: true)
        #expect(await world.look() == "checked")
        #expect(world.spawns.value.isEmpty)
    }

    @Test func theIdleRuleIsOffWithTheSetting() async throws {
        let world = try await World(scratch)
        defer { world.stop() }
        let file = BoardStore(root: world.repo).folder + "/workflow.md"
        let off = LeadWorkflow.updating(try Data(contentsOf: URL(fileURLWithPath: file)), with: [("handover_idle_min", "0")])
        try LeadWorkflow.write(off, to: file)
        try world.write(age: 70 * 60)
        #expect(await world.look() == "checked")
        #expect(world.spawns.value.isEmpty)
        try LeadWorkflow.write(LeadWorkflow.updating(off, with: [("handover_idle_min", "50")]), to: file)
        _ = try await world.handedOver()
    }

    @Test func aLeadWhoseRoleTheVaultBindsElsewhereIsNotHandedOver() async throws {
        let world = try await World(scratch)
        defer { world.stop() }
        try world.write(age: 70 * 60)
        // The board names another session than the vault's: nothing here may move the role.
        try BoardStore(root: world.repo).update { board in board.leadSession = UUID().uuidString }
        let event = await world.look()
        #expect(event == "checked" || event == nil)
        #expect(world.spawns.value.isEmpty && world.holder() == world.lead.session.id.uuidString)
    }
}
