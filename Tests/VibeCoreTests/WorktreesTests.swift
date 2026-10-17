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

struct ShellTests {
    @Test func aTimedOutCommandTakesItsChildrenWithIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = Shell.run(executable: "/bin/sh", args: ["-c", "sleep 30 & echo $! > child; wait"], in: dir, timeout: 1)
        let child = Int32((try String(contentsOfFile: dir + "/child", encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
        var gone = false
        for _ in 0..<50 where !gone {
            gone = kill(child, 0) != 0
            if !gone { usleep(100_000) }
        }
        #expect(gone)
    }
}
