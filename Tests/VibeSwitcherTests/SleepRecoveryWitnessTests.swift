import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

struct SleepRecoveryWitnessTests {
    let temp = Scratch()

    @Test func sleepRecoveryWitnessSuppressesPendingButNotDroppedAndNudgesOnlyNewEvents() async throws {
        let root = temp.url("witness").path
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher/run", withIntermediateDirectories: true)
        try await Task.detached {
            var task = LeadTask(slug: "sleep-task", title: "Sleep task",
                                contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))
            task.status = .running
            task.worker = "worker"
            var board = LeadBoard()
            board.tasks = [task]
            func look(at: Double = 1000) -> WitnessWork {
                let seen = ["worker": LeadWitness.Seen(live: true, status: .done,
                                                      apiError: LeadSleepRecovery.error, apiErrorAt: at)]
                return WitnessWork(board: board, seen: seen, now: Date(timeIntervalSince1970: at + 1),
                                   advancing: false, budgetMinutes: 60, firstSeen: { _ in nil }, told: { _ in false },
                                   step: { _ in #expect(!Thread.isMainThread) }, recoveryRoot: root)
            }
            let first = look()
            #expect(first.messages.isEmpty)
            let event = try #require(first.sleepInterruptions.first)
            let nudge = LeadAdvance.nudgeFile(root: root)
            #expect(FileManager.default.fileExists(atPath: nudge))
            // An event marker, not a wait for two filesystem timestamps to differ.
            try "unchanged".write(toFile: nudge, atomically: true, encoding: .utf8)
            #expect(look().messages.isEmpty)
            #expect(try String(contentsOfFile: nudge, encoding: .utf8) == "unchanged")
            let store = LeadSleepRecovery.Store(root: root)
            _ = try store.claim(event, now: 1001, attempting: false)
            try store.release(event)
            #expect(look().messages.contains { $0.text().contains("API error") })
            #expect(try String(contentsOfFile: nudge, encoding: .utf8) == "unchanged")
            #expect(look(at: 1002).messages.isEmpty)
            #expect(try String(contentsOfFile: nudge, encoding: .utf8) != "unchanged")
        }.value
    }

    @Test func sleepRecoveryWitnessQueuesWorkersAndVerifiersWithoutReviewAdvancement() {
        for status in [LeadTask.Status.running, .review] {
            var task = LeadTask(slug: "sleep-task", title: "Sleep task",
                                contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))
            task.status = status
            task.worker = "worker"
            task.verifier = status == .review ? "verifier" : nil
            let session = status == .review ? "verifier" : "worker"
            var board = LeadBoard()
            board.tasks = [task]
            let seen = [session: LeadWitness.Seen(live: true, status: .done,
                                                 apiError: LeadSleepRecovery.error, apiErrorAt: 1000)]
            let work = WitnessWork(board: board, seen: seen, now: Date(timeIntervalSince1970: 1001),
                                   advancing: false, budgetMinutes: 60, firstSeen: { _ in nil }, told: { _ in false })
            #expect(work.sleepInterruptions.map(\.session) == [session])
        }
    }
}
