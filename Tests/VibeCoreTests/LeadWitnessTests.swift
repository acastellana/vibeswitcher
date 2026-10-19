import Foundation
import Testing
@testable import VibeCore

/// A verifier that gave its verdict, then the worker committed again (report moved the verdict to `outdatedEvidence`).
extension LeadWitnessTests {
    /// The board as report() leaves it: the verifier's verdict on `a`, then the worker's report on a newer commit.
    func reworked(_ slug: String, passed: Bool, verifier: String = "v1", at: Double, panel: LeadAuditPanel? = nil) -> LeadBoard {
        var task = task(slug, .review, worker: "w1", verifier: verifier)
        task.panel = panel
        task.outdatedEvidence = LeadEvidence(completion: passed ? .complete : .incomplete, integrity: passed ? .clean : .suspect,
                                             summary: "", commit: "a", at: at)
        var board = LeadBoard()
        board.tasks = [task]
        return board
    }

    /// 2026-10-19, twice: verifier-2-0-part (its verdict failed at 17:08; the worker's fix at 17:19) and
    /// a-new-project-button (complete, suspect at 20:5x; then the worker's fix). Each verifier had submitted, and the
    /// witness said it "stopped without calling submit_audit". It says nothing: report() already told the lead to
    /// audit the new commit.
    @Test func aVerifierThatGaveItsVerdictIsNoNewsOnceTheBranchMoves() {
        let t0 = Date(timeIntervalSince1970: 1_792_429_680)  // 2026-10-19 17:08
        let started = t0.timeIntervalSince1970 - 600
        let verdict = t0.timeIntervalSince1970
        // Sitting at its prompt after submit_audit, its session ended, or its agent gone and its shell left open.
        let afterwards: [LeadWitness.Seen] = [
            .init(live: true, status: .done, since: t0, activity: .idle(background: nil), lastActivity: verdict, started: started),
            .init(live: false, exit: 0, started: started),
            .init(live: true, agentQuit: true, started: started),
        ]
        for passed in [true, false] {
            for slug in ["verifier-2-0-part", "a-new-project-button"] {
                let board = reworked(slug, passed: passed, at: verdict)
                for seen in afterwards {
                    for after in [60.0, 660, 3_600] {
                        let sessions = ["v1": seen, "w1": LeadWitness.Seen(live: true, status: .working, since: t0 + 600, activity: .working("Bash"),
                                                                           lastActivity: verdict + after, started: started - 3_600)]
                        let events = LeadWitness.events(board: board, seen: sessions, now: t0 + after)
                        #expect(events.isEmpty, "\(slug), passed \(passed), \(after)s on: \(events.map(\.text))")
                        let told = LeadWitness.messages(board: board, seen: sessions, now: t0 + after, told: { _ in false })
                        #expect(!told.contains { $0.text.contains("submit_audit") || $0.text.contains("without a verdict") })
                    }
                }
            }
        }
        // Several finders: the vote was their verdict, each of them done.
        let panel = LeadAuditPanel(focuses: ["contract and acceptance", "bugs and regressions"], sessions: ["v1", "v2"], reported: [1, 2],
                                   commit: "a", logs: [], run: "the test command passed")
        let board = reworked("verifier-2-0-part", passed: false, at: verdict, panel: panel)
        let ended = LeadWitness.Seen(live: false, exit: 0, started: started)
        #expect(LeadWitness.events(board: board, seen: ["v1": ended, "v2": ended], now: t0 + 660).isEmpty)
    }

    /// The lead audits the new commit: that verifier started after the earlier verdict, so one that stops without
    /// submitting is told, as one that ends is.
    @Test func theNextVerifierIsStillWatched() {
        let t0 = Date(timeIntervalSince1970: 1_792_429_680)
        let verdict = t0.timeIntervalSince1970
        let started = verdict + 700
        let board = reworked("verifier-2-0-part", passed: false, verifier: "v2", at: verdict)
        let stopped = LeadWitness.Seen(live: true, status: .done, since: t0 + 900, activity: .idle(background: nil), lastActivity: started + 200, started: started)
        let told = LeadWitness.events(board: board, seen: ["v2": stopped], now: t0 + 900 + LeadWitness.quiet + 1)
        #expect(told.map(\.text).contains { $0.contains("The verifier on verifier-2-0-part stopped without calling submit_audit") }, "\(told.map(\.text))")
        let ended = LeadWitness.events(board: board, seen: ["v2": .init(live: false, exit: 1, started: started)], now: t0 + 900)
        #expect(ended.map(\.key) == ["v2|ended"])
        #expect(ended.first?.text.contains("ended without a verdict") == true)
    }
}
