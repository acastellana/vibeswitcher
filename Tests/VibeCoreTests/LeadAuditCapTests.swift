import Foundation
import Testing
@testable import VibeCore

/// A project's audits at once are capped at heavy_slots (see `LeadAuditCap.swift`): 2026-11-19, nine audits started
/// within a minute of a quota reset, the load went to 54–110, and every merge waited 20+ minutes for a test slot.
extension LeadAdvanceTests {
    /// The verifiers the lead has started so far, by task.
    func verifiersStarted(_ runtime: FakeRuntime) -> [String] {
        runtime.calls.lock()
        defer { runtime.calls.unlock() }
        return runtime.spawned.compactMap { spawn in
            spawn.command.range(of: #"--name 'verify-([^']+)'"#, options: .regularExpression).map { String(spawn.command[$0].dropFirst("--name 'verify-".count).dropLast()) }
        }
    }

    /// Five tasks ready for audit and heavy_slots 2: auto_advance starts two audits, holds the other three in board
    /// order with one line saying so, and starts the next as one's verdict comes in. The lead's audit past the cap is
    /// refused with why and its place in line, unless it says override_heavy_slots.
    @Test func autoAdvanceStartsNoMoreAuditsThanHeavySlotsAndTheNextAsOneEnds() async throws {
        let (root, runtime, lead) = try team(["max_workers": 5, "heavy_slots": 2])
        lead.macLimits = { MacLimits(maxSessions: 12) }
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        let slugs = ["cap-a", "cap-b", "cap-c", "cap-d", "cap-e"]
        for slug in slugs {
            let added = lead.call("add_task", ["title": slug.replacingOccurrences(of: "-", with: " "), "goal": "g", "acceptance": ["a"], "review": "audit"])
            #expect(!added.isError, "\(added.text)")
        }
        #expect(await advancing.until { slugs.allSatisfy { task($0, root)?.status == .running } })
        for slug in slugs { try work(slug, file: "\(slug).txt", root: root, runtime) }

        // Two start, in the order their work came in; the rest are held in board order, said in one line.
        #expect(await advancing.until { reports(runtime).contains { $0.contains("Holding the audits of cap-c, cap-d, cap-e: heavy_slots is 2, and 2 of this project's audits are under way (cap-a, cap-b)") } },
                "\(reports(runtime))")
        await advancing.settle()
        #expect(verifiersStarted(runtime) == ["cap-a", "cap-b"])
        #expect(reports(runtime).contains { $0.contains("They start, in board order, as one ends.") })

        // The lead's audit past the cap: refused, with why and its place in line; nothing started.
        let refused = lead.call("audit", ["task": "cap-d"])
        #expect(refused.isError && refused.text.contains("heavy_slots is 2") && refused.text.contains("(cap-a, cap-b)")
                && refused.text.contains("Its place in line: 2nd, after cap-c (board order)") && refused.text.contains("override_heavy_slots: true"), "\(refused.text)")
        #expect(verifiersStarted(runtime) == ["cap-a", "cap-b"])

        // cap-a's verdict comes in: the next in board order starts, and only it.
        let verdict = try seat("verify-cap-a", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked", "tests": "passed"])
        #expect(!verdict.isError, "\(verdict.text)")
        #expect(await advancing.until { reports(runtime).contains { $0.contains("Started the audit of cap-c") } }, "\(reports(runtime))")
        await advancing.settle()
        #expect(verifiersStarted(runtime) == ["cap-a", "cap-b", "cap-c"])
        #expect(await advancing.until { reports(runtime).contains { $0.contains("Holding the audits of cap-d, cap-e: heavy_slots is 2, and 2 of this project's audits are under way (cap-b, cap-c)") } },
                "\(reports(runtime))")

        // The lead's override starts one past the cap.
        let forced = lead.call("audit", ["task": "cap-d", "override_heavy_slots": true])
        #expect(!forced.isError, "\(forced.text)")
        #expect(verifiersStarted(runtime) == ["cap-a", "cap-b", "cap-c", "cap-d"])
    }

    /// Only this project's audits count for its cap: another project's under way doesn't hold one here, and a
    /// re-audit of its own task (a new commit after findings) counts as one of its audits.
    @Test func onlyThisProjectsAuditsCountForItsCap() throws {
        let (root, runtime, lead) = try team(["heavy_slots": 1])
        lead.macLimits = { MacLimits(maxSessions: 12) }
        for slug in ["one-x", "one-y"] {
            #expect(!lead.call("add_task", ["title": slug.replacingOccurrences(of: "-", with: " "), "goal": "g", "acceptance": ["a"], "review": "audit", "auto_advance": false]).isError)
            #expect(!lead.call("start_worker", ["task": slug]).isError)
            try work(slug, file: "\(slug).txt", root: root, runtime)
        }
        #expect(!lead.call("audit", ["task": "one-x"]).isError)
        let held = lead.call("audit", ["task": "one-y"])
        #expect(held.isError && held.text.contains("heavy_slots is 1, and 1 of this project's audits is under way (one-x)")
                && held.text.contains("Its place in line: 1st (none waits ahead of it)"), "\(held.text)")

        // Another project on the same Mac, its own cap of 1: one-x's verifier doesn't count there.
        let other = temp.url("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherRoot = other.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: otherRoot) }
        try commit("a.txt", "one\n", in: otherRoot)
        let otherLead = try self.lead(otherRoot, runtime)
        otherLead.power = { nil }
        otherLead.macLimits = { MacLimits(maxSessions: 12) }
        #expect(!otherLead.call("configure", ["merge_policy": "auto", "test_command": "true", "heavy_slots": 1]).isError)
        #expect(!otherLead.call("add_task", ["title": "two z", "goal": "g", "acceptance": ["a"], "review": "audit", "auto_advance": false]).isError)
        #expect(!otherLead.call("start_worker", ["task": "two-z"]).isError)
        try commit("z.txt", "zed\n", in: Worktrees.path(root: otherRoot, slug: "two-z"))
        #expect(!(try seat("worker-two-z", runtime).call("report", doneReport("added z.txt"))).isError)
        let otherAudit = otherLead.call("audit", ["task": "two-z"])
        #expect(!otherAudit.isError, "\(otherAudit.text)")
        // Nor does two-z's count here.
        let still = lead.call("audit", ["task": "one-y"])
        #expect(still.isError && still.text.contains("1 of this project's audits is under way (one-x)") && !still.text.contains("two-z"), "\(still.text)")

        // one-x's verdict leaves an Important finding; its worker commits a fix and reports: the re-audit is one of
        // this project's audits, and one-y's waits behind it.
        let finding: [String: Any] = ["severity": "Important", "file": "one-x.txt", "line": 1, "evidence": "says bee",
                                      "failure_scenario": "cat one-x.txt gives bee", "status": "open"]
        #expect(!(try seat("verify-one-x", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "one problem",
                                                                          "tests": "passed", "findings": [finding]])).isError)
        #expect(!lead.call("audit", ["task": "one-y"]).isError)
        try commit("one-x.txt", "fixed\n", in: Worktrees.path(root: root, slug: "one-x"))
        #expect(!(try seat("worker-one-x", runtime).call("report", doneReport("fixed one-x.txt"))).isError)
        let reaudit = lead.call("audit", ["task": "one-x"])
        #expect(reaudit.isError && reaudit.text.contains("under way (one-y)"), "\(reaudit.text)")
    }
}
