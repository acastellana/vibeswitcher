import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// AI summaries of what each agent is doing (the parity table's row; `TeamSummaryWatch`): after a refresh, a line is
/// asked for each task at work whose agent's session is live, of the model the engine is given (here a fake: no model
/// is ever run by a test), rate-limited per agent, off with Settings' AI summaries and while the usage holds Haiku back;
/// the lines reach the boards (`teamSummaries`, `BoardValue`'s `summary`). Each test has a scratch root and host;
/// nothing is slept on.
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
}
