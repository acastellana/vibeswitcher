import Foundation
import Testing
@testable import VibeCore

struct WorktreesTests {
    /// A repository on `main` with one commit.
    func repo() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)")
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

    @Test func aPassingBranchFastForwardsMainAndIsCleanedUp() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "add-b")
        try commit("b.txt", "bee\n", in: worktree)
        // main moved meanwhile: the branch is rebased onto it first.
        try commit("c.txt", "sea\n", in: root)
        let checked = Worktrees.rebaseAndTest(root: root, slug: "add-b", test: "test -f b.txt && test -f c.txt")
        guard case .passed(let tested) = checked else { Issue.record("\(checked)"); return }
        #expect(try Worktrees.merge(root: root, slug: "add-b", commit: tested) == .merged)
        #expect(FileManager.default.fileExists(atPath: root + "/b.txt"))
        try Worktrees.remove(root: root, slug: "add-b")
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(Git.run(["branch", "--list", "agent/add-b"], in: root).output.isEmpty)
    }

    @Test func failingTestsAndConflictsAreReported() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "x")
        try commit("a.txt", "worker\n", in: worktree)
        #expect(Worktrees.rebaseAndTest(root: root, slug: "x", test: "false").isFailure)
        try commit("a.txt", "main\n", in: root)
        #expect(Worktrees.rebaseAndTest(root: root, slug: "x", test: "true") == .conflict)
        // The aborted rebase leaves the branch as it was.
        #expect(try String(contentsOfFile: worktree + "/a.txt", encoding: .utf8) == "worker\n")
    }

    func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("wt-scratch-\(UUID().uuidString)/merge") }

    @Test func anAuditedCommitWithoutMergesIsRebasedCommitByCommit() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "l")
        try commit("l.txt", "l\n", in: worktree)
        try commit("m.txt", "m\n", in: worktree)
        try commit("c.txt", "c\n", in: root)
        let main = Git.run(["rev-parse", "main"], in: root).output
        let tip = Git.run(["rev-parse", "HEAD"], in: worktree).output
        guard case .passed(let tested) = Worktrees.rebaseAndTest(root: root, commit: tip, onto: main, test: "test -f l.txt", scratch: scratch())
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
                                                                 scratch: scratch())
        else { Issue.record("not passed"); return }
        #expect(Git.run(["rev-parse", "\(tested)~1"], in: root).output == main)
        #expect(Git.run(["rev-list", "--merges", tested], in: root).output.isEmpty)
        #expect(Git.run(["show", "\(tested):a.txt"], in: root).output == "worker and main")
        #expect(Git.run(["log", "-1", "--format=%B", tested], in: root).output == "change a.txt\n\n- change s.txt")
        // A merge whose changes conflict with the base is still a conflict.
        try commit("s.txt", "main's s\n", in: root)
        let moved = Git.run(["rev-parse", "main"], in: root).output
        #expect(Worktrees.rebaseAndTest(root: root, commit: tip, onto: moved, test: "true", scratch: scratch()) == .conflict)
    }

    @Test func mergingRefusesADirtyMainCheckout() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "y")
        try commit("y.txt", "y\n", in: worktree)
        try "local edit\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        #expect(try Worktrees.merge(root: root, slug: "y") == .refused("The main checkout has uncommitted changes; commit or stash them first."))
        #expect(try String(contentsOfFile: root + "/a.txt", encoding: .utf8) == "local edit\n")
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
        guard case .passed(let tested) = Worktrees.rebaseAndTest(root: root, slug: "t", test: "true") else { Issue.record("not passed"); return }
        // The worker commits again while the tests run: that commit was never tested.
        try commit("late.txt", "late\n", in: worktree)
        #expect(try Worktrees.merge(root: root, slug: "t", commit: tested) == .merged)
        #expect(Git.run(["rev-parse", "main"], in: root).output == tested)
        #expect(!FileManager.default.fileExists(atPath: root + "/late.txt"))
    }

    @Test func uncommittedWorkIsNotTakenForAConflict() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "d")
        try commit("d.txt", "d\n", in: worktree)
        try "editing\n".write(toFile: worktree + "/d.txt", atomically: true, encoding: .utf8)
        guard case .error(let text) = Worktrees.rebaseAndTest(root: root, slug: "d", test: "true") else { Issue.record("not an error"); return }
        #expect(text.contains("uncommitted"))
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
    @Test func aRepositoryWhoseGitIsAFileIsExcludedToo() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["commit", "-q", "--allow-empty", "-m", "first"]] {
            Git.run(args, in: root)
        }
        // A worktree: its .git is a file pointing at the main repository.
        let other = root + "-wt"
        Git.run(["worktree", "add", "-q", "-b", "side", other], in: root)
        try BoardStore(root: other).ensureExcluded()
        #expect(Git.run(["check-ignore", "-q", ".vibeswitcher/board.json"], in: other).ok)
    }
}

struct ShellTests {
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let run = runUntilTimedOut("sleep \(Self.childRuns) & echo $! > child; wait", in: dir)
        #expect(run.took < hangGuard)
        let child = try #require(run.child)
        #expect(eventually { kill(child, 0) != 0 })
    }

    @Test func aCommandThatIgnoresTermIsKilled() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let run = runUntilTimedOut("trap '' TERM; sleep \(Self.childRuns) & echo $! > child; wait", in: dir, grace: 1)
        // It returned long before its child would have ended: the child was killed, not waited for.
        #expect(run.took < hangGuard)
        let child = try #require(run.child)
        #expect(eventually { kill(child, 0) != 0 })
    }

    @Test func aChildLeftBehindByItsParentIsKilledToo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // The shell dies on TERM; the child it started ignores TERM and is left to launchd (still holding the output
        // pipe, so the call would wait for it).
        let run = runUntilTimedOut("(trap '' TERM; exec sleep \(Self.childRuns)) & echo $! > child; wait", in: dir, grace: 1)
        #expect(run.took < hangGuard)
        let child = try #require(run.child)
        #expect(eventually { kill(child, 0) != 0 })
    }
}

