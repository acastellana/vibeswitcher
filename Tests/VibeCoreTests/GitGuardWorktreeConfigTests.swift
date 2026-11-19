import Foundation
import Testing
@testable import VibeCore

/// The review of 2026-11-19: the node's git runs outside any box, on worktrees a box writes. With
/// `extensions.worktreeConfig` on, git reads `<own>/config.worktree` there, so a `core.fsmonitor` or a `core.hooksPath`
/// set in it would be a program the node runs as the user. A box can no longer write that file
/// (`SandboxPlannerTests.aWorkerCantWriteItsWorktreesGitConfig`); this is the other half: were one there all the same,
/// `Git.run` (every git the node starts on a worktree goes through it) runs neither.
struct GitGuardWorktreeConfigTests {
    let temp = Scratch()

    /// git as it is, with nothing guarded: how a repository is set up here before the guard has seen it, and how a
    /// planted program is shown to run at all.
    @discardableResult
    func plain(_ arguments: [String], in directory: String) -> Git.Result {
        Shell.run(executable: Platform.Tools.git, args: arguments, in: directory, env: Git.environment, timeout: 60, grace: 1)
    }

    /// A repository with one commit and a worker's worktree, `extensions.worktreeConfig` on, made by `git`: `plain`
    /// (the guard hasn't seen it) or `Git.run` (it has, in the main checkout, as the node's first git there does).
    func repository(_ name: String, git: ([String], String) -> Git.Result) throws -> (root: String, worktree: String) {
        let url = temp.url(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = SandboxPolicy.resolved(url.path)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"],
                          ["commit", "-q", "--allow-empty", "-m", "first"],
                          ["config", "core.repositoryFormatVersion", "1"], ["config", "extensions.worktreeConfig", "true"],
                          ["worktree", "add", "-q", "-b", "agent/w/head", ".vibeswitcher/worktrees/w"]] {
            let ran = git(arguments, root)
            #expect(ran.ok, "git \(arguments): \(ran.error)")
        }
        return (root, root + "/.vibeswitcher/worktrees/w")
    }

    func marks() throws -> String {
        let url = temp.url("marks")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SandboxPolicy.resolved(url.path)
    }

    func marked(_ marks: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: marks)) ?? []).sorted() }

    static let hooks = ["post-merge", "reference-transaction", "post-checkout", "pre-commit", "prepare-commit-msg", "commit-msg",
                        "post-commit", "pre-rebase", "post-rewrite", "pre-merge-commit", "post-index-change"]

    /// What a worker would plant in its worktree's own config: a fsmonitor program and a hooks folder of its own, each
    /// program marking `<marks>/<its name>` when it runs. Written with `plain`, straight into `config.worktree`.
    func plant(root: String, worktree: String, marks: String) throws {
        let planted = worktree + "/.planted"
        try FileManager.default.createDirectory(atPath: planted + "/hooks", withIntermediateDirectories: true)
        try installScript("#!/bin/sh\ntouch '\(marks)/fsmonitor'\n", atPath: planted + "/fsmonitor")
        for name in Self.hooks { try installScript("#!/bin/sh\ntouch '\(marks)/\(name)'\nexit 0\n", atPath: planted + "/hooks/" + name) }
        for (key, value) in [("core.fsmonitor", planted + "/fsmonitor"), ("core.hooksPath", planted + "/hooks")] {
            #expect(plain(["config", "--worktree", key, value], in: worktree).ok)
        }
        let config = try String(contentsOfFile: root + "/.git/worktrees/w/config.worktree", encoding: .utf8)
        #expect(config.contains("fsmonitor") && config.contains("hooksPath"), "\(config)")
    }

    /// The node's git steps on a worker's worktree: the reads (status, diff), and the ones that would run a hook (a
    /// commit, a checkout, a merge, a rebase).
    func nodesGit(in worktree: String) throws {
        try "one\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        for arguments in [["status", "--porcelain=v2", "-z", "--untracked-files=all"], ["add", "a.txt"], ["diff", "--cached", "--stat"],
                          ["commit", "-q", "-m", "a"], ["checkout", "-q", "-b", "agent/w/other"],
                          ["commit", "-q", "--allow-empty", "-m", "b"], ["checkout", "-q", "agent/w/head"],
                          ["merge", "-q", "--no-ff", "-m", "merged", "agent/w/other"], ["rebase", "-q", "main"],
                          ["status", "--porcelain=v2"]] {
            let ran = Git.run(arguments, in: worktree)
            #expect(ran.ok, "git \(arguments): \(ran.error)")
        }
    }

    /// The node's first git in a repository is in its main checkout (the engine's start, `start_worker`'s
    /// `worktree add`), so the guard has seen it by the time a worker's worktree is there.
    @Test func theNodesGitOnAWorkersWorktreeRunsNoFsmonitorAndNoHookItsConfigNames() throws {
        let (root, worktree) = try repository("seen") { Git.run($0, in: $1) }
        let marks = try marks()
        try plant(root: root, worktree: worktree, marks: marks)
        try nodesGit(in: worktree)
        #expect(marked(marks).isEmpty, "the node's git ran \(marked(marks))")
        // The probe proves something: git as it is runs both there.
        try "two\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        #expect(plain(["status", "--porcelain=v2"], in: worktree).ok)
        #expect(plain(["commit", "-q", "-a", "-m", "c"], in: worktree).ok)
        #expect(marked(marks).contains("fsmonitor") && marked(marks).contains("pre-commit"), "\(marked(marks))")
    }

    /// A repository the guard first sees in a worker's worktree (its record of the repository lost, or never taken):
    /// the hooks it takes as the repository's baseline are the main checkout's, never the folder that worktree's own
    /// config names, which is the worker's.
    @Test func aRepositoryFirstSeenInAWorkersWorktreeTakesNoHooksFromItsConfig() throws {
        let (root, worktree) = try repository("unseen") { plain($0, in: $1) }
        let marks = try marks()
        // The user's own hook, in the repository's hooks folder: the baseline, wherever it is taken.
        try installScript("#!/bin/sh\ntouch '\(marks)/the-users-post-commit'\nexit 0\n", atPath: root + "/.git/hooks/post-commit")
        try plant(root: root, worktree: worktree, marks: marks)
        try nodesGit(in: worktree)
        #expect(marked(marks) == ["the-users-post-commit"], "the node's git ran \(marked(marks))")
        // By the guard's own spelling of the common folder, and the file system's of the hooks': the Mac has two.
        let common = try #require(GitGuard.gitDirs(of: root)?.common)
        let accepted = try #require(GitGuard.accepted(commonDir: common))
        #expect(GitGuard.real(accepted.folder) == GitGuard.real(root + "/.git/hooks") && accepted.run == ["post-commit"], "\(accepted)")
    }
}
