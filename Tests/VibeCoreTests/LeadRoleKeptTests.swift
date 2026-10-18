import Foundation
import Testing
@testable import VibeCore

/// A running lead through an install: the app binds its role again only to the session the vault binds it to, and a
/// session whose role went elsewhere is told where, without a "/mcp" that wouldn't help.
struct LeadRoleKeptTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("kept")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    @Test func theAppBindsTheRunningLeadAgainOnlyToTheSessionItHeld() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let grant = try #require(vault.current(.lead, root: root, task: nil)?.id)
        // Relaunched, the app finds the lead's session still running: its role, bound to it again, the same grant.
        #expect(try vault.rebindLead(root: root, session: "lead-session")?.id == grant)
        #expect(vault.current(.lead, root: root, task: nil)?.session == "lead-session")
        #expect(!lead.call("status", [:]).isError)
        // Another session (a second "Lead · …" left running) gets nothing, and the lead keeps its role.
        #expect(try vault.rebindLead(root: root, session: "other-session") == nil)
        #expect(vault.current(.lead, root: root, task: nil)?.session == "lead-session")
        // A vault that began empty binds the role to no session: none takes it back.
        let empty = LeadVault.Book().vault(folder: vault.folder, as: { .app })
        #expect(try empty.rebindLead(root: root, session: "lead-session") == nil)
        #expect(empty.current(.lead, root: root, task: nil) == nil)
        // Only the app binds: the lead's own session can't bind a role to itself again.
        let fromLead = vault(for: runtime)
        #expect(throws: LeadVault.Refused.self) { try fromLead.rebindLead(root: root, session: "lead-session") }
    }

    @Test func aReplacedLeadIsToldWhichSessionToContinueInAndNotToReconnect() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let old = try lead(root, runtime)
        #expect(!old.call("status", [:]).isError)
        // You started a new lead from the app: its session holds the role now.
        let new = try runtime.spawn(cwd: root, command: "claude", label: "Lead · kept", agent: "claude", trust: true)
        let grant = try vault.startLead(root: root, branch: "main")
        try vault.bind(grant, root: root, session: new)
        let refused = old.call("status", [:])
        #expect(refused.isError)
        #expect(refused.text.contains("session \(new.prefix(8))"), "\(refused.text)")
        #expect(refused.text.contains("‘Lead · kept’"))
        #expect(refused.text.contains("continue in that session"))
        #expect(refused.text.contains("won't bring them back"))
        #expect(!refused.text.contains("/mcp"))
        #expect(!refused.text.contains("started another session for it"))
    }

    @Test func aLeadWhoseRoleTheHostLostIsToldSoAndNotToReconnect() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        // The host's vault lost the team (it started over): nobody started another lead.
        let grant = try #require(vault.current(.lead, root: root, task: nil)?.id)
        try vault.revoke(grant, root: root)
        let refused = lead.call("status", [:])
        #expect(refused.isError)
        #expect(refused.text.contains("no other session does"), "\(refused.text)")
        #expect(refused.text.contains("Project Lead"))
        #expect(!refused.text.contains("VibeSwitcher started"))
        #expect(!refused.text.contains("/mcp"))
    }

    @Test func aWorkerStartedUnderOneLeadStillReportsAfterANewLeadTakesOver() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let leadA = try lead(root, runtime)
        _ = leadA.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(!leadA.call("start_worker", ["task": "add-b"]).isError)
        let worker = try seat("worker-add-b", runtime)
        #expect(!worker.call("progress", ["text": "half way"]).isError)
        // You start lead B from the app: it takes the lead's role; the team lead A started keeps its grants.
        let grant = try vault.startLead(root: root, branch: "main")
        try vault.bind(grant, root: root, session: "lead-b-session")
        let progress = worker.call("progress", ["text": "tests pass"])
        #expect(!progress.isError, "\(progress.text)")
        let report = worker.call("report", ["status": "done", "summary": "added b"])
        #expect(!report.isError, "\(report.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.status == .review)
        // Lead B runs the task on (its verifier); lead A is sent to it.
        let seatB = FakeSeat(runtime, agent: LeadAgent(pid: 4343, tty: "ttys041", session: "lead-b-session"))
        let leadB = LeadToolset(root: root, runtime: seatB, vault: vault(for: seatB))
        let audit = leadB.call("audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(leadA.call("status", [:]).text.contains("session lead-b-s"))
    }

    @Test func aWorkerReplacedByTheLeadIsToldToStop() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let worker = try issued(.worker, task: "t", root: root, runtime, session: "first-worker")
        let lead = try #require(vault.current(.lead, root: root, task: nil)?.session)
        let issuer = book.vault(folder: vault.folder, as: { .session(lead) })
        let grant = try issuer.issue(role: .worker, root: root, task: "t")
        try issuer.bind(grant, root: root, session: "second-worker")
        let refused = worker.call("progress", ["text": "done"])
        #expect(refused.isError)
        #expect(refused.text.contains("task t's worker role"), "\(refused.text)")
        #expect(refused.text.contains("The lead started another worker"))
        #expect(refused.text.contains("session second-w"))
        #expect(refused.text.contains("Stop here"))
    }
}
