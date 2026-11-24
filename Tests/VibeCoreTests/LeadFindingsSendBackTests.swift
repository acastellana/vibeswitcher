import Foundation
import Testing
@testable import VibeCore

/// 2026-11-21, claude-dictation-text: auto_advance sent a fresh worker its audit's open Important finding cut to the
/// board's one line ("… clearing()…"), and the worker had to ask for its failure scenario. A worker is sent each open
/// finding whole, from auto_advance (to its running worker, or a fresh one after a release) and from the lead's
/// message(findings:) alike. Fake sessions only; each wait is on the loop's own passes.
extension LeadAdvanceTests {
    /// A finding far past any one-line cut, its evidence over several lines, each field ending in a marker of its own.
    func longFinding() -> (report: [String: Any], evidence: String, scenario: String) {
        let evidence = "b.txt:1 says bee where the contract wants b.\n"
            + (1...40).map { "Line \($0) of what the verifier ran and saw: grep -n bee b.txt gives 1:bee, and the check expects b." }.joined(separator: "\n")
            + "\nEND-OF-EVIDENCE"
        let scenario = "A user runs `cat b.txt` after clearing() the cache: "
            + String(repeating: "the read gives bee, the comparison with b fails, and the caller retries; ", count: 20)
            + "END-OF-SCENARIO"
        return (["severity": "Important", "file": "b.txt", "line": 1, "evidence": evidence, "failure_scenario": scenario, "status": "open"], evidence, scenario)
    }

    /// The finding's two fields reached the worker whole, in one message.
    func sentWhole(_ sent: String, _ evidence: String, _ scenario: String) -> Bool {
        sent.contains(evidence) && sent.contains(scenario)
    }

    @Test func wholeFindingsGoToARunningWorker() async throws {
        let (root, runtime, lead) = try team()
        _ = try await auditUnderWay(root, runtime, lead)
        let long = longFinding()
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "one problem",
                                                                                "tests": "passed", "findings": [long.report]])
        #expect(!verdict.isError, "\(verdict.text)")
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        #expect(await advancing.until { reports(runtime).contains { $0.contains("Sent add-b's worker the open Important findings add-b:F1") } })
        let sent = try #require(toWorker("add-b", root, runtime).first { $0.contains("answer_findings") })
        #expect(sentWhole(sent, long.evidence, long.scenario), "\(sent)")
        #expect(!sent.contains("You're a new worker"), "\(sent)")
    }

    @Test func wholeFindingsGoToAFreshWorkerAfterARelease() async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        let (worker, _, _) = try await releasedAudit(idle: true, root, runtime, advancing, lead)
        #expect(await advancing.until { killed(worker, runtime) && task("add-b", root)?.released == worker })
        let long = longFinding()
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "one problem",
                                                                                "tests": "passed", "findings": [long.report]])
        #expect(!verdict.isError, "\(verdict.text)")
        #expect(await advancing.until { task("add-b", root)?.worker != worker
            && reports(runtime).contains { $0.contains("(in a new worker: its last one was released during the audit)") } })
        let sent = try #require(toWorker("add-b", root, runtime).first { $0.contains("answer_findings") })
        #expect(sent.contains("You're a new worker on this task"), "\(sent)")
        #expect(sentWhole(sent, long.evidence, long.scenario), "\(sent)")
    }

    /// The lead's own path: the verdict names message(findings:), which sends the named findings whole.
    @Test func wholeFindingsGoWithTheLeadsMessage() async throws {
        let (root, runtime, lead) = try team()
        _ = try await auditUnderWay(root, runtime, lead)
        let long = longFinding()
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "one problem",
                                                                                "tests": "passed", "findings": [long.report]])
        #expect(!verdict.isError, "\(verdict.text)")
        let told = BoardStore(root: root).load().reports?.first { $0.about == "verifier add-b" }?.text ?? ""
        #expect(told.contains("findings: [\"F1\"]"), "\(told)")
        let sent = lead.call("message", ["task": "add-b", "text": "Your audit's open finding:", "findings": ["add-b:F1"]])
        #expect(!sent.isError, "\(sent.text)")
        let got = try #require(toWorker("add-b", root, runtime).first { $0.hasPrefix("Your audit's open finding:") })
        #expect(sentWhole(got, long.evidence, long.scenario), "\(got)")
        // An id it doesn't have sends nothing.
        let wrong = lead.call("message", ["task": "add-b", "text": "And this one", "findings": ["F9"]])
        #expect(wrong.isError && wrong.text.contains("F9"), "\(wrong.text)")
        #expect(!toWorker("add-b", root, runtime).contains { $0.hasPrefix("And this one") })
    }
}
