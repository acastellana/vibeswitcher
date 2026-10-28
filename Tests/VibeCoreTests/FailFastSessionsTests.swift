import Darwin
import Foundation
import Testing
@testable import VibeCore

/// project-c, 2026-10-24: no session of app-security-rpc-trust had the vibeswitcher tools, the worker nor its four
/// verifiers, and nothing noticed: 3.7 M tokens went to verdicts that couldn't be filed, and the sessions held 4 of the
/// Mac's 6 slots. The host now keeps when each worker's and verifier's tool server first asked who it is; one that
/// hasn't `toolsWithin` after its start is told to the lead once, and ended. On fake sessions and a clock given.
extension LeadWitnessTests {
    static let bound = 1_792_800_000.0

    func noTools(_ board: LeadBoard, _ seen: [String: LeadWitness.Seen], after: TimeInterval) -> [(key: String, text: String)] {
        LeadWitness.events(board: board, seen: seen, now: Date(timeIntervalSince1970: Self.bound + after))
    }

    @Test func aVerifierWhoseToolsNeverConnectedIsToldOnceAndEnded() {
        var board = LeadBoard()
        board.tasks = [task("app-security-rpc-trust", .review, worker: "w1", verifier: "v1")]
        let quiet = LeadWitness.Seen(live: true, status: .working, activity: .working("Bash"), lastActivity: Self.bound + 200,
                                     started: Self.bound, boundAt: Self.bound)
        // Within its first minutes, nothing: a tool server answers in seconds, and this one may yet.
        #expect(noTools(board, ["v1": quiet], after: LeadWitness.toolsWithin - 1).isEmpty)
        #expect(LeadWitness.withoutTools(board: board, seen: ["v1": quiet], now: Date(timeIntervalSince1970: Self.bound + 60)).isEmpty)
        // Past them, it never got its tools: told under one key (so once), and ended.
        let late = noTools(board, ["v1": quiet], after: LeadWitness.toolsWithin)
        #expect(late.map(\.key) == ["v1|no-tools"])
        #expect(late.first?.text.contains("The verifier on app-security-rpc-trust never got its tools") == true, "\(late)")
        #expect(late.first?.text.contains("VibeSwitcher ends its session") == true)
        #expect(late.first?.text.contains("audit(app-security-rpc-trust) starts another verifier") == true)
        #expect(LeadWitness.withoutTools(board: board, seen: ["v1": quiet], now: Date(timeIntervalSince1970: Self.bound + 400)) == ["v1"])

        // Once it's ended, the same key (told already), never "ended without a verdict" besides.
        var ended = quiet
        ended.live = false
        ended.cause = "killed by SIGTERM"
        let after = noTools(board, ["v1": ended], after: 600)
        #expect(after.map(\.key) == ["v1|no-tools"], "\(after)")
        #expect(after.first?.text.contains("Its session has ended") == true)
        #expect(LeadWitness.withoutTools(board: board, seen: ["v1": ended], now: Date(timeIntervalSince1970: Self.bound + 600)).isEmpty)
        let told = LeadWitness.messages(board: board, seen: ["v1": ended], now: Date(timeIntervalSince1970: Self.bound + 600), told: { $0 == "v1|no-tools" })
        #expect(told.isEmpty, "\(told.map(\.text))")
    }

    @Test func aWorkerWhoseToolsNeverConnectedIsToldAndNotAlsoAsStalled() {
        var board = LeadBoard()
        board.tasks = [task("one", .running, worker: "w1")]
        // Between turns past idleAfter too: only the missing tools are told.
        let seen = ["w1": LeadWitness.Seen(live: true, status: .done, since: Date(timeIntervalSince1970: Self.bound + 30),
                                           activity: .idle(background: nil), lastActivity: Self.bound + 30, started: Self.bound, boundAt: Self.bound)]
        let events = noTools(board, seen, after: LeadStall.idleAfter + 60)
        #expect(events.map(\.key) == ["w1|no-tools"], "\(events.map(\.text))")
        #expect(events.first?.text.contains("The worker on one never got its tools") == true)
        #expect(events.first?.text.contains("start_worker(one) starts another") == true)
        #expect(LeadWitness.stalls(board: board, seen: seen, now: Date(timeIntervalSince1970: Self.bound + LeadStall.idleAfter + 60)).isEmpty)
    }

    @Test func toolsThatConnectedOrABindTimeNotKnownAreNoNews() {
        var board = LeadBoard()
        board.tasks = [task("one", .running, worker: "w1"), task("two", .review, worker: "w2", verifier: "v2")]
        let working = { (bound: Double?, tools: Double?, submitted: Double?) in
            LeadWitness.Seen(live: true, status: .working, activity: .working("Bash"), lastActivity: Self.bound + 3_500,
                             started: Self.bound, submittedAt: submitted, boundAt: bound, toolsAt: tools)
        }
        for seen in [working(Self.bound, Self.bound + 4, nil),  // its tools connected
                     working(nil, nil, nil),                      // an older host: nothing known either way
                     working(Self.bound, nil, Self.bound + 900)] { // a verdict came, so they did
            let all = ["w1": seen, "v2": seen]
            #expect(noTools(board, all, after: 3_600).isEmpty)
            #expect(LeadWitness.withoutTools(board: board, seen: all, now: Date(timeIntervalSince1970: Self.bound + 3_600)).isEmpty)
        }
        // A worker the lead stopped, or a task no longer at that step, isn't watched for it.
        var stopped = board
        stopped.tasks[0].stopped = "w1"
        stopped.tasks[1].status = .done
        let missing = working(Self.bound, nil, nil)
        #expect(LeadWitness.withoutTools(board: stopped, seen: ["w1": missing, "v2": missing], now: Date(timeIntervalSince1970: Self.bound + 3_600)).isEmpty)
    }
}

/// The host keeps when a role was bound to its session, and when that session's tool server first asked who it is.
struct ToolsConnectedTests {
    let root = "/Users/you/dev/tools-connected"

    @Test func theRosterSaysWhenARolesToolsConnected() throws {
        let book = LeadVault.Book()
        guard case .grant(let lead) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else { Issue.record("no lead"); return }
        #expect(book.answer(.bind(grant: lead, root: root, session: "lead"), from: .app) == .ok)
        guard case .grant(let grant) = book.answer(.issue(role: .verifier, root: root, task: "t", auditing: "c0ffee"), from: .session("lead")) else {
            Issue.record("no verifier"); return
        }
        let before = Date().timeIntervalSince1970
        #expect(book.answer(.bind(grant: grant, root: root, session: "verifier"), from: .session("lead")) == .ok)
        func entry() throws -> LeadVault.RosterEntry {
            guard case .roster(let entries) = book.answer(.roster(root: root), from: .session("lead")) else { throw LeadVault.Refused("no roster") }
            return try #require(entries.first { $0.session == "verifier" })
        }
        let bound = try #require(try entry().boundAt)
        #expect(bound >= before)
        #expect(try entry().toolsAt == nil)
        // Its tool server asks who it is: that's its tools connecting, kept the first time only.
        guard case .member(let member?) = book.answer(.whoami(root: root), from: .session("verifier")) else { Issue.record("no member"); return }
        #expect(member.role == .verifier)
        let tools = try #require(try entry().toolsAt)
        #expect(tools >= bound)
        _ = book.answer(.whoami(root: root), from: .session("verifier"))
        #expect(try entry().toolsAt == tools)
        // Kept across a handover to a new host.
        let next = LeadVault.Book(restoring: book.serialized)
        guard case .roster(let carried) = next.answer(.roster(root: root), from: .session("lead")) else { Issue.record("no roster"); return }
        #expect(carried.first { $0.session == "verifier" }?.toolsAt == tools)
    }
}

extension LeadToolsetTests {
    /// project-c: four verifiers in a row without tools, each audit started as if the last had simply ended. audit and
    /// start_worker now name the earlier session that never got its tools before they start another.
    @Test func auditNamesTheEarlierVerifierThatNeverGotItsTools() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        // session-2: its tool server never ran, and its session has ended.
        #expect(!call(lead, "audit", ["task": "one"]).isError)
        runtime.pids["session-2"] = 999_999
        let again = call(lead, "audit", ["task": "one"])
        #expect(!again.isError, "\(again.text)")
        #expect(again.text.hasPrefix("The earlier verifier on one (session session-"), "\(again.text)")
        #expect(again.text.contains("never got its tools"))
        // session-3's tool server asked who it is (its tools connected): ended, it's not named.
        _ = try seat("verify-one", runtime)
        runtime.pids["session-3"] = 999_999
        let third = call(lead, "audit", ["task": "one"])
        #expect(!third.isError, "\(third.text)")
        #expect(!third.text.contains("never got"), "\(third.text)")
    }

    @Test func startWorkerNamesTheEarlierWorkerThatNeverGotItsTools() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        runtime.pids["session-1"] = 999_999
        let again = call(lead, "start_worker", ["task": "one"])
        #expect(!again.isError, "\(again.text)")
        #expect(again.text.hasPrefix("The earlier worker on one (session session-"), "\(again.text)")
        // One the lead stopped itself (before its tools had a moment, say) isn't named.
        #expect(!call(lead, "stop_worker", ["task": "one"]).isError)
        let third = call(lead, "start_worker", ["task": "one"])
        #expect(!third.isError, "\(third.text)")
        #expect(!third.text.contains("never got"), "\(third.text)")
    }

    /// films, 2026-10-18/19: cleanup failed five times and six idle sessions held Mac slots for about 20 h, until
    /// another lead killed them by pid. When the host doesn't end a session, cleanup ends its processes itself: the
    /// user's carrying its `VIBESWITCHER_SESSION` id (decision 2026-10-23 02:44), here a `sleep` this test started.
    @Test func cleanupEndsASessionTheHostDidntEnd() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.stopWait = 2
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        agent.arguments = ["300"]
        try agent.run()
        defer { if agent.isRunning { agent.terminate() } }
        let found = try #require(SessionStrays.descendants(of: getpid()).first { $0.pid == agent.processIdentifier })
        runtime.pids["session-1"] = agent.processIdentifier
        runtime.refusals["session-1"] = Self.refusal
        lead.sessionProcesses = { $0 == "session-1" ? [found] : [] }
        let cleaned = call(lead, "cleanup", ["task": "one", "force": true])
        #expect(!cleaned.isError, "\(cleaned.text)")
        #expect(cleaned.text.contains("ended pid \(agent.processIdentifier) (Worker: One) itself, after the host didn't (\(Self.refusal))"), "\(cleaned.text)")
        #expect(!SessionStrays.isRunning(found))
        #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "one")))
    }

    /// What still runs is named, by pid and command, never a bare refusal.
    @Test func cleanupNamesWhatStillRunsByPidAndCommand() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.stopWait = 0.3
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        // Its agent carries no session id cleanup can find (none of its processes do).
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        agent.arguments = ["301"]
        try agent.run()
        defer { agent.terminate() }
        runtime.pids["session-1"] = agent.processIdentifier
        runtime.refusals["session-1"] = Self.refusal
        lead.sessionProcesses = { _ in [] }
        let cleaned = call(lead, "cleanup", ["task": "one", "force": true])
        #expect(cleaned.isError)
        #expect(cleaned.text.contains("couldn't end pid \(agent.processIdentifier) (Worker: One): \(Self.refusal)"), "\(cleaned.text)")
        #expect(cleaned.text.contains("still running: pid \(agent.processIdentifier) (\(LeadToolset.command(of: agent.processIdentifier)))"), "\(cleaned.text)")
        #expect(LeadToolset.command(of: agent.processIdentifier).contains("sleep"))
        #expect(agent.isRunning)
        #expect(FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "one")))
    }

    /// project-c, 2026-10-21: cleanup(force) answered "Cleaned up", and the lead told the user three tasks were abandoned;
    /// they stayed failed (they never had a worker, LeadTask.isAbandoned). cleanup now says the state it leaves, as
    /// status and the board show it.
    @Test func cleanupSaysTheStateItLeavesTheTaskIn() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two", "Three", "Four"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        _ = call(lead, "start_worker", ["task": "one"])
        _ = call(lead, "start_worker", ["task": "two"])
        #expect(!call(lead, "stop_worker", ["task": "two"]).isError)
        #expect(!call(lead, "update_task", ["task": "two", "status": "abandoned", "reason": "nothing will carry it"]).isError)
        #expect(!call(lead, "update_task", ["task": "three", "status": "failed"]).isError)
        let status = { (slug: String) in BoardStore(root: root).load().task(slug).map(LeadToolset.shownState) }

        let one = call(lead, "cleanup", ["task": "one", "force": true]).text
        #expect(one.hasSuffix("It was running: now abandoned."), "\(one)")
        #expect(status("one") == "abandoned")
        let two = call(lead, "cleanup", ["task": "two"]).text
        #expect(two.hasSuffix("It stays abandoned."), "\(two)")
        let three = call(lead, "cleanup", ["task": "three", "force": true]).text
        #expect(three.contains("It stays failed. It never had a worker"), "\(three)")
        #expect(status("three") == "failed")
        #expect(call(lead, "board").text.contains("three [failed]"))
        let four = call(lead, "cleanup", ["task": "four", "force": true]).text
        #expect(four.contains("It was planned: now failed."), "\(four)")
    }
}
