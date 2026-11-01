import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The incident of 2026-10-31 and 2026-11-01 (docs/lead/incidents.md): a verifier's session waited indefinitely on a
/// permission prompt the user couldn't see or reach, and the lead could only start the audit again, the finders' work
/// lost. Here a fake Claude Code (`FakeClaude`, on a scratch pty through a scratch session host: never a real session)
/// is the verifier, waiting on a permission prompt; the witness's look (`WitnessWork`, as the app's) at an injected
/// time, and the app's decline (`PromptDecline.handle`, as `LeadController` runs it) through the session host.
@MainActor
@Suite(.serialized)
struct StuckVerifierPromptTests {
    let temp = Scratch()

    @Test func aVerifierPromptNoOneAnswersIsDeclinedAfterTheWaitWithItsReasonAndTheLeadIsToldOnce() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let command = "git ls-files -s Package.swift; git config --get remote.origin.url"
        h.tell(["op": "permission", "command": command])
        try await h.paneShows { $0.contains("Do you want to proceed?") && $0.contains("git config") }

        let verifier = h.session.id.uuidString
        var task = LeadTask(slug: "audit-me", title: "audit-me", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = .review
        task.verifier = verifier
        var board = LeadBoard()
        board.tasks = [task]
        let since = Date()
        let started = since.addingTimeInterval(-300).timeIntervalSince1970
        let seen = [verifier: LeadWitness.Seen(live: true, status: .needsInput, since: since, detail: "Bash: git ls-files -s Package.swift",
                                               pending: PendingPrompt(text: "Run: " + command, since: since.timeIntervalSince1970),
                                               started: started, boundAt: started, toolsAt: started + 2)]
        var told: Set<String> = []
        func look(_ after: TimeInterval) -> WitnessWork {
            WitnessWork(board: board, seen: seen, now: since.addingTimeInterval(after), advancing: false, budgetMinutes: 60,
                        firstSeen: { _ in nil }, told: { told.contains($0) })
        }

        // Before the wait: nothing declined, and nothing for the lead (who could only start the audit again).
        for after in [5.0, 60, 119] {
            let work = look(after)
            #expect(work.stuckPrompts.isEmpty, "\(after)s")
            #expect(work.messages.isEmpty, "\(after)s: \(work.messages.map { $0.text() })")
        }
        #expect(h.agent["mode"] as? String == "permission")

        // Past it: declined, as the app does (each stuck prompt told once).
        var reports: [String] = []
        let work = look(LeadWitness.promptWait + 1)
        #expect(work.messages.isEmpty)
        #expect(work.stuckPrompts.count == 1)
        for stuck in work.stuckPrompts where told.insert(stuck.key).inserted {
            PromptDecline.handle(stuck, host: h.host) { text in reports.append(text()) }
        }
        // The verifier gets the reason as the prompt's No, and its turn goes on.
        try await h.waitFor { h.agent["declined"] as? String == LeadWitness.declineReason }
        #expect(h.agent["mode"] as? String == "working")
        let transcript = try String(contentsOf: h.transcript, encoding: .utf8)
        #expect(transcript.contains("the user said:\\n" + LeadWitness.declineReason), "\(transcript.suffix(600))")
        // The lead: one report, naming the command.
        try await h.waitFor { !reports.isEmpty }
        #expect(reports.count == 1)
        #expect(reports.first?.contains("permission prompt no one answers: “Run: \(command)”") == true, "\(reports)")
        #expect(reports.first?.contains(LeadWitness.declineReason) == true)
        // And the next looks tell nothing more.
        for after in [300.0, 3_600] {
            let again = look(after)
            #expect(again.stuckPrompts.isEmpty && again.messages.isEmpty, "\(after)s")
        }
        #expect(reports.count == 1)
    }

    /// A No row that takes no text (Claude Code 2.1.304's plain "No"), where the reason's letters are keys: the "k" in
    /// "check" moves the cursor up. Enter never goes on a Yes row; Esc declines it instead, and the lead is told so.
    @Test func aNoRowThatTakesNoReasonIsDeclinedWithEscNeverApproved() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let command = "bash scripts/probe.sh --deep"
        h.tell(["op": "permission", "command": command, "plainNo": true])
        try await h.paneShows { $0.contains("Do you want to proceed?") && $0.contains("probe.sh") }
        let since = Date().addingTimeInterval(-LeadWitness.promptWait - 1)
        let stuck = LeadWitness.StuckPrompt(key: "\(h.session.id.uuidString)|input-1", session: h.session.id.uuidString, slug: "audit-me",
                                            prompt: PendingPrompt(text: "Run: " + command, since: since.timeIntervalSince1970))
        var reports: [String] = []
        PromptDecline.handle(stuck, host: h.host) { text in reports.append(text()) }
        try await h.waitFor { !reports.isEmpty }
        #expect(reports.count == 1 && reports.first?.contains("with Esc") == true && reports.first?.contains(command) == true, "\(reports)")
        try await h.waitFor { h.agent["mode"] as? String == "idle" }
        #expect(h.agent["reply"] as? String == "Denied.", "\(h.agent)")
        let transcript = try String(contentsOf: h.transcript, encoding: .utf8)
        #expect(!transcript.contains("\"ran " + command), "a Yes went in: \(transcript.suffix(400))")
    }
}
