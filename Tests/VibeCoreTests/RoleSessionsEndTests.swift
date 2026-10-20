import Foundation
import Testing
@testable import VibeCore

/// Role sessions end themselves when their job is done (2026-10-20): two genswap verifiers ran on idle for 14.7 h and
/// 20.6 h, their tasks long finished, because cleanup ended only a task's newest session. The vault's roster names
/// every worker and verifier a team had (`LeadVault.Request.roster`), the app ends those of finished tasks from it
/// (`LeadTeams.finishedRoles`), a submitted verifier's end is expected (`LeadWitness.Seen.submittedAt`), and what still
/// runs an hour on is named (`LeadTeams.stranded`, `LeadWitness.strandedText`, the sessions tool).
struct RoleSessionsEndTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    let root = "/Users/you/dev/role-sessions-end-repo"
    let other = "/Users/you/dev/role-sessions-end-other"

    /// A grant for `role` on `task` bound to `session`, issued by the app (a lead) or `lead`.
    @discardableResult
    func bind(_ role: LeadLaunch.Role, task: String?, session: String, root: String, lead: String? = nil,
              finder: LeadVault.Finder? = nil) throws -> String {
        let issuer = lead.map { lead in book.vault(folder: vault.folder, as: { .session(lead) }) } ?? vault
        let grant = try issuer.issue(role: role, root: root, task: task, auditing: role == .verifier ? "c0ffee" : nil, finder: finder)
        try issuer.bind(grant, root: root, session: session)
        return grant
    }

    func asSession(_ session: String) -> LeadVault { book.vault(folder: vault.folder, as: { .session(session) }) }

    // MARK: The vault's roster

    /// Every worker and verifier, the replaced verifiers too (with their task), never a lead; who submitted, when.
    @Test func theRosterNamesEveryWorkerAndVerifierOfATaskNotOnlyTheNewest() throws {
        try bind(.lead, task: nil, session: "lead", root: root)
        try bind(.worker, task: "t", session: "w1", root: root, lead: "lead")
        try bind(.verifier, task: "t", session: "v1", root: root, lead: "lead")
        // A later audit replaces v1, and that one submits.
        try bind(.verifier, task: "t", session: "v2", root: root, lead: "lead")
        _ = try asSession("v2").submitVerdict(root: root, completion: .complete, integrity: .clean, summary: "ok")
        // Another project's team.
        try bind(.lead, task: nil, session: "other-lead", root: other)
        try bind(.worker, task: "x", session: "ow", root: other, lead: "other-lead")

        let roster = try vault.roster()
        #expect(Set(roster.map(\.session)) == ["w1", "v1", "v2", "ow"])
        #expect(!roster.contains { $0.role == .lead })
        let v1 = try #require(roster.first { $0.session == "v1" })
        #expect(v1.role == .verifier && v1.task == "t" && !v1.holds && v1.submittedAt == nil)
        let v2 = try #require(roster.first { $0.session == "v2" })
        #expect(v2.holds && v2.submittedAt != nil)
        #expect(roster.first { $0.session == "ow" }?.root == LeadVault.canonical(other))

        // A lead reads its own team's only; a worker, or anyone else, none; every team's is the app's alone.
        #expect(Set(try asSession("lead").roster(root: root).map(\.session)) == ["w1", "v1", "v2"])
        #expect(throws: LeadVault.Refused.self) { try asSession("lead").roster(root: other) }
        #expect(throws: LeadVault.Refused.self) { try asSession("lead").roster() }
        #expect(throws: LeadVault.Refused.self) { try asSession("w1").roster(root: root) }

        // Retired (cleanup): every one is former now, each with its task.
        try asSession("lead").retire(root: root, task: "t")
        let retired = try vault.roster(root: root)
        #expect(Set(retired.map(\.session)) == ["w1", "v1", "v2"] && retired.allSatisfy { !$0.holds && $0.task == "t" })
        #expect(retired.first { $0.session == "w1" }?.role == .worker)
    }

    /// Only a stored verdict or ballot is recorded as submitted: a refused one isn't.
    @Test func onlyAStoredVerdictOrBallotCountsAsSubmitted() throws {
        try bind(.lead, task: nil, session: "lead", root: root)
        try bind(.worker, task: "t", session: "w1", root: root, lead: "lead")
        #expect(throws: LeadVault.Refused.self) {
            try asSession("w1").submitVerdict(root: root, completion: .complete, integrity: .clean, summary: "forged")
        }
        let panel = { (index: Int) in LeadVault.Finder(panel: "p", index: index, size: 2, focus: "bugs", nitCap: 5) }
        try bind(.verifier, task: "t", session: "f1", root: root, lead: "lead", finder: panel(1))
        try bind(.verifier, task: "t", session: "f2", root: root, lead: "lead", finder: panel(2))
        let ballot = try asSession("f1").submit(root: root, completion: .complete, integrity: .clean, summary: "fine")
        #expect(ballot.verdict == nil && ballot.cast == 1)
        let submitted = book.submittedSessions()
        #expect(Set(submitted.keys) == ["f1"])
        _ = try asSession("f2").submit(root: root, completion: .complete, integrity: .clean, summary: "fine")
        #expect(Set(book.submittedSessions().keys) == ["f1", "f2"])
        #expect(try vault.roster(root: root).filter { $0.submittedAt != nil }.map(\.session).sorted() == ["f1", "f2"])
    }

    /// A vault kept by an older build: its former sessions have no role or task recorded (read back as they were).
    @Test func anOlderVaultsFormerSessionsHaveNoTask() throws {
        try bind(.lead, task: nil, session: "lead", root: root)
        try bind(.verifier, task: "t", session: "v1", root: root, lead: "lead")
        try bind(.verifier, task: "t", session: "v2", root: root, lead: "lead")
        var json = try #require(try JSONSerialization.jsonObject(with: book.serialized) as? [String: Any])
        var teams = try #require(json["teams"] as? [String: [String: Any]])
        for key in teams.keys { teams[key]?["formerRoles"] = nil }
        json["teams"] = teams
        let older = LeadVault.Book(restoring: try JSONSerialization.data(withJSONObject: json))
        let roster = try older.vault(folder: vault.folder, as: { .app }).roster()
        let v1 = try #require(roster.first { $0.session == "v1" })
        #expect(v1.task == nil && !v1.holds)
    }

    // MARK: Which sessions the app ends

    static let now = Date(timeIntervalSince1970: 1_792_480_000)

    func hosted(_ id: UUID = UUID(), label: String, cwd: String, live: Bool = true) -> HostSession {
        HostSession(id: id, tty: "ttys0\(abs(id.hashValue) % 90)", childPID: 4000 + Int32(abs(id.hashValue) % 900), cwd: cwd, command: "claude",
                    label: label, agent: "claude", title: "", startedAt: Self.now - 80_000, cols: 80, rows: 24,
                    exit: live ? nil : HostSession.Exit(status: 129, at: Self.now - 100))
    }

    func task(_ slug: String, _ status: LeadTask.Status, worktree: String? = "kept", since: Double? = nil) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""), status: status)
        task.worktree = worktree
        task.since = since ?? Self.now.timeIntervalSince1970 - 53_000
        return task
    }

    /// The roster filter: every live worker and verifier of a merged, folded, abandoned or cleaned-up task, the
    /// replaced verifiers too; never the lead (this project's or another's), the user's own sessions (no role in the
    /// vault, even one in a worktree labelled as a worker), an ended session, or a task still under way.
    @Test func theAppEndsOnlyRoleSessionsOfFinishedTasksFromTheRoster() {
        let canonical = LeadVault.canonical(root)
        let tree = { (slug: String) in "\(self.root)/.vibeswitcher/worktrees/\(slug)" }
        let ids = (0..<14).map { _ in UUID() }
        let sessions = [
            hosted(ids[0], label: "Lead · repo", cwd: root),
            hosted(ids[1], label: "Worker: Merged", cwd: tree("merged")),
            hosted(ids[2], label: "Verifier: Merged", cwd: tree("merged")),
            hosted(ids[3], label: "Verifier: Merged", cwd: tree("merged")),
            hosted(ids[4], label: "Verifier: Folded", cwd: tree("folded")),
            hosted(ids[5], label: "Worker: Abandoned", cwd: tree("abandoned")),
            hosted(ids[6], label: "Worker: Cleaned", cwd: tree("cleaned")),
            hosted(ids[7], label: "Worker: Running", cwd: tree("running")),
            hosted(ids[8], label: "Verifier: Review", cwd: tree("review")),
            hosted(ids[9], label: "Worker: Merged", cwd: tree("merged")),   // the user's own: no role in the vault
            hosted(ids[10], label: "Shell", cwd: tree("merged")),           // the user's own
            hosted(ids[11], label: "Lead · other", cwd: other),             // another project's lead
            hosted(ids[12], label: "Verifier: Merged", cwd: tree("merged"), live: false),
            hosted(ids[13], label: "Verifier: Merged", cwd: tree("merged")),  // a former one an older vault kept without its task
        ]
        let entry = { (index: Int, role: LeadLaunch.Role, task: String?, holds: Bool) in
            LeadVault.RosterEntry(root: canonical, session: ids[index].uuidString, role: role, task: task, holds: holds)
        }
        // A roster that (wrongly) names the leads too: they're never ended.
        let roster = [
            entry(0, .lead, nil, true), entry(1, .worker, "merged", true), entry(2, .verifier, "merged", false), entry(3, .verifier, "merged", true),
            entry(4, .verifier, "folded", true), entry(5, .worker, "abandoned", true), entry(6, .worker, "cleaned", false),
            entry(7, .worker, "running", true), entry(8, .verifier, "review", true), entry(12, .verifier, "merged", false),
            entry(13, .worker, nil, false),
            LeadVault.RosterEntry(root: LeadVault.canonical(other), session: ids[11].uuidString, role: .worker, task: "merged", holds: true),
        ]
        var board = LeadBoard()
        board.leadSession = ids[0].uuidString
        board.tasks = [task("merged", .done, worktree: nil), task("folded", .folded), task("abandoned", .abandoned),
                       task("cleaned", .failed, worktree: nil), task("running", .running), task("review", .review)]
        var otherBoard = LeadBoard()
        otherBoard.tasks = [task("merged", .done, worktree: nil)]
        let finished = LeadTeams.finishedRoles(roster, hosted: sessions, boards: [canonical: board, LeadVault.canonical(other): otherBoard])
        #expect(Set(finished.map(\.session.id)) == Set([1, 2, 3, 4, 5, 6, 13].map { ids[$0] }))
        #expect(finished.first { $0.session.id == ids[13] }?.role == .verifier)
        // Nothing without the board (a project whose board can't be read), nor from an empty roster.
        #expect(LeadTeams.finishedRoles(roster, hosted: sessions, boards: [:]).isEmpty)
        #expect(LeadTeams.finishedRoles([], hosted: sessions, boards: [canonical: board]).isEmpty)
    }

    // MARK: Stranded

    @Test func strandedSessionsAreNamedInOneMessageALineEach() throws {
        let canonical = LeadVault.canonical("/Users/you/dev/genswap")
        let tree = { (slug: String) in "/Users/you/dev/genswap/.vibeswitcher/worktrees/\(slug)" }
        let a = hosted(label: "Verifier: Contract plan 8", cwd: tree("contract-plan-task-8"))
        let b = hosted(label: "Verifier: Publish", cwd: tree("publish-the-new-shell"))
        let c = hosted(label: "Worker: Fresh", cwd: tree("fresh"))
        var board = LeadBoard()
        board.tasks = [task("contract-plan-task-8", .done, worktree: nil), task("publish-the-new-shell", .done, worktree: nil), task("fresh", .done, worktree: nil)]
        let roster = [(a, "contract-plan-task-8"), (b, "publish-the-new-shell"), (c, "fresh")].map {
            LeadVault.RosterEntry(root: canonical, session: $0.0.id.uuidString, role: $0.0.label.hasPrefix("Worker") ? .worker : .verifier, task: $0.1, holds: false)
        }
        let finished = LeadTeams.finishedRoles(roster, hosted: [a, b, c], boards: [canonical: board])
        let now = Self.now.timeIntervalSince1970
        let idle: [UUID: Double] = [a.id: now - 52_920, b.id: now - 74_160, c.id: now - 1_800]
        let stranded = LeadTeams.stranded(finished, idleSince: { idle[$0.id] }, agent: { ($0.childPID, 412_000_000) }, now: Self.now)
        #expect(stranded.map(\.task) == ["contract-plan-task-8", "publish-the-new-shell"])
        let text = try #require(LeadWitness.strandedText(stranded, now: Self.now))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 4, "\(text)")
        #expect(lines[1] == "- The verifier on contract-plan-task-8 (genswap): idle 14.7 h, pid \(a.childPID), 412 MB, task finished 14.7 h ago")
        #expect(lines[2].hasPrefix("- The verifier on publish-the-new-shell (genswap): idle 20.6 h, pid \(b.childPID), 412 MB"))
        #expect(lines[0].hasPrefix("2 role sessions still run"))
        // Working, or idle less than an hour: not stranded; none, no message.
        #expect(LeadTeams.stranded(finished, idleSince: { _ in nil }, agent: { _ in (nil, nil) }, now: Self.now).isEmpty)
        #expect(LeadWitness.strandedText([]) == nil)
    }

    // MARK: The witness

    /// The-witness-never's rule kept: a verifier the roster says submitted, ended by the host or sitting at its
    /// prompt, is no news, whether the board shows the verdict yet or not.
    @Test func aSubmittedVerifiersEndIsExpected() {
        let t0 = Self.now
        var review = task("t", .review)
        review.worker = "w1"
        review.verifier = "v1"
        var board = LeadBoard()
        board.tasks = [review]
        let worker = LeadWitness.Seen(live: true, status: .working, since: t0, activity: .working("Bash"), lastActivity: t0.timeIntervalSince1970, started: t0.timeIntervalSince1970 - 3_600)
        let submitted = t0.timeIntervalSince1970 - 30
        for verifier in [LeadWitness.Seen(live: false, exit: 129, cause: "hung up by vibeswitcher-host", started: submitted - 600, submittedAt: submitted),
                         LeadWitness.Seen(live: true, status: .done, since: t0 - 200, activity: .idle(background: nil), lastActivity: submitted,
                                          started: submitted - 600, submittedAt: submitted)] {
            let told = LeadWitness.messages(board: board, seen: ["w1": worker, "v1": verifier], now: t0 + 600, told: { _ in false })
            #expect(told.isEmpty, "\(told.map(\.text))")
        }
        // Without the roster's word, an end before the verdict reached the board is still told.
        let ended = LeadWitness.Seen(live: false, exit: 1, started: submitted - 600)
        #expect(LeadWitness.events(board: board, seen: ["w1": worker, "v1": ended], now: t0).contains { $0.text.contains("ended without a verdict") })
    }

    // MARK: The lead's tools

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// After submit_audit the host ends the verifier: its transcript is read as before, by read_session(task,
    /// verifier); and the sessions tool marks a worker or verifier of a task finished over an hour ago 'stranded'.
    @Test func readSessionReadsAnEndedVerifierAndTheSessionsToolMarksStrandedOnes() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b", "acceptance": ["b"], "boundaries": ["b"]]).isError)
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        #expect(!(try seat("worker-add-b", runtime)).call("report", ["status": "done", "summary": "added b"]).isError)
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let verifier = try launched("verify-add-b", runtime).session
        let submitted = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "incomplete", "integrity": "clean", "summary": "b is wrong"])
        #expect(!submitted.isError, "\(submitted.text)")
        #expect(try vault.roster(root: root).first { $0.session == verifier }?.submittedAt != nil)

        // The host ends it; its transcript stays where Claude wrote it.
        runtime.killed.append(verifier)
        let transcript = URL(fileURLWithPath: VibePaths.home).appendingPathComponent(".claude/projects/role-sessions-end/\(UUID().uuidString).jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Recorded.uxTranscript.write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        runtime.transcripts[verifier] = transcript.path
        let read = lead.call("read_session", ["task": "add-b", "who": "verifier"])
        #expect(!read.isError && !read.text.contains("No conversation yet"), "\(read.text)")

        // Finished over an hour ago with its worker still running, not working: stranded. Under an hour: not yet.
        let worker = try launched("worker-add-b", runtime).session
        runtime.statuses[worker] = "finished its turn"
        for (ago, marked) in [(7_200.0, true), (600, false)] {
            // The status first (its change is stamped now), then when it took it.
            try BoardStore(root: root).update { board in
                guard let index = board.taskIndex("add-b") else { return }
                board.tasks[index].status = .abandoned
            }
            try BoardStore(root: root).update { board in
                guard let index = board.taskIndex("add-b") else { return }
                board.tasks[index].since = Date().timeIntervalSince1970 - ago
            }
            let line = try #require(lead.call("sessions", [:]).text.split(separator: "\n").first { $0.contains(worker) })
            #expect(line.contains("stranded (task finished 2.0 h ago)") == marked, "\(line)")
            // Only a role session's line, never the lead's.
            #expect(!lead.call("sessions", [:]).text.split(separator: "\n").contains { $0.contains("Lead") && $0.contains("stranded") })
        }
        let idle = LeadSessionInfo(id: worker, cwd: worktree, label: "Worker: Add b", live: true, status: "finished its turn", tty: nil)
        var board = BoardStore(root: root).load()
        board.tasks[try #require(board.taskIndex("add-b"))].since = Date().timeIntervalSince1970 - 7_200
        #expect(LeadToolset.strandedSince(idle, root: root, board: board, now: Date().timeIntervalSince1970) != nil)
        var working = idle
        working.status = "working: Bash"
        #expect(LeadToolset.strandedSince(working, root: root, board: board, now: Date().timeIntervalSince1970) == nil)
    }
}
