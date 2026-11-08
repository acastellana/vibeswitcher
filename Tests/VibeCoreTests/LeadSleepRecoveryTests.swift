import Foundation
import Testing
@testable import VibeCore

extension LeadAdvanceTests {
    func sleepTeam() throws -> (String, FakeRuntime, LeadToolset, LeadAdvance) {
        let (root, runtime, lead) = try team(test: nil, ["auto_advance": false])
        lead.power = { PowerState(onBattery: false, percent: 90) }
        #expect(!lead.call("add_task", ["title": "Sleep task", "goal": "g", "acceptance": ["a"], "review": "audit"]).isError)
        #expect(!lead.call("start_worker", ["task": "sleep-task"]).isError)
        return (root, runtime, lead, LeadAdvance(lead: lead, run: { $0(); return true }))
    }

    /// The fake's actual transcript ends on an API error, as the witness sees it. No real tty is used.
    func interrupted(_ session: String, root: String, runtime: FakeRuntime, at: Double = 1000,
                     error: String = LeadSleepRecovery.error) throws -> [LeadSleepRecovery.Interruption] {
        let file = temp.url("\(session)-\(Int(at)).jsonl")
        let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: at))
        let object: [String: Any] = ["type": "assistant", "isApiErrorMessage": true, "timestamp": date,
                                   "message": ["content": [["type": "text", "text": error]]]]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try data.write(to: file)
        runtime.transcripts[session] = file.path
        runtime.statuses[session] = "done"
        let seen = LeadWitness.Seen(live: true, status: .done, apiError: error, apiErrorAt: at)
        return LeadSleepRecovery.interruptions(board: BoardStore(root: root).load(), seen: [session: seen])
    }

    @Test func sleepRecoveryWorkerWaitsForPowerAndLoadAndSendsOnceAcrossRelaunch() throws {
        let (root, runtime, lead, loop) = try sleepTeam()
        defer { withExtendedLifetime(lead) {} }
        let worker = try #require(task("sleep-task", root)?.worker)
        let events = try interrupted(worker, root: root, runtime: runtime, error: LeadSleepRecovery.error + ". Press enter to retry.")
        #expect(events.count == 1)
        #expect(LeadSleepRecovery.enqueue(events, root: root) == Set(events.map(\.key)))
        var battery = PowerState(onBattery: true, percent: 20)
        battery.heldUnder = 50
        lead.power = { battery }
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime).isEmpty)
        lead.power = { nil } // Stale reading after sleep is no permission to start.
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime).isEmpty)
        lead.power = { PowerState(onBattery: false, percent: 90) }
        runtime.load = 10000
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime).isEmpty)
        runtime.load = 0
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime) == [LeadSleepRecovery.message])
        _ = LeadSleepRecovery.enqueue(events, root: root)
        let again = LeadAdvance(lead: lead, run: { $0(); return true })
        again.trigger()
        #expect(toWorker("sleep-task", root, runtime) == [LeadSleepRecovery.message])
        #expect(reports(runtime).contains { $0.contains("Resumed after sleep:") })
        #expect(!LeadAdvance.wakes("- Resumed after sleep: sent sleep-task's worker one go-on message."))
    }

    @Test func sleepRecoveryRetriesAfterLoadDropsWithoutANewInterruption() async throws {
        let (root, runtime, lead, loop) = try sleepTeam()
        let worker = try #require(task("sleep-task", root)?.worker)
        let events = try interrupted(worker, root: root, runtime: runtime)
        #expect(LeadSleepRecovery.enqueue(events, root: root) == Set(events.map(\.key)))
        runtime.load = 10000
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime).isEmpty)
        #expect(LeadSleepRecovery.enqueue(events, root: root).isEmpty, "A gate refusal must release the witness notice")
        #expect(try LeadSleepRecovery.Store(root: root).pending() == events)
        loop.trigger()
        #expect(roomWaits.waits().filter { $0.wait.what == "resume_after_sleep" && $0.wait.auto == true }.count == 1)
        #expect(roomWaits.look(mac: MacLoad.count([], load: 10000), limits: lead.macLimits(),
                              now: Date().addingTimeInterval(LeadWitness.RoomWaits.expiry + 1)).isEmpty)
        #expect(roomWaits.waits().count == 1)

        let advancing = Advancing(lead)
        defer { advancing.stop() }
        await advancing.settle()
        runtime.calls.withLock { runtime.load = 0 }
        // Only the existing room watch runs: no new interruption, enqueue, or manual advance trigger.
        #expect(roomWaits.look(mac: MacLoad.count([], load: 0), limits: lead.macLimits()).isEmpty)
        #expect(await advancing.until { toWorker("sleep-task", root, runtime) == [LeadSleepRecovery.message] })
        #expect(try LeadSleepRecovery.Store(root: root).pending().isEmpty)
        await advancing.settle()
        #expect(toWorker("sleep-task", root, runtime) == [LeadSleepRecovery.message])
    }

    @Test func sleepRecoverySessionReadFailureReleasesNoticeAndRetriesFromRoomWatch() async throws {
        let (root, runtime, lead, loop) = try sleepTeam()
        let worker = try #require(task("sleep-task", root)?.worker)
        let events = try interrupted(worker, root: root, runtime: runtime)
        _ = LeadSleepRecovery.enqueue(events, root: root)
        runtime.hostDown = "host restarting"
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime).isEmpty)
        #expect(LeadSleepRecovery.enqueue(events, root: root).isEmpty, "A session read failure must release the witness notice")
        #expect(try LeadSleepRecovery.Store(root: root).pending() == events)
        loop.trigger()
        #expect(roomWaits.waits().filter { $0.wait.what == "resume_after_sleep" && $0.wait.auto == true }.count == 1)

        // A room nudge that still cannot list sessions must rearm the wait.
        _ = roomWaits.look(mac: MacLoad.count([], load: 0), limits: lead.macLimits())
        loop.trigger()
        #expect(roomWaits.waits().count == 1)
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        await advancing.settle()
        runtime.calls.withLock { runtime.hostDown = nil }
        // No new interruption or manual trigger: only the app's room watch nudges the server.
        _ = roomWaits.look(mac: MacLoad.count([], load: 0), limits: lead.macLimits())
        #expect(await advancing.until { toWorker("sleep-task", root, runtime) == [LeadSleepRecovery.message] })
        #expect(try LeadSleepRecovery.Store(root: root).pending().isEmpty)
        await advancing.settle()
        #expect(toWorker("sleep-task", root, runtime) == [LeadSleepRecovery.message])
    }

    @Test func sleepRecoveryMissingPowerReleasesNoticeAndRearmsRoomRetry() throws {
        let (root, runtime, lead, loop) = try sleepTeam()
        defer { withExtendedLifetime(lead) {} }
        let worker = try #require(task("sleep-task", root)?.worker)
        let events = try interrupted(worker, root: root, runtime: runtime)
        _ = LeadSleepRecovery.enqueue(events, root: root)
        lead.power = { nil }
        loop.trigger()
        #expect(LeadSleepRecovery.enqueue(events, root: root).isEmpty)
        #expect(try LeadSleepRecovery.Store(root: root).pending() == events)
        #expect(roomWaits.waits().count == 1)
        _ = roomWaits.look(mac: MacLoad.count([], load: 0), limits: lead.macLimits())
        #expect(roomWaits.waits().isEmpty)
        loop.trigger()
        #expect(roomWaits.waits().count == 1, "A still-stale power reading must not lose the retry")
        #expect(toWorker("sleep-task", root, runtime).isEmpty)
        lead.power = { PowerState(onBattery: false, percent: 90) }
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime) == [LeadSleepRecovery.message])
    }

    @Test func sleepRecoveryThirdOccurrenceGoesToLeadAndWindowExpires() throws {
        let (root, runtime, lead, loop) = try sleepTeam()
        defer { withExtendedLifetime(lead) {} }
        let worker = try #require(task("sleep-task", root)?.worker)
        for at in [1000.0, 1001, 1002] {
            _ = LeadSleepRecovery.enqueue(try interrupted(worker, root: root, runtime: runtime, at: at), root: root)
            loop.trigger()
        }
        #expect(toWorker("sleep-task", root, runtime).count == 2)
        #expect(progress(root).contains("third time in an hour"))
        #expect(reports(runtime).contains { $0.contains("third time in an hour") })
        #expect(LeadAdvance.wakes("- The worker stopped a third time in an hour; it needs you."))
        // Inject elapsed time into the durable ledger, rather than waiting an hour.
        try LeadSleepRecovery.Store(root: root).edit { records in
            for i in records.indices { records[i].handled = Date().timeIntervalSince1970 - 3601 }
        }
        _ = LeadSleepRecovery.enqueue(try interrupted(worker, root: root, runtime: runtime, at: 1003), root: root)
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime).count == 3)
    }

    @Test func sleepRecoveryRestartsAuditOnSameCommitAndRefusesMovedBranch() throws {
        let (root, runtime, lead, loop) = try sleepTeam()
        defer { withExtendedLifetime(lead) {} }
        try work("sleep-task", file: "b.txt", root: root, runtime)
        #expect(!lead.call("audit", ["task": "sleep-task"]).isError)
        let first = try #require(task("sleep-task", root)?.verifier)
        let commit = try #require(vault.current(.verifier, root: root, task: "sleep-task")?.auditing)
        _ = LeadSleepRecovery.enqueue(try interrupted(first, root: root, runtime: runtime), root: root)
        loop.trigger()
        let second = try #require(task("sleep-task", root)?.verifier)
        #expect(second != first)
        #expect(killed(first, runtime))
        #expect(vault.current(.verifier, root: root, task: "sleep-task")?.auditing == commit)
        loop.trigger()
        #expect(task("sleep-task", root)?.verifier == second)
        _ = LeadSleepRecovery.enqueue(try interrupted(second, root: root, runtime: runtime, at: 1001), root: root)
        try self.commit("b.txt", "moved\n", in: Worktrees.path(root: root, slug: "sleep-task"))
        loop.trigger()
        #expect(task("sleep-task", root)?.verifier == second)
        #expect(!killed(second, runtime))
        #expect(progress(root).contains("branch moved since the interrupted audit"))
    }

    @Test func sleepRecoveryIgnoresUsageAndOverloadAndAlreadyResumedTurns() throws {
        let (root, runtime, lead, loop) = try sleepTeam()
        defer { withExtendedLifetime(lead) {} }
        let worker = try #require(task("sleep-task", root)?.worker)
        for error in ["API Error: overloaded", "API Error: usage limit reached"] {
            let events = try interrupted(worker, root: root, runtime: runtime, error: error)
            #expect(events.isEmpty)
            _ = LeadSleepRecovery.enqueue(events, root: root)
            loop.trigger()
        }
        let events = try interrupted(worker, root: root, runtime: runtime)
        _ = LeadSleepRecovery.enqueue(events, root: root)
        _ = try interrupted(worker, root: root, runtime: runtime, at: 1001, error: "API Error: usage limit reached")
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime).isEmpty)
        let seen = LeadWitness.Seen(live: true, apiError: "API Error: usage limit reached", apiErrorAt: 1001)
        #expect(LeadWitness.events(board: BoardStore(root: root).load(), seen: [worker: seen]).contains { $0.text.contains("API error") })
    }
    @Test func sleepRecoveryRefusedDeliveryIsReportedAndNeverRetyped() throws {
        let (root, runtime, lead, loop) = try sleepTeam()
        defer { withExtendedLifetime(lead) {} }
        let worker = try #require(task("sleep-task", root)?.worker)
        runtime.delivery = .notSubmitted("draft")
        let events = try interrupted(worker, root: root, runtime: runtime)
        _ = LeadSleepRecovery.enqueue(events, root: root)
        loop.trigger()
        let attempts = toWorker("sleep-task", root, runtime).count
        #expect(attempts == 1)
        #expect(reports(runtime).contains { $0.contains("Sleep resume was not submitted") })
        #expect(LeadSleepRecovery.enqueue(events, root: root).isEmpty)
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime).count == attempts)
    }

    @Test func sleepRecoveryUnconfirmedTranscriptReportsToLeadAndReleasesWitnessNotice() throws {
        let (root, runtime, lead, loop) = try sleepTeam()
        defer { withExtendedLifetime(lead) {} }
        let worker = try #require(task("sleep-task", root)?.worker)
        let events = try interrupted(worker, root: root, runtime: runtime)
        _ = LeadSleepRecovery.enqueue(events, root: root)
        runtime.transcripts.removeValue(forKey: worker)
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime).isEmpty)
        #expect(reports(runtime).contains { $0.contains("could not be confirmed as still interrupted") })
        #expect(LeadSleepRecovery.enqueue(events, root: root).isEmpty)
        let before = reports(runtime).count
        loop.trigger()
        #expect(reports(runtime).count == before)
    }

    @Test func sleepRecoveryDoesNotMessageAnAgentThatQuitWhileHeld() throws {
        let (root, runtime, lead, loop) = try sleepTeam()
        defer { withExtendedLifetime(lead) {} }
        let worker = try #require(task("sleep-task", root)?.worker)
        _ = LeadSleepRecovery.enqueue(try interrupted(worker, root: root, runtime: runtime), root: root)
        runtime.endings[worker] = LeadWitness.agentQuitEnding
        loop.trigger()
        #expect(toWorker("sleep-task", root, runtime).isEmpty)
    }

    @Test func sleepRecoveryPanelRefusesBranchMovedDuringSharedTests() throws {
        let (root, runtime, lead, loop) = try sleepTeam()
        defer { withExtendedLifetime(lead) {} }
        try work("sleep-task", file: "b.txt", root: root, runtime)
        #expect(!lead.call("audit", ["task": "sleep-task"]).isError)
        let verifier = try #require(task("sleep-task", root)?.verifier)
        // The shared test run moves this fake worker's branch before the restart launches its panel.
        let worktree = Worktrees.path(root: root, slug: "sleep-task")
        let command = "cd " + RecentProjects.shellQuote(worktree)
            + "; printf 'moved\\n' > moved.txt; git add moved.txt; git commit -qm moved"
        #expect(!lead.call("configure", ["audit_finders": 2, "test_command": command]).isError)
        _ = LeadSleepRecovery.enqueue(try interrupted(verifier, root: root, runtime: runtime), root: root)
        loop.trigger()
        #expect(task("sleep-task", root)?.verifier == verifier)
        #expect(!killed(verifier, runtime))
        #expect(progress(root).contains("moved since the interrupted audit"))
    }

}
