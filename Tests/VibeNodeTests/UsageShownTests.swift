import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The account's usage shown to you (the parity table's "Usage shown to you"): the engine's account watch reads the
/// usage the roles' tool servers keep under the node's root at each refresh (`NodeUsage`), `status`, `settings` and the
/// page carry it, and a review row waiting on a limit says so on the board (`UsageWaits`, the app's
/// `TeamRows.usageWaits`). No credential is read; every reading here is a scratch root's. Nothing is slept on.
struct UsageShownTests {
    private let scratch = Scratch()

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let account = "7a1c0e52-0000-4000-8000-0000000000aa"

    static func limit(_ name: String, _ used: Double, model: String? = nil, reached: Bool = false, resetsIn: Double = 3600,
                      account: String? = UsageShownTests.account) -> AccountUsage.Limit {
        AccountUsage.Limit(name: name, model: model, usedPercent: used, resetsAt: now.timeIntervalSince1970 + resetsIn,
                           at: now.timeIntervalSince1970 - 60, reached: reached, account: account)
    }

    static func review(_ slug: String, change: (inout LeadTask) -> Void = { _ in }) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""), status: .review)
        task.review = .audit
        change(&task)
        return task
    }

    static func team(_ limits: [AccountUsage.Limit], ignoring: Bool = false) -> TeamReading {
        var team = TeamReading()
        team.usage = AccountUsage(limits: limits, account: account)
        team.ignoreUsageLimits = ignoring
        team.workerModel = "opus"
        return team
    }

    // MARK: Review rows

    /// A task in review with no verifier yet, whose audit's model a limit holds back at the threshold, waits for it:
    /// the row says on which model and when the limit resets. Under the threshold, or with Ignore usage limits on, it
    /// doesn't (only a refusal holds then), and a task already passed or not under review never waits.
    @Test func aReviewHeldBackByALimitWaitsForIt() {
        var board = LeadBoard()
        board.tasks = [Self.review("held"), Self.review("passed") { $0.evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: "ok") },
                       Self.review("none") { $0.review = LeadTask.Review.none }]
        let waits = UsageWaits.reviews(board, team: Self.team([Self.limit("seven_day", 91)]), now: Self.now)
        #expect(Set(waits.keys) == [board.tasks[0].id], "\(waits)")
        let wait = waits[board.tasks[0].id]
        #expect(wait?.state.hasPrefix("Waits for ") == true && wait?.line.contains("limit resets") == true, "\(String(describing: wait))")

        #expect(UsageWaits.reviews(board, team: Self.team([Self.limit("seven_day", 79)]), now: Self.now).isEmpty)
        #expect(UsageWaits.reviews(board, team: Self.team([Self.limit("seven_day", 99)], ignoring: true), now: Self.now).isEmpty)
        let refused = UsageWaits.reviews(board, team: Self.team([Self.limit("five_hour", 100, reached: true)], ignoring: true), now: Self.now)
        #expect(Set(refused.keys) == [board.tasks[0].id])
        // Another account's reading holds nothing back: only the one Claude Code is logged in to.
        #expect(UsageWaits.reviews(board, team: Self.team([Self.limit("seven_day", 95, account: "someone-else")]), now: Self.now).isEmpty)
        // A limit that has reset holds nothing.
        #expect(UsageWaits.reviews(board, team: Self.team([Self.limit("seven_day", 95, resetsIn: -10)]), now: Self.now).isEmpty)
    }

    /// The verifier stopped at a limit (its transcript's refusal) waits for that limit's reset, named by the model it was
    /// launched on; a verifier still at work isn't waiting, whatever the usage says.
    @Test func aVerifierStoppedAtALimitWaitsAndOneAtWorkDoesnt() {
        let verifier = UUID()
        let at = Self.now.timeIntervalSince1970
        var task = Self.review("audited")
        task.verifier = verifier.uuidString
        task.launchedModels = [verifier.uuidString: "claude-fable-5-2"]
        var board = LeadBoard()
        board.tasks = [task]
        var team = Self.team([])
        team.hosted[verifier.uuidString] = HostSession(id: verifier, tty: "ttypts901", childPID: 63_101, cwd: "/nowhere", command: "claude",
                                                       label: "Verifier: audited", agent: "claude", title: "Claude", startedAt: Self.now.addingTimeInterval(-600), cols: 120, rows: 40, exit: nil)
        let refusal = UsageLimit(said: "You've hit your fable limit", resetsAt: at + 7200, at: at - 30, kind: "seven_day_overage_included")
        team.watched[verifier.uuidString] = (activity: .usageLimit(refusal), tail: nil, progress: nil)
        let wait = UsageWaits.reviews(board, team: team, now: Self.now)[task.id]
        #expect(wait == ReviewUsageWait(model: "claude-fable-5-2", resetsAt: at + 7200))
        #expect(wait?.state == "Waits for Fable")
        #expect(wait?.line.hasPrefix("Fable's limit resets ") == true)

        team.watched[verifier.uuidString] = (activity: .working(nil), tail: nil, progress: nil)
        team.usage = AccountUsage(limits: [Self.limit("seven_day", 99)], account: Self.account)
        #expect(UsageWaits.reviews(board, team: team, now: Self.now).isEmpty)
    }

    /// The board's row reads the wait: its state and dim line, still in the running group; a passed task's doesn't.
    @Test func theBoardsRowSaysItWaits() throws {
        var board = LeadBoard()
        board.tasks = [Self.review("held"), Self.review("passed") { $0.evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: "ok") }]
        let wait = ReviewUsageWait(model: "opus", resetsAt: Self.now.timeIntervalSince1970 + 3600)
        let value = BoardValue.value(project: "p", root: "/r", board: board, now: Self.now,
                                     usageWaits: [board.tasks[0].id: wait, board.tasks[1].id: wait])
        let tasks = try #require(value["tasks"]?.array)
        let held = try #require(tasks.first { $0["slug"] == .string("held") })
        #expect(held["state"] == .string("Waits for Opus") && held["group"] == .string("running"))
        #expect(held["line"]?.string?.hasPrefix("Opus's limit resets ") == true)
        #expect(tasks.first { $0["slug"] == .string("passed") }?["state"] == .string("Ready to merge"))
        #expect(WireSchema.check(value, as: "board") == nil)
    }

    // MARK: Status and settings

    /// The value carries the active account's limits still holding, most used first, each marked when it holds work
    /// back; never an account's id; and the command line's lines say them, Fable held back and Ignore usage limits.
    @Test func theValueAndItsLinesSayTheLimits() throws {
        let usage = AccountUsage(limits: [Self.limit("five_hour", 20), Self.limit("seven_day", 85),
                                          Self.limit("seven_day_overage_included", 100, model: "fable", reached: true),
                                          Self.limit("seven_day", 99, account: "another-account")],
                                 account: Self.account, names: [Self.account: "a…@example.invalid"])
        let value = NodeUsage.value(NodeUsage.Reading(usage: usage, now: Self.now))
        #expect(WireSchema.check(value, as: "node.usage") == nil)
        let limits = try #require(value["limits"]?.array)
        #expect(limits.map { $0["usedPercent"]?.int } == [100, 85, 20])
        #expect(limits.map { $0["holds"]?.bool } == [true, true, false])
        #expect(value["account"] == .string("a…@example.invalid") && value["fableHeldBack"]?.string != nil)
        let encoded = String(decoding: NodeWire.message(value), as: UTF8.self)
        #expect(!encoded.contains(Self.account) && !encoded.contains("another-account"))

        let lines = NodeUsage.lines(value)
        #expect(lines.first?.hasPrefix("usage for a…@example.invalid (best effort") == true)
        #expect(lines.first?.contains("the weekly limit (every model): 85% used") == true, "\(lines)")
        #expect(lines.contains { $0.contains("leads start no workers or audits") })
        #expect(lines.contains { $0.contains("Fable held back until") })

        let ignored = NodeUsage.lines(NodeUsage.value(NodeUsage.Reading(usage: usage, ignoring: true, now: Self.now)))
        #expect(ignored.first?.hasSuffix(AccountUsage.ignoredMark) == true)
        #expect(ignored.contains { $0.contains("only a limit Claude refused a request at holds") })
        #expect(NodeUsage.lines(NodeUsage.value(NodeUsage.Reading(now: Self.now))) == [
            "usage (best effort, what the sessions' status lines and Claude's refusals said): nothing known"])
        #expect(NodeUsage.lines(nil).isEmpty && NodeUsage.lines(.null).isEmpty)
    }

    // MARK: The engine

    /// A refresh reads the usage kept under the engine's root (`account-usage.json`, as the roles' status lines keep it)
    /// into `status`; a running lead's review held back by it is sent to the boards (`usageWaits`), and a `LiveBoards`
    /// following them shows the row waiting.
    @Test func aRefreshReadsTheUsageAndTheBoardShowsTheWait() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.lead()
        let held = Self.review("held")
        let repo = world.repo
        try await offPool { try BoardStore(root: repo).update { $0.tasks.append(held) } }
        let store = AccountUsageStore(file: world.host.root.appendingPathComponent("account-usage.json"), home: world.host.home.path)
        let at = Date().timeIntervalSince1970
        store.record([AccountUsage.Limit(name: "seven_day", usedPercent: 93, resetsAt: at + 86_400, at: at)])

        world.engine.refresh()
        await world.drained()
        #expect(await eventually(timeout: 60) { world.queue.sync { world.engine.usageWaits.values[repo]?[held.id] != nil } })
        let usage = try #require(world.queue.sync { world.engine.usage })
        let value = NodeUsage.value(usage)
        #expect(value["limits"]?.array?.first?["usedPercent"] == .int(93), "\(value)")

        let leads = Changes<LeadStore.Lead>()
        let boards = LiveBoards(queue: world.queue, leads: leads, usageWaits: world.engine.usageWaits)
        leads.send(world.project, LeadStore.Lead(project: world.project, root: repo))
        world.queue.sync { boards.start(clock: nil) }
        defer { boards.stop() }
        #expect(await eventually(timeout: 60) {
            boards.values[world.project]?["tasks"]?.array?.first { $0["slug"] == .string("held") }?["state"]?.string?.hasPrefix("Waits for ") == true
        }, "\(String(describing: boards.values[world.project]))")

        // The limit gone (Ignore usage limits on): the next refresh sends no wait, and the board's row is back in review.
        try MacLimits(ignoreUsageLimits: true).save(to: world.host.root.appendingPathComponent("mac-limits.json"))
        world.engine.refresh()
        await world.drained()
        #expect(await eventually(timeout: 60) {
            boards.values[world.project]?["tasks"]?.array?.first { $0["slug"] == .string("held") }?["state"]?.string?.hasPrefix("Waits for ") == false
        })
    }
}
