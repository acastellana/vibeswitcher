import Foundation
import Testing
@testable import VibeCore

/// genswap, 2026-10-24: app-security-rpc-trust had four verifiers alive at once (13:37, 13:50, 14:14, 14:22), one per
/// audit call on the same commit, none of them ended by the next audit; all four went together at 14:31, when the task
/// was folded. An audit now ends the task's earlier verifier first: a task has one live verifier, or audit_finders
/// finders, at a time. On fake sessions only.
func liveVerifiers(_ runtime: FakeRuntime, root: String, slug: String) -> [String] {
    let folder = (Worktrees.path(root: root, slug: slug) as NSString).standardizingPath
    return ((try? runtime.sessions()) ?? []).filter { session in
        session.live && (session.cwd as NSString).standardizingPath == folder && LeadTeams.role(label: session.label) == .verifier
    }.map(\.id)
}

extension LeadToolsetTests {
    @Test func auditAgainEndsTheEarlierVerifierFirst() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        let first = call(lead, "audit", ["task": "one"])
        #expect(!first.isError, "\(first.text)")
        #expect(liveVerifiers(runtime, root: root, slug: "one") == ["session-2"])
        // session-2 is still at work (or never got its tools): the next audit ends it before it starts session-3.
        let again = call(lead, "audit", ["task": "one"])
        #expect(!again.isError, "\(again.text)")
        #expect(runtime.killed.contains("session-2"))
        #expect(again.text.contains("Ended one's earlier verifier first"), "\(again.text)")
        #expect(liveVerifiers(runtime, root: root, slug: "one") == ["session-3"])
        #expect(BoardStore(root: root).load().task("one")?.verifier == "session-3")
        // And again: never more than one.
        #expect(!call(lead, "audit", ["task": "one"]).isError)
        #expect(liveVerifiers(runtime, root: root, slug: "one") == ["session-4"])
        // The worker isn't one of them.
        #expect(!runtime.killed.contains("session-1"))
    }

    /// One the host won't end refuses the audit: a verifier started beside it would make two.
    @Test func auditRefusesWhileTheEarlierVerifierCantBeEnded() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.stopWait = 0.3
        lead.sessionProcesses = { _ in [] }
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        #expect(!call(lead, "audit", ["task": "one"]).isError)
        runtime.refusals["session-2"] = Self.refusal
        let spawned = runtime.spawned.count
        let again = call(lead, "audit", ["task": "one"])
        #expect(again.isError)
        #expect(again.text.hasPrefix("Not audited, no verifier started: one's earlier verifier is still running"), "\(again.text)")
        #expect(runtime.spawned.count == spawned)
        #expect(liveVerifiers(runtime, root: root, slug: "one") == ["session-2"])
        #expect(BoardStore(root: root).load().task("one")?.verifier == "session-2")
    }
}

extension LeadAuditFindersTests {
    /// Under audit_finders 2, an audit again ends the first panel's two finders: two live, never four.
    @Test func anAuditAgainEndsTheEarlierPanelsFinders() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try ready(runtime, finders: 2)
        #expect(!call(lead, "audit", ["task": "add-b"]).isError)
        let panel = try #require(BoardStore(root: root).load().task("add-b")?.panel?.sessions)
        #expect(panel.count == 2)
        #expect(Set(liveVerifiers(runtime, root: root, slug: "add-b")) == Set(panel))
        let again = call(lead, "audit", ["task": "add-b"])
        #expect(!again.isError, "\(again.text)")
        #expect(again.text.contains("Ended add-b's 2 earlier verifiers first"), "\(again.text)")
        #expect(Set(runtime.killed).isSuperset(of: panel))
        let next = try #require(BoardStore(root: root).load().task("add-b")?.panel?.sessions)
        #expect(Set(liveVerifiers(runtime, root: root, slug: "add-b")) == Set(next))
        #expect(next.count == 2 && Set(next).isDisjoint(with: panel))
    }
}

extension LeadAdvanceTests {
    /// auto_advance's audit of a new head ends the verifier still on the old one (it never submitted) before its own.
    @Test func theAutomaticAuditEndsTheEarlierVerifierFirst() throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"])
        #expect(advancing.until { task("add-b", root)?.status == .running })
        try work("add-b", file: "b.txt", root: root, runtime)
        let first = head("agent/add-b", root)
        #expect(advancing.until { vault.current(.verifier, root: root, task: "add-b")?.auditing == first })
        let earlier = try #require(task("add-b", root)?.verifier)
        // Its verifier never submits; the worker commits more and reports done again on a new head.
        try work("add-b", file: "c.txt", root: root, runtime)
        let second = head("agent/add-b", root)
        #expect(second != first)
        #expect(advancing.until { vault.current(.verifier, root: root, task: "add-b")?.auditing == second })
        runtime.calls.lock()
        let killed = runtime.killed
        runtime.calls.unlock()
        #expect(killed.contains(earlier))
        let now = try #require(task("add-b", root)?.verifier)
        #expect(now != earlier)
        #expect(liveVerifiers(runtime, root: root, slug: "add-b") == [now])
    }
}
