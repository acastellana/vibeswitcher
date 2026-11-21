import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// AI summaries of what each agent is doing (the parity table's row; `TeamSummaryWatch`): after a refresh, a line is
/// asked for each task at work whose agent's session is live, of the model the engine is given (here a fake: no model
/// is ever run by a test), rate-limited per agent, off with Settings' AI summaries and while the usage holds Haiku back;
/// the lines reach the boards (`teamSummaries`, `BoardValue`'s `summary`). Each test has a scratch root and host;
/// nothing is slept on.
// A scratch host starts the sessions these use: on Linux only, as BoardNodeTests (the Mac's host refuses a scratch spawn).
@Suite(NodeTraits.linuxOnly)
struct TeamSummaryWatchTests {
    private let scratch = Scratch()

    /// A fake model: each prompt it was given, and the line it answers.
    final class Model: @unchecked Sendable {
        let prompts = Locked<[String]>([])
        let answer: String
        init(answer: String = "Writing the retry's tests") { self.answer = answer }
        var generate: Summarizer.Generate { { [self] prompt in prompts.mutate { $0.append(prompt) }; return answer } }
    }

    /// The engine's summarizer on `model`, as `Options.summarize` makes it (its model runs on `summaryRuns`, its lines
    /// delivered on the engine's queue).
    static func give(_ world: DeliveryWorld, _ model: Model) {
        world.queue.sync {
            let (runs, queue) = (world.engine.summaryRuns, world.queue)
            let summarizer = Summarizer(generate: model.generate, run: { runs.async(execute: $0) }, deliver: { queue.async(execute: $0) })
            let engine = world.engine
            summarizer.changed = { [weak engine] in engine?.publishSummaries() }
            world.engine.summarizer = summarizer
        }
    }

    static func lines(_ world: DeliveryWorld) -> [String: String]? { world.queue.sync { world.engine.teamSummaries.values[world.repo] } }

    /// A running task whose worker is a live session on the scratch host, and its team as the refresh reads it.
    static func running(_ world: DeliveryWorld) async throws -> (task: LeadTask, worker: NodeHarness) {
        let worker = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: world.repo, label: "Worker: retry")
        var task = LeadTask(slug: "retry", title: "Retry a failed upload once",
                            contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""), status: .running)
        task.worker = worker.session.id.uuidString
        task.checkpoints = [LeadCheckpoint(text: "The retry runs once; writing its tests", at: Date().timeIntervalSince1970)]
        let repo = world.repo
        try await offPool { try BoardStore(root: repo).update { $0.tasks.append(task) } }
        return (task, worker)
    }

    /// A refresh with the summaries on asks the model once for the running task's worker, from its title and its
    /// checkpoint, and its line reaches `teamSummaries`; the next refresh, nothing having changed, asks nothing (one
    /// line an agent, only when its input changed). Settings' AI summaries off: the lines go, nothing more is asked.
    @Test func aRefreshWritesALineForEachAgentAtWorkOnceAndTheSettingStopsIt() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let model = Model()
        Self.give(world, model)
        _ = try await world.lead()
        let (task, _) = try await Self.running(world)

        world.engine.refresh()
        #expect(await eventually(timeout: 60) { Self.lines(world)?[task.id] == model.answer }, "\(String(describing: Self.lines(world)))")
        let prompt = try #require(model.prompts.value.first)
        #expect(prompt.contains("Task: Retry a failed upload once") && prompt.contains("The retry runs once; writing its tests"), "\(prompt)")
        #expect(prompt.contains("software agent"))

        world.engine.refresh()
        await world.drained()
        world.queue.sync {}
        world.engine.summaryReads.sync {}
        world.engine.summaryRuns.sync {}
        #expect(model.prompts.value.count == 1, "\(model.prompts.value)")

        let applied = try NodeSettings.setNode(try #require(NodeSettings.setting("ai_summaries")), to: "off", files: NodeSettings.Files(root: world.host.root))
        #expect(applied.value == "off" && applied.was == "on")
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { Self.lines(world) == nil }, "\(String(describing: Self.lines(world)))")
        #expect(model.prompts.value.count == 1)
    }

    /// While the account's usage holds Haiku back (an every-model limit at the threshold), no line is asked and those
    /// written go; with no model given (a scratch node's engine), nothing is looked at.
    @Test func noLineWhileTheUsageHoldsHaikuBackOrWithNoModel() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.lead()
        let (task, _) = try await Self.running(world)
        let store = AccountUsageStore(file: world.host.root.appendingPathComponent("account-usage.json"), home: world.host.home.path)
        let at = Date().timeIntervalSince1970

        // No model: the refresh sends no summaries at all.
        world.engine.refresh()
        await world.drained()
        #expect(world.queue.sync { world.engine.teamSummaries.values.isEmpty && world.engine.summarizer == nil })

        let model = Model()
        Self.give(world, model)
        store.record([AccountUsage.Limit(name: "five_hour", usedPercent: 96, resetsAt: at + 3600, at: at)])
        world.engine.refresh()
        await world.drained()
        world.engine.summaryReads.sync {}
        world.engine.summaryRuns.sync {}
        #expect(model.prompts.value.isEmpty)
        #expect(Self.lines(world)?[task.id] == nil)
    }

    /// A line is sent only while its task is at work: a running task's (its own words otherwise), never a blocked one's
    /// nor a review waiting on a limit.
    @Test func theBoardCarriesALineOnlyForATaskAtWork() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func task(_ slug: String, _ status: LeadTask.Status) -> LeadTask {
            var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""), status: status)
            task.review = .audit
            return task
        }
        var board = LeadBoard()
        board.tasks = [task("working", .running), task("blocked", .blocked), task("held", .review), task("reviewed", .review)]
        let summaries = Dictionary(uniqueKeysWithValues: board.tasks.map { ($0.id, "Doing \($0.slug)") })
        let value = BoardValue.value(project: "p", root: "/r", board: board, now: now,
                                     usageWaits: [board.tasks[2].id: ReviewUsageWait(model: "fable", resetsAt: nil)], summaries: summaries)
        let tasks = try #require(value["tasks"]?.array)
        func summary(_ slug: String) -> NodeWire.Value? { tasks.first { $0["slug"] == .string(slug) }?["summary"] }
        #expect(summary("working") == .string("Doing working"))
        #expect(summary("reviewed") == .string("Doing reviewed"))
        #expect(summary("blocked") == .null && summary("held") == .null)
        #expect(WireSchema.check(value, as: "board") == nil)
        // The command line's row says the summary in its line's place.
        let shown = BoardText.line(try #require(tasks.first { $0["slug"] == .string("working") }), now: now)
        #expect(shown.hasSuffix(" — Doing working"), "\(shown)")
    }

    /// Settings: AI summaries on by default (the app's), off and back by `set`; the left-out list no longer names them.
    @Test func theSettingIsOnByDefaultAndSetsOff() throws {
        let files = NodeSettings.Files(root: scratch.url("node-root"))
        try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
        let setting = try #require(NodeSettings.setting("ai_summaries"))
        #expect(setting.scope == .node && setting.form == .flag && setting.home == .preferences)
        #expect(NodeSettings.node(files: files).first { $0.setting.key == "ai_summaries" }?.value == "on")
        _ = try NodeSettings.setNode(setting, to: "off", files: files)
        #expect(!NodeSummaries.isOn(files.preferences))
        _ = try NodeSettings.setNode(setting, to: nil, files: files)
        #expect(NodeSummaries.isOn(files.preferences))
        #expect(!NodeSettings.leftOut.contains { $0.title.contains("AI summaries") })
    }

    /// The headless model's folder is made under the node's root and emptied; one that is a link isn't used (its
    /// target's files would be what's emptied).
    @Test func theModelsFolderIsEmptiedAndALinkRefused() throws {
        let root = scratch.url("summaries-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let made = try #require(NodeSummaries.folder(root: root))
        try Data("left".utf8).write(to: URL(fileURLWithPath: made).appendingPathComponent("left.txt"))
        #expect(NodeSummaries.folder(root: root) == made)
        #expect(try FileManager.default.contentsOfDirectory(atPath: made).isEmpty)

        let other = scratch.url("summaries-linked")
        let target = scratch.url("summaries-target")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("headless"), withDestinationURL: target)
        #expect(NodeSummaries.folder(root: other) == nil)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("keep.txt").path))
    }

    // MARK: Decisions and messages

    /// The lead's decisions reach the board through a refresh (decisions.md read, newest first), whatever the
    /// summaries do; a long one gets its line once, a short one never asks.
    @Test func aLongDecisionGetsItsLineOnceAndEveryDecisionReachesTheBoard() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let model = Model(answer: "Run the two small tasks side by side")
        Self.give(world, model)
        _ = try await world.lead()
        let repo = world.repo
        let long = "Run the onboarding steps and the upload retry in parallel, since they touch different files and neither waits on the other"
        try await offPool {
            try BoardStore(root: repo).appendDecision("Keep it short", why: "")
            try BoardStore(root: repo).appendDecision(long, why: "Both are small")
        }
        func decisions() -> [BoardDecision]? { world.queue.sync { world.engine.boardDecisions.values[repo] } }

        world.engine.refresh()
        #expect(await eventually(timeout: 60) { decisions()?.first { $0.text == long }?.summary == model.answer }, "\(String(describing: decisions()))")
        #expect(decisions()?.map(\.text) == [long, "Keep it short"], "newest first")
        #expect(decisions()?.last?.summary == nil)
        #expect(model.prompts.value.count == 1 && model.prompts.value[0].contains("Decision: Run the onboarding steps"))
        world.engine.refresh()
        await world.drained()
        world.engine.summaryRuns.sync {}
        #expect(model.prompts.value.count == 1, "a decision's line is asked once")

        // A LiveBoards following the engine shows them.
        let leads = Changes<LeadStore.Lead>()
        let boards = LiveBoards(queue: world.queue, leads: leads, decisions: world.engine.boardDecisions)
        leads.send(world.project, LeadStore.Lead(project: world.project, root: repo))
        world.queue.sync { boards.start(clock: nil) }
        defer { boards.stop() }
        #expect(await eventually(timeout: 60) { boards.values[world.project]?["decisions"]?.array?.first?["summary"] == .string(model.answer) })

        // Off: the lines go, the decisions stay.
        _ = try NodeSettings.setNode(try #require(NodeSettings.setting("ai_summaries")), to: "off", files: NodeSettings.Files(root: world.host.root))
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { decisions()?.count == 2 && decisions()?.allSatisfy { $0.summary == nil } == true })
    }

    /// A long message's TL;DR is asked once when its chat asks (`summarizeMessage`), and reaches `messageSummaries`; a
    /// short one, or any while the summaries are off, asks nothing. A chat store following them puts it on the `team`
    /// item as `summary`.
    @Test func aLongMessagesTLDRIsAskedOnceAndShownOnItsItem() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let model = Model(answer: "The upload retry is done and its tests pass")
        Self.give(world, model)
        _ = try await world.lead()
        world.engine.refresh()
        await world.drained()
        #expect(world.queue.sync { world.engine.summariesAllowed })
        let body = (1...8).map { "Line \($0) of the worker's report on the upload retry." }.joined(separator: "\n")
        let long = TeamMessage(sender: .teammate(member: "worker", task: "retry"), body: body)
        let short = TeamMessage(sender: .teammate(member: "worker", task: "retry"), body: "Done.")
        #expect(long.needsSummary && !short.needsSummary)
        world.engine.summarizeMessage(session: "s1", entry: "m_09", message: long)
        world.engine.summarizeMessage(session: "s1", entry: "m_10", message: short)
        #expect(await eventually(timeout: 60) { world.queue.sync { world.engine.messageSummaries.values["s1|m_09"] } == model.answer })
        world.engine.summarizeMessage(session: "s1", entry: "m_09", message: long)
        world.queue.sync {}
        world.engine.summaryRuns.sync {}
        #expect(model.prompts.value.count == 1 && model.prompts.value[0].contains("Line 8 of the worker's report"))
        #expect(world.queue.sync { world.engine.messageSummaries.values["s1|m_10"] } == nil)
    }

    /// A chat store asks a TL;DR for a long message VibeSwitcher handed the lead as its chat is read (not for a short
    /// one), and once a line comes the `team` item carries it as `summary` (a `set` op), its text untouched.
    @Test func aChatsLongMessageAsksItsTLDRAndItsItemCarriesIt() async throws {
        let home = scratch.url("chat-home")
        let transcript = home.appendingPathComponent(".claude/projects/-work-p/0f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let long = "[VibeSwitcher · worker login-fix, not the user] " + (1...8).map { "Line \($0) of the report." }.joined(separator: "\n")
        let lines = [["type": "user", "uuid": "m_08", "timestamp": "2026-11-17T09:16:00.000Z",
                      "message": ["role": "user", "content": "[VibeSwitcher · worker login-fix, not the user] Done."]] as [String: Any],
                     ["type": "user", "uuid": "m_09", "timestamp": "2026-11-17T09:16:30.000Z", "message": ["role": "user", "content": long]]]
        try Data(lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }.joined().utf8).write(to: transcript)
        let queue = DispatchQueue(label: "chat-engine")
        let sessions = Changes<Session>()
        let summaries = Changes<String>()
        let asked = Locked<[(String, String)]>([])
        let extras = Changes<[NodeWire.Value]>()
        let chats = ChatStore(queue: queue, home: home.path, sessions: sessions, summaries: summaries,
                              ask: { session, entry, _ in asked.mutate { $0.append((session, entry)) } }, extras: extras)
        var made = LiveWorld.session("pts/3")
        made.transcriptPath = transcript.path
        sessions.send("local:pts/3", made)
        let stream = try #require(queue.sync { () -> ChatStream? in
            guard case .opened(let stream) = chats.open("local:pts/3") else { return nil }
            return stream
        })
        #expect(await eventually { asked.value.count == 1 })
        #expect(asked.value.first.map { [$0.0, $0.1] } == ["local:pts/3", "m_09"], "only the long one: \(asked.value)")
        func item() -> NodeWire.Value? { queue.sync { stream.items.first { $0.id == "m_09" }?.value } }
        #expect(item()?["summary"] == nil)
        summaries.send("local:pts/3|m_09", "The login fix is done")
        #expect(await eventually { item()?["summary"] == .string("The login fix is done") }, "\(String(describing: item()))")
        #expect(item()?["text"]?.string?.contains("Line 8 of the report.") == true)
        #expect(WireSchema.check(try #require(item()), as: "chat.item") == nil)

        // The lead's all-done card (`LeadEngine.chatExtras`) comes into the chat between the two messages, by its time.
        let mark = LeadAllDone(id: "m1", at: try #require(NodeWire.date("2026-11-17T09:16:10.000Z")).timeIntervalSince1970, since: 0, tasks: [])
        extras.send("local:pts/3", [try #require(ChatValue.value(.allDone(mark)))])
        func ids() -> [String] { queue.sync { stream.items.map(\.id) } }
        #expect(await eventually { ids().contains("all-done:m1") }, "\(ids())")
        #expect(ids() == ["m_08", "all-done:m1", "m_09"], "\(ids())")
        chats.stop()
    }
}
