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
        #expect(checked == .passed)
        #expect(try Worktrees.merge(root: root, slug: "add-b") == .merged)
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
}
