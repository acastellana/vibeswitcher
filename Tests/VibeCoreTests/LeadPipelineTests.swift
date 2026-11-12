import Foundation
import Testing
@testable import VibeCore

/// The pipeline watch (`LeadPipeline`): a task ready to merge 20 min or more with no merge landing gets the lead one
/// report naming the cause and the action, at most every 30 min while it lasts, and status shows it. Fake boards and an
/// injected clock throughout; no test waits on time.
@Suite(.serialized)
struct LeadPipelineTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A task in review with a passing verdict at `ready`.
    static func ready(_ slug: String, at ready: Date) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = .review
        task.review = .audit
        task.evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: "ok", commit: "c0ffee", at: ready.timeIntervalSince1970)
        return task
    }

    static func board(_ tasks: [LeadTask]) -> LeadBoard {
        var board = LeadBoard()
        board.tasks = tasks
        return board
    }

    @Test func nothingIsSaidBeforeTwentyMinutesNorWithin20OfAMergeLanding() {
        let board = Self.board([Self.ready("add-b", at: Self.t0)])
        let early = LeadPipeline.look(board, signals: .init(head: "h"), base: "main", now: Self.t0.addingTimeInterval(19 * 60))
        #expect(early.stalled.isEmpty && early.text == nil && !early.tell)
        // The next look is armed for the 20-minute mark.
        #expect(early.next == Self.t0.addingTimeInterval(LeadPipeline.stallAfter))
        // A merge (of others) landed after it was ready: the pipeline moves, and the next look is 20 min after it.
        let landed = Self.t0.addingTimeInterval(30 * 60)
        let moving = LeadPipeline.look(board, signals: .init(head: "h", lastMerge: landed), base: "main", now: Self.t0.addingTimeInterval(40 * 60))
        #expect(moving.stalled.isEmpty && !moving.tell && moving.next == landed.addingTimeInterval(LeadPipeline.stallAfter))
        // 20 min with none landing since: it was ready all that time, so it's held, counted from that merge.
        let stuck = LeadPipeline.look(board, signals: .init(head: "h", lastMerge: landed), base: "main", now: Self.t0.addingTimeInterval(50 * 60))
        #expect(stuck.stalled == ["add-b"] && stuck.tell && stuck.since == landed, "\(String(describing: stuck.text))")
        #expect((stuck.text ?? "").contains("has been ready to merge for 20 min with no merge landing"), "\(String(describing: stuck.text))")
        // A task not ready (in review, no verdict yet) never counts.
        var auditing = Self.ready("add-c", at: Self.t0)
        auditing.evidence = nil
        #expect(LeadPipeline.look(Self.board([auditing]), signals: .init(), base: "main", now: Self.t0.addingTimeInterval(3600)).stalled.isEmpty)
        // Review none, its done report in: ready from when it took review.
        var none = auditing
        none.review = LeadTask.Review.none
        none.since = Self.t0.timeIntervalSince1970
        #expect(LeadPipeline.readySince(none) == Self.t0)
    }

    /// Each cause, most decisive first, with the action named.
    @Test func eachCauseIsNamedWithItsAction() {
        let now = Self.t0.addingTimeInterval(25 * 60)
        var board = Self.board([Self.ready("add-b", at: Self.t0), Self.ready("add-c", at: Self.t0.addingTimeInterval(60))])
        func look(_ signals: LeadPipeline.Signals) -> LeadPipeline.Look {
            LeadPipeline.look(board, signals: signals, base: "main", now: now)
        }
        // Merge in progress, with its ETA from recent merge times.
        let merging = look(.init(head: "h", merging: (["add-a"], now.addingTimeInterval(-10 * 60)), recentDurations: [1200, 1500, 900]))
        #expect(merging.cause == .merging && merging.tell, "\(String(describing: merging.text))")
        #expect(merging.stalled == ["add-b", "add-c"])
        let text = merging.text ?? ""
        #expect(text.hasPrefix("Merges are held: add-b, add-c have been ready to merge for 25 min with no merge landing. Cause: a merge in progress."), "\(text)")
        #expect(text.contains("A merge of add-a has been running for 10 min; recent merges took about 20 min, so it should end in about 10 min"), "\(text)")
        // The gate not installed.
        let gate = look(.init(head: "h", gateLag: "Gate code on main isn't installed yet: 1 commit (x); merges run the installed build (abc)."))
        #expect(gate.cause == .gate && (gate.text ?? "").contains("Ask the user to install the app from main"), "\(String(describing: gate.text))")
        // The load hold, over a merge in progress.
        let load = look(.init(head: "h", loadHold: (14.5, 12), merging: (["add-a"], now)))
        #expect(load.cause == .load && (load.text ?? "").contains("The Mac's load (14.5) is over load_threshold (12)"), "\(String(describing: load.text))")
        // Every test slot held, by what for how long, over the load.
        let slots = look(.init(head: "h", slotsHeld: (2, "slot 1 held by another project's run, for 52 min; slot 2 held by another project's run, for 47 min"), loadHold: (14.5, 12)))
        #expect(slots.cause == .slots, "\(String(describing: slots.text))")
        #expect((slots.text ?? "").contains("Every one of the 2 Mac-wide test slots are held: slot 1 held by another project's run, for 52 min; slot 2"), "\(String(describing: slots.text))")
        // The lead's records failing a check, over all of those.
        let records = look(.init(head: "h", records: ["docs/lead/progress.md:12 (PrivateNamesLint)"], slotsHeld: (2, "x"), loadHold: (14.5, 12)))
        #expect(records.cause == .records && (records.text ?? "").contains("docs/lead/progress.md:12 (PrivateNamesLint). Clear each with redact_record(file, line, text)"), "\(String(describing: records.text))")
        // Main red (the whole failure, the base not moved), over everything.
        board.mainRed = LeadMainRed(tests: ["breaks()"], onto: "h", at: 0, all: true, fixes: ["fix-breaks"], lines: [])
        var held = LeadPipeline.Signals(head: "h", records: ["docs/lead/progress.md:12 (PrivateNamesLint)"])
        held.mainRedHolds = true
        let red = look(held)
        #expect(red.cause == .mainRed && (red.text ?? "").contains("main is red: breaks() fail on main itself (h), so every merge fails on them. Get fix-breaks done first"), "\(String(describing: red.text))")
        // Once it no longer holds (a fix landed, the base moved), it's not the cause.
        #expect(look(.init(head: "moved")).cause == .unknown)
        board.mainRed = nil
        #expect((look(.init(head: "h")).text ?? "").contains("VibeSwitcher sees nothing holding them"))
    }

    /// Told once; again only 30 min after, whichever task is oldest meanwhile; a new stall (after a merge landed) is told afresh.
    @Test func itsToldOnceThenAtMostEveryThirtyMinutes() {
        var board = Self.board([Self.ready("add-b", at: Self.t0)])
        let first = LeadPipeline.look(board, signals: .init(head: "h"), base: "main", now: Self.t0.addingTimeInterval(20 * 60))
        #expect(first.tell && first.next == Self.t0.addingTimeInterval(50 * 60))
        board.pipeline = LeadPipeline.Told(at: Self.t0.addingTimeInterval(20 * 60).timeIntervalSince1970, since: Self.t0.timeIntervalSince1970, cause: "x")
        let soon = LeadPipeline.look(board, signals: .init(head: "h"), base: "main", now: Self.t0.addingTimeInterval(49 * 60))
        #expect(!soon.tell && soon.text != nil && soon.next == Self.t0.addingTimeInterval(50 * 60))
        // The oldest leaves without a merge landing (sent back by a split; verified again): the same stall, whose oldest
        // is now add-c. Not told again before the 30 minutes are up.
        var churned = board
        churned.tasks = [Self.ready("add-c", at: Self.t0.addingTimeInterval(5 * 60))]
        let sentBack = LeadPipeline.look(churned, signals: .init(head: "h"), base: "main", now: Self.t0.addingTimeInterval(26 * 60))
        #expect(sentBack.stalled == ["add-c"] && !sentBack.tell && sentBack.next == Self.t0.addingTimeInterval(50 * 60))
        churned.tasks = [Self.ready("add-b", at: Self.t0.addingTimeInterval(27 * 60)), Self.ready("add-c", at: Self.t0.addingTimeInterval(5 * 60))]
        #expect(!LeadPipeline.look(churned, signals: .init(head: "h"), base: "main", now: Self.t0.addingTimeInterval(48 * 60)).tell)
        let later = LeadPipeline.look(board, signals: .init(head: "h"), base: "main", now: Self.t0.addingTimeInterval(50 * 60))
        #expect(later.tell)
        // add-b merged; add-c, ready since, stalls on its own: a new stall.
        board.tasks = [Self.ready("add-c", at: Self.t0.addingTimeInterval(30 * 60))]
        let fresh = LeadPipeline.look(board, signals: .init(head: "h", lastMerge: Self.t0.addingTimeInterval(29 * 60)), base: "main",
                                      now: Self.t0.addingTimeInterval(51 * 60))
        #expect(fresh.tell && fresh.stalled == ["add-c"])
    }

    /// The tool server's watch: the lead gets the report once (on the board's reports, from auto_advance), the board
    /// keeps when, it's repeated 30 min later, and status shows it meanwhile. The records' lint is read from the base.
    @Test func theLeadIsToldOnceAndStatusShowsIt() throws {
        let url = temp.url("pipeline")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        let lead = try lead(root, FakeRuntime())
        lead.testLock = nil
        lead.mergeStats = { nil }
        lead.recordLints = { .all }
        // A records line PrivateNamesLint fails on, committed as it was before the tools linted their text.
        try lead.store.appendProgress("Dismissed: it was \(LeadRecordTextTests.privateName)'s")
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("records not committed"); return }
        var clock = Self.t0
        lead.pipelineClock = { clock }
        try lead.store.update { board in board.tasks.append(Self.ready("add-b", at: Self.t0)) }

        clock = Self.t0.addingTimeInterval(10 * 60)
        #expect(!lead.watchPipeline().tell)
        #expect(lead.store.load().reports?.isEmpty ?? true)
        clock = Self.t0.addingTimeInterval(21 * 60)
        let look = lead.watchPipeline()
        #expect(look.tell && look.cause == .records, "\(String(describing: look.text))")
        let reports = lead.store.load().reports ?? []
        #expect(reports.count == 1 && reports[0].about == LeadAdvance.sender, "\(reports)")
        #expect(reports[0].text.contains("Cause: the lead's records failing a check.") && reports[0].text.contains("docs/lead/progress.md:3 (PrivateNamesLint)"), "\(reports[0].text)")
        #expect(RecordLint.problems(in: reports[0].text).isEmpty)
        // Not again within 30 min; status shows it meanwhile.
        clock = Self.t0.addingTimeInterval(40 * 60)
        #expect(!lead.watchPipeline().tell)
        #expect(lead.store.load().reports?.count == 1)
        let status = lead.call("status", [:]).text
        #expect(status.contains("Merges are held: add-b has been ready to merge for 40 min with no merge landing. Cause: the lead's records failing a check."), "\(status)")
        clock = Self.t0.addingTimeInterval(51 * 60)
        #expect(lead.watchPipeline().tell)
        #expect(lead.store.load().reports?.count == 2)
        let progress = try String(contentsOfFile: root + "/docs/lead/progress.md", encoding: .utf8)
        #expect(progress.contains("Pipeline held: add-b ready to merge with none landing; cause: the lead's records failing a check"), "\(progress)")
    }
}
