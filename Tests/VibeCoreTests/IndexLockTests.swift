import Darwin
import Foundation
import Testing
@testable import VibeCore

/// 2026-10-18: 0-byte index.lock files no process held, in the main checkout (20:08:27, it blocked two merges) and in a
/// worktree just made for a worker (20:08), and again in a worker's worktree at 20:53. git removes its lock when it's
/// stopped with TERM, HUP or INT; only a git killed outright (SIGKILL) leaves it. Claude Code stops a status line that's
/// still running when it draws the next one with TERM to its process group, then SIGKILLs the group about 2 s later
/// (tried on 2.1.302: a child slow to act on TERM was killed 2 s after it). The status line here (claude-hud) runs
/// `git status`, which holds index.lock while it collects; on a Mac too busy to run it in those 2 s (load 140-200 that
/// evening) it's killed holding it. These tests do the same to a `git status` in a scratch repository: stopped first,
/// standing in for a git the busy Mac doesn't get to, then TERM and KILL to its group.
struct IndexLockTests {
    let temp = Scratch()

    /// A repository whose `git status` takes a moment: enough untracked files that it's caught holding its lock.
    func repo() throws -> String {
        let url = temp.url("index-lock")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        let folder = root + "/untracked"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for index in 0..<3000 { FileManager.default.createFile(atPath: "\(folder)/\(index).txt", contents: Data("\(index)\n".utf8)) }
        return root
    }

    /// Runs `git status` with `environment` (on top of this process's, without any GIT_OPTIONAL_LOCKS of its own) and,
    /// if it's ever caught holding index.lock, kills it as Claude Code does a status line on a busy Mac: stopped there
    /// (the Mac doesn't get to it), TERM to its group, then KILL. Whether it was caught, and whether the lock was left.
    func killStatus(in root: String, environment: [String: String]) -> (caught: Bool, left: Bool) {
        let lock = root + "/.git/index.lock"
        var base = ProcessInfo.processInfo.environment
        base["GIT_OPTIONAL_LOCKS"] = nil
        // The lock is there for a few milliseconds of each run: tried until one is caught.
        for _ in 0..<40 {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["status", "--porcelain"]
            git.currentDirectoryURL = URL(fileURLWithPath: root)
            git.environment = base.merging(environment) { $1 }
            git.standardOutput = FileHandle.nullDevice
            git.standardError = FileHandle.nullDevice
            git.standardInput = FileHandle.nullDevice
            guard (try? git.run()) != nil else { return (false, false) }
            // Process makes it the leader of a process group of its own, as Claude Code starts a status line.
            let group = git.processIdentifier
            var caught = false
            while git.isRunning, !caught {
                caught = FileManager.default.fileExists(atPath: lock)
                if !caught { usleep(100) }
            }
            if caught {
                kill(group, SIGSTOP)
                kill(-group, SIGTERM)
                usleep(100_000)
                kill(-group, SIGKILL)
            }
            git.waitUntilExit()
            let left = FileManager.default.fileExists(atPath: lock)
            // Scratch: the next try starts clean.
            if left { try? FileManager.default.removeItem(atPath: lock) }
            if caught { return (true, left) }
        }
        return (false, false)
    }

    /// The incidents, reproduced: a `git status` killed outright while it holds index.lock leaves it, 0 bytes.
    @Test func aGitKilledOutrightLeavesItsLock() throws {
        let root = try repo()
        let killed = killStatus(in: root, environment: ["GIT_OPTIONAL_LOCKS": "1"])
        #expect(killed.caught, "git status was never caught holding index.lock")
        #expect(killed.left)
    }

    /// Stopped with TERM, a git that holds the lock (a `git commit -a` waiting for its editor) removes it: a git that
    /// gets to run its signal handler cleans up. (Not in its first microseconds: it makes the file a moment before it
    /// registers it for removal.)
    @Test func aGitStoppedWithTermRemovesItsLock() throws {
        let root = try repo()
        try "two\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["commit", "-q", "-a"]
        git.currentDirectoryURL = URL(fileURLWithPath: root)
        let editing = root + "/editing"
        git.environment = ProcessInfo.processInfo.environment.merging(["GIT_EDITOR": "touch '\(editing)'; sleep 60; true"]) { $1 }
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        let lock = root + "/.git/index.lock"
        // Waiting for its editor: the git holding the lock is past setting up.
        #expect(eventually { FileManager.default.fileExists(atPath: editing) })
        #expect(FileManager.default.fileExists(atPath: lock))
        kill(-git.processIdentifier, SIGTERM)
        git.waitUntilExit()
        #expect(!FileManager.default.fileExists(atPath: lock))
    }

    /// The git VibeSwitcher runs (a merge's `git status` in the main checkout, among others) leaves no lock however
    /// it's stopped.
    @Test func vibeSwitchersGitLeavesNoLockWhenKilled() throws {
        let root = try repo()
        #expect(!killStatus(in: root, environment: Git.environment).left)
        // It still answers.
        try "two\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        #expect(Git.run(["status", "--porcelain", "--untracked-files=no"], in: root).output == "M a.txt")
    }

    /// Nor does the git that the lead's, a worker's or a verifier's session runs, its status line's included: they
    /// start with the role's environment.
    @Test func theTeamsSessionsLeaveNoLockWhenTheirGitIsKilled() throws {
        let root = try repo()
        for role in [LeadLaunch.Role.lead, .worker, .verifier] {
            #expect(!killStatus(in: root, environment: LeadLaunch.environment(role)).left, "\(role)")
        }
    }
}

/// A process that holds `path` open (and made it, as git makes its lock), until it's stopped.
func holdOpen(_ path: String) throws -> Process {
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/bin/sh")
    holder.arguments = ["-c", "exec 3>>\"$0\"; exec sleep 300", path]
    try holder.run()
    #expect(eventually { FileManager.default.fileExists(atPath: path) && ProcessTable.info(pid: holder.processIdentifier)?.comm == "sleep" })
    return holder
}

/// A lock a git killed outright left `age` seconds ago: 0 bytes, nobody holding it.
/// When it was last written, as the messages say it ("(21:24)"): exact however long the looking takes.
@discardableResult
func leaveStaleLock(_ path: String, age: TimeInterval) -> String {
    let written = Date().addingTimeInterval(-age)
    FileManager.default.createFile(atPath: path, contents: nil)
    try? FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: path)
    return "(\(LeadBoard.clock(written.timeIntervalSince1970)))"
}

struct IndexLockHolderTests {
    let temp = Scratch()

    func repo() throws -> String {
        let url = temp.url("lock-holder")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    @Test func noLockIsNone() throws {
        #expect(IndexLock.find(in: try repo()) == nil)
    }

    @Test func aLockAProcessHasOpenNamesItsPidAndCommand() throws {
        let root = try repo()
        let path = root + "/.git/index.lock"
        let holder = try holdOpen(path)
        defer { holder.terminate(); holder.waitUntilExit() }
        let lock = try #require(IndexLock.find(in: root))
        #expect(lock.holder?.pid == holder.processIdentifier)
        #expect(lock.holder?.command == "sleep 300")
        #expect(lock.description.contains("held by pid \(holder.processIdentifier) (sleep 300)"))
        // Never removed while it's held, however old.
        #expect(!lock.removeIfStale(minimumAge: 0))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// The user's `git commit` waiting for its editor in the main checkout: its git holds the lock.
    @Test func aGitCommitWaitingForItsEditorHoldsIt() throws {
        let root = try repo()
        try "two\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["commit", "-q", "-a"]
        git.currentDirectoryURL = URL(fileURLWithPath: root)
        let editing = root + "/editing"
        git.environment = ProcessInfo.processInfo.environment.merging(["GIT_EDITOR": "touch '\(editing)'; sleep 300; true"]) { $1 }
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        defer { kill(-git.processIdentifier, SIGTERM); git.waitUntilExit() }
        #expect(eventually { FileManager.default.fileExists(atPath: editing) })
        let lock = try #require(IndexLock.find(in: root))
        #expect(lock.holder?.pid == git.processIdentifier)
        #expect(lock.holder?.command.contains("commit -q -a") == true)
        #expect(!lock.removeIfStale(minimumAge: 0))
    }

    @Test func aLockNobodyHoldsIsStaleWithItsAgeAndPath() throws {
        let root = try repo()
        let path = root + "/.git/index.lock"
        let written = leaveStaleLock(path, age: 17 * 60)
        let lock = try #require(IndexLock.find(in: root))
        #expect(lock.stale && lock.size == 0)
        #expect(lock.path.hasSuffix("/.git/index.lock"))
        #expect(lock.description.contains("\(lock.path) is stale: no process has it open and no git runs in \(root)"))
        #expect(lock.description.contains("It's 0 bytes, last written "))
        #expect(lock.description.contains(" min ago \(written), left by a git that was killed outright"))
        #expect(lock.age() >= 17 * 60)
        // One just made may be a git at work that wasn't seen yet: left.
        leaveStaleLock(path, age: 5)
        #expect(!(try #require(IndexLock.find(in: root))).removeIfStale())
        leaveStaleLock(path, age: 120)
        #expect(try #require(IndexLock.find(in: root)).removeIfStale())
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aWorktreesLockIsItsOwn() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "w")
        let path = Git.run(["rev-parse", "--path-format=absolute", "--git-path", "index.lock"], in: worktree).output
        #expect(path.hasSuffix("/.git/worktrees/w/index.lock"))
        leaveStaleLock(path, age: 60)
        #expect(IndexLock.find(in: worktree)?.path == path)
        // The main checkout's is another.
        #expect(IndexLock.find(in: root) == nil)
    }

    /// A git at work in a worktree under the main checkout doesn't hold the main checkout's lock.
    @Test func aGitInAWorktreeDoesntHoldTheMainCheckoutsLock() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "w")
        try "two\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["commit", "-q", "-a"]
        git.currentDirectoryURL = URL(fileURLWithPath: worktree)
        let editing = root + "/editing"
        git.environment = ProcessInfo.processInfo.environment.merging(["GIT_EDITOR": "touch '\(editing)'; sleep 300; true"]) { $1 }
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        defer { kill(-git.processIdentifier, SIGTERM); git.waitUntilExit() }
        #expect(eventually { FileManager.default.fileExists(atPath: editing) })
        leaveStaleLock(root + "/.git/index.lock", age: 600)
        #expect(IndexLock.find(in: root)?.stale == true)
        #expect(IndexLock.find(in: worktree)?.holder?.pid == git.processIdentifier)
    }

    /// A search for the holder that runs out of time (the process table takes minutes on a loaded Mac) says so, with
    /// the lock's path, size and age, and the lock is never removed on it: neither when the search is still going
    /// at the time limit, nor when it gave up at its deadline itself.
    @Test func aSearchThatRunsOutOfTimeSaysSoAndRemovesNothing() throws {
        let root = try repo()
        let path = root + "/.git/index.lock"
        let written = leaveStaleLock(path, age: 30 * 60)
        let slow: IndexLock.Search = { _, _, _ in
            Thread.sleep(forTimeInterval: 3)
            return .none
        }
        let gaveUp: IndexLock.Search = { _, _, _ in .unknown }
        for search in [slow, gaveUp] {
            let started = Date()
            let lock = try #require(IndexLock.find(in: root, timeLimit: 0.3, search: search))
            #expect(Date().timeIntervalSince(started) < 2.5, "waited for the search past its time limit")
            #expect(!lock.checked && !lock.stale && lock.holder == nil)
            #expect(lock.description == "\(lock.path) is there, and VibeSwitcher couldn't check who holds it in time. It's 0 bytes, last written \(LeadToolset.age(lock.age())) ago \(written)")
            #expect(!lock.removeIfStale(minimumAge: 0, timeLimit: 0.3, search: search))
            // Not even when the first look found nobody, if the look before removing runs out of time.
            var looked = try #require(IndexLock.find(in: root))
            #expect(looked.stale)
            #expect(!looked.removeIfStale(minimumAge: 0, timeLimit: 0.3, search: search))
            #expect(FileManager.default.fileExists(atPath: path))
            looked.checked = false
            #expect(!looked.removeIfStale(minimumAge: 0))
            #expect(FileManager.default.fileExists(atPath: path))
            let refusal = Worktrees.refusal(lock)
            #expect(refusal.contains("couldn't check who holds it in time") && refusal.contains("before anyone removes it"), "\(refusal)")
        }
    }

    /// On the main thread (the app's) it never reads the process table: the lock is reported unchecked at once.
    @MainActor @Test func onTheMainThreadItDoesntLookForTheHolder() throws {
        let root = try repo()
        let path = root + "/.git/index.lock"
        let holder = try holdOpen(path)
        defer { holder.terminate(); holder.waitUntilExit() }
        let searched: IndexLock.Search = { _, _, _ in
            Issue.record("searched on the main thread")
            return .none
        }
        let lock = try #require(IndexLock.find(in: root, search: searched))
        #expect(!lock.checked && lock.holder == nil)
        #expect(!lock.removeIfStale(minimumAge: 0))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// A fast-forward into the main checkout says whose lock stops it, and leaves a stale one there.
    @Test func aFastForwardNamesTheLockInTheMainCheckout() throws {
        let root = try repo()
        let worktree = try Worktrees.create(root: root, slug: "b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "b"], in: worktree)
        let path = root + "/.git/index.lock"
        leaveStaleLock(path, age: 600)
        guard case .refused(let stale) = try Worktrees.merge(root: root, slug: "b") else { Issue.record("merged over a lock"); return }
        #expect(stale.contains("is stale") && stale.contains("rm '\(IndexLock.real(path))'"), "\(stale)")
        #expect(FileManager.default.fileExists(atPath: path))
        try FileManager.default.removeItem(atPath: path)
        let holder = try holdOpen(path)
        defer { holder.terminate(); holder.waitUntilExit() }
        guard case .refused(let held) = try Worktrees.merge(root: root, slug: "b") else { Issue.record("merged over a lock"); return }
        #expect(held.contains("held by pid \(holder.processIdentifier)"), "\(held)")
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

extension LeadToolsetTests {
    /// merge meets the main checkout's lock before running the tests, and names it: stale (left there, it's the user's
    /// checkout too) or held (by whom).
    @Test func mergeSaysWhoseLockStopsIt() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        let path = root + "/.git/index.lock"
        let written = leaveStaleLock(path, age: 25 * 60)
        let stale = call(lead, "merge", ["task": "add-b"])
        #expect(stale.isError)
        #expect(stale.text.hasPrefix("Not merged (nothing was tested): "), "\(stale.text)")
        #expect(stale.text.contains("is stale") && stale.text.contains(" min ago \(written)"), "\(stale.text)")
        #expect(FileManager.default.fileExists(atPath: path))
        try FileManager.default.removeItem(atPath: path)
        let holder = try holdOpen(path)
        let held = call(lead, "merge", ["task": "add-b"])
        #expect(held.isError && held.text.contains("held by pid \(holder.processIdentifier) (sleep 300)"), "\(held.text)")
        holder.terminate()
        holder.waitUntilExit()
        #expect(FileManager.default.fileExists(atPath: path))
        try FileManager.default.removeItem(atPath: path)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
    }

    /// start_worker removes a stale lock from the task's own worktree (it would stop the worker's first commit), and
    /// leaves one a process holds, telling the lead and the worker whose it is.
    @Test func startWorkerClearsAStaleLockInItsWorktreeAndNamesAHeldOne() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(!call(lead, "start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        let path = Git.run(["rev-parse", "--path-format=absolute", "--git-path", "index.lock"], in: worktree).output
        _ = call(lead, "stop_worker", ["task": "add-b"])
        leaveStaleLock(path, age: 10 * 60)
        let cleared = call(lead, "start_worker", ["task": "add-b"])
        #expect(!cleared.isError, "\(cleared.text)")
        #expect(cleared.text.hasPrefix("Removed a stale index.lock from its worktree (0 bytes, last written "), "\(cleared.text)")
        #expect(cleared.text.contains(" min ago; no process held it). Worker started"), "\(cleared.text)")
        #expect(!FileManager.default.fileExists(atPath: path))

        _ = call(lead, "stop_worker", ["task": "add-b"])
        let holder = try holdOpen(path)
        defer { holder.terminate(); holder.waitUntilExit() }
        let held = call(lead, "start_worker", ["task": "add-b"])
        #expect(!held.isError, "\(held.text)")
        #expect(held.text.contains("held by pid \(holder.processIdentifier) (sleep 300)"), "\(held.text)")
        #expect(runtime.spawned.last?.command.contains("held by pid \(holder.processIdentifier)") == true)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
