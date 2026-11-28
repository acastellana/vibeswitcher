import Foundation
import Testing
@testable import VibeCore

/// The commit under `ref` when `ref`'s own commit is the lead's records commit (`LeadRecords`: its subject, and only
/// docs/lead's two logs changed), else `ref`'s: what merged, whether or not the records went on top of it.
func underRecords(_ ref: String, in root: String) -> String {
    let subject = Git.run(["log", "-1", "--format=%s", ref], in: root).output
    let files = Set(Git.run(["diff-tree", "--no-commit-id", "--name-only", "-r", ref], in: root).output.split(separator: "\n").map(String.init))
    let records = LeadRecords.isSubject(subject) && !files.isEmpty && files.isSubset(of: ["docs/lead/decisions.md", "docs/lead/progress.md"])
    return Git.run(["rev-parse", records ? "\(ref)~1" : ref], in: root).output
}

/// Whether `ref` is `since` or holds only the lead's records commits on top of it (`LeadRecords.subject`, touching
/// only the records): what a merge that didn't land leaves, the records it committed before its rebase
/// (`LeadRecords.commitBeforeMerge`) aside.
func onlyRecords(on ref: String, since: String, in root: String) -> Bool {
    guard Git.run(["merge-base", "--is-ancestor", since, ref], in: root).ok else { return false }
    let commits = Git.run(["rev-list", "\(since)..\(ref)"], in: root).output.split(separator: "\n").map(String.init)
    return commits.allSatisfy { commit in
        let files = Git.run(["diff-tree", "--no-commit-id", "--name-only", "-r", commit], in: root).output.split(separator: "\n")
        return LeadRecords.isSubject(Git.run(["log", "-1", "--format=%s", commit], in: root).output)
            && files.allSatisfy { LeadRecords.paths("docs/lead").contains(String($0)) }
    }
}

/// The lead's decision and progress logs in the repository (`records_dir`), committed to the base branch by the
/// lead's tool server: only those files, batched, around merges, never disturbing the user's uncommitted work. Every
/// repository here is a temporary one.
@Suite(.serialized)
struct LeadRecordsTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let logs = ["docs/lead/decisions.md", "docs/lead/progress.md"]

    func repo() throws -> String {
        let url = temp.url("records")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        for name in ["a.txt", "c.txt"] { try "one\n".write(toFile: root + "/" + name, atomically: true, encoding: .utf8) }
        Git.run(["add", "a.txt", "c.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func head(_ ref: String, _ root: String) -> String { Git.run(["rev-parse", ref], in: root).output }

    func files(of commit: String, _ root: String) -> [String] {
        Git.run(["diff-tree", "--no-commit-id", "--name-only", "-r", commit], in: root).output.split(separator: "\n").map(String.init).sorted()
    }

    func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    func workflow(_ root: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try text.write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
    }

    // MARK: records_dir

    @Test func theWorkflowSaysWhereTheRecordsGo() throws {
        #expect(LeadWorkflow.parse("---\nmax_workers: 2\n---").recordsDir == "docs/lead")
        #expect(LeadWorkflow.parse("").recordsDir == "docs/lead")
        #expect(LeadWorkflow.parse("---\nrecords_dir:\n---").recordsDir == nil)
        #expect(LeadWorkflow.parse("---\nrecords_dir: notes/lead/\n---").recordsDir == "notes/lead")
        for outside in ["/etc", "../up", "docs/../../up", ".git/x", ".vibeswitcher/logs", "~/lead"] {
            #expect(LeadWorkflow.parse("---\nrecords_dir: \(outside)\n---").recordsDir == nil, "\(outside)")
        }
        #expect(LeadWorkflow.template.contains("\nrecords_dir: docs/lead\n"))
        #expect(LeadWorkflow.parse(LeadWorkflow.template).recordsDir == "docs/lead")

        let root = try repo()
        let store = BoardStore(root: root)
        #expect(store.recordPath("decisions.md") == root + "/docs/lead/decisions.md")
        let lead = try lead(root, FakeRuntime())
        let set = lead.call("configure", ["records_dir": "notes/lead"])
        #expect(!set.isError, "\(set.text)")
        #expect(store.recordsDir == "notes/lead")
        #expect(store.recordPath("progress.md") == root + "/notes/lead/progress.md")
        #expect(lead.call("configure", ["records_dir": "../elsewhere"]).isError)
        #expect(store.recordsDir == "notes/lead")
        // Empty: kept in .vibeswitcher, as before; nothing is committed.
        #expect(!lead.call("configure", ["records_dir": ""]).isError)
        #expect(store.recordsDir == nil)
        #expect(store.recordPath("decisions.md") == root + "/.vibeswitcher/decisions.md")
        let before = head("main", root)
        #expect(!lead.call("record_decision", ["decision": "Keep it local", "why": "the user said so"]).isError)
        #expect(read(root + "/.vibeswitcher/decisions.md").contains("Keep it local"))
        #expect(lead.records.flush(base: "main") == .local)
        #expect(head("main", root) == before)
    }

    @Test func workersMayNotEditTheRecords() throws {
        let worker = LeadLaunch.deny(.worker, base: "main", records: "docs/lead")
        for rule in ["Edit(docs/lead/**)", "Write(docs/lead/**)", "Bash(git add docs/lead*)"] { #expect(worker.contains(rule), "\(rule)") }
        #expect(!LeadLaunch.deny(.worker, base: "main").contains { $0.contains("docs/lead") })
        // A worker the lead starts gets them, from the workflow.
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "Add b", "goal": "g", "acceptance": ["a"]])
        let started = lead.call("start_worker", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        let settings = String(decoding: try LaunchArguments.data("--settings", in: LaunchArguments.command("worker-add-b", runtime)), as: UTF8.self)
        #expect(settings.contains("Edit(docs\\/lead\\/**)") || settings.contains("Edit(docs/lead/**)"))
    }

    // MARK: The commit

    @Test func aDirtyCheckoutStaysExactlyAsItWas() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        // The user's work in progress: a staged change, a staged and further modified file, an unstaged change, a
        // staged new file and an untracked one.
        try "staged\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        try "staged c\n".write(toFile: root + "/c.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "c.txt"], in: root)
        try "staged c, then more\n".write(toFile: root + "/c.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: root + "/new.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "new.txt"], in: root)
        try "mine\n".write(toFile: root + "/untracked.txt", atomically: true, encoding: .utf8)
        let state = {
            (staged: Git.run(["diff", "--cached", "--", ".", ":!docs"], in: root).output,
             unstaged: Git.run(["diff", "--", ".", ":!docs"], in: root).output,
             index: Git.run(["ls-files", "-s", "--", ".", ":!docs"], in: root).output,
             status: Git.run(["status", "--porcelain", "--untracked-files=all", "--", ".", ":!docs"], in: root).output,
             files: ["a.txt", "c.txt", "new.txt", "untracked.txt"].map { self.read(root + "/" + $0) })
        }
        let before = state()
        let parent = head("main", root)

        #expect(!lead.call("record_decision", ["decision": "Use SQLite", "why": "no server to run"]).isError)
        #expect(!lead.call("post_update", ["title": "Plan", "body": "Two tasks."]).isError)
        guard case .committed(let commit) = lead.records.flush(base: "main") else { Issue.record("not committed"); return }

        #expect(head("main", root) == commit)
        #expect(head("\(commit)^@", root) == parent)
        #expect(files(of: commit, root) == Self.logs)
        // Named by what it adds, a count of each kind (`LeadRecords.subject(adding:)`).
        #expect(Git.run(["log", "-1", "--format=%s", commit], in: root).output == "Lead: 1 decision, 1 progress line")
        // No trailer of any kind (a workflow may refuse them: project-c's regression_command does).
        let body = Git.run(["log", "-1", "--format=%B", commit], in: root).output
        #expect(Git.run(["log", "-1", "--format=%(trailers)", commit], in: root).output.isEmpty, "\(body)")
        #expect(!body.lowercased().contains("co-authored-by") && body == LeadRecords.message("docs/lead", adding: [.decisions: 1, .progress: 1]), "\(body)")
        #expect(Git.run(["show", "\(commit):docs/lead/decisions.md"], in: root).output.contains("Use SQLite"))
        #expect(Git.run(["show", "\(commit):docs/lead/progress.md"], in: root).output.contains("Update: Plan"))
        // None of the user's changes went in, and every one is where it was.
        #expect(Git.run(["show", "\(commit):a.txt"], in: root).output == "one")
        let after = state()
        #expect(after.staged == before.staged)
        #expect(after.unstaged == before.unstaged)
        #expect(after.index == before.index)
        #expect(after.status == before.status)
        #expect(after.files == before.files)
        // The logs are clean in the checkout: committed, in the index as in the commit.
        #expect(Git.run(["status", "--porcelain", "--", "docs"], in: root).output.isEmpty)
        // The lead's own move: the next merge's check takes it.
        #expect(try vault.head(root: root, branch: "main") == commit)
        // Nothing new: nothing committed.
        #expect(lead.records.flush(base: "main") == .unchanged)
        #expect(head("main", root) == commit)
    }

    /// 2026-11-26: 11 records commits in a row on main with nothing between them, about 120 of the 140 commits that
    /// day: the timer (`tick`, every 5 minutes) committed whatever the lead had written since its last pass, with no
    /// merge to need them. A day's record-writing calls with no merge between them, the timer passing between each as
    /// it does, commit nothing now; the merge that follows commits all of them first, as one commit named by what it
    /// adds, and nothing after it.
    @Test func aDaysRecordsMakeOneCommitAtTheMergeThatNeedsThem() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let first = head("main", root)
        var now = Date()
        // The timer's pass, 5.5 minutes after the last (its 30-second ticks past the 5-minute interval).
        func pass() {
            now = now.addingTimeInterval(330)
            lead.records.tick(base: "main", now: now)
        }
        for number in 1...3 {
            #expect(!lead.call("record_decision", ["decision": "Decision \(number)", "why": "w"]).isError)
            pass()
            #expect(!lead.call("post_update", ["title": "Update \(number)", "body": "b"]).isError)
            pass()
        }
        #expect(!lead.call("record_incident", ["what": "A hang", "evidence": "the log"]).isError)
        pass()
        // A task's whole round: planned, a worker started, its report, an audit and its verdict, the timer between.
        _ = lead.call("add_task", ["title": "add-b", "goal": "g", "acceptance": ["a"]])
        pass()
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        pass()
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "add-b\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b.txt"], in: worktree)
        _ = try seat("worker-add-b", runtime).call("report", doneReport("added"))
        pass()
        _ = lead.call("audit", ["task": "add-b"])
        pass()
        _ = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked"])
        pass()
        // All of it on disk, none of it committed.
        #expect(Git.run(["rev-list", "--count", "\(first)..main"], in: root).output == "0")
        #expect(read(root + "/docs/lead/decisions.md").contains("Decision 3") && read(root + "/docs/lead/progress.md").contains("Started a worker on add-b"))
        #expect(!Git.run(["status", "--porcelain", "--", "docs/lead"], in: root).output.isEmpty)
        #expect(lead.call("status", [:]).text.contains("Records:") == false)

        // The merge: one records commit before its code, and nothing after it.
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        let landed = Git.run(["log", "--reverse", "--format=%s", "\(first)..main"], in: root).output.split(separator: "\n").map(String.init)
        #expect(landed.count == 2, "\(landed)")
        let records = try #require(BoardStore(root: root).load().task("add-b")?.merged?.onto)
        #expect(head("\(records)~1", root) == first)
        #expect(head("main", root) == BoardStore(root: root).load().task("add-b")?.merged?.commit)
        let subject = Git.run(["log", "-1", "--format=%s", records], in: root).output
        #expect(LeadRecords.isSubject(subject) && subject.hasPrefix("Lead: 3 decisions, ") && subject.hasSuffix(" progress lines, 1 incident"), "\(subject)")
        let committed = Git.run(["show", "\(records):docs/lead/decisions.md"], in: root).output
        for number in 1...3 { #expect(committed.contains("Decision \(number)")) }
        #expect(Git.run(["show", "\(records):docs/lead/incidents.md"], in: root).output.contains("A hang"))
        // The merge's own lines and the cleanup's wait on disk too, the timer passing.
        _ = lead.call("cleanup", ["task": "add-b"])
        pass()
        pass()
        #expect(Git.run(["rev-list", "--count", "\(first)..main"], in: root).output == "2")
        #expect(read(root + "/docs/lead/progress.md").contains("Merged add-b"))
    }

    /// The timer's pass rolls progress.md's earlier months over on disk and commits nothing of it.
    @Test func theTimersPassCommitsNothingButAWaitingRedaction() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let start = Date()
        let records = LeadRecords(store: BoardStore(root: root), vault: vault(for: FakeRuntime()), now: start)
        let first = head("main", root)
        #expect(!lead.call("record_decision", ["decision": "One", "why": "w"]).isError)
        #expect(records.tick(base: "main", now: start.addingTimeInterval(60)) == nil)
        #expect(records.tick(base: "main", now: start.addingTimeInterval(301)) == nil)
        #expect(records.tick(base: "main", now: start.addingTimeInterval(3600)) == nil)
        #expect(head("main", root) == first)
        // A redaction whose line has left its file since (archived, rolled over) is never carried: no pass commits for it.
        try LeadRedaction.save([LeadRedaction(file: "docs/lead/decisions.md", old: "- gone (before)", new: "- gone", lints: ["PrivateNamesLint"])], lead.store)
        #expect(records.tick(base: "main", now: start.addingTimeInterval(3650)) == nil)
        #expect(head("main", root) == first)
        // A redaction whose commit had to wait: the next pass commits it (and the records with it).
        let line = try #require(read(root + "/docs/lead/decisions.md").components(separatedBy: "\n").first { $0.contains("One") })
        try LeadRedaction.save([LeadRedaction(file: "docs/lead/decisions.md", old: line + " (before)", new: line, lints: ["PrivateNamesLint"])], lead.store)
        #expect(records.tick(base: "main", now: start.addingTimeInterval(3700)) == nil)
        guard case .committed(let commit)? = records.tick(base: "main", now: start.addingTimeInterval(4000)) else { Issue.record("not committed"); return }
        #expect(head("\(commit)~1", root) == first)
        #expect(Git.run(["log", "-1", "--format=%B", commit], in: root).output.contains("Redacted by the lead (redact_record)"))
        #expect(LeadRedaction.pending(lead.store).isEmpty)
    }

    /// The timer's commit (a redaction's that had to wait) runs as the tool server's background work: a new build's
    /// switch waits for one under way, so it's never cut between the branch's update and the vault's head (a move
    /// "outside the lead" for the next merge).
    @Test func anInstallsSwitchWaitsForACommitUnderWay() async throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("record_decision", ["decision": "Keep it", "why": "w"]).isError)
        let line = try #require(read(root + "/docs/lead/decisions.md").components(separatedBy: "\n").first { $0.contains("Keep it") })
        try LeadRedaction.save([LeadRedaction(file: "docs/lead/decisions.md", old: line + " (before)", new: line, lints: ["PrivateNamesLint"])], lead.store)
        let first = head("main", root)
        let records = LeadRecords(store: BoardStore(root: root), vault: vault(for: runtime), now: .distantPast)
        // Due once: the ticks after the commit find nothing to do.
        records.interval = 3600

        let binary = temp.url("vibeswitcher-mcp").path
        try "build 1".write(toFile: binary, atomically: true, encoding: .utf8)
        let build = Locked(BinaryWatch.Identity(modified: 1, size: 1, inode: 1))
        let watch = BinaryWatch(path: binary, running: build.get(), identify: { _ in build.get() })
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: LeadAdvanceTests.NoTools(), watch: watch)
        let asked = DispatchSemaphore(value: 0)
        let switches = Locked(0)
        server.switchWhen = {
            switches.change { $0 += 1 }
            asked.signal()
            return false
        }
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        #expect(pipe(&input) == 0 && pipe(&output) == 0)
        let served = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            server.serve(input: input[0], output: output[1])
            served.signal()
        }
        defer {
            close(input[1])
            _ = served.wait(timeout: .now() + 20)
            for fd in [input[0], output[0], output[1]] { close(fd) }
        }
        // A commit under way (held where the tick asks for the branch), and a new build installed meanwhile.
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let held = Locked(false)
        records.start(every: 0.05, run: { server.background($0) }) {
            if !held.get() {
                held.set(true)
                started.signal()
                release.wait()
            }
            return "main"
        }
        #expect(await offPool { started.wait(timeout: .now() + 30) } == .success)
        build.set(BinaryWatch.Identity(modified: 2, size: 2, inode: 2))
        // The server reads and answers a request (it looks whether to switch first): no switch while the commit runs.
        let ping = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8) + Data([0x0A])
        _ = ping.withUnsafeBytes { write(input[1], $0.baseAddress, $0.count) }
        var reply = [UInt8](repeating: 0, count: 4096)
        var answer = [pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)]
        #expect(poll(&answer, 1, 30_000) == 1)
        #expect(Sys.read(output[0], &reply, reply.count) > 0)
        #expect(switches.get() == 0)
        // Once it ends, the switch is tried: the commit is on the branch and the vault has it as the lead's.
        release.signal()
        #expect(await offPool { asked.wait(timeout: .now() + 30) } == .success)
        #expect(switches.get() >= 1)
        #expect(head("main~1", root) == first)
        #expect(try vault.head(root: root, branch: "main") == head("main", root))
    }

    @Test func indexLockIsWaitedForAndAFailureIsReported() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(!lead.call("record_decision", ["decision": "Ship it", "why": "it works"]).isError)
        let lock = root + "/.git/index.lock"
        // Held until the commit finds it held, then let go: waited for.
        FileManager.default.createFile(atPath: lock, contents: Data())
        let refused = Locked(0)
        lead.records.lockWait = 120
        lead.records.lockPause = {
            refused.set(refused.get() + 1)
            unlink(lock)
        }
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("not committed"); return }
        #expect(refused.get() == 1)
        // Held on: reported, never removed, nothing lost.
        let before = head("main", root)
        #expect(!lead.call("record_decision", ["decision": "Then this", "why": "w"]).isError)
        FileManager.default.createFile(atPath: lock, contents: Data())
        lead.records.lockPause = nil
        lead.records.lockWait = 0.5
        guard case .failed = lead.records.flush(base: "main") else { Issue.record("didn't fail"); return }
        #expect(FileManager.default.fileExists(atPath: lock))
        #expect(head("main", root) == before)
        #expect(Git.run(["ls-files", "-s", "docs/lead/decisions.md"], in: root).output.contains(Git.run(["rev-parse", "main:docs/lead/decisions.md"], in: root).output))
        #expect(read(root + "/docs/lead/decisions.md").contains("Then this"))
        #expect(lead.call("status", [:]).text.contains("Records: committing decisions.md and progress.md failed"))
        unlink(lock)
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("not committed"); return }
        #expect(!lead.call("status", [:]).text.contains("Records:"))
    }

    @Test func everythingWrittenIsRedacted() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(!lead.call("record_decision", ["decision": "Rotate the key", "why": #"It leaked: password="hunter two" in the log."#]).isError)
        #expect(!lead.call("post_update", ["title": #"Fixed: api_key="abc def""#, "body": "Rotated."]).isError)
        let decisions = read(root + "/docs/lead/decisions.md"), progress = read(root + "/docs/lead/progress.md")
        #expect(decisions.contains("Rotate the key") && !decisions.contains("hunter"))
        #expect(progress.contains("Fixed:") && !progress.contains("abc def"))
    }

    // MARK: Moving the old logs

    @Test func theOldLogsMoveOnceWithoutDuplicates() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        try workflow(root, "---\nrecords_dir:\n---")
        try store.appendDecision("Old one", why: "first")
        try store.appendDecision("Old two", why: #"second, password="a b c""#)
        try store.appendProgress("Planned two tasks")
        let local = root + "/.vibeswitcher/decisions.md"
        #expect(read(local).contains("Old two"))
        // records_dir set: what shows is the old file's until something is written.
        try workflow(root, "---\nrecords_dir: docs/lead\n---")
        #expect(store.decisions().map(\.text) == ["Old one", "Old two"])
        // A move that stopped partway: one entry already there.
        try FileManager.default.createDirectory(atPath: root + "/docs/lead", withIntermediateDirectories: true)
        let one = LeadRecords.entries(read(local), kind: .decisions).entries[0]
        try ("# Decisions\n\n" + one).write(toFile: root + "/docs/lead/decisions.md", atomically: true, encoding: .utf8)

        try store.appendDecision("New one", why: "third")
        #expect(store.decisions().map(\.text) == ["Old one", "Old two", "New one"])
        #expect(!FileManager.default.fileExists(atPath: local))
        #expect(FileManager.default.fileExists(atPath: local + ".moved"))
        let moved = read(root + "/docs/lead/decisions.md")
        #expect(moved.hasPrefix("# Decisions\n\n## "))
        #expect(!moved.contains("a b c"))
        #expect(read(root + "/docs/lead/progress.md").contains("Planned two tasks"))
        #expect(!FileManager.default.fileExists(atPath: root + "/.vibeswitcher/progress.md"))
        // Once: more writes don't bring anything back.
        try store.appendProgress("Merged one")
        try store.appendDecision("New two", why: "fourth")
        #expect(store.decisions().map(\.text) == ["Old one", "Old two", "New one", "New two"])
        #expect(read(root + "/docs/lead/progress.md").components(separatedBy: "Planned two tasks").count == 2)

        // The lead's first commit carries them: its start, a new lead (`LeadToolset.introduceLead`).
        let before = head("main", root)
        let lead = try lead(root, FakeRuntime())
        #expect(head("main~1", root) == before)
        #expect(Git.run(["show", "main:docs/lead/decisions.md"], in: root).output.contains("Old one"))
        #expect(lead.records.flush(base: "main") == .unchanged)
    }

    @Test func aMoveOnTheFirstCommitWithNothingNewWritten() throws {
        let root = try repo()
        try workflow(root, "---\nrecords_dir:\n---")
        try BoardStore(root: root).appendDecision("Old one", why: "first")
        try workflow(root, "---\n---")
        let before = head("main", root)
        // The lead's start, a new lead, commits the move (`LeadToolset.introduceLead`).
        let lead = try lead(root, FakeRuntime())
        #expect(head("main~1", root) == before)
        #expect(Git.run(["show", "main:docs/lead/decisions.md"], in: root).output.contains("Old one"))
        #expect(lead.records.flush(base: "main") == .unchanged)
        #expect(!FileManager.default.fileExists(atPath: root + "/.vibeswitcher/decisions.md"))
    }

    // MARK: Merges

    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, slug: String, file: String) throws {
        _ = lead.call("add_task", ["title": slug, "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": slug])
        let worktree = Worktrees.path(root: root, slug: slug)
        try "\(slug)\n".write(toFile: worktree + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: worktree)
        Git.run(["commit", "-q", "-m", "add \(file)"], in: worktree)
        _ = try seat("worker-\(slug)", runtime).call("report", doneReport("added"))
        _ = lead.call("audit", ["task": slug])
        _ = try seat("verify-\(slug)", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked"])
    }

    /// Until 2026-11-27 each merge was followed by a records commit of its own lines; they wait on disk now, and the
    /// next merge commits them before its rebase, on top of the last merge's code.
    @Test func aMergesRecordsWaitForTheNextMergeToCommitThemFirst() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root, slug: "add-b", file: "b.txt")
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        let records = head("main", root)
        // Nothing after the merge: main is its code, its lines on disk.
        #expect(records == BoardStore(root: root).load().task("add-b")?.merged?.commit)
        #expect(read(root + "/docs/lead/progress.md").contains("Merged add-b"))
        #expect(!Git.run(["show", "main:docs/lead/progress.md"], in: root).output.contains("Merged add-b"))
        #expect(try vault.head(root: root, branch: "main") == records)
        // The next merge goes on top: the records commit is the lead's own, not a move to ask about.
        _ = lead.call("cleanup", ["task": "add-b"])
        try audited(lead, runtime, root: root, slug: "add-d", file: "d.txt")
        let next = lead.call("merge", ["task": "add-d"])
        #expect(!next.isError, "\(next.text)")
        // add-b's lines, and those add-d's report and audit wrote, went in first (`LeadRecords.commitBeforeMerge`), on
        // top of add-b's code.
        let onto = try #require(BoardStore(root: root).load().task("add-d")?.merged?.onto)
        #expect(LeadRecords.isSubject(Git.run(["log", "-1", "--format=%s", onto], in: root).output))
        #expect(head("\(onto)~1", root) == records)
        #expect(Git.run(["show", "\(onto):docs/lead/progress.md"], in: root).output.contains("Merged add-b"))
        #expect(head("main~1", root) == onto)
        #expect(Git.run(["rev-list", "--merges", "main"], in: root).output.isEmpty)
    }

    @Test func noRecordsCommitLandsWhileAMergeTests() async throws {
        let root = try repo()
        let runtime = FakeRuntime()
        // The tests say they've started and run until the test lets them end: the checks below happen while they run.
        let started = temp.url("started").path, release = temp.url("release").path
        try workflow(root, "---\ntest_command: touch '\(started)'; while [ ! -e '\(release)' ]; do sleep 0.05; done; test -f b.txt\n---")
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root, slug: "add-b", file: "b.txt")
        #expect(!lead.call("record_decision", ["decision": "Merge add-b", "why": "audited"]).isError)
        // Committed now, so the merge has none to commit before its rebase: what's written below is new.
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("records not committed"); return }
        try lead.store.appendProgress("Before the merge")
        let before = head("main", root)
        final class Box: @unchecked Sendable { var result: MCPToolResult? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let merging = lead
        Thread.detachNewThread {
            box.result = merging.call("merge", ["task": "add-b"])
            done.signal()
        }
        // While its tests run, a batch is due: it waits for the merge.
        #expect(await eventually { FileManager.default.fileExists(atPath: started) })
        let committedFirst = head("main", root)
        #expect(LeadRecords.isSubject(Git.run(["log", "-1", "--format=%s", committedFirst], in: root).output))
        #expect(head("\(committedFirst)~1", root) == before)
        try lead.store.appendDecision("During the merge's tests", why: "a batch is due")
        #expect(lead.records.flush(base: "main") == .waiting("a merge into main is running."))
        #expect(head("main", root) == committedFirst)
        FileManager.default.createFile(atPath: release, contents: nil)
        #expect(await offPool { done.wait(timeout: .now() + hangGuard) } == .success)
        #expect(box.result?.isError == false, "\(box.result?.text ?? "")")
        // The tested commit is what landed; the line written meanwhile waits on disk for what next needs it in git.
        #expect(head("main", root) == BoardStore(root: root).load().task("add-b")?.merged?.commit)
        #expect(read(root + "/docs/lead/decisions.md").contains("During the merge's tests"))
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("records not committed"); return }
        #expect(Git.run(["show", "main:docs/lead/decisions.md"], in: root).output.contains("During the merge's tests"))
    }

    @Test func aBranchMovedByAnotherWaitsForTheMergeToTakeIt() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(!lead.call("record_decision", ["decision": "One", "why": "w"]).isError)
        // A commit nobody accounted for (not the user's sessions, not the lead's merge).
        try "x\n".write(toFile: root + "/x.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "x.txt"], in: root)
        Git.run(["commit", "-q", "-m", "hand-made"], in: root)
        let moved = head("main", root)
        guard case .waiting(let why) = lead.records.flush(base: "main") else { Issue.record("committed on top of an untaken move"); return }
        #expect(why.contains("moved since the lead last left it"))
        #expect(head("main", root) == moved)
        #expect(lead.call("status", [:]).text.contains("Records: decisions.md and progress.md wait to be committed"))
    }

    @Test func aWorkersProcessCantCommitTheRecords() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        try BoardStore(root: root).appendDecision("A decision", why: "w")
        let before = head("main", root)
        let worker = try issued(.worker, task: "t", root: root, runtime)
        guard case .failed(let why) = worker.records.flush(base: "main") else { Issue.record("a worker committed"); return }
        #expect(why.contains("Only VibeSwitcher or the lead"))
        #expect(head("main", root) == before)
        // Nor straight through the vault as its session.
        let records = LeadRecords(store: BoardStore(root: root), vault: book.vault(folder: vault.folder, as: { .session("own-worker-session") }))
        guard case .failed = records.flush(base: "main") else { Issue.record("a worker committed"); return }
        #expect(head("main", root) == before)
        // The lead can.
        let lead = LeadToolset(root: root, runtime: runtime, vault: vault(for: runtime))
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("the lead couldn't"); return }
    }

    @Test func theFilesCommitTouchesOnlyItsPaths() throws {
        let root = try repo()
        try FileManager.default.createDirectory(atPath: root + "/docs/lead", withIntermediateDirectories: true)
        try "# Decisions\n".write(toFile: root + "/docs/lead/decisions.md", atomically: true, encoding: .utf8)
        try "changed\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        let parent = head("main", root)
        // Not on top of a head it wasn't given.
        #expect(Worktrees.commitFiles(root: root, branch: "main", paths: Self.logs, message: "m", from: "0000", landing: .unchecked("test")) != .unchanged)
        #expect(head("main", root) == parent)
        guard case .committed(let commit, let from) = Worktrees.commitFiles(root: root, branch: "main", paths: Self.logs, message: "m", landing: .unchecked("test")) else {
            Issue.record("not committed"); return
        }
        #expect(from == parent)
        #expect(files(of: commit, root) == ["docs/lead/decisions.md"])
        #expect(Git.run(["diff", "--cached", "--name-only"], in: root).output == "a.txt")
        #expect(Worktrees.commitFiles(root: root, branch: "main", paths: Self.logs, message: "m", landing: .unchecked("test")) == .unchanged)
        // A branch not checked out: only the ref moves.
        Git.run(["branch", "other"], in: root)
        try "# Decisions\n\nmore\n".write(toFile: root + "/docs/lead/decisions.md", atomically: true, encoding: .utf8)
        guard case .committed(let onOther, _) = Worktrees.commitFiles(root: root, branch: "other", paths: Self.logs, message: "m", landing: .unchecked("test")) else {
            Issue.record("not committed"); return
        }
        #expect(head("other", root) == onOther)
        #expect(head("main", root) == commit)
    }
}
