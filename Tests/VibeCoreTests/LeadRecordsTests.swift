import Foundation
import Testing
@testable import VibeCore

/// The commit under `ref` when `ref`'s own commit is the lead's records commit (`LeadRecords`: its subject, and only
/// docs/lead's two logs changed), else `ref`'s: what merged, whether or not the records went on top of it.
func underRecords(_ ref: String, in root: String) -> String {
    let subject = Git.run(["log", "-1", "--format=%s", ref], in: root).output
    let files = Set(Git.run(["diff-tree", "--no-commit-id", "--name-only", "-r", ref], in: root).output.split(separator: "\n").map(String.init))
    let records = subject == LeadRecords.subject && !files.isEmpty && files.isSubset(of: ["docs/lead/decisions.md", "docs/lead/progress.md"])
    return Git.run(["rev-parse", records ? "\(ref)~1" : ref], in: root).output
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
        let settings = read(vault.runFolder(root: root, name: "worker-add-b").appendingPathComponent("settings.json").path)
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
        #expect(Git.run(["log", "-1", "--format=%s", commit], in: root).output == LeadRecords.subject)
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
        #expect(vault.head(root: root, branch: "main") == commit)
        // Nothing new: nothing committed.
        #expect(lead.records.flush(base: "main") == .unchanged)
        #expect(head("main", root) == commit)
    }

    @Test func commitsAreBatched() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let start = Date()
        let records = LeadRecords(store: BoardStore(root: root), vault: vault(for: runtime), now: start)
        records.interval = 300
        let first = head("main", root)
        for number in 1...3 { #expect(!lead.call("record_decision", ["decision": "Decision \(number)", "why": "w"]).isError) }
        // Each line on its own commits nothing.
        #expect(head("main", root) == first)
        #expect(records.tick(base: "main", now: start.addingTimeInterval(60)) == nil)
        #expect(head("main", root) == first)
        // Due: one commit with all three.
        guard case .committed(let batch)? = records.tick(base: "main", now: start.addingTimeInterval(301)) else { Issue.record("not committed"); return }
        #expect(head("\(batch)~1", root) == first)
        let committed = Git.run(["show", "\(batch):docs/lead/decisions.md"], in: root).output
        for number in 1...3 { #expect(committed.contains("Decision \(number)")) }
        #expect(!lead.call("record_decision", ["decision": "Decision 4", "why": "w"]).isError)
        #expect(records.tick(base: "main", now: start.addingTimeInterval(400)) == nil)
        #expect(head("main", root) == batch)
        #expect(records.tick(base: "main", now: start.addingTimeInterval(602)) == .committed(head("main", root)))
        #expect(Git.run(["rev-list", "--count", "\(first)..main"], in: root).output == "2")
    }

    @Test func indexLockIsWaitedForAndAFailureIsReported() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(!lead.call("record_decision", ["decision": "Ship it", "why": "it works"]).isError)
        let lock = root + "/.git/index.lock"
        // Held for a moment: waited for.
        FileManager.default.createFile(atPath: lock, contents: Data())
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { unlink(lock) }
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("not committed"); return }
        // Held on: reported, never removed, nothing lost.
        let before = head("main", root)
        #expect(!lead.call("record_decision", ["decision": "Then this", "why": "w"]).isError)
        FileManager.default.createFile(atPath: lock, contents: Data())
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

        // The lead's first commit carries them.
        let lead = try lead(root, FakeRuntime())
        guard case .committed(let commit) = lead.records.flush(base: "main") else { Issue.record("not committed"); return }
        #expect(Git.run(["show", "\(commit):docs/lead/decisions.md"], in: root).output.contains("Old one"))
    }

    @Test func aMoveOnTheFirstCommitWithNothingNewWritten() throws {
        let root = try repo()
        try workflow(root, "---\nrecords_dir:\n---")
        try BoardStore(root: root).appendDecision("Old one", why: "first")
        try workflow(root, "---\n---")
        let lead = try lead(root, FakeRuntime())
        guard case .committed(let commit) = lead.records.flush(base: "main") else { Issue.record("not committed"); return }
        #expect(Git.run(["show", "\(commit):docs/lead/decisions.md"], in: root).output.contains("Old one"))
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
        _ = try seat("worker-\(slug)", runtime).call("report", ["status": "done", "summary": "added"])
        _ = lead.call("audit", ["task": slug])
        _ = try seat("verify-\(slug)", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked"])
    }

    @Test func eachMergeIsFollowedByARecordsCommitTheNextMergeTakes() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root, slug: "add-b", file: "b.txt")
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        let records = head("main", root)
        // No decision was recorded: the progress log alone.
        #expect(files(of: records, root) == ["docs/lead/progress.md"])
        #expect(underRecords("main", in: root) == BoardStore(root: root).load().task("add-b")?.merged?.commit)
        #expect(Git.run(["show", "main:docs/lead/progress.md"], in: root).output.contains("Merged add-b"))
        #expect(vault.head(root: root, branch: "main") == records)
        // The next merge goes on top: the records commit is the lead's own, not a move to ask about.
        _ = lead.call("cleanup", ["task": "add-b"])
        try audited(lead, runtime, root: root, slug: "add-d", file: "d.txt")
        let next = lead.call("merge", ["task": "add-d"])
        #expect(!next.isError, "\(next.text)")
        #expect(head("\(underRecords("main", in: root))~1", root) == records)
        #expect(Git.run(["rev-list", "--merges", "main"], in: root).output.isEmpty)
    }

    @Test func noRecordsCommitLandsWhileAMergeTests() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        try workflow(root, "---\ntest_command: sleep 2 && test -f b.txt\n---")
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root, slug: "add-b", file: "b.txt")
        #expect(!lead.call("record_decision", ["decision": "Merge add-b", "why": "audited"]).isError)
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
        Thread.sleep(forTimeInterval: 1)
        #expect(lead.records.flush(base: "main") == .waiting("a merge into main is running."))
        #expect(head("main", root) == before)
        done.wait()
        #expect(box.result?.isError == false, "\(box.result?.text ?? "")")
        // Then right after it: the tested commit is what landed, the records on top.
        #expect(underRecords("main", in: root) == BoardStore(root: root).load().task("add-b")?.merged?.commit)
        #expect(Git.run(["show", "main:docs/lead/decisions.md"], in: root).output.contains("Merge add-b"))
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
        #expect(Worktrees.commitFiles(root: root, branch: "main", paths: Self.logs, message: "m", from: "0000") != .unchanged)
        #expect(head("main", root) == parent)
        guard case .committed(let commit, let from) = Worktrees.commitFiles(root: root, branch: "main", paths: Self.logs, message: "m") else {
            Issue.record("not committed"); return
        }
        #expect(from == parent)
        #expect(files(of: commit, root) == ["docs/lead/decisions.md"])
        #expect(Git.run(["diff", "--cached", "--name-only"], in: root).output == "a.txt")
        #expect(Worktrees.commitFiles(root: root, branch: "main", paths: Self.logs, message: "m") == .unchanged)
        // A branch not checked out: only the ref moves.
        Git.run(["branch", "other"], in: root)
        try "# Decisions\n\nmore\n".write(toFile: root + "/docs/lead/decisions.md", atomically: true, encoding: .utf8)
        guard case .committed(let onOther, _) = Worktrees.commitFiles(root: root, branch: "other", paths: Self.logs, message: "m") else {
            Issue.record("not committed"); return
        }
        #expect(head("other", root) == onOther)
        #expect(head("main", root) == commit)
    }
}
