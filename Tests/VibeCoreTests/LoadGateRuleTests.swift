import Foundation
import Testing
@testable import VibeCore

/// Rule (cI) of docs/process/reviews/load-gate-2026-11.md: every gate judges the Mac's room by one function of the
/// load averages, every project's team sessions and the heavy slots held (`MacLoad.room`). While nothing of ours runs
/// the 1-minute alone counts; otherwise the greater of the 1- and 5-minute, as before. The user, 2026-11-27, after the
/// 11:01 restart refused every start with nothing running: "it can be that the load is 51, since literally all of them
/// are queued or the worker ended. It can't be." The averages, slots and census are injected: no real load, no sleeps.
extension LeadToolsetTests {
    /// The 2026-11-27 restart as the load recorder sampled it (1- and 5-minute), boosted (load_threshold 36), no team
    /// session throughout, a heavy slot held 11:14–11:17.
    static let restart: [(at: String, one: Double, five: Double, slot: Bool, room: Bool)] = [
        ("11:09", 28.8, 175.98, false, true), ("11:10", 12.8, 144.62, false, true), ("11:11", 7.89, 119.17, false, true),
        ("11:12", 7.17, 98.75, false, true), ("11:13", 6.27, 81.85, false, true),
        ("11:14", 5.28, 67.83, true, false), ("11:15", 4.53, 56.22, true, false), ("11:16", 3.85, 46.61, true, false),
        ("11:17", 4.84, 39.07, true, false),
        ("11:18", 27.36, 40.63, false, true), ("11:19", 11.82, 33.76, false, true),
    ]

    /// A slot of `lock` held until `release`.
    func holdSlot(_ lock: TestLock?) throws -> TestLock.Held {
        guard case .held(let held, _, _) = try #require(lock).acquire(as: "a build", timeout: hangGuard) else {
            throw BoardError(text: "no slot taken")
        }
        return held
    }

    // MARK: The one function

    @Test func theLastMinuteAloneCountsOnlyWhileNothingOfOursRuns() {
        let averages = MacLoad.Averages(one: 5, five: 60)
        // Nothing of ours: the 1-minute, room under 36 (and under 24).
        let idle = MacLoad.room(averages, teamSessions: 0, slotsHeld: 0)
        #expect(idle == MacLoad.Room(averages: averages, reading: .lastMinute))
        #expect(idle?.load == 5)
        #expect(!MacLoad.count([], load: nil).judging(idle).isBusy(threshold: 24))
        // A heavy slot held (the 2026-10-28 shape): the 5-minute counts, no room.
        let held = MacLoad.room(averages, teamSessions: 0, slotsHeld: 1)
        #expect(held?.reading == .steady && held?.load == 60)
        #expect(MacLoad.count([], load: nil).judging(held).isBusy(threshold: 36))
        // A team session running, no slot held (the 11-14 01:13 shape): no room.
        let team = MacLoad.room(averages, teamSessions: 1, slotsHeld: 0)
        #expect(team?.reading == .steady && team?.load == 60)
        // Each signal that can't be read: today's rule, the greater of the two.
        #expect(MacLoad.room(averages, teamSessions: nil, slotsHeld: 0)?.load == 60)
        #expect(MacLoad.room(averages, teamSessions: 0, slotsHeld: nil)?.load == 60)
        #expect(MacLoad.room(averages, teamSessions: nil, slotsHeld: nil)?.load == 60)
        // A load that can't be read: no room, whatever runs.
        #expect(MacLoad.room(nil, teamSessions: 0, slotsHeld: 0) == nil)
        #expect(MacLoad.count([], load: nil).judging(nil).isBusy(threshold: 1_000_000))
        // The 1-minute over the 5-minute: it counts either way.
        #expect(MacLoad.room(MacLoad.Averages(one: 40, five: 12), teamSessions: 3, slotsHeld: 2)?.load == 40)
    }

    /// "room again in about N minutes": N = 5 ln((five − one) / (T − one)), rounded up, said only while the 5-minute
    /// alone holds the load over T. The review's example: 70 and 6 against 36, 5 ln(64 / 30) = 3.8 → 4.
    @Test func theRoomAgainEstimate() {
        let room = MacLoad.Room(averages: MacLoad.Averages(one: 6, five: 70), reading: .steady)
        #expect(room.minutesToRoom(threshold: 36) == 4)
        #expect(MacLoad.count([], load: nil).judging(room).roomAgainText(threshold: 36) == "room again in about 4 minutes")
        // The 1-minute over T itself, the 5-minute under it, or the 1-minute alone read: no estimate.
        #expect(MacLoad.Room(averages: MacLoad.Averages(one: 40, five: 70), reading: .steady).minutesToRoom(threshold: 36) == nil)
        #expect(MacLoad.Room(averages: MacLoad.Averages(one: 6, five: 30), reading: .steady).minutesToRoom(threshold: 36) == nil)
        #expect(MacLoad.Room(averages: MacLoad.Averages(one: 6, five: 70), reading: .lastMinute).minutesToRoom(threshold: 36) == nil)
        // The 11:09 reading with a slot held: 5 ln(147.18 / 7.2) = 15.1 → 16.
        #expect(MacLoad.Room(averages: MacLoad.Averages(one: 28.8, five: 175.98), reading: .steady).minutesToRoom(threshold: 36) == 16)
    }

    /// The room-again message says which reading the load is, as the refusal does: at the restart's 11:09 look, the
    /// 1-minute alone and why.
    @Test func theRoomAgainMessageSaysWhichReading() {
        let limits = MacLimits(maxSessions: 6, loadThreshold: 36)
        let idle = MacLoad.count([], load: nil).judging(MacLoad.room(MacLoad.Averages(one: 28.8, five: 175.98), teamSessions: 0, slotsHeld: 0))
        let text = LeadWitness.roomText(["start_worker(one)"], mac: idle, limits: limits, root: "/r")
        #expect(text.contains("Now: load 28.8 (the last minute's: no worker or verifier runs and no build or test holds a slot; load_threshold 36"), "\(text)")
        let busy = MacLoad.count([], load: nil).judging(MacLoad.room(MacLoad.Averages(one: 5, five: 30), teamSessions: 1, slotsHeld: 0))
        let steady = LeadWitness.roomText(["start_worker(one)"], mac: busy, limits: limits, root: "/r")
        #expect(steady.contains("Now: load 30.0 (its 5-minute average; the last minute's is 5.0; load_threshold 36"), "\(steady)")
    }

    // MARK: start_worker and audit

    /// The restart, minute by minute, through start_worker's own census and holders: room 11:09–11:13, refused
    /// 11:14–11:17 with a slot held (the 5-minute over 36), room from 11:18. Each start that goes is ended before the
    /// next minute, so nothing of ours runs again.
    @Test func startWorkerOnTheRestartReadsTheLastMinuteWhileNothingOfOursRuns() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 36) }
        #expect(!call(lead, "configure", ["max_workers": 20]).isError)
        for minute in Self.restart {
            _ = call(lead, "add_task", ["title": "At \(minute.at)", "goal": "g", "acceptance": ["a"]])
        }
        let tasks = BoardStore(root: root).load().tasks.map(\.slug)
        for (minute, slug) in zip(Self.restart, tasks) {
            runtime.averages = MacLoad.Averages(one: minute.one, five: minute.five)
            let held = minute.slot ? try holdSlot(lead.testLock) : nil
            let started = call(lead, "start_worker", ["task": slug])
            held?.release()
            #expect(started.isError == !minute.room, "\(minute.at): \(started.text)")
            if minute.room {
                // Ended at once: the next minute finds no worker running.
                for session in runtime.spawned.map(\.id) where !runtime.killed.contains(session) { try runtime.kill(session) }
            } else {
                #expect(started.text.contains("load \(String(format: "%.1f", minute.five)) (its 5-minute average; the last minute's is \(String(format: "%.1f", minute.one));"), "\(started.text)")
                #expect(started.text.contains("room again in about"), "\(started.text)")
            }
        }
        #expect(runtime.spawned.count == Self.restart.filter(\.room).count)
    }

    /// After the restart, one worker started at 11:09: a second start at 11:10 is refused, the 5-minute at 145. With a
    /// team session running and no slot held the 5-minute counts (the 11-14 01:13 shape).
    @Test func aSecondStartAfterTheRestartWaitsForTheFiveMinute() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 36) }
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        runtime.averages = MacLoad.Averages(one: 28.8, five: 175.98)
        let first = call(lead, "start_worker", ["task": "one"])
        #expect(!first.isError, "\(first.text)")
        runtime.averages = MacLoad.Averages(one: 12.8, five: 144.62)
        let second = call(lead, "start_worker", ["task": "two"])
        #expect(second.isError && second.text.contains("load 144.6 (its 5-minute average; the last minute's is 12.8;"), "\(second.text)")
        #expect(runtime.spawned.count == 1)
        // Another project's worker instead of this one's (the host counts it, doesn't list it): refused the same.
        try runtime.kill("session-1")
        runtime.unlisted = [Self.member("project-c", "a")]
        runtime.averages = MacLoad.Averages(one: 5, five: 60)
        #expect(call(lead, "start_worker", ["task": "two"]).isError)
        // Nothing of ours anywhere: it goes on the 1-minute.
        runtime.unlisted = []
        let started = call(lead, "start_worker", ["task": "two"])
        #expect(!started.isError, "\(started.text)")
    }

    /// The census or the slots unreadable: today's rule, the greater of the two.
    @Test func anUnreadableCensusOrSlotsFallsBackToTheGreaterOfTheTwo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 36) }
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        runtime.averages = MacLoad.Averages(one: 5, five: 60)
        // No slots to read (no lock): not idle.
        lead.testLock = nil
        #expect(lead.roomLoad()?.reading == .steady)
        #expect(call(lead, "start_worker", ["task": "one"]).isError)
        // A slot that can't be opened: not idle.
        let locks = temp.url("unreadable-slots")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let slot = locks.appendingPathComponent("test-build.lock")
        try Data().write(to: slot)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: slot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: slot.path) }
        lead.testLock = TestLock(directory: locks.path)
        #expect(lead.roomLoad()?.reading == .steady)
        #expect(call(lead, "start_worker", ["task": "one"]).isError)
        // A census that can't be read: start_worker refuses outright (it can't count the cap); the load alone says not idle.
        lead.testLock = testLock
        runtime.censusDown = "the host is restarting"
        #expect(lead.roomLoad()?.reading == .steady)
        #expect(call(lead, "start_worker", ["task": "one"]).isError)
        // All readable and nothing of ours: the 1-minute.
        runtime.censusDown = nil
        #expect(lead.roomLoad()?.reading == .lastMinute)
        #expect(!call(lead, "start_worker", ["task": "one"]).isError)
    }

    /// audit judges the same: its task's worker ended and nothing else of ours running, the 1-minute; a slot held, the
    /// 5-minute too.
    @Test func auditReadsTheLastMinuteWhileNothingOfOursRuns() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 36) }
        _ = call(lead, "add_task", ["title": "Add b", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "add-b"])
        _ = call(try seat("worker-add-b", runtime), "report", doneReport("added"))
        try runtime.kill("session-1")
        runtime.averages = MacLoad.Averages(one: 5, five: 60)
        let held = try holdSlot(lead.testLock)
        let busy = call(lead, "audit", ["task": "add-b"])
        held.release()
        #expect(busy.isError && busy.text.contains("No verifier started") && busy.text.contains("load 60.0 (its 5-minute average"), "\(busy.text)")
        let audit = call(lead, "audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(runtime.spawned.count == 2)
    }

    // MARK: merge's wait and status

    /// merge's wait reads the slots and census at each poll: with nothing of ours running it doesn't wait on the
    /// 5-minute; with a slot held it does, and says which reading it waits on.
    @Test func mergesLoadWaitReadsTheLastMinuteWhileNothingOfOursRuns() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 36) }
        lead.loadPoll = 0.01
        var workflow = LeadWorkflow()
        workflow.testTimeoutMinutes = 45
        // Nothing of ours: no wait at all (under the greater of the two it would wait one poll, for the second reading).
        runtime.averageReadings = [MacLoad.Averages(one: 5, five: 60), MacLoad.Averages(one: 5, five: 5)]
        #expect(try lead.waitForLoad(workflow, slug: "add-b") == nil)
        #expect(runtime.averageReadings.count == 1)
        runtime.averageReadings = []
        // A slot held: it waits until the 5-minute is under, and the progress says why.
        let held = try holdSlot(lead.testLock)
        defer { held.release() }
        runtime.averages = nil
        runtime.averageReadings = [MacLoad.Averages(one: 5, five: 60), MacLoad.Averages(one: 5, five: 50), MacLoad.Averages(one: 5, five: 30)]
        let told = Told()
        let waited = try ToolProgress.with(ToolProgress(every: 0.01, told.add)) { try lead.waitForLoad(workflow, slug: "add-b") }
        #expect(waited?.from == 60)
        #expect(runtime.averageReadings.isEmpty)
        #expect(told.texts.first?.contains("for the Mac's load (60, its 5-minute average; the last minute's is 5.0) to drop below load_threshold (36)") == true, "\(told.texts)")
    }

    /// status's Mac line goes through the same function and says which reading.
    @Test func statusSaysWhichReadingTheLoadIs() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 36) }
        runtime.averages = MacLoad.Averages(one: 5, five: 60)
        let idle = call(lead, "status").text
        #expect(idle.contains("Mac (all projects): load 5.0 (1-min: none of ours runs; load_threshold 36)"), "\(idle)")
        #expect(!idle.contains("start_worker and audit refuse until it eases"), "\(idle)")
        let held = try holdSlot(lead.testLock)
        defer { held.release() }
        let busy = call(lead, "status").text
        #expect(busy.contains("load 60.0 (5-min; 1-min 5.0; load_threshold 36)"), "\(busy)")
        #expect(busy.contains("start_worker and audit refuse until it eases"), "\(busy)")
    }
}
