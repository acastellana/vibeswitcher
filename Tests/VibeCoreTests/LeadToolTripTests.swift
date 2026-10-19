import Foundation
import Testing
@testable import VibeCore

/// The lead's tools not tripping the lead (2026-10-18 review of 3 vibeswitcher leads and the genswap lead): a task a
/// decision holds back isn't merged, outputs fit in its context, wrong parameter names are named, host errors read as
/// errors, and a host replacement doesn't leave the board saying "running".
struct LeadToolTripTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("trip")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func commit(_ file: String, _ text: String, in dir: String) throws {
        let path = dir + "/" + file
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        Git.run(["commit", "-q", "-m", "change \(file)"], in: dir)
    }

    /// A task with a worker that committed b.txt and reported; returns its worktree.
    func reported(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String) throws -> String {
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        _ = lead.call("start_worker", ["task": "add-b"])
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("b.txt", "bee\n", in: worktree)
        _ = try seat("worker-add-b", runtime).call("report", ["status": "done", "summary": "added"])
        return worktree
    }

    func passingAudit(_ lead: LeadToolset, _ runtime: FakeRuntime) throws {
        _ = lead.call("audit", ["task": "add-b"])
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
    }

    // MARK: Holds

    /// genswap, 14:52: a fresh lead merged an audited prototype its decisions.md said never to merge until the user
    /// had looked. The prompt says to check, and a kept task can't be merged by mistake.
    @Test func theLeadIsToldToCheckWhatHoldsATaskBack() {
        let prompt = LeadPrompts.lead(project: "p", root: "/r", workflow: LeadWorkflow())
        #expect(prompt.contains("check first that nothing holds the task back"))
        #expect(prompt.contains("decisions.md"))
        #expect(prompt.contains("kept"))
        for goal in [nil, "build it"] {
            let start = LeadPrompts.leadStart(root: "/r", goal: goal, note: "n")
            #expect(start.contains("/r/docs/lead/decisions.md") && start.contains("/r/docs/lead/progress.md"))
        }
    }

    @Test func aKeptTaskIsntMergedAndSaysWhy() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try reported(lead, runtime, root: root)
        try passingAudit(lead, runtime)
        let unsaid = lead.call("update_task", ["task": "add-b", "status": "kept"])
        #expect(unsaid.isError && unsaid.text.contains("reason"))
        #expect(BoardStore(root: root).load().task("add-b")?.status == .review)
        let kept = lead.call("update_task", ["task": "add-b", "status": "kept", "reason": "prototype: never merge until the user has looked"])
        #expect(!kept.isError, "\(kept.text)")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .kept && task.keptBecause == "prototype: never merge until the user has looked")

        let status = lead.call("status", [:]).text
        #expect(status.contains("\nkept:\n- add-b: Add b"))
        #expect(status.contains("kept: prototype: never merge"))
        #expect(!status.contains("\nfailed:"))
        #expect(lead.call("board", [:]).text.contains("- add-b [kept]"))

        let merge = lead.call("merge", ["task": "add-b"])
        #expect(merge.isError && merge.text.contains("kept unmerged (prototype: never merge until the user has looked)"))
        #expect(Git.run(["show", "main:b.txt"], in: root).ok == false)
        // Cleanup without force refuses too: its work stays.
        #expect(lead.call("cleanup", ["task": "add-b"]).isError)
        // A new audit or report doesn't undo it.
        _ = lead.call("audit", ["task": "add-b"])
        #expect(BoardStore(root: root).load().task("add-b")?.status == .kept)
        // Set back, it's an ordinary task again.
        #expect(!lead.call("update_task", ["task": "add-b", "status": "planned"]).isError)
        let back = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(back.status == .planned && back.keptBecause == nil)
    }

    @Test func mergingAMergedTaskSaysWhenNotNoAudit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try reported(lead, runtime, root: root)
        try passingAudit(lead, runtime)
        #expect(!lead.call("merge", ["task": "add-b"]).isError)
        let merged = try #require(BoardStore(root: root).load().task("add-b")?.merged)
        let again = lead.call("merge", ["task": "add-b"])
        #expect(again.isError)
        #expect(again.text.contains("already merged at \(merged.commit.prefix(8))"))
        #expect(!again.text.contains("no passing audit"))
        // And it can't be set to another state.
        #expect(lead.call("update_task", ["task": "add-b", "status": "kept", "reason": "x"]).text.contains("merged already"))
    }

    // MARK: update_task

    @Test func updateTaskAppendsOrReplacesAndDropsNothingUnsaid() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"], "context": "Files: a.swift"])
        let appended = lead.call("update_task", ["task": "one", "append_context": "Also: the user wants it blue."])
        #expect(!appended.isError && appended.text.contains("context (added to)"))
        #expect(BoardStore(root: root).load().task("one")?.contract.context == "Files: a.swift\n\nAlso: the user wants it blue.")
        _ = lead.call("update_task", ["task": "one", "context": "Only this."])
        #expect(BoardStore(root: root).load().task("one")?.contract.context == "Only this.")
        // A name it doesn't take, or a state it doesn't set: refused whole, saying so.
        let typo = lead.call("update_task", ["task": "one", "goal": "new", "contxt": "lost?"])
        #expect(typo.isError && typo.text.contains("contxt") && typo.text.contains("append_context"))
        #expect(BoardStore(root: root).load().task("one")?.contract.goal == "g")
        let state = lead.call("update_task", ["task": "one", "status": "done"])
        #expect(state.isError && state.text.contains("planned, blocked, failed, kept"))
        let update = lead.tools.first { $0.name == "update_task" }
        #expect(update?.properties["append_context"] != nil && update?.properties["context"]?.description.contains("Replaces") == true)
    }

    // MARK: Parameter names

    /// 53 progress calls and 3 reports here and in genswap passed `message`, and failed or lost their summary.
    @Test func workerToolsTakeTheNamesWorkersUse() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "one"])
        let worker = try seat("worker-one", runtime)
        #expect(!worker.call("progress", ["message": "Parser done"]).isError)
        #expect(!worker.call("progress", ["summary": "Tests\npass"]).isError)
        #expect(!worker.call("progress", ["text": ["one", "two"]]).isError)
        #expect(BoardStore(root: root).load().task("one")?.checkpoints?.map(\.text) == ["Parser done", "Tests pass", "one two"])
        let nothing = worker.call("progress", ["what": "x"])
        #expect(nothing.isError && nothing.text.contains("`text`") && nothing.text.contains("what"))

        let unsaid = worker.call("report", ["status": "done"])
        #expect(unsaid.isError && unsaid.text.contains("`summary`"))
        #expect(!worker.call("report", ["status": "done", "message": "Added b.txt; tests pass"]).isError)
        #expect(BoardStore(root: root).load().task("one")?.report == "Added b.txt; tests pass")
        #expect(!worker.call("ask_lead", ["text": "Which file?"]).isError)
        #expect(runtime.steered.last?.text.contains("Which file?") == true)
        // The lead's message, too.
        #expect(!lead.call("message", ["task": "one", "message": "Use b.txt"]).isError)
        #expect(runtime.steered.last?.text == "Use b.txt")
    }

    // MARK: clear_draft

    @Test func aDraftThatStaysIsntAnInvitationToRetry() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "one"])
        runtime.delivery = .behindDraft("open rotate.html so I can try it")
        #expect(lead.call("message", ["task": "one", "text": "hi"]).text.contains("clear_draft: true"))
        runtime.delivery = .draftStayed(before: "open rotate.html so I can try it", after: "merge it into memecoins")
        let stayed = lead.call("message", ["task": "one", "text": "hi", "clear_draft": true]).text
        #expect(!stayed.contains("clear_draft: true"))
        #expect(stayed.contains("“open rotate.html so I can try it”") && stayed.contains("still showed “merge it into memecoins”"))
        runtime.delivery = .draftStayed(before: "x", after: nil)
        #expect(lead.call("message", ["task": "one", "text": "hi", "clear_draft": true]).text.contains("couldn't be cleared"))
    }

    // MARK: Host errors (E-09)

    @Test func aHostThatCantBeReadIsAnErrorNotNoSessions() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "one"])
        runtime.hostDown = "The session host didn't answer."
        // Its worker may well still run there: a second one isn't started in its worktree.
        let start = lead.call("start_worker", ["task": "one"])
        #expect(start.isError && start.text.contains("can't be read") && start.text.contains("didn't answer"))
        #expect(runtime.spawned.count == 1)
        let stop = lead.call("stop_worker", ["task": "one"])
        #expect(stop.isError && stop.text.contains("wasn't stopped"))
        #expect(runtime.killed.isEmpty && BoardStore(root: root).load().task("one")?.status == .running)
        let cleanup = lead.call("cleanup", ["task": "one", "force": true])
        #expect(cleanup.isError && cleanup.text.contains("nothing was cleaned up"))
        #expect(FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "one")))
        #expect(lead.call("status", [:]).text.contains("The session host can't be read right now"))
        #expect(lead.call("sessions", [:]).text.contains("can't be read"))
        #expect(lead.call("read_session", ["task": "one"]).isError)
        runtime.hostDown = nil
        #expect(!lead.call("stop_worker", ["task": "one"]).isError)
    }

    // MARK: After a host replacement

    @Test func aWorkerWhoseSessionIsGoneReadsEnded() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "one"])
        let worker = try #require(BoardStore(root: root).load().task("one")?.worker)
        #expect(lead.call("status", [:]).text.contains("\nrunning:\n- one: One"))
        // The host was replaced: its sessions are gone from the list.
        runtime.forgotten.append(worker)
        let status = lead.call("status", [:]).text
        #expect(!status.contains("\nrunning:"))
        #expect(status.contains("\nworker ended (1), not running:\n- one: One — worker ended: its session is gone"))
        #expect(lead.call("board", [:]).text.contains("- one [worker ended]"))
        #expect(lead.call("board", ["task": "one"]).text.contains("Now: worker ended"))
        // Nothing to kill: cleanup doesn't try.
        #expect(!lead.call("cleanup", ["task": "one", "force": true]).isError)
        #expect(runtime.killed.isEmpty)
        // A verifier gone without a verdict reads so too.
        var task = LeadTask(slug: "two", title: "Two", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""), status: .review)
        task.verifier = "gone-verifier"
        #expect(LeadToolset.endedMember(task, [:])?.hasPrefix("verifier ended") == true)
        task.evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: "ok")
        #expect(LeadToolset.endedMember(task, [:]) == nil)
    }

    // MARK: Size

    /// A board as big as this repository's gets (46 tasks, 30+ reports): status was 87–408 KB here, board 337 KB in
    /// genswap. Synthetic: 60 tasks with long everything, 100 long reports.
    func bigBoard(_ root: String, _ runtime: FakeRuntime) throws {
        let long = String(repeating: "word ", count: 400)
        let states: [LeadTask.Status] = [.planned, .running, .review, .done, .failed, .blocked, .kept]
        try BoardStore(root: root).update { board in
            for number in 0..<60 {
                let state = states[number % states.count]
                var task = LeadTask(slug: "task-number-\(number)", title: "Task \(number) " + long,
                                    contract: LeadContract(goal: long, acceptance: [long, long], boundaries: [long], context: long + long), status: state)
                task.checkpoints = (0..<40).map { LeadCheckpoint(text: "step \($0) " + String(long.prefix(300))) }
                task.report = long
                task.evidence = state == .planned ? nil : LeadEvidence(completion: .complete, integrity: .clean, summary: long)
                task.setback = LeadSetback(stage: .review, reason: long)
                task.blocker = state == .blocked ? long : nil
                task.keptBecause = state == .kept ? long : nil
                task.attempts = 3
                if state != .planned {
                    task.worker = "w-\(number)"
                    task.worktree = state == .failed && number % 2 == 0 ? nil : "/x"
                }
                if state == .done { task.merged = LeadMergeRecord(commit: "abc", tested: true) }
                board.tasks.append(task)
            }
            board.reports = (0..<100).map { number in
                LeadReport(about: "worker task-number-\(number % 60)", text: "The worker on task-number-\(number % 60) says it's done: " + long,
                           at: Date().timeIntervalSince1970 - Double(100 - number))
            }
            board.updates = (0..<30).map { LeadUpdate(title: "Update \($0) " + long, body: long) }
            board.ask("A question " + String(long.prefix(200)), options: ["a", "b"], priority: .important, whyNow: nil)
        }
        // Half the workers still run.
        for number in stride(from: 0, to: 60, by: 2) {
            runtime.spawned.append(("w-\(number)", "/x", "claude", "Worker", true))
        }
    }

    @Test func statusAndBoardStayBounded() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try bigBoard(root, runtime)
        let status = lead.call("status", [:]).text
        #expect(status.utf8.count < 10_000, "status is \(status.utf8.count) bytes")
        // Each report one line, cut; those about merged or abandoned tasks a count.
        #expect(status.contains("Reports since your last status (100)"))
        #expect(status.contains("earlier ones: board(task) has them"))
        #expect(status.contains("about tasks already merged or abandoned"))
        #expect(status.components(separatedBy: "\n").allSatisfy { $0.count <= 700 })
        // The next one has no reports left to list.
        #expect(!lead.call("status", [:]).text.contains("Reports since"))

        let board = lead.call("board", [:]).text
        #expect(board.utf8.count < 16_000, "board is \(board.utf8.count) bytes")
        #expect(board.contains("- task-number-59 ["))
        #expect(board.contains("board(task) shows one in full"))

        // One task in full: its whole contract and its reports.
        let one = lead.call("board", ["task": "task-number-1"]).text
        #expect(one.contains("\"context\"") && one.contains("\"checkpoints\""))
        #expect(one.contains("Reports about it (oldest first):"))
        #expect(one.utf8.count < 200_000)
        #expect(lead.call("board", ["task": "nope"]).isError)
    }

    // MARK: The audit flag

    @Test func ignoredFilesClaudeWritesForItselfArentSettings() throws {
        #expect(!Worktrees.isAgentConfig(".claude/scheduled_tasks.lock", ignored: true))
        #expect(Worktrees.isAgentConfig(".claude/settings.local.json", ignored: true))
        #expect(Worktrees.isAgentConfig(".claude/commands/ship.md", ignored: true))
        #expect(Worktrees.isAgentConfig("CLAUDE.local.md", ignored: true))
        #expect(Worktrees.isAgentConfig(".claude/scheduled_tasks.lock"))
        let root = try repo()
        try commit(".gitignore", ".claude/*.lock\n.claude/settings.local.json\n", in: root)
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "Add b", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "add-b"])
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try FileManager.default.createDirectory(atPath: worktree + "/.claude", withIntermediateDirectories: true)
        try "1".write(toFile: worktree + "/.claude/scheduled_tasks.lock", atomically: true, encoding: .utf8)
        #expect(Worktrees.agentConfigChanges(root: root, slug: "add-b", base: "main").isEmpty)
        try "{}".write(toFile: worktree + "/.claude/settings.local.json", atomically: true, encoding: .utf8)
        #expect(Worktrees.agentConfigChanges(root: root, slug: "add-b", base: "main") == [".claude/settings.local.json"])
    }
}
