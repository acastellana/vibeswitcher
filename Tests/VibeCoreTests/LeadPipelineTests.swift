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
        // The battery hold, over main red: it refuses the fix's merge too, and merging by hand.
        held.batteryHold = (4, 10)
        let battery = look(held)
        #expect(battery.cause == .battery && (battery.text ?? "").contains("The Mac is on battery at 4 %, under the user's 10 % limit (Settings › Performance), so nothing merges, by hand or by auto_advance, until AC power returns"), "\(String(describing: battery.text))")
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

    /// The battery hold as the cause: on 2026-11-17 at 02:25, on battery at 4 % under the user's 10 % limit (the
    /// witness and auto_advance had told the hold at 02:08), the watch said "Cause: nothing VibeSwitcher sees … merge
    /// one by hand", which the hold would only refuse. It names the hold, isn't told again while it lasts, and once AC
    /// power returns the stall's next report waits its 30 min from then, as merges start again.
    @Test func theBatteryHoldIsNamedAndNotRepeatedWhileItLasts() throws {
        let url = temp.url("pipeline-battery")
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
        var held = PowerState(onBattery: true, percent: 4)
        held.heldUnder = 10
        var power: PowerState? = held
        lead.power = { power }
        var clock = Self.t0
        lead.pipelineClock = { clock }
        try lead.store.update { board in board.tasks.append(Self.ready("shell-cards-ending", at: Self.t0)) }

        clock = Self.t0.addingTimeInterval(125 * 60)
        let look = lead.watchPipeline()
        let text = look.text ?? ""
        #expect(look.tell, "\(text)")
        #expect(text.hasPrefix("Merges are held: shell-cards-ending has been ready to merge for 125 min with no merge landing. Cause: the battery hold."), "\(text)")
        #expect(text.contains("on battery at 4 %, under the user's 10 % limit") && text.contains("until AC power returns"), "\(text)")
        #expect(!text.contains("nothing VibeSwitcher sees") && !text.contains("merge one by hand"), "\(text)")
        #expect(lead.store.load().reports?.count == 1)
        // Not again while the hold lasts, however long.
        for minute in [160.0, 200, 300] {
            clock = Self.t0.addingTimeInterval(minute * 60)
            let again = lead.watchPipeline()
            #expect(!again.tell, "at \(minute) min: \(String(describing: again.text))")
        }
        #expect(lead.store.load().reports?.count == 1, "\(lead.store.load().reports ?? [])")
        // AC power returns at 310 min: merges may start again, so the next report waits 30 min from then.
        power = PowerState(onBattery: false, percent: 12, charging: true)
        clock = Self.t0.addingTimeInterval(310 * 60)
        #expect(!lead.watchPipeline().tell)
        clock = Self.t0.addingTimeInterval(339 * 60)
        #expect(!lead.watchPipeline().tell)
        #expect(lead.store.load().reports?.count == 1, "\(lead.store.load().reports ?? [])")
        clock = Self.t0.addingTimeInterval(341 * 60)
        let after = lead.watchPipeline()
        #expect(after.tell && (after.text ?? "").contains("Cause: nothing VibeSwitcher sees."), "\(String(describing: after.text))")
        #expect(lead.store.load().reports?.count == 2)
    }
}

/// The held-merges report by the Mac's awake clock (`MacTime`, noted as the witness's sleep log does): on 2026-11-16 a
/// Mac in maintenance sleep on battery told the lead "Merges are held … for 138 min … slot 1 … for 150 min, long" at
/// one dark wake, then the same at 169, 215 and 260 min, though nothing had run: the test processes sat at 0% CPU
/// because the Mac slept.
@Suite(.serialized)
struct LeadPipelineSleepTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let t0 = LeadPipelineTests.t0

    /// A Mac awake 25 min, then asleep with dark wakes at 138, 169, 215 and 260 min, each a minute awake: the lead is
    /// told once while awake, not again at a dark wake, and status counts awake minutes and names the sleep. Awake
    /// again for 30 min, it's told again, as today.
    @Test func darkWakesDontRepeatTheReportAndItsMinutesAreAwake() throws {
        let url = temp.url("pipeline-sleep")
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
        // The wall clock, and the awake clock: it stands still while the Mac sleeps.
        var wall = Self.t0
        var awake: TimeInterval = 1_000
        lead.pipelineClock = { wall }
        lead.macTime = MacTime(wall: { wall }, awake: { awake })
        func at(minute: Double, awakeMinute: Double) {
            wall = Self.t0.addingTimeInterval(minute * 60)
            awake = 1_000 + awakeMinute * 60
        }
        try lead.store.update { board in board.tasks.append(LeadPipelineTests.ready("add-b", at: Self.t0)) }

        at(minute: 5, awakeMinute: 5)
        #expect(!lead.watchPipeline().tell)
        at(minute: 21, awakeMinute: 21)
        #expect(lead.watchPipeline().tell)
        #expect(lead.store.load().reports?.count == 1)
        at(minute: 25, awakeMinute: 25)
        #expect(!lead.watchPipeline().tell)
        // Asleep from minute 25; each dark wake a minute awake.
        for (index, minute) in [138.0, 169, 215, 260].enumerated() {
            at(minute: minute, awakeMinute: 25 + Double(index + 1))
            let look = lead.watchPipeline()
            #expect(!look.tell, "dark wake at \(minute) min: \(String(describing: look.text))")
            // The next look waits for the awake time still due, not a wall time already past.
            #expect((look.next ?? .distantPast) > wall)
        }
        #expect(lead.store.load().reports?.count == 1, "\(lead.store.load().reports ?? [])")
        // Status: 29 min awake, the sleep named.
        let status = lead.call("status", [:]).text
        #expect(status.contains("Merges are held: add-b has been ready to merge for 29 min"), "\(status)")
        #expect(status.contains("the Mac slept 231 min"), "\(status)")
        // Awake again: 30 min awake after the report, it's told again.
        at(minute: 290, awakeMinute: 50)
        #expect(!lead.watchPipeline().tell)
        at(minute: 291, awakeMinute: 51)
        #expect(lead.watchPipeline().tell)
        #expect(lead.store.load().reports?.count == 2)
    }

    /// A slot whose run the Mac slept through: its minutes are awake ones, the sleep is named, and it isn't "long";
    /// a slot held long while the Mac was awake still is.
    @Test func aSlotPausedBySleepSaysSoInsteadOfLong() {
        let now = Self.t0.addingTimeInterval(150 * 60)
        var sleep = MacSleepLog()
        // Awake from the start to minute 12, then asleep (dark wakes, no time awake to speak of) to minute 150.
        sleep.note(wall: Self.t0.timeIntervalSince1970, awake: 0)
        sleep.note(wall: Self.t0.addingTimeInterval(12 * 60).timeIntervalSince1970, awake: 12 * 60)
        sleep.note(wall: now.timeIntervalSince1970, awake: 12 * 60)
        let paused = TestLock.Holder(slot: 1, note: "pid 7, scripts/test.sh in /elsewhere/p, since 02:10", since: Self.t0, project: "p")
        let text = LeadPipeline.slotsText([paused], root: "/r/mine", now: now, sleep: sleep)
        #expect(text == "slot 1 held by another project's run, for 12 min, paused by sleep: 138 min of its 150 min", "\(text)")
        // Awake all the way: as TestLock says it, long.
        let awake = LeadPipeline.slotsText([paused], root: "/r/mine", now: now, sleep: MacSleepLog())
        #expect(awake == TestLock.text([paused], for: "/r/mine", now: now) && awake.hasSuffix("for 150 min, long"), "\(awake)")
        // The report names it under the slots cause, its minutes awake.
        let board = LeadPipelineTests.board([LeadPipelineTests.ready("add-b", at: Self.t0)])
        let look = LeadPipeline.look(board, signals: .init(head: "h", slotsHeld: (1, text)), base: "main", now: now, sleep: sleep)
        #expect(look.stalled.isEmpty && !look.tell, "12 min awake isn't a stall: \(String(describing: look.text))")
        let later = now.addingTimeInterval(10 * 60)
        sleep.note(wall: later.timeIntervalSince1970, awake: 22 * 60)
        let held = LeadPipeline.look(board, signals: .init(head: "h", slotsHeld: (1, text)), base: "main", now: later, sleep: sleep)
        #expect(held.tell && held.cause == .slots, "\(String(describing: held.text))")
        #expect((held.text ?? "").hasPrefix("Merges are held: add-b has been ready to merge for 22 min awake with no merge landing; the Mac slept 138 min of the 160 min since"), "\(String(describing: held.text))")
        #expect((held.text ?? "").contains("paused by sleep: 138 min of its 150 min") && !(held.text ?? "").contains("min, long"), "\(String(describing: held.text))")
    }
}
