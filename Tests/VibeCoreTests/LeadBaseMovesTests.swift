import Foundation
import Testing
@testable import VibeCore

/// The user's own sessions commit to the lead's base: the next merge takes that, without a restart. What the team
/// does to the base (and anything that can't be told apart from it) is still refused.
struct LeadBaseMovesTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("moves")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["config", "commit.gpgsign", "false"]] {
            Git.run(args, in: root)
        }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func commit(_ file: String, _ text: String, in dir: String, _ extra: [String] = []) throws {
        try text.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        #expect(Git.run(["commit", "-q", "-m", "change \(file)"] + extra, in: dir).ok)
    }

    func head(_ ref: String, _ root: String) -> String { Git.run(["rev-parse", ref], in: root).output }

    /// A session's hook event around a shell command, as Claude Code sends it.
    func event(_ name: String, _ command: String, cwd: String, call: String) -> [String: Any] {
        ["hook_event_name": name, "tool_name": "Bash", "tool_input": ["command": command], "cwd": cwd, "tool_use_id": call,
         "session_id": "whatever-the-hook-claims"]
    }

    /// What the session's hooks tell the host around `command` (which `body` carries out), as `session`'s process.
    func ran(_ command: String, in dir: String, as session: LeadVault, _ body: () throws -> Void) throws {
        let call = UUID().uuidString
        let before = GitMoves.steps(for: event("PreToolUse", command, cwd: dir, call: call))
        #expect(!before.isEmpty, "\(command)")
        for (root, step) in before { try session.record(step, root: root) }
        try body()
        for (root, step) in GitMoves.steps(for: event("PostToolUse", command, cwd: dir, call: call)) { try session.record(step, root: root) }
    }

    /// A session the user opened in the window (the host says so: the app asked for it), holding no role here.
    var yours: LeadVault { book.vault(folder: vault.folder, as: { .session("user-session") }, userOpened: true) }

    /// A task with a worker that committed b.txt, reported and passed its audit.
    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String) throws {
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        _ = lead.call("start_worker", ["task": "add-b"])
        try commit("b.txt", "bee\n", in: Worktrees.path(root: root, slug: "add-b"))
        _ = try seat("worker-add-b", runtime).call("report", doneReport("added"))
        _ = lead.call("audit", ["task": "add-b"])
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
    }

    // MARK: Taken

    @Test func aCommitFromYourOwnSessionIsTakenAtTheNextMerge() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root)
        try ran("git add c.txt && git commit -m 'fix the crash'", in: root, as: yours) { try commit("c.txt", "see\n", in: root) }
        let mine = head("main", root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("Merged add-b"))
        // An update only for a merge the user would notice (decision 2026-10-21 22:52, item 6), not one per merge.
        #expect(merged.text.contains("Next: cleanup(add-b). " + LeadPrompts.Policy.updates), "\(merged.text)")
        #expect(!merged.text.contains("Post an update for the user"))
        #expect(Git.run(["merge-base", "--is-ancestor", mine, "main"], in: root).ok)
        #expect(vault.head(root: root, branch: "main") == head("main", root))
        let update = try #require(BoardStore(root: root).load().updates.last)
        #expect(update.body.contains("accepted 1 commit on main from your session"), "\(update.body)")
        #expect(update.body.contains(String(mine.prefix(7))))
    }

    @Test func severalCommandsOfYoursInARowAreTakenTogether() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        Git.run(["checkout", "-q", "-b", "side"], in: root)
        try commit("s.txt", "side\n", in: root)
        Git.run(["checkout", "-q", "main"], in: root)
        try ran("git commit -am one", in: root, as: yours) { try commit("c.txt", "see\n", in: root) }
        try ran("cd \(root) && git merge --no-ff side -m 'Merge side'", in: "/", as: yours) {
            #expect(Git.run(["merge", "-q", "--no-ff", "side", "-m", "Merge side"], in: root).ok)
        }
        Git.run(["checkout", "-q", "side"], in: root)
        try commit("t.txt", "tee\n", in: root)
        let picked = head("side", root)
        Git.run(["checkout", "-q", "main"], in: root)
        try ran("git -C \(root) cherry-pick \(picked)", in: "/tmp", as: yours) { #expect(Git.run(["cherry-pick", picked], in: root).ok) }

        let move = try vault.acceptMove(root: root, branch: "main")
        #expect(move.accepted, "\(move.reason ?? "")")
        #expect(move.sessions == ["user-session"])
        #expect(move.commits.count == 4)
        #expect(vault.headMoved(root: root, branch: "main") == nil)
    }

    /// genswap keeps its base checked out in .claude/worktrees/fair-launch: a session of yours there commits on it.
    @Test func aCommitFromYourSessionInALinkedWorktreeIsTaken() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        Git.run(["switch", "-q", "-c", "elsewhere"], in: root)
        let worktree = root + "/.claude/worktrees/main"
        #expect(Git.run(["worktree", "add", "-q", worktree, "main"], in: root).ok)
        #expect(GitMoves.checkout(at: worktree).map { GitMoves.resolved($0.root) } == GitMoves.resolved(root))
        #expect(GitMoves.checkout(at: worktree)?.branch == "main")
        try ran("git commit -am 'fix the README'", in: worktree, as: yours) { try commit("c.txt", "see\n", in: worktree) }
        let move = try vault.acceptMove(root: root, branch: "main")
        #expect(move.accepted, "\(move.reason ?? "")")
        #expect(move.sessions == ["user-session"])
    }

    /// genswap, 2026-10-22 18:07: the user ran the lead's `!` commit, so nothing told the host about it. The merge
    /// says what the window does about it (asks, here), never to restart the lead.
    @Test func theMergeSaysTheWindowIsAskingAndNeedsNoRestart() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root)
        let left = head("main", root)
        try commit("c.txt", "see\n", in: root)
        let now = head("main", root)

        // Before the window looked.
        let early = lead.call("merge", ["task": "add-b"])
        #expect(early.isError)
        #expect(early.text.contains("VibeSwitcher's window looks at main every few seconds"), "\(early.text)")
        #expect(early.text.contains("No restart is needed"))
        #expect(!early.text.contains("starting the lead again"))

        // It asks you.
        try LeadVault.BaseMoveNote(branch: "main", from: left, to: now, state: .asking, commits: 1, reason: nil).save(root: root)
        let asking = lead.call("merge", ["task": "add-b"])
        #expect(asking.isError)
        #expect(asking.text.contains("No command VibeSwitcher saw"), "\(asking.text)")
        #expect(asking.text.contains("VibeSwitcher is asking the user: a card in your chat in its window lists the 1 commit"), "\(asking.text)")
        // A note about another move says nothing about this one.
        try LeadVault.BaseMoveNote(branch: "main", from: left, to: left, state: .kept, commits: 1, reason: nil).save(root: root)
        #expect(lead.call("merge", ["task": "add-b"]).text.contains("every few seconds"))

        // You accept: the same lead merges.
        try vault.setHead(now, root: root, branch: "main")
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
    }

    @Test func aBaseCheckedOutInAWorktreeOutsideTheTeamsIsNamedWithTheOneCommandThatFreesIt() throws {
        let root = try repo()
        Git.run(["switch", "-q", "-c", "elsewhere"], in: root)
        let worktree = root + "/.claude/worktrees/main"
        #expect(Git.run(["worktree", "add", "-q", worktree, "main"], in: root).ok)
        let from = head("main", root)
        Git.run(["switch", "-q", "-c", "work", "main"], in: root)
        try commit("b.txt", "bee\n", in: root)
        let commit = head("work", root)

        guard case .refused(let clean) = Worktrees.fastForward(root: root, base: "main", to: commit, from: from) else {
            Issue.record("merged under the worktree")
            return
        }
        #expect(clean.contains("main is checked out in .claude/worktrees/main, a worktree outside VibeSwitcher's"), "\(clean)")
        #expect(clean.contains("it's clean"), "\(clean)")
        #expect(clean.contains("`git switch --detach` in that worktree"), "\(clean)")
        #expect(clean.contains("`! cd /") && clean.contains("/.claude/worktrees/main && git switch --detach` in your chat"), "\(clean)")

        try "changed\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        guard case .refused(let dirty) = Worktrees.fastForward(root: root, base: "main", to: commit, from: from) else {
            Issue.record("merged under the worktree")
            return
        }
        #expect(dirty.contains("1 uncommitted file: a.txt (modified)"), "\(dirty)")
        #expect(dirty.contains("Its uncommitted files stay as they are."), "\(dirty)")

        // The one command: the merge goes through, and the worktree keeps its files.
        #expect(Git.run(["switch", "-q", "--detach"], in: worktree).ok)
        #expect(Worktrees.fastForward(root: root, base: "main", to: commit, from: from) == .merged)
        #expect(head("main", root) == commit)
        #expect((try? String(contentsOfFile: worktree + "/a.txt", encoding: .utf8)) == "changed\n")
    }

    // MARK: Refused

    @Test func aWorkersCommitOnTheBaseIsRefused() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root)
        let known = try #require(vault.head(root: root, branch: "main"))
        // Its hooks record the commit as its session's: the host tells the worker's process apart, and a session that
        // holds a role in the team isn't yours, even had the app opened it.
        let worker = try launched("worker-add-b", runtime).session
        let workers = book.vault(folder: vault.folder, as: { .session(worker) }, userOpened: true)
        try ran("git -C \(root) commit -am sneak", in: Worktrees.path(root: root, slug: "add-b"), as: workers) {
            try commit("c.txt", "unaudited\n", in: root)
        }

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.contains("moved since the lead last left it"), "\(merged.text)")
        #expect(merged.text.contains("isn't one of yours"), "\(merged.text)")
        #expect(vault.head(root: root, branch: "main") == known)
        #expect(try vault.acceptMove(root: root, branch: "main").accepted == false)
    }

    @Test func aForgedHookClaimFromATeamProcessIsRefused() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root)
        let known = try #require(vault.head(root: root, branch: "main"))
        let worker = try launched("worker-add-b", runtime).session
        let workers = book.vault(folder: vault.folder, as: { .session(worker) })
        // The worker moves main with plumbing, writing a reflog entry that reads like a commit, and its process tells
        // the host the hook events a commit would have made (a session id in them is nobody's word).
        let unaudited = Git.run(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "unaudited"], in: root).output
        try ran("git commit -m fix", in: root, as: workers) {
            #expect(Git.run(["update-ref", "-m", "commit: fix", "refs/heads/main", unaudited], in: root).ok)
        }
        // Nor from a process outside every session, nor from a session one of the team started.
        let nobody = book.vault(folder: vault.folder, as: { .unknown })
        #expect(throws: LeadVault.Refused.self) {
            try nobody.record(LeadVault.GitStep(phase: .before, call: nil, verb: "commit", branch: "main", head: known), root: root)
        }
        let started = book.vault(folder: vault.folder, as: { .session("started-by-the-worker") })
        try ran("git commit -m fix", in: root, as: started) {}

        let move = try vault.acceptMove(root: root, branch: "main")
        #expect(!move.accepted)
        #expect(move.reason?.contains("isn't one of yours") == true, "\(move.reason ?? "")")
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(vault.head(root: root, branch: "main") == known)
        #expect(head("main", root) == unaudited)
    }

    @Test func aCommitNoSessionOfYoursIsSeenMakingIsAskedAbout() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        // A terminal outside the window, or a hook that didn't run: nobody accounts for it.
        try commit("c.txt", "see\n", in: root)
        let move = try vault.acceptMove(root: root, branch: "main")
        #expect(!move.accepted)
        #expect(move.waiting != true)
        #expect(move.reason?.contains("No command VibeSwitcher saw") == true, "\(move.reason ?? "")")
        #expect(move.commits.map(\.subject) == ["change c.txt"])
    }

    @Test func aRewriteOfTheBaseIsRefusedEvenFromYourSession() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        try ran("git commit -m one", in: root, as: yours) { try commit("c.txt", "see\n", in: root) }
        #expect(try vault.acceptMove(root: root, branch: "main").accepted)
        // A reset back past where the lead left it.
        #expect(Git.run(["reset", "-q", "--hard", "HEAD~1"], in: root).ok)
        let reset = try vault.acceptMove(root: root, branch: "main")
        #expect(!reset.accepted)
        #expect(reset.reason?.contains("was rewritten") == true, "\(reset.reason ?? "")")
        #expect(reset.commits.isEmpty)
        // An amend of the commit the lead left, as a command of yours: still a rewrite.
        try ran("git commit -m 'first, amended'", in: root, as: yours) { try commit("d.txt", "dee\n", in: root, ["--amend"]) }
        #expect(try vault.acceptMove(root: root, branch: "main").accepted == false)
        // A rebase, even one that only fast-forwards: its entries aren't a commit, merge, cherry-pick, revert, am or pull.
        #expect(Git.run(["reset", "-q", "--hard", try #require(vault.head(root: root, branch: "main"))], in: root).ok)
        Git.run(["checkout", "-q", "-b", "side"], in: root)
        try commit("s.txt", "side\n", in: root)
        Git.run(["checkout", "-q", "main"], in: root)
        try ran("git commit -m wip && git rebase side", in: root, as: yours) { #expect(Git.run(["rebase", "-q", "side"], in: root).ok) }
        let rebased = try vault.acceptMove(root: root, branch: "main")
        #expect(!rebased.accepted)
        #expect(rebased.reason?.contains("not a commit, merge") == true, "\(rebased.reason ?? "")")
        #expect(vault.headMoved(root: root, branch: "main") != nil)
    }

    @Test func acceptingTheMoveInTheAppUnblocksTheMergeWithoutARestart() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root)
        try commit("c.txt", "see\n", in: root)
        #expect(lead.call("merge", ["task": "add-b"]).isError)
        let move = try vault.acceptMove(root: root, branch: "main")
        #expect(!move.accepted)
        // You click Accept: the app (and only it, or the lead) records the head; the same lead merges on.
        #expect(throws: LeadVault.Refused.self) { try self.yours.setHead(move.to, root: root, branch: "main") }
        try vault.setHead(move.to, root: root, branch: "main")
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(vault.current(.lead, root: root, task: nil)?.session == runtime.me.session)
    }

    @Test func onlyTheAppOrTheLeadAsksToTakeAMove() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        try ran("git commit -m one", in: root, as: yours) { try commit("c.txt", "see\n", in: root) }
        #expect(throws: LeadVault.Refused.self) { try self.yours.acceptMove(root: root, branch: "main") }
        #expect(try vault(for: runtime).acceptMove(root: root, branch: "main").accepted)
    }

    // MARK: The judge

    func history(_ entries: [(old: String, new: String, time: Double, message: String)], parents: [String: [String]]) -> LeadVault.BaseHistory {
        LeadVault.BaseHistory(head: entries.last!.new, fastForward: true, order: parents.keys.sorted().reversed(),
                              commits: parents.mapValues { LeadVault.BaseHistory.Commit(parents: $0, subject: "s") },
                              reflog: entries.map { LeadVault.BaseHistory.Entry(old: $0.old, new: $0.new, time: $0.time, message: $0.message) })
    }

    func run(_ verb: String, _ before: String, _ after: String?, _ started: Double, _ ended: Double?, user: Bool = true) -> LeadVault.GitRun {
        LeadVault.GitRun(session: user ? "you" : "worker", user: user, call: nil, verb: verb, branch: "main", before: before, after: after,
                         started: started, ended: ended)
    }

    @Test func aCommitSlippedInBehindOneOfYoursIsRefused() {
        // Your `git commit` made U; before its hooks said it was done, something moved main on to W.
        let moves = history([("h", "u", 100, "commit: yours"), ("u", "w", 101, "commit: slipped in")], parents: ["u": ["h"], "w": ["u"]])
        let move = LeadVault.judge(from: "h", history: moves, branch: "main", runs: [run("commit", "h", "w", 99, 102)], now: 103)
        #expect(!move.accepted)
        #expect(move.reason?.contains("No command") == true, "\(move.reason ?? "")")
        // With a second commit of yours to account for it, it is taken.
        let both = LeadVault.judge(from: "h", history: moves, branch: "main",
                                   runs: [run("commit", "h", "u", 99, 100.5), run("commit", "u", "w", 100.6, 102)], now: 103)
        #expect(both.accepted)
    }

    @Test func aCommandStillRunningIsWaitedFor() {
        let moves = history([("h", "u", 100, "commit: yours")], parents: ["u": ["h"]])
        let move = LeadVault.judge(from: "h", history: moves, branch: "main", runs: [run("commit", "h", nil, 99, nil)], now: 101)
        #expect(!move.accepted)
        #expect(move.waiting == true)
    }

    /// A team session's git command that ran when an entry was made marks the move as possibly the team's, also when
    /// it hasn't ended yet (no heads said) or ended within the hook's slack after it: what the window saw you send
    /// never takes such a move.
    @Test func aTeamCommandRunningWhenTheEntryWasMadeMarksTheMoveTheTeams() {
        let moves = history([("h", "u", 100, "commit: x")], parents: ["u": ["h"]])
        let judge = { (runs: [LeadVault.GitRun]) in LeadVault.judge(from: "h", history: moves, branch: "main", runs: runs, now: 101) }
        // Still in flight at the entry's time.
        #expect(judge([run("commit", "h", nil, 99, nil, user: false)]).team == true)
        // Started before it, ended within the slack after it, wherever it says it ended.
        #expect(judge([run("merge", "h", "h", 98, 101.5, user: false)]).team == true)
        // Ended before it, or started after it: not the team's.
        #expect(judge([run("commit", "h", "h", 90, 97, user: false)]).team == nil)
        #expect(judge([run("commit", "u", nil, 103, nil, user: false)]).team == nil)
        // The guard itself is unchanged: none of these is taken.
        #expect(!judge([run("commit", "h", nil, 99, nil, user: false)]).accepted)
    }

    @Test func aCommandOfYoursOnlyAccountsForWhatItCouldHaveMade() {
        let moves = history([("h", "u", 100, "commit: yours")], parents: ["u": ["h"]])
        // Finished before the entry was written; another kind of command; another branch; a worker's beside yours.
        #expect(!LeadVault.judge(from: "h", history: moves, branch: "main", runs: [run("commit", "h", "u", 90, 95)], now: 101).accepted)
        #expect(!LeadVault.judge(from: "h", history: moves, branch: "main", runs: [run("pull", "h", "u", 99, 101)], now: 101).accepted)
        let merge = history([("h", "u", 100, "merge side: Fast-forward")], parents: ["u": ["h"]])
        #expect(!LeadVault.judge(from: "h", history: merge, branch: "main", runs: [run("cherry-pick", "h", "u", 99, 101)], now: 101).accepted)
        var elsewhere = run("commit", "h", "u", 99, 101)
        elsewhere.branch = "side"
        #expect(!LeadVault.judge(from: "h", history: moves, branch: "main", runs: [elsewhere], now: 101).accepted)
        #expect(!LeadVault.judge(from: "h", history: moves, branch: "main", runs: [run("commit", "h", "u", 99, 101), run("commit", "h", "u", 99, 101, user: false)],
                                 now: 101).accepted)
        // A commit that isn't one on the head before it (a plumbing move with a commit's message).
        let plumbing = history([("h", "w", 100, "commit: fix")], parents: ["u": ["h"], "w": ["u"]])
        #expect(!LeadVault.judge(from: "h", history: plumbing, branch: "main", runs: [run("commit", "h", "w", 99, 101)], now: 101).accepted)
    }

    @Test func theReflogMustLeadBackToWhereTheLeadLeftIt() {
        let moves = history([("x", "u", 100, "commit: yours")], parents: ["u": ["h"]])
        let move = LeadVault.judge(from: "h", history: moves, branch: "main", runs: [run("commit", "h", "u", 99, 101)], now: 101)
        #expect(!move.accepted)
        #expect(move.reason?.contains("reflog") == true)
    }

    // MARK: The hooks' side

    @Test func theCommandsThatCanMoveABranchAreFoundInAShellLine() {
        func found(_ line: String, cwd: String = "/r") -> [String] { GitMoves.commands(in: line, cwd: cwd).map { "\($0.verb) \($0.folder)" } }
        #expect(found("git add -A && git commit -m 'a && b; git pull'") == ["commit /r"])
        #expect(found("cd sub && git -C ../other merge side") == ["merge /r/other"])
        #expect(found("GIT_EDITOR=true git -c core.x=y --no-pager cherry-pick abc | tail -3") == ["cherry-pick /r"])
        #expect(found("git status; git log --oneline; echo git commit") == [])
        #expect(found("git revert HEAD\ngit am < p.patch\n/usr/bin/git pull --ff-only") == ["revert /r", "am /r", "pull /r"])
        #expect(found("cd /abs && git commit -m x", cwd: "/elsewhere") == ["commit /abs"])
    }

    @Test func onlyShellToolCallsBeforeAndAfterTheyRunAreSteps() {
        let checkout: (String) -> (root: String, branch: String, head: String)? = { _ in ("/r", "main", "abc") }
        let pre: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "git commit -m x"], "cwd": "/r",
                                  "tool_use_id": "t1"]
        let steps = GitMoves.steps(for: pre, checkout: checkout)
        #expect(steps.count == 1)
        #expect(steps.first?.root == "/r")
        #expect(steps.first?.step == LeadVault.GitStep(phase: .before, call: "t1", verb: "commit", branch: "main", head: "abc"))
        var post = pre
        post["hook_event_name"] = "PostToolUse"
        #expect(GitMoves.steps(for: post, checkout: checkout).first?.step.phase == .after)
        var other = pre
        other["tool_name"] = "Edit"
        #expect(GitMoves.steps(for: other, checkout: checkout).isEmpty)
        other = pre
        other["hook_event_name"] = "Stop"
        #expect(GitMoves.steps(for: other, checkout: checkout).isEmpty)
    }

    @Test func theRecordsAreKeptOnlyWhereALeadWorksAndSurviveTheHostsRestart() throws {
        let root = try repo()
        let elsewhere = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        try ran("git commit -m one", in: elsewhere, as: yours) { try commit("c.txt", "see\n", in: elsewhere) }
        try ran("git commit -m one", in: root, as: yours) { try commit("c.txt", "see\n", in: root) }
        // The host keeps its vault sealed on disk: a new host reads the records back.
        let restored = LeadVault.Book(restoring: book.serialized)
        let again = restored.vault(folder: vault.folder, as: { .app })
        #expect(try again.acceptMove(root: root, branch: "main").accepted)
        #expect(!String(decoding: book.serialized, as: UTF8.self).contains(LeadVault.key(elsewhere)))
    }
}
