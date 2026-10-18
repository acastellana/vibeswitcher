import Foundation
import Testing
@testable import VibeCore

struct GitBranchTests {
    let temp = Scratch()
    func folder() throws -> URL {
        let url = temp.url("gitbranch")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func readsTheBranchFromHEAD() throws {
        let repo = try folder()
        try write("ref: refs/heads/feature/x\n", to: repo.appendingPathComponent(".git/HEAD"))
        #expect(GitBranch.current(in: repo.path) == "feature/x")
    }

    @Test func walksUpFromASubfolder() throws {
        let repo = try folder()
        try write("ref: refs/heads/main\n", to: repo.appendingPathComponent(".git/HEAD"))
        let sub = repo.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(GitBranch.current(in: sub.path) == "main")
    }

    @Test func detachedHeadShowsAShortHash() throws {
        let repo = try folder()
        try write("0123456789abcdef0123456789abcdef01234567\n", to: repo.appendingPathComponent(".git/HEAD"))
        #expect(GitBranch.current(in: repo.path) == "0123456")
    }

    @Test func followsAWorktreeGitFile() throws {
        let base = try folder()
        try write("ref: refs/heads/wt-branch\n", to: base.appendingPathComponent("main/.git/worktrees/wt/HEAD"))
        let tree = base.appendingPathComponent("wt")
        try write("gitdir: ../main/.git/worktrees/wt\n", to: tree.appendingPathComponent(".git"))
        #expect(GitBranch.current(in: tree.path) == "wt-branch")
    }

    @Test func noRepositoryMeansNoBranch() throws {
        let plain = try folder()
        #expect(GitBranch.current(in: plain.appendingPathComponent("missing").path) == nil)
        #expect(GitBranch.current(in: plain.path) == nil)
    }
}
