import Darwin
import Foundation
import Testing
@testable import VibeCore

/// 2026-10-18 22:15–23:40: cleanup answered "Cleaned up" and stop_worker "Stopped the worker", yet seven of the team's
/// Claude sessions ran on for hours (320–390 MB each). The host refused every kill of the worker (it held no role in
/// the team any more: its grant didn't come over to the first host with a vault), and the tool server dropped the
/// refusal; the task's earlier verifiers, replaced by a later audit, were off the board, so cleanup never asked.
extension LeadToolsetTests {
    static let refusal = "Only VibeSwitcher, the session itself (or the one that started it) or its team's lead ends a session."

    @Test func stopWorkerSaysTheHostsRefusalNotStopped() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.stopWait = 0.3
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        runtime.refusals["session-1"] = Self.refusal
        let stopped = call(lead, "stop_worker", ["task": "one"])
        #expect(stopped.isError)
        #expect(stopped.text.contains("couldn't end pid \(getpid()): \(Self.refusal)"), "\(stopped.text)")
        #expect(!stopped.text.contains("Stopped"))
        // Not stopped, so not said to be on the board either.
        #expect(BoardStore(root: root).load().task("one")?.stopped == nil)
        #expect(try runtime.sessions().first?.live == true)

        runtime.refusals = [:]
        let again = call(lead, "stop_worker", ["task": "one"])
        #expect(!again.isError)
        #expect(again.text.contains("Stopped the worker on one (ended pid \(getpid()))"), "\(again.text)")
    }

    @Test func stopWorkerSaysWhenTheWorkerOutlivesTheWait() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.stopWait = 0.3
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        runtime.stubborn = ["session-1"]
        let stopped = call(lead, "stop_worker", ["task": "one"])
        #expect(stopped.isError)
        #expect(stopped.text.contains("couldn't end pid \(getpid())") && stopped.text.contains("still running"), "\(stopped.text)")
    }

    @Test func cleanupEndsTheTasksEarlierVerifiersToo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        // Audited twice: the board holds only the second verifier (session-3).
        #expect(!call(lead, "audit", ["task": "one"]).isError)
        #expect(!call(lead, "audit", ["task": "one"]).isError)
        #expect(BoardStore(root: root).load().task("one")?.verifier == "session-3")
        runtime.pids = ["session-1": getpid(), "session-2": getppid(), "session-3": getpid()]
        let cleaned = call(lead, "cleanup", ["task": "one", "force": true])
        #expect(!cleaned.isError, "\(cleaned.text)")
        #expect(Set(runtime.killed) == ["session-1", "session-2", "session-3"])
        #expect(cleaned.text.contains("ended pid \(getppid())"), "\(cleaned.text)")
        #expect(try runtime.sessions().isEmpty)
    }

    @Test func cleanupThatCantEndASessionSaysWhyAndKeepsTheWorktree() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.stopWait = 0.3
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        runtime.refusals["session-1"] = Self.refusal
        let cleaned = call(lead, "cleanup", ["task": "one", "force": true])
        #expect(cleaned.isError)
        #expect(cleaned.text.contains("couldn't end pid \(getpid()): \(Self.refusal)"), "\(cleaned.text)")
        #expect(!cleaned.text.contains("Cleaned up"))
        #expect(FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "one")))
    }

    /// The host can still say a session runs after its process went (it hadn't reaped it yet): what counts is the
    /// process.
    @Test func aSessionWhoseProcessIsGoneIsntListedLive() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        #expect(call(lead, "sessions").text.contains("session-1: Worker: One — working"))
        // No process has this pid (macOS's go up to 99998).
        runtime.pids["session-1"] = 999_999
        let listed = call(lead, "sessions").text
        #expect(listed.contains("session-1: Worker: One — ended"), "\(listed)")
        #expect(!call(lead, "start_worker", ["task": "one"]).isError)
    }
}

/// The host's kill check (`LeadVault.Book.leads`): the lead ends its team's sessions, the ones that no longer hold a
/// role there too (a verifier a later audit replaced, a task retired while its session ran on).
struct ReplacedMembersTests {
    let root = "/tmp/replaced-members-repo"

    func grant(_ book: LeadVault.Book, _ role: LeadLaunch.Role, task: String?, session: String, by issuer: LeadVault.Caller) {
        guard case .grant(let grant) = book.answer(.issue(role: role, root: root, task: task, auditing: "c0ffee"), from: issuer) else {
            Issue.record("no grant for \(role)"); return
        }
        #expect(book.answer(.bind(grant: grant, root: root, session: session), from: issuer) == .ok)
    }

    @Test func theLeadEndsAVerifierALaterAuditReplaced() {
        let book = LeadVault.Book()
        grant(book, .lead, task: nil, session: "lead-1", by: .app)
        grant(book, .verifier, task: "t", session: "verifier-a", by: .session("lead-1"))
        // The lead is started again (another session), and audits the task again.
        grant(book, .lead, task: nil, session: "lead-2", by: .app)
        grant(book, .verifier, task: "t", session: "verifier-b", by: .session("lead-2"))
        grant(book, .worker, task: "t", session: "worker", by: .session("lead-2"))
        #expect(book.leads("verifier-b", caller: .session("lead-2")))
        #expect(book.leads("verifier-a", caller: .session("lead-2")))
        // It holds no role: it can't give a verdict, and its own tools are off.
        #expect(book.answer(.whoami(root: root), from: .session("verifier-a")) == .member(nil))
        // Only the lead: not the task's worker, not the old lead's session, not another project's lead.
        #expect(!book.leads("verifier-a", caller: .session("worker")))
        #expect(!book.leads("verifier-a", caller: .session("lead-1")))
        #expect(!book.leads("verifier-a", caller: .app))
        let other = LeadVault.Book()
        grant(other, .lead, task: nil, session: "lead-2", by: .app)
        #expect(!other.leads("verifier-a", caller: .session("lead-2")))
    }

    @Test func theLeadEndsARetiredTasksSessions() {
        let book = LeadVault.Book()
        grant(book, .lead, task: nil, session: "lead", by: .app)
        grant(book, .worker, task: "t", session: "worker", by: .session("lead"))
        #expect(book.answer(.retire(root: root, task: "t"), from: .session("lead")) == .ok)
        #expect(book.leads("worker", caller: .session("lead")))
        // A lead started after it is its lead too.
        grant(book, .lead, task: nil, session: "lead-2", by: .app)
        #expect(book.leads("worker", caller: .session("lead-2")))
    }

    @Test func formerMembersSurviveAHandover() {
        let book = LeadVault.Book()
        grant(book, .lead, task: nil, session: "lead", by: .app)
        grant(book, .verifier, task: "t", session: "verifier-a", by: .session("lead"))
        grant(book, .verifier, task: "t", session: "verifier-b", by: .session("lead"))
        let next = LeadVault.Book(restoring: book.serialized)
        #expect(next.leads("verifier-a", caller: .session("lead")))
    }
}
