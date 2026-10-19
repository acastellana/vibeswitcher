import Foundation
import Testing
@testable import VibeCore

/// VibeSwitcher's own files are private: 0600 files in 0700 folders, under the usual umask 022 too, whichever writer
/// made them (docs/eval/open-2026-10-19.md, F-F1 + F-L6). The home folder is group-readable and another local account
/// is in staff, so a 0644 board.json or an old launch prompt was readable by it. Scratch trees only.
@Suite(.serialized)
struct PrivateFilesTests {
    let temp = Scratch()

    static func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    /// Runs `body` under umask 022 (what a login gives), as the app and the tool server do.
    func underUsualUmask<T>(_ body: () throws -> T) rethrows -> T {
        let old = umask(0o022)
        defer { umask(old) }
        return try body()
    }

    /// A git repository to be a lead's project.
    func repo() throws -> String {
        let url = temp.url("private-repo")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        return root
    }

    @Test func theHelperWritesPrivateFilesInPrivateFolders() throws {
        let top = temp.url("private-helper")
        try underUsualUmask {
            let deep = top.appendingPathComponent("a/b/c", isDirectory: true)
            try VibePaths.ensurePrivate(deep)
            for path in ["", "/a", "/a/b", "/a/b/c"] { #expect(Self.mode(top.path + path) == 0o700, "\(path)") }
            let file = deep.appendingPathComponent("x.json")
            try VibePaths.writePrivate(Data("{}".utf8), to: file)
            #expect(Self.mode(file.path) == 0o600)
            // Written over: still 0600, and no temporary file is left beside it.
            try VibePaths.writePrivate(Data("{\"a\":1}".utf8), to: file)
            #expect(Self.mode(file.path) == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: deep.path) == ["x.json"])
            // An older 0755 folder is made private.
            chmod(deep.path, 0o755)
            try VibePaths.ensurePrivate(deep)
            #expect(Self.mode(deep.path) == 0o700)
        }
    }

    /// The vault keeps calling them, as before: only folders under its own are changed.
    @Test func theVaultStillUsesThem() throws {
        let outside = temp.url("private-vault")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        chmod(outside.path, 0o755)
        let vault = LeadVault(folder: outside.appendingPathComponent("vault"), ask: { _ in throw LeadVault.unexpected })
        try underUsualUmask {
            let run = vault.runFolder(root: "/tmp/some-project", name: "worker-x")
            try vault.ensurePrivate(run)
            var folder = run
            while folder.path != outside.path {
                #expect(Self.mode(folder.path) == 0o700, "\(folder.path)")
                folder = folder.deletingLastPathComponent()
            }
            #expect(Self.mode(outside.path) == 0o755, "above the vault: left as it was")
            try LeadVault.writePrivate(Data("p".utf8), to: run.appendingPathComponent("prompt.md"))
            #expect(Self.mode(run.appendingPathComponent("prompt.md").path) == 0o600)
        }
    }

    /// The board, its folder, the decision and progress logs, the workflow and the locks' folders.
    @Test func everyBoardWriterIsPrivate() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        try underUsualUmask {
            try store.prepare()
            // The logs kept in .vibeswitcher (the template keeps them in docs/lead).
            try LeadWorkflow.write(LeadWorkflow.updating(Data(LeadWorkflow.template.utf8), with: [("records_dir", "")]),
                                   to: store.folder + "/workflow.md")
            try store.update { $0.baseBranch = "main" }
            try store.appendProgress("one")
            try store.appendDecision("Ship it", why: "It works.")
            try store.replaceRecord("decisions.md", with: "# Decisions\n")
            let lock = FileLock.attempt(store.folder + "/run/merge-x.lock")
            #expect(lock != nil)
        }
        #expect(Self.mode(store.folder) == 0o700)
        #expect(Self.mode(store.folder + "/run") == 0o700)
        for name in ["board.json", "board.json.lock", "progress.md", "decisions.md", "workflow.md", "records.lock", "run/merge-x.lock"] {
            #expect(Self.mode(store.folder + "/" + name) == 0o600, "\(name)")
        }
    }

    /// An older 0755 `.vibeswitcher` is made 0700 by the next write.
    @Test func anOlderOpenFolderIsClosedByTheNextWrite() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        try FileManager.default.createDirectory(atPath: store.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try underUsualUmask { try store.update { $0.baseBranch = "main" } }
        #expect(Self.mode(store.folder) == 0o700)
        #expect(Self.mode(store.folder + "/board.json") == 0o600)
    }

    /// Records moved into `records_dir` are the repository's own files, committed: its usual modes, not 0600.
    @Test func recordsInTheRepositoryKeepItsModes() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        try underUsualUmask {
            try store.prepare()
            try LeadWorkflow.write(LeadWorkflow.updating(Data(LeadWorkflow.template.utf8), with: [("records_dir", "")]),
                                   to: store.folder + "/workflow.md")
            try store.appendProgress("before")
            try LeadWorkflow.write(LeadWorkflow.updating(Data(LeadWorkflow.template.utf8), with: [("records_dir", "docs/lead")]),
                                   to: store.folder + "/workflow.md")
            try store.appendProgress("after")
        }
        #expect(Self.mode(root + "/docs/lead/progress.md") == 0o644)
        #expect(Self.mode(root + "/docs/lead") == 0o755)
        #expect(Self.mode(store.folder + "/progress.md.moved") == 0o600)
    }

    // MARK: The one-time repair

    /// A scratch `.vibeswitcher` as older versions left it.
    func oldTree(now: Date) throws -> URL {
        let folder = temp.url("private-old").appendingPathComponent(".vibeswitcher")
        let fm = FileManager.default
        func file(_ path: String, _ mode: Int, age: TimeInterval = 0) throws {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            chmod(url.path, mode_t(mode))
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        let day: TimeInterval = 24 * 3600
        try file("board.json", 0o644)
        try file("decisions.md", 0o644)
        try file("sub/notes.txt", 0o640)
        try file("tool", 0o755)
        try file("worktrees/w/Package.swift", 0o644)
        try file("run/old-worker/prompt.md", 0o644, age: 2 * day)
        try file("run/old-worker/mcp.json", 0o644, age: 2 * day)
        try file("run/live-lead/prompt.md", 0o644, age: 3 * day)
        try file("run/new-worker/prompt.md", 0o644, age: 3600)
        try file("run/merge-old.lock", 0o644, age: 5 * day)
        for dir in ["", "sub", "run", "run/old-worker", "run/live-lead", "run/new-worker", "worktrees"] {
            chmod(folder.appendingPathComponent(dir).path, 0o755)
        }
        for dir in ["run/old-worker", "run/live-lead"] {
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3 * day)], ofItemAtPath: folder.appendingPathComponent(dir).path)
        }
        // A link out of the tree is not followed.
        let outside = temp.url("private-outside")
        try Data("y".utf8).write(to: outside)
        chmod(outside.path, 0o644)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)
        return folder
    }

    @Test func theRepairMakesOldFilesPrivateAndRemovesStaleLaunchFiles() throws {
        let now = Date()
        let folder = try oldTree(now: now)
        let live = ["claude", "--append-system-prompt-file", folder.path + "/run/live-lead/prompt.md"]
        let outcome = PrivateRepair.repair(folder, skipping: PrivateRepair.skippedInProject, cleaningRun: true, now: now,
                                           liveArguments: { live })
        let path = { (name: String) in folder.appendingPathComponent(name).path }
        for name in ["", "sub", "run", "run/live-lead", "run/new-worker"] { #expect(Self.mode(path(name)) == 0o700, "\(name)") }
        for name in ["board.json", "decisions.md", "sub/notes.txt", "run/live-lead/prompt.md", "run/new-worker/prompt.md",
                     "run/merge-old.lock"] {
            #expect(Self.mode(path(name)) == 0o600, "\(name)")
        }
        #expect(Self.mode(path("tool")) == 0o700, "a program keeps running")
        // Stale and named by no live session: removed. Named by one, or recent: kept. A lock: kept, made private.
        #expect(!FileManager.default.fileExists(atPath: path("run/old-worker")))
        #expect(outcome.removed == [path("run/old-worker")])
        #expect(outcome.keptLive == [path("run/live-lead")])
        #expect(FileManager.default.fileExists(atPath: path("run/merge-old.lock")))
        // Left alone: the worktrees (the project's own code) and what a link points at.
        #expect(Self.mode(path("worktrees")) == 0o755)
        #expect(Self.mode(path("worktrees/w/Package.swift")) == 0o644)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: path("link"))
        #expect(Self.mode(target) == 0o644)

        // Idempotent: a second run changes nothing (the live session's folder is still named, so it's kept again).
        let again = PrivateRepair.repair(folder, skipping: PrivateRepair.skippedInProject, cleaningRun: true, now: now,
                                         liveArguments: { live })
        #expect(again.madePrivate.isEmpty && again.removed.isEmpty)
        #expect(again.keptLive == [path("run/live-lead")])
    }

    /// When the processes can't be listed, no launch file is removed: it can't be told whether one is in use.
    @Test func nothingIsRemovedWhenTheProcessesCantBeListed() throws {
        let now = Date()
        let folder = try oldTree(now: now)
        let outcome = PrivateRepair.repair(folder, cleaningRun: true, now: now, liveArguments: { nil })
        #expect(outcome.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("run/old-worker/prompt.md").path))
    }

    /// `~/.vibeswitcher`'s host files, vault, signing folder and hook binary are left as they are.
    @Test func theRepairLeavesTheHostsFilesAlone() throws {
        let folder = temp.url("private-root")
        let fm = FileManager.default
        for name in ["lead/run/x", "host", "signing", "bin", "state"] {
            try fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["host.log", "bin/vibeswitcher-hook", "lead/run/x/prompt.md", "state/ttys001.json", "focus-debug.json"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        for name in ["host.log", "lead/run/x/prompt.md", "state/ttys001.json", "focus-debug.json"] { chmod(folder.appendingPathComponent(name).path, 0o644) }
        chmod(folder.appendingPathComponent("bin/vibeswitcher-hook").path, 0o755)
        for name in ["lead", "host", "signing", "bin", "state"] { chmod(folder.appendingPathComponent(name).path, 0o755) }
        PrivateRepair.repair(folder, skipping: PrivateRepair.skippedAtRoot)
        let mode = { (name: String) in Self.mode(folder.appendingPathComponent(name).path) }
        #expect(mode("state") == 0o700 && mode("state/ttys001.json") == 0o600 && mode("focus-debug.json") == 0o600)
        for name in ["lead", "host", "signing", "bin", "bin/vibeswitcher-hook"] { #expect(mode(name) == 0o755, "\(name)") }
        #expect(mode("host.log") == 0o644 && mode("lead/run/x/prompt.md") == 0o644)
    }

    /// A project's folder is repaired once: the first write there, logged once, then marked done.
    @Test func aProjectIsRepairedOnceAndLoggedOnce() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        try FileManager.default.createDirectory(atPath: store.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try Data("{}".utf8).write(to: URL(fileURLWithPath: store.folder + "/old.json"))
        chmod(store.folder + "/old.json", 0o644)
        try store.update { $0.baseBranch = "main" }
        try store.update { $0.baseBranch = "dev" }
        #expect(Self.mode(store.folder + "/old.json") == 0o600)
        #expect(FileManager.default.fileExists(atPath: store.folder + "/" + PrivateRepair.marker))
        #expect(Breadcrumbs.shared.lines.filter { $0.contains("privacy: \(store.folder):") }.count == 1)
        // Marked done: a later 0644 file isn't looked for again (every write of its own is private already).
        let second = BoardStore(root: root)
        chmod(store.folder + "/old.json", 0o644)
        PrivateRepair.project(second.folder + "/")
        #expect(Self.mode(store.folder + "/old.json") == 0o644)
    }
}
