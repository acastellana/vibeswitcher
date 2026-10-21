import Foundation
import Testing
@testable import VibeCore

struct WorktreesTests {
    let temp = Scratch()
    /// A repository on `main` with one commit.
    func repo() throws -> String {
        let url = temp.url("wt")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] {
            _ = Git.run(args, in: root)
        }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        _ = Git.run(["add", "a.txt"], in: root)
        _ = Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func commit(_ file: String, _ text: String, in dir: String) throws {
        try text.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        _ = Git.run(["add", file], in: dir)
        _ = Git.run(["commit", "-q", "-m", "change \(file)"], in: dir)
    }

    @Test func aWorkerGetsItsOwnWorktreeAndBranch() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "add-b")
        #expect(worktree == root + "/.vibeswitcher/worktrees/add-b")
        #expect(Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree).output == "agent/add-b")
        #expect(Worktrees.mainBranch(root: root) == "main")
    }

    func scratch() -> URL { temp.url("wt-scratch").appendingPathComponent("merge") }

    /// The test and build lock a merge's tests take: a scratch one, never the Mac-wide one other runs hold.
    var lock: TestLock { TestLock(directory: temp.url("wt-lock").path) }

    /// The heads of `main` and of `slug`'s branch.
    func heads(_ root: String, _ slug: String) -> (main: String, tip: String) {
        (Git.run(["rev-parse", "main"], in: root).output, Git.run(["rev-parse", Worktrees.branch(slug)], in: root).output)
    }

    /// The worktrees git lists for `root`, its own checkout included.
    func listed(_ root: String) -> [String] {
        Git.run(["worktree", "list", "--porcelain"], in: root).output.components(separatedBy: "\n")
            .filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst("worktree ".count)) }
    }

    @Test func aPassingBranchFastForwardsMainAndIsCleanedUp() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "add-b")
        try commit("b.txt", "bee\n", in: worktree)
        // main moved meanwhile: the branch is rebased onto it first.
        try commit("c.txt", "sea\n", in: root)
        let (main, tip) = heads(root, "add-b")
        let scratch = scratch()
        let checked = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "test -f b.txt && test -f c.txt", scratch: scratch, lock: lock)
        guard case .passed(let tested) = checked else { Issue.record("\(checked)"); return }
        #expect(Worktrees.fastForward(root: root, base: "main", to: tested, from: main) == .merged)
        #expect(FileManager.default.fileExists(atPath: root + "/b.txt"))
        // The scratch worktree the checks ran in is gone, from the disk and from git's list.
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(listed(root).count == 2)
        try Worktrees.remove(root: root, slug: "add-b", force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(Git.run(["branch", "--list", "agent/add-b"], in: root).output.isEmpty)
    }

    /// The merge's commands run with HOME, CFFIXED_USER_HOME and TMPDIR in a scratch folder of their own, made before
    /// and removed after: never the user's own home (~/.vibeswitcher, the Keychain, app.log). A failure's output
    /// starts by naming it.
    @Test func theCommandsRunWithAScratchHomeRemovedAfterwards() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "h")
        try commit("h.txt", "h\n", in: worktree)
        let (main, tip) = heads(root, "h")
        let home = temp.url("merge-home")
        let marks = temp.url("home-marks").path
        try FileManager.default.createDirectory(atPath: marks, withIntermediateDirectories: true)
        // What each command sees, and what it leaves there (a log and a temporary file).
        func seen(_ name: String) -> String {
            "printf '%s\\n' \"$HOME\" \"$CFFIXED_USER_HOME\" \"$TMPDIR\" > \(marks)/\(name)"
                + " && mkdir -p \"$HOME/.vibeswitcher\" && echo host >> \"$HOME/.vibeswitcher/app.log\" && touch \"$TMPDIR/left\""
        }
        let checked = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, setup: seen("init"), test: seen("test"),
                                              scratch: scratch(), home: home, lock: lock)
        guard case .passed = checked else { Issue.record("\(checked)"); return }
        let expected = [home.path, home.path, home.path + "/tmp/"]
        for name in ["init", "test"] {
            let lines = try String(contentsOfFile: "\(marks)/\(name)", encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(lines == expected, "\(name): \(lines)")
        }
        #expect(!FileManager.default.fileExists(atPath: home.path))
        // A failed run: its output names the folder, and that goes too.
        guard case .failed(let output) = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: seen("failed") + " && false",
                                                                 scratch: scratch(), home: home, lock: lock)
        else { Issue.record("it passed"); return }
        #expect(output.hasPrefix("HOME, CFFIXED_USER_HOME and TMPDIR: \(home.path) (a scratch folder, removed afterwards)\n"), "\(output)")
        #expect(!FileManager.default.fileExists(atPath: home.path))
        // A failed init_command says so first, as before.
        guard case .failed(let setup) = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, setup: "false", test: "true",
                                                                scratch: scratch(), home: home, lock: lock)
        else { Issue.record("it passed"); return }
        #expect(setup.hasPrefix("init_command failed:\nHOME, CFFIXED_USER_HOME and TMPDIR: \(home.path)"), "\(setup)")
        // One left by a run that died with its process: emptied before the next.
        try FileManager.default.createDirectory(atPath: home.path + "/stale", withIntermediateDirectories: true)
        #expect(Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "test ! -e \"$HOME/stale\"", scratch: scratch(), home: home, lock: lock)
            == .passed(tip))
        #expect(!FileManager.default.fileExists(atPath: home.path))
        // Without one given, it's next to the scratch worktree.
        let place = scratch()
        let beside = place.deletingLastPathComponent().appendingPathComponent("merge-home").path
        #expect(Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "test \"$HOME\" = \(beside)", scratch: place, lock: lock) == .passed(tip))
        #expect(!FileManager.default.fileExists(atPath: beside))
        #expect(listed(root).count == 2)
    }

    @Test func failingTestsAndConflictsAreReported() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "x")
        try commit("a.txt", "worker\n", in: worktree)
        var (main, tip) = heads(root, "x")
        #expect(Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "false", scratch: scratch(), lock: lock).isFailure)
        try commit("a.txt", "main\n", in: root)
        (main, tip) = heads(root, "x")
        #expect(Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "true", scratch: scratch(), lock: lock) == .conflict)
        // The branch and its worktree are left as they were.
        #expect(try String(contentsOfFile: worktree + "/a.txt", encoding: .utf8) == "worker\n")
        #expect(heads(root, "x").tip == tip)
    }

    @Test func anAuditedCommitWithoutMergesIsRebasedCommitByCommit() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "l")
        try commit("l.txt", "l\n", in: worktree)
        try commit("m.txt", "m\n", in: worktree)
        try commit("c.txt", "c\n", in: root)
        let main = Git.run(["rev-parse", "main"], in: root).output
        let tip = Git.run(["rev-parse", "HEAD"], in: worktree).output
        guard case .passed(let tested) = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "test -f l.txt", scratch: scratch(), lock: lock)
        else { Issue.record("not passed"); return }
        #expect(Git.run(["log", "--format=%s", "\(main)..\(tested)"], in: root).output == "change m.txt\nchange l.txt")
        #expect(Git.run(["rev-parse", "\(tested)~2"], in: root).output == main)
    }

    @Test func anAuditedCommitThatMergedTheBaseInLandsAsOneCommitOnTopOfIt() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "s")
        try commit("a.txt", "worker\n", in: worktree)
        try commit("s.txt", "s\n", in: worktree)
        try commit("a.txt", "main\n", in: root)
        // The worker merges main in and resolves; main moves on again meanwhile, without conflict.
        #expect(!Git.run(["merge", "main"], in: worktree).ok)
        try "worker and main\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: worktree)
        #expect(Git.run(["commit", "-q", "--no-edit"], in: worktree).ok)
        try commit("c.txt", "c\n", in: root)
        let main = Git.run(["rev-parse", "main"], in: root).output
        let tip = Git.run(["rev-parse", "HEAD"], in: worktree).output
        // A rebase would replay the first commit onto main and conflict again; the branch is squashed instead.
        guard case .passed(let tested) = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "test -f c.txt && test -f s.txt",
                                                                 scratch: scratch(), lock: lock)
        else { Issue.record("not passed"); return }
        #expect(Git.run(["rev-parse", "\(tested)~1"], in: root).output == main)
        #expect(Git.run(["rev-list", "--merges", tested], in: root).output.isEmpty)
        #expect(Git.run(["show", "\(tested):a.txt"], in: root).output == "worker and main")
        #expect(Git.run(["log", "-1", "--format=%B", tested], in: root).output == "change a.txt\n\n- change s.txt")
        // A merge whose changes conflict with the base is still a conflict.
        try commit("s.txt", "main's s\n", in: root)
        let moved = Git.run(["rev-parse", "main"], in: root).output
        #expect(Worktrees.rebaseAndTest(root: root, commit: tip, onto: moved, test: "true", scratch: scratch(), lock: lock) == .conflict)
    }

    /// The user's own work in progress in the main checkout, on files the merge doesn't change, doesn't stop it,
    /// and is there afterwards as it was: modified, not staged.
    @Test func uncommittedChangesTheMergeDoesntTouchStay() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "y")
        try commit("y.txt", "y\n", in: worktree)
        try "local edit\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try "mine\n".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        #expect(try Worktrees.merge(root: root, slug: "y") == .merged)
        #expect(Git.run(["rev-parse", "main"], in: root).output == heads(root, "y").tip)
        #expect(try String(contentsOfFile: root + "/y.txt", encoding: .utf8) == "y\n")
        #expect(try String(contentsOfFile: root + "/a.txt", encoding: .utf8) == "local edit\n")
        #expect(Git.run(["status", "--porcelain", "--", "a.txt", "notes.txt"], in: root).output == "M a.txt\n?? notes.txt")
        #expect(Git.run(["diff", "--cached", "--name-only"], in: root).output.isEmpty)
    }

    @Test func anUnstagedChangeToAFileTheMergeChangesIsRefusedByName() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "y")
        try commit("a.txt", "worker\n", in: worktree)
        let before = Git.run(["rev-parse", "main"], in: root).output
        try "local edit\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        #expect(try Worktrees.merge(root: root, slug: "y") == .refused(
            "The main checkout has uncommitted changes to a file this merge changes: a.txt (modified). Commit or stash it first; the checkout's other uncommitted changes can stay."))
        #expect(Git.run(["rev-parse", "main"], in: root).output == before)
        #expect(try String(contentsOfFile: root + "/a.txt", encoding: .utf8) == "local edit\n")
    }

    @Test func aStagedChangeToAFileTheMergeChangesIsRefused() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "y")
        try commit("a.txt", "worker\n", in: worktree)
        try "staged edit\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        guard case .refused(let reason) = try Worktrees.merge(root: root, slug: "y") else { Issue.record("merged over a staged change"); return }
        #expect(reason.contains(": a.txt (staged)."), "\(reason)")
        // Staged and then edited again: both.
        try "edited again\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        guard case .refused(let both) = try Worktrees.merge(root: root, slug: "y") else { Issue.record("merged over a staged change"); return }
        #expect(both.contains(": a.txt (staged and modified)."), "\(both)")
        #expect(try String(contentsOfFile: root + "/a.txt", encoding: .utf8) == "edited again\n")
    }

    @Test func anUntrackedFileWhereTheMergeAddsOneIsRefusedByName() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "y")
        try FileManager.default.createDirectory(atPath: worktree + "/new", withIntermediateDirectories: true)
        try commit("new/y.txt", "y\n", in: worktree)
        try FileManager.default.createDirectory(atPath: root + "/new", withIntermediateDirectories: true)
        try "mine\n".write(toFile: root + "/new/y.txt", atomically: true, encoding: .utf8)
        #expect(try Worktrees.merge(root: root, slug: "y") == .refused(
            "The main checkout has uncommitted changes to a file this merge changes: new/y.txt (untracked). Commit or stash it first; the checkout's other uncommitted changes can stay."))
        #expect(try String(contentsOfFile: root + "/new/y.txt", encoding: .utf8) == "mine\n")
    }

    /// Of several uncommitted files, only the one the merge changes is named.
    @Test func onlyTheOverlappingFilesAreNamed() throws {
        let root = try repo()
        try commit("c.txt", "c\n", in: root)
        let worktree = try Worktrees.create(root: root, slug: "y")
        try commit("c.txt", "worker's c\n", in: worktree)
        try commit("y.txt", "y\n", in: worktree)
        try "local edit\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try "mine\n".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        try "staged\n".write(toFile: root + "/d.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "d.txt"], in: root)
        try "my c\n".write(toFile: root + "/c.txt", atomically: true, encoding: .utf8)
        guard case .refused(let reason) = try Worktrees.merge(root: root, slug: "y") else { Issue.record("merged over c.txt"); return }
        #expect(reason == "The main checkout has uncommitted changes to a file this merge changes: c.txt (modified). Commit or stash it first; the checkout's other uncommitted changes can stay.")
        // Two of them: both named, in order.
        try "my y\n".write(toFile: root + "/y.txt", atomically: true, encoding: .utf8)
        guard case .refused(let two) = try Worktrees.merge(root: root, slug: "y") else { Issue.record("merged over c.txt"); return }
        #expect(two == "The main checkout has uncommitted changes to files this merge changes: c.txt (modified), y.txt (untracked). Commit or stash them first; the checkout's other uncommitted changes can stay.")
    }

    /// What the overlap doesn't see, git still does: --ff-only moves the branch, and overwrites nothing.
    @Test func gitStillRefusesWhatTheOverlapMisses() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "y")
        try FileManager.default.createDirectory(atPath: worktree + "/new", withIntermediateDirectories: true)
        try commit("new/y.txt", "y\n", in: worktree)
        let before = Git.run(["rev-parse", "main"], in: root).output
        // An untracked file where the merge needs a folder: not a path the merge changes, but in its way.
        try "mine\n".write(toFile: root + "/new", atomically: true, encoding: .utf8)
        guard case .refused(let reason) = try Worktrees.merge(root: root, slug: "y") else { Issue.record("merged over new"); return }
        #expect(!reason.isEmpty)
        #expect(Git.run(["rev-parse", "main"], in: root).output == before)
        #expect(try String(contentsOfFile: root + "/new", encoding: .utf8) == "mine\n")
    }

    /// A rename in the main checkout counts by both names; one the merge makes changes both its paths.
    @Test func renamesOverlapByBothNames() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "y")
        try commit("a.txt", "worker\n", in: worktree)
        Git.run(["mv", "a.txt", "r.txt"], in: root)
        guard case .refused(let old) = try Worktrees.merge(root: root, slug: "y") else { Issue.record("merged over a rename"); return }
        #expect(old.contains(": a.txt (staged)."), "\(old)")
        Git.run(["mv", "r.txt", "a.txt"], in: root)
        let other = try Worktrees.create(root: root, slug: "m")
        Git.run(["mv", "a.txt", "moved.txt"], in: other)
        Git.run(["commit", "-q", "-m", "move a"], in: other)
        try "mine\n".write(toFile: root + "/moved.txt", atomically: true, encoding: .utf8)
        guard case .refused(let new) = try Worktrees.merge(root: root, slug: "m") else { Issue.record("merged over moved.txt"); return }
        #expect(new.contains(": moved.txt (untracked)."), "\(new)")
        try FileManager.default.removeItem(atPath: root + "/moved.txt")
        try "local edit\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        guard case .refused(let gone) = try Worktrees.merge(root: root, slug: "m") else { Issue.record("merged over a.txt"); return }
        #expect(gone.contains(": a.txt (modified)."), "\(gone)")
    }

    @Test func aBranchBehindMainIsNotMergedBlindly() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "z")
        try commit("z.txt", "z\n", in: worktree)
        try commit("other.txt", "o\n", in: root)
        if case .refused = try Worktrees.merge(root: root, slug: "z") {} else { Issue.record("merged a branch that isn't on top of main") }
    }

    @Test func onlyTheTestedCommitReachesMain() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "t")
        try commit("t.txt", "t\n", in: worktree)
        let (main, tip) = heads(root, "t")
        guard case .passed(let tested) = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "true", scratch: scratch(), lock: lock)
        else { Issue.record("not passed"); return }
        // The worker commits again while the tests run: that commit was never tested.
        try commit("late.txt", "late\n", in: worktree)
        #expect(Worktrees.fastForward(root: root, base: "main", to: tested, from: main) == .merged)
        #expect(Git.run(["rev-parse", "main"], in: root).output == tested)
        #expect(!FileManager.default.fileExists(atPath: root + "/late.txt"))
    }

    @Test func uncommittedWorkIsNotTakenForAConflict() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "d")
        try commit("d.txt", "d\n", in: worktree)
        try "editing\n".write(toFile: worktree + "/d.txt", atomically: true, encoding: .utf8)
        // The commit is tested where no one works: the worker's edit is neither a conflict nor tested, and stays.
        let (main, tip) = heads(root, "d")
        let checked = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "test \"$(cat d.txt)\" = d", scratch: scratch(), lock: lock)
        guard case .passed = checked else { Issue.record("\(checked)"); return }
        #expect(try String(contentsOfFile: worktree + "/d.txt", encoding: .utf8) == "editing\n")
    }

    @Test func aStrayFolderIsNotTakenForTheWorktree() throws {
        let root = try repo()
        let path = Worktrees.path(root: root, slug: "s")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        #expect(!Worktrees.isWorktree(root: root, slug: "s"))
        // An empty leftover is replaced by a real worktree; one with files in it is left alone.
        #expect(try Worktrees.open(root: root, slug: "s") == path)
        #expect(Worktrees.isWorktree(root: root, slug: "s"))
        let other = Worktrees.path(root: root, slug: "o")
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try "mine\n".write(toFile: other + "/notes.txt", atomically: true, encoding: .utf8)
        #expect(throws: Worktrees.Failure.self) { try Worktrees.open(root: root, slug: "o") }
        #expect(FileManager.default.fileExists(atPath: other + "/notes.txt"))
    }

    /// `slug`'s worktree with two commits on its branch (the first conflicting with main), stopped at that pick of an
    /// interactive rebase onto main, the conflict resolved and staged. The branch's head, from before.
    func stuckRebase(_ root: String, slug: String) throws -> String {
        let worktree = try Worktrees.create(root: root, slug: slug)
        try commit("a.txt", "worker\n", in: worktree)
        try commit("w.txt", "w\n", in: worktree)
        try commit("a.txt", "main\n", in: root)
        let rebase = Shell.run(executable: "/usr/bin/git", args: ["rebase", "-i", "main"], in: worktree,
                               env: ["GIT_TERMINAL_PROMPT": "0", "GIT_SEQUENCE_EDITOR": "true", "GIT_EDITOR": "true"])
        #expect(!rebase.ok)
        try "both\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: worktree)
        return Git.run(["rev-parse", "refs/heads/\(Worktrees.branch(slug))"], in: root).output
    }

    @Test func aWorktreeStuckMidRebaseIsDescribedThenRecoveredWithItsCommits() throws {
        let root = try repo()
        let head = try stuckRebase(root, slug: "r")
        let worktree = Worktrees.path(root: root, slug: "r")
        #expect(!Worktrees.isWorktree(root: root, slug: "r"))
        let stuck = try #require(Worktrees.interrupted(root: root, slug: "r"))
        #expect(stuck.kind == .rebase && stuck.head == head && stuck.unsafe == nil)
        #expect(stuck.step == 1 && stuck.steps == 2)
        #expect(stuck.staged == ["a.txt"] && stuck.conflicted.isEmpty)
        #expect(stuck.onto.hasSuffix("(main)"))
        #expect(stuck.description.contains("rebasing agent/r onto") && stuck.description.contains("pick 1 of 2"))
        // Without recover it's only described, and nothing moves.
        #expect(throws: Worktrees.Interrupted.self) { try Worktrees.open(root: root, slug: "r") }
        #expect(Worktrees.interrupted(root: root, slug: "r") != nil)
        #expect(try Worktrees.open(root: root, slug: "r", recover: true) == worktree)
        #expect(Worktrees.isWorktree(root: root, slug: "r"))
        #expect(Git.run(["rev-parse", "refs/heads/agent/r"], in: root).output == head)
        #expect(Git.run(["rev-parse", "HEAD"], in: worktree).output == head)
        #expect(Git.run(["status", "--porcelain"], in: worktree).output.isEmpty)
        #expect(Worktrees.interrupted(root: root, slug: "r") == nil)
    }

    @Test func aWorktreeStuckMidMergeIsRecoveredWithItsCommits() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "m")
        try commit("a.txt", "worker\n", in: worktree)
        try commit("a.txt", "main\n", in: root)
        let head = Git.run(["rev-parse", "HEAD"], in: worktree).output
        #expect(!Git.run(["merge", "main"], in: worktree).ok)
        let unresolved = try #require(Worktrees.interrupted(root: root, slug: "m"))
        #expect(unresolved.kind == .merge && unresolved.conflicted == ["a.txt"] && unresolved.onto.hasSuffix("(main)"))
        try "both\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: worktree)
        let stuck = try #require(Worktrees.interrupted(root: root, slug: "m"))
        #expect(stuck.staged == ["a.txt"] && stuck.conflicted.isEmpty && !stuck.detached && stuck.unsafe == nil)
        #expect(stuck.description.contains("merging") && stuck.description.contains("into agent/m"))
        // On the branch, it's the worker's to finish: opened as it is, the merge and its resolution kept.
        #expect(try Worktrees.open(root: root, slug: "m") == worktree)
        #expect(Worktrees.interrupted(root: root, slug: "m")?.staged == ["a.txt"])
        #expect(try String(contentsOfFile: worktree + "/a.txt", encoding: .utf8) == "both\n")
        #expect(try Worktrees.open(root: root, slug: "m", recover: true) == worktree)
        #expect(Git.run(["rev-parse", "refs/heads/agent/m"], in: root).output == head)
        #expect(Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree).output == "agent/m")
        #expect(!FileManager.default.fileExists(atPath: Git.run(["rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD"], in: worktree).output))
        #expect(try String(contentsOfFile: worktree + "/a.txt", encoding: .utf8) == "worker\n")
    }

    @Test func aMergeStartedDetachedAtTheBranchIsRecoveredOntoTheBranch() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "d")
        try commit("a.txt", "worker\n", in: worktree)
        try commit("a.txt", "main\n", in: root)
        let head = Git.run(["rev-parse", "HEAD"], in: worktree).output
        Git.run(["checkout", "-q", "--detach"], in: worktree)
        #expect(!Git.run(["merge", "main"], in: worktree).ok)
        let stuck = try #require(Worktrees.interrupted(root: root, slug: "d"))
        #expect(stuck.kind == .merge && stuck.detached)
        #expect(throws: Worktrees.Interrupted.self) { try Worktrees.open(root: root, slug: "d") }
        #expect(try Worktrees.open(root: root, slug: "d", recover: true) == worktree)
        #expect(Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree).output == "agent/d")
        #expect(Git.run(["rev-parse", "refs/heads/agent/d"], in: root).output == head)
    }

    @Test func aRebaseWhoseBranchMovedSinceIsNotAborted() throws {
        let root = try repo()
        _ = try stuckRebase(root, slug: "v")
        // Something put another commit on the branch meanwhile: aborting would set it back to where the rebase began.
        try commit("x.txt", "x\n", in: root)
        Git.run(["update-ref", "refs/heads/agent/v", "HEAD"], in: root)
        let moved = Git.run(["rev-parse", "refs/heads/agent/v"], in: root).output
        let stuck = try #require(Worktrees.interrupted(root: root, slug: "v"))
        #expect(stuck.unsafe != nil)
        #expect(throws: Worktrees.Failure.self) { try Worktrees.open(root: root, slug: "v", recover: true) }
        #expect(Git.run(["rev-parse", "refs/heads/agent/v"], in: root).output == moved)
        #expect(Worktrees.interrupted(root: root, slug: "v") != nil)
    }

    @Test func aFolderThatBelongsToSomethingElseIsStillRefused() throws {
        let root = try repo()
        // A repository of its own where the worktree would be, stuck mid-rebase, with the task's branch in the repo.
        Git.run(["branch", "agent/own"], in: root)
        let own = Worktrees.path(root: root, slug: "own")
        try FileManager.default.createDirectory(atPath: own, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "agent/own"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: own) }
        try commit("a.txt", "theirs\n", in: own)
        Git.run(["checkout", "-q", "-b", "side"], in: own)
        try commit("a.txt", "side\n", in: own)
        Git.run(["checkout", "-q", "agent/own"], in: own)
        try commit("a.txt", "other\n", in: own)
        #expect(!Git.run(["rebase", "side"], in: own).ok)
        #expect(Worktrees.interrupted(root: root, slug: "own") == nil)
        #expect(throws: Worktrees.Failure.self) { try Worktrees.open(root: root, slug: "own", recover: true) }
        #expect(FileManager.default.fileExists(atPath: Git.run(["rev-parse", "--path-format=absolute", "--git-path", "rebase-merge"], in: own).output))
        // This repository's worktree, stuck rebasing a branch that isn't the task's.
        let worktree = try Worktrees.create(root: root, slug: "t")
        Git.run(["checkout", "-q", "-b", "other"], in: worktree)
        try commit("a.txt", "other\n", in: worktree)
        try commit("a.txt", "main\n", in: root)
        #expect(!Git.run(["rebase", "main"], in: worktree).ok)
        #expect(Worktrees.interrupted(root: root, slug: "t") == nil)
        #expect(throws: Worktrees.Failure.self) { try Worktrees.open(root: root, slug: "t", recover: true) }
        #expect(FileManager.default.fileExists(atPath: Git.run(["rev-parse", "--path-format=absolute", "--git-path", "rebase-merge"], in: worktree).output))
    }

    /// A worktree on a branch made in it (for a review) goes back on the task's branch, the other branch kept, and
    /// says the commits there the task's branch doesn't have.
    @Test func aWorktreeOnAnotherBranchIsPutBackOnItsOwn() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "rv")
        try commit("b.txt", "bee\n", in: worktree)
        let head = Git.run(["rev-parse", "HEAD"], in: worktree).output
        #expect(Worktrees.offBranch(root: root, slug: "rv") == nil)
        Git.run(["switch", "-q", "-c", "review-rv"], in: worktree)
        try commit("r.txt", "review\n", in: worktree)
        let review = Git.run(["rev-parse", "HEAD"], in: worktree).output
        #expect(!Worktrees.isWorktree(root: root, slug: "rv"))
        let off = try #require(Worktrees.offBranch(root: root, slug: "rv"))
        #expect(off.on == "review-rv" && off.commit == review && off.branch == "agent/rv")
        #expect(off.ahead.count == 1 && off.ahead[0].hasSuffix("change r.txt") && off.uncommitted.isEmpty)
        #expect(off.mergeCommand == "git merge review-rv")
        #expect(off.description.contains("on branch review-rv at \(review.prefix(8)), not on agent/rv"))
        #expect(try Worktrees.putBack(root: root, slug: "rv") == off)
        #expect(Worktrees.isWorktree(root: root, slug: "rv"))
        #expect(Git.run(["rev-parse", "HEAD"], in: worktree).output == head)
        #expect(Git.run(["rev-parse", "refs/heads/review-rv"], in: root).output == review)
        #expect(Worktrees.offBranch(root: root, slug: "rv") == nil)
        #expect(throws: Worktrees.Failure.self) { try Worktrees.putBack(root: root, slug: "rv") }
    }

    /// Detached, with uncommitted files: described with them, and not switched unless they're carried along.
    @Test func aDetachedWorktreeWithUncommittedFilesIsNotSwitchedOverThem() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "dt")
        let head = Git.run(["rev-parse", "HEAD"], in: worktree).output
        Git.run(["switch", "-q", "--detach"], in: worktree)
        try "worker\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: worktree + "/new file.txt", atomically: true, encoding: .utf8)
        let off = try #require(Worktrees.offBranch(root: root, slug: "dt"))
        #expect(off.on == nil && off.commit == head && off.ahead.isEmpty)
        #expect(off.uncommitted == [Worktrees.Uncommitted(path: "a.txt", state: "modified"), Worktrees.Uncommitted(path: "new file.txt", state: "untracked")])
        #expect(off.description.contains("a detached HEAD") && off.description.contains("a.txt (modified), new file.txt (untracked)"))
        #expect(off.commitCommand == "`git add 'new file.txt'`, then `git commit -am \"<what they are>\"`")
        #expect(throws: Worktrees.OffBranch.self) { try Worktrees.putBack(root: root, slug: "dt") }
        #expect(Git.run(["symbolic-ref", "-q", "HEAD"], in: worktree).output.isEmpty)
        // Carried, they come along onto the branch, as they were.
        #expect(try Worktrees.putBack(root: root, slug: "dt", carry: true).uncommitted.count == 2)
        #expect(Worktrees.isWorktree(root: root, slug: "dt"))
        #expect(try String(contentsOfFile: worktree + "/a.txt", encoding: .utf8) == "worker\n")
        #expect(FileManager.default.fileExists(atPath: worktree + "/new file.txt"))
    }

    /// Carried files that the task's branch changes too: git refuses, and nothing moves.
    @Test func carriedFilesTheSwitchWouldOverwriteStopIt() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "ow")
        try commit("a.txt", "branch\n", in: worktree)
        Git.run(["switch", "-q", "--detach", "main"], in: worktree)
        try "uncommitted\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        #expect(throws: Worktrees.Failure.self) { try Worktrees.putBack(root: root, slug: "ow", carry: true) }
        #expect(Worktrees.offBranch(root: root, slug: "ow") != nil)
        #expect(try String(contentsOfFile: worktree + "/a.txt", encoding: .utf8) == "uncommitted\n")
    }

    /// Something in progress on the other branch isn't the task's to undo: not off-branch, as before.
    @Test func aWorktreeMidRebaseOfAnotherBranchIsntPutBack() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "ip")
        Git.run(["switch", "-q", "-c", "other"], in: worktree)
        try commit("a.txt", "other\n", in: worktree)
        try commit("a.txt", "main\n", in: root)
        #expect(!Git.run(["rebase", "main"], in: worktree).ok)
        #expect(Worktrees.offBranch(root: root, slug: "ip") == nil)
        #expect(throws: Worktrees.Failure.self) { try Worktrees.putBack(root: root, slug: "ip") }
    }

    /// A hook in the repository that fails, saying `text`.
    func failingHook(_ name: String, saying text: String, in root: String) throws {
        let hooks = Git.run(["rev-parse", "--path-format=absolute", "--git-path", "hooks"], in: root).output
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\necho '\(text)' >&2\nexit 1\n".write(toFile: hooks + "/" + name, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks + "/" + name)
    }

    /// E-15: a rebase stopped by something else than a conflict says what stopped it.
    @Test func aRebaseThatFailsWithoutAConflictSaysWhatFailed() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "h")
        try commit("h.txt", "h\n", in: worktree)
        try commit("c.txt", "c\n", in: root)
        let (main, tip) = heads(root, "h")
        // A base that isn't there.
        guard case .error(let missing) = Worktrees.rebaseAndTest(root: root, commit: tip, onto: "no-such-branch", test: "true", scratch: scratch(), lock: lock)
        else { Issue.record("not an error"); return }
        #expect(missing.contains("not on a conflict") && missing.contains("no-such-branch"), "\(missing)")
        // A hook that refuses the rebase.
        try failingHook("pre-rebase", saying: "pre-rebase hook says no", in: root)
        let scratch = scratch()
        guard case .error(let hooked) = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "true", scratch: scratch, lock: lock)
        else { Issue.record("not an error"); return }
        #expect(hooked.contains("pre-rebase hook says no") && !hooked.lowercased().contains("conflicts"), "\(hooked)")
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(listed(root).count == 2)
    }

    /// E-15: a branch that merged the base in is squashed; a hook that refuses that commit is said, not a conflict.
    @Test func aSquashThatFailsWithoutAConflictSaysWhatFailed() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "q")
        try commit("s.txt", "s\n", in: worktree)
        try commit("c.txt", "c\n", in: root)
        #expect(Git.run(["merge", "-q", "--no-edit", "main"], in: worktree).ok)
        try commit("d.txt", "d\n", in: root)
        try failingHook("pre-commit", saying: "pre-commit hook says no", in: root)
        let (main, tip) = heads(root, "q")
        let checked = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "true", scratch: scratch(), lock: lock)
        guard case .error(let text) = checked else { Issue.record("\(checked)"); return }
        #expect(text.contains("pre-commit hook says no"), "\(text)")
    }

    /// E-17: a test command that never ends is stopped at the time limit with what it started (also a child its shell
    /// left behind, outside its family but in its process group), and the scratch worktree goes.
    @Test func aTestCommandThatNeverEndsIsStoppedAsHung() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "n")
        try commit("n.txt", "n\n", in: worktree)
        let (main, tip) = heads(root, "n")
        let marks = temp.url("hung").path
        try FileManager.default.createDirectory(atPath: marks, withIntermediateDirectories: true)
        // The subshell exits at once: its sleep is launchd's child by the time the time limit comes.
        let test = "(sleep \(ShellTests.childRuns) & echo $! > \(marks)/child); echo started; sleep \(ShellTests.childRuns)"
        var timeout: TimeInterval = 2
        var child: Int32?, checked = Worktrees.Check.cancelled, took: TimeInterval = 0
        let scratch = scratch()
        // On a busy Mac the shell may not have started the child in time: given twice as long, until it has.
        while child == nil, timeout < hangGuard {
            let started = Date()
            checked = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: test, scratch: scratch, timeout: timeout, lock: lock)
            took = Date().timeIntervalSince(started)
            child = (try? String(contentsOfFile: marks + "/child", encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if child == nil { timeout *= 2 }
        }
        guard case .hung(let command, let after, let output) = checked else { Issue.record("\(checked)"); return }
        #expect(command == "test command" && after == timeout && output.contains("started"))
        #expect(took < hangGuard)
        let left = try #require(child)
        #expect(eventually { kill(left, 0) != 0 })
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(!FileManager.default.fileExists(atPath: scratch.path + "-home"))
        #expect(output.hasPrefix("HOME, CFFIXED_USER_HOME and TMPDIR: \(scratch.path)-home "), "\(output)")
        #expect(listed(root).count == 2)
    }

    /// E-12: a cancelled run stops its test command, removes its scratch worktree (git's list included) and says
    /// cancelled, not failed.
    @Test func aCancelledRunIsCancelledAndCleanedUp() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "k")
        try commit("k.txt", "k\n", in: worktree)
        let (main, tip) = heads(root, "k")
        let marks = temp.url("cancel").path
        try FileManager.default.createDirectory(atPath: marks, withIntermediateDirectories: true)
        let token = ShellCancel()
        let scratch = scratch()
        let result = Locked<Worktrees.Check?>(nil)
        Thread.detachNewThread {
            let checked = ShellCancel.with(token) {
                Worktrees.rebaseAndTest(root: root, commit: tip, onto: main,
                                        test: "sleep \(ShellTests.childRuns) & echo $! > \(marks)/child; wait", scratch: scratch, lock: lock)
            }
            result.set(checked)
        }
        #expect(eventually { FileManager.default.fileExists(atPath: marks + "/child") })
        token.cancel()
        #expect(eventually { result.get() != nil })
        #expect(result.get() == .cancelled)
        let child = try #require(Int32(try String(contentsOfFile: marks + "/child", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(eventually { kill(child, 0) != 0 })
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(!FileManager.default.fileExists(atPath: scratch.path + "-home"))
        #expect(listed(root).count == 2)
        // Cancelled before it began, nothing is set up.
        let early = ShellCancel()
        early.cancel()
        #expect(ShellCancel.with(early) { Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "true", scratch: scratch, lock: lock) } == .cancelled)
        #expect(listed(root).count == 2)
    }

    @Test func timeLimitsReadInMinutes() {
        #expect(Worktrees.duration(45 * 60) == "45 min")
        #expect(Worktrees.duration(2) == "2 s")
        #expect(Worktrees.testTimeout == 45 * 60)
    }

    @Test func aBranchLeftWithoutItsWorktreeIsCheckedOutAgain() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "b")
        try commit("b.txt", "b\n", in: worktree)
        _ = Git.run(["worktree", "remove", worktree], in: root)
        #expect(try Worktrees.open(root: root, slug: "b") == worktree)
        #expect(FileManager.default.fileExists(atPath: worktree + "/b.txt"))
    }
}

struct ExcludeTests {
    let temp = Scratch()
    @Test func aRepositoryWhoseGitIsAFileIsExcludedToo() throws {
        let url = temp.url("ex")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["commit", "-q", "--allow-empty", "-m", "first"]] {
            Git.run(args, in: root)
        }
        // A worktree: its .git is a file pointing at the main repository.
        let other = temp.adopt(URL(fileURLWithPath: root + "-wt")).path
        Git.run(["worktree", "add", "-q", "-b", "side", other], in: root)
        try BoardStore(root: other).ensureExcluded()
        #expect(Git.run(["check-ignore", "-q", ".vibeswitcher/board.json"], in: other).ok)
    }
}

struct ShellTests {
    let temp = Scratch()
    /// How long the children below run, in seconds: twice the hang guard, so a run that returns within the guard
    /// and a child gone within the guard after that mean the child was killed, not waited for or left to end.
    static let childRuns = Int(2 * hangGuard)

    /// Runs `script`, which starts a child and writes its pid to `child`, until `timeout` ends it. On a busy Mac the
    /// shell may not have got that far in the first second: then it's run again with twice the time, until it has.
    /// The child, and how long the run that started it took.
    func runUntilTimedOut(_ script: String, in dir: String, grace: TimeInterval = 5) -> (child: Int32?, took: TimeInterval) {
        var timeout: TimeInterval = 1
        while true {
            let started = Date()
            _ = Shell.run(executable: "/bin/sh", args: ["-c", script], in: dir, timeout: timeout, grace: grace)
            let took = Date().timeIntervalSince(started)
            let written = try? String(contentsOfFile: dir + "/child", encoding: .utf8)
            if let child = written.flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { return (child, took) }
            guard timeout < hangGuard else { return (nil, took) }
            timeout *= 2
        }
    }

    @Test func aTimedOutCommandTakesItsChildrenWithIt() throws {
        let dir = temp.url("shell").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let run = runUntilTimedOut("sleep \(Self.childRuns) & echo $! > child; wait", in: dir)
        #expect(run.took < hangGuard)
        let child = try #require(run.child)
        #expect(eventually { kill(child, 0) != 0 })
    }

    @Test func aCommandThatIgnoresTermIsKilled() throws {
        let dir = temp.url("shell").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let run = runUntilTimedOut("trap '' TERM; sleep \(Self.childRuns) & echo $! > child; wait", in: dir, grace: 1)
        // It returned long before its child would have ended: the child was killed, not waited for.
        #expect(run.took < hangGuard)
        let child = try #require(run.child)
        #expect(eventually { kill(child, 0) != 0 })
    }

    @Test func aChildLeftBehindByItsParentIsKilledToo() throws {
        let dir = temp.url("shell").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // The shell dies on TERM; the child it started ignores TERM and is left to launchd (still holding the output
        // pipe, so the call would wait for it).
        let run = runUntilTimedOut("(trap '' TERM; exec sleep \(Self.childRuns)) & echo $! > child; wait", in: dir, grace: 1)
        #expect(run.took < hangGuard)
        let child = try #require(run.child)
        #expect(eventually { kill(child, 0) != 0 })
    }

    /// E-17: a command that ends but leaves something holding its output open (a background job) isn't waited for
    /// without end: what it wrote is returned, and what it left is stopped with its process group.
    @Test func aBackgroundJobHoldingTheOutputIsNotWaitedFor() throws {
        let dir = temp.url("shell").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let started = Date()
        let run = Shell.run(executable: "/bin/sh", args: ["-c", "(sleep \(Self.childRuns) & echo $! > child); echo done"], in: dir, grace: 1)
        #expect(Date().timeIntervalSince(started) < hangGuard)
        #expect(run.ok && !run.timedOut && run.output == "done")
        let child = try #require(Int32(try String(contentsOfFile: dir + "/child", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(eventually { kill(child, 0) != 0 })
    }

    /// E-32: `signalFamily` stops a process and what it started (its children and theirs), each matched by pid and
    /// start time; a process outside the family, or one an earlier walk names that has since been replaced, is left be.
    /// Only processes this test started are signalled.
    @Test func signalFamilyStopsAProcessAndWhatItStartedAndNothingElse() throws {
        let dir = temp.url("family").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func start(_ executable: String, _ args: [String]) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
            try process.run()
            return process
        }
        func written(_ name: String) -> Int32? {
            (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        /// Running as it was when read: gone, or its pid another process's by now, is not.
        func running(_ process: ProcInfo) -> Bool { ProcessTable.info(pid: process.pid)?.startTime == process.startTime }
        // A shell, the leader of a process group of its own (Process starts it so), with a child and a grandchild that
        // ignore nothing; and a process outside it.
        let shell = try start("/bin/sh", ["-c", "sleep \(Self.childRuns) & echo $! > child; (sleep \(Self.childRuns) & echo $! > grandchild; wait) & wait"])
        let outsider = try start("/bin/sleep", ["\(Self.childRuns)"])
        defer {
            for process in [shell, outsider] where process.isRunning { kill(process.processIdentifier, SIGKILL) }
            for name in ["child", "grandchild"] { if let pid = written(name), getpgid(pid) == shell.processIdentifier { kill(pid, SIGKILL) } }
        }
        #expect(eventually { written("child") != nil && written("grandchild") != nil })
        let root = try #require(ProcessTable.info(pid: shell.processIdentifier))
        let child = try #require(written("child").flatMap(ProcessTable.info(pid:)))
        let grandchild = try #require(written("grandchild").flatMap(ProcessTable.info(pid:)))
        let other = try #require(ProcessTable.info(pid: outsider.processIdentifier))
        #expect(getpgid(root.pid) == root.pid && getpgid(child.pid) == root.pid && getpgid(grandchild.pid) == root.pid)
        #expect(getpgid(other.pid) != root.pid)

        // The outsider named by an earlier walk, but with another start time: a pid since given to another process.
        let replaced = ProcInfo(pid: other.pid, ppid: other.ppid, tty: other.tty, comm: other.comm,
                                startTime: other.startTime.addingTimeInterval(-60), agent: nil)
        let signalled = Shell.signalFamily(of: root.pid, SIGTERM, also: [replaced])
        #expect(Set([root.pid, child.pid, grandchild.pid]).isSubset(of: Set(signalled.map(\.pid))))
        // The shell is this process's child: it's gone once Process has reaped it.
        #expect(eventually { !shell.isRunning && !running(child) && !running(grandchild) })
        #expect(shell.terminationReason == .uncaughtSignal && shell.terminationStatus == SIGTERM)
        #expect(running(other) && outsider.isRunning)
        outsider.terminate()
        outsider.waitUntilExit()
    }

    @Test func aTimedOutRunSaysSoAndIsntOk() {
        let run = Shell.run(executable: "/bin/sleep", args: ["\(Self.childRuns)"], in: "/", timeout: 0.5, grace: 1)
        #expect(run.timedOut && !run.cancelled && !run.ok)
    }

    /// A shell that ignores TERM goes on after its time is up, answers and exits 0. What it wrote is kept (evidence of
    /// what it was doing) but the run isn't ok; Git.run, whose callers take its output as git's answer, gives none.
    /// On a busy Mac the shell may be stopped before it set its trap: then it's run again with twice the time.
    @Test func aLateAnswerIsNeverTheResult() throws {
        let dir = temp.url("shell").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var timeout: TimeInterval = 0.25
        var shell: Git.Result?
        while shell == nil, timeout < hangGuard {
            let run = Shell.run(executable: "/bin/sh", args: ["-c", "trap '' TERM; sleep \(2 * timeout); echo late"], in: dir,
                                timeout: timeout, grace: hangGuard)
            if run.timedOut, run.output == "late" { shell = run }
            timeout *= 2
        }
        let late = try #require(shell)
        #expect(late.status == 0 && !late.ok)

        Git.run(["init", "-q"], in: dir)
        timeout = 0.25
        var answered = false
        while !answered, timeout < hangGuard {
            let script = "trap '' TERM; sleep \(2 * timeout); echo late; echo > answered"
            let git = Git.run(["-c", "alias.late=!\(script)", "late"], in: dir, timeout: timeout, grace: hangGuard)
            answered = git.timedOut && FileManager.default.fileExists(atPath: dir + "/answered")
            #expect(!git.timedOut || (!git.ok && git.output.isEmpty && git.error.contains("stopped")))
            timeout *= 2
        }
        #expect(answered)
    }
}

/// A value shared between threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ new: Value) {
        lock.lock()
        value = new
        lock.unlock()
    }

    func change<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}


extension LeadToolsetTests {
    /// merge says the fast-forward's refusal as it is: the files in the main checkout it would change, and only those.
    @Test func mergeNamesTheUncommittedFilesItWouldChange() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        try "local edit\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try "mine\n".write(toFile: root + "/b.txt", atomically: true, encoding: .utf8)
        let refused = call(lead, "merge", ["task": "add-b"])
        #expect(refused.isError)
        #expect(refused.text == "Not merged: The main checkout has uncommitted changes to a file this merge changes: b.txt (untracked). Commit or stash it first; the checkout's other uncommitted changes can stay.", "\(refused.text)")
        #expect(try String(contentsOfFile: root + "/b.txt", encoding: .utf8) == "mine\n")
        try FileManager.default.removeItem(atPath: root + "/b.txt")
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(try String(contentsOfFile: root + "/b.txt", encoding: .utf8) == "bee\n")
        #expect(try String(contentsOfFile: root + "/a.txt", encoding: .utf8) == "local edit\n")
    }
}
