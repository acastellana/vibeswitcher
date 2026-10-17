import Foundation

/// Runs git (never through a shell, never prompting for credentials).
public enum Git {
    public struct Result: Equatable, Sendable {
        public var status: Int32
        public var output: String
        public var error: String
        public var ok: Bool { status == 0 }
    }

    @discardableResult
    public static func run(_ args: [String], in directory: String) -> Result {
        Shell.run(executable: "/usr/bin/git", args: args, in: directory, env: ["GIT_TERMINAL_PROMPT": "0"])
    }
}

/// Stops the commands a piece of work runs when it's cancelled (an MCP tool call the user interrupted). Set for
/// the current thread with `with`; `Shell.run` picks it up.
public final class ShellCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private static let key = "VibeSwitcher.ShellCancel"
    public static var current: ShellCancel? { Thread.current.threadDictionary[key] as? ShellCancel }

    public static func with<T>(_ token: ShellCancel, _ body: () throws -> T) rethrows -> T {
        Thread.current.threadDictionary[key] = token
        defer { Thread.current.threadDictionary[key] = nil }
        return try body()
    }
}

/// Runs a program and captures its output.
public enum Shell {
    public static func run(executable: String, args: [String], in directory: String, env: [String: String] = [:],
                           timeout: TimeInterval = 120, grace: TimeInterval = 5) -> Git.Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Git.Result(status: -1, output: "", error: "\(error)") }
        // Read while it runs, so a chatty program can't fill the pipe and stall.
        // Their own threads, not the shared pool: callers block too, and many at once (parallel tests, several tool
        // calls) could leave the readers no thread to run on.
        var output = Data(), errors = Data()
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread { output = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        Thread.detachNewThread { errors = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        let cancel = ShellCancel.current
        while process.isRunning, Date() < deadline, cancel?.isCancelled != true { usleep(20_000) }
        if process.isRunning {
            // Out of time: its children (a test runner's workers) go too, or they'd keep running in the worktree.
            // Asked first; whatever is still there after `grace` (it ignores TERM) is killed.
            let asked = signalFamily(of: process.processIdentifier, SIGTERM)
            let end = Date().addingTimeInterval(grace)
            while process.isRunning, Date() < end { usleep(50_000) }
            signalFamily(of: process.processIdentifier, SIGKILL, also: asked)
        }
        process.waitUntilExit()
        group.wait()
        return Git.Result(status: process.terminationStatus,
                          output: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                          error: String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension Shell {
    /// Signals a process and its descendants (plus `also`, an earlier walk: a descendant whose parent died since
    /// has moved to launchd), children first, each matched by pid and start time (so a pid reused meanwhile isn't
    /// hit). Returns who it signalled.
    @discardableResult
    static func signalFamily(of root: Int32, _ signal: Int32, also earlier: [ProcInfo] = []) -> [ProcInfo] {
        let table = ProcessTable.snapshot()
        var family = table[root].map { [$0] } ?? []
        family += earlier.filter { member in !family.contains { $0.pid == member.pid } }
        var index = 0
        while index < family.count {
            let parent = family[index].pid
            family += table.values.filter { child in child.ppid == parent && child.pid != parent && !family.contains { $0.pid == child.pid } }
            index += 1
        }
        for member in family.reversed() where ProcessTable.info(pid: member.pid)?.startTime == member.startTime {
            kill(member.pid, signal)
        }
        return family
    }
}

/// Workers' worktrees (`<repo>/.vibeswitcher/worktrees/<slug>` on `agent/<slug>`) and the merge queue's git steps.
public enum Worktrees {
    public enum Check: Equatable, Sendable {
        /// The checks passed on this commit (the branch rebased onto main).
        case passed(String)
        case failed(String)
        /// Rebasing onto main conflicted; the rebase was undone.
        case conflict
        case error(String)

        public var isFailure: Bool { if case .failed = self { return true } else { return false } }
    }

    public enum Merge: Equatable, Sendable {
        case merged
        case refused(String)
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    public static func path(root: String, slug: String) -> String {
        (root as NSString).appendingPathComponent(".vibeswitcher/worktrees/\(slug)")
    }

    public static func branch(_ slug: String) -> String { "agent/\(slug)" }

    /// `main`, else `master`, else whatever is checked out.
    public static func mainBranch(root: String) -> String {
        for name in ["main", "master"] where Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: root).ok {
            return name
        }
        return Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: root).output
    }

    /// The branch checked out at `root`; nil when detached.
    public static func currentBranch(root: String) -> String? {
        let head = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: root)
        return head.ok && !head.output.isEmpty && head.output != "HEAD" ? head.output : nil
    }

    /// A new worktree on a new branch from `base` (main by default), or on the task's branch when it's still there.
    @discardableResult
    public static func create(root: String, slug: String, base: String? = nil) throws -> String {
        // Worktrees live inside the repo: keep them out of its status first.
        try BoardStore(root: root).ensureExcluded()
        let path = path(root: root, slug: slug)
        let exists = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch(slug))"], in: root).ok
        let result = Git.run(["worktree", "add", "-q"] + (exists ? [path, branch(slug)] : ["-b", branch(slug), path, base ?? mainBranch(root: root)]), in: root)
        guard result.ok else { throw Failure(description: result.error.isEmpty ? "git worktree add failed" : result.error) }
        return path
    }

    /// The folder is a worktree of this repository on the task's branch (not a leftover folder, where git would
    /// find the main checkout instead and the worker's commits would land there).
    public static func isWorktree(root: String, slug: String) -> Bool {
        let path = path(root: root, slug: slug)
        guard FileManager.default.fileExists(atPath: path + "/.git") else { return false }
        let top = Git.run(["rev-parse", "--show-toplevel"], in: path)
        let resolved = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        return top.ok && resolved(top.output) == resolved(path)
            && Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path).output == branch(slug)
    }

    /// The task's worktree: the existing one, or a new one. An empty leftover folder is replaced; one with files
    /// in it is never touched (they might be someone's).
    public static func open(root: String, slug: String, base: String? = nil) throws -> String {
        if isWorktree(root: root, slug: slug) { return path(root: root, slug: slug) }
        let path = path(root: root, slug: slug)
        if FileManager.default.fileExists(atPath: path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            guard contents.isEmpty else {
                throw Failure(description: "\(path) is there but isn't the worktree of \(branch(slug)); move it away, then start the worker again.")
            }
            try FileManager.default.removeItem(atPath: path)
            Git.run(["worktree", "prune"], in: root)
        }
        return try create(root: root, slug: slug, base: base)
    }

    /// Puts the branch on top of main and runs the checks there.
    public static func rebaseAndTest(root: String, slug: String, test: String?, base: String? = nil, timeout: TimeInterval = 1200) -> Check {
        let path = path(root: root, slug: slug)
        guard FileManager.default.fileExists(atPath: path) else { return .error("No worktree for \(slug).") }
        guard Git.run(["status", "--porcelain", "--untracked-files=no"], in: path).output.isEmpty else {
            return .error("The worktree of \(slug) has uncommitted changes (its worker may still be working). Have it commit, or stop it, then merge again.")
        }
        let rebase = Git.run(["rebase", base ?? mainBranch(root: root)], in: path)
        guard rebase.ok else {
            Git.run(["rebase", "--abort"], in: path)
            return .conflict
        }
        // What's tested is what may be merged: the commit now, not whatever the branch holds later.
        let tested = Git.run(["rev-parse", "HEAD"], in: path).output
        guard let test, !test.trimmingCharacters(in: .whitespaces).isEmpty else { return .passed(tested) }
        let run = Shell.run(executable: "/bin/zsh", args: ["-lc", test], in: path, timeout: timeout)
        if run.ok { return .passed(tested) }
        let output = (run.output + "\n" + run.error).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(String(output.suffix(4000)))
    }

    /// Fast-forwards main to `commit` (the tested one; the branch's head when nil). Never rewrites anything and
    /// never touches uncommitted work: a dirty main checkout, main checked out elsewhere, or a commit not on top
    /// of main is refused with the reason.
    public static func merge(root: String, slug: String, commit: String? = nil, base: String? = nil) throws -> Merge {
        let main = base ?? mainBranch(root: root)
        guard !["HEAD", ""].contains(main) else { return .refused("The repository has no main branch checked out.") }
        let branch = commit ?? branch(slug)
        guard Git.run(["merge-base", "--is-ancestor", branch, self.branch(slug)], in: root).ok else {
            return .refused("\(branch) isn't on \(self.branch(slug)).")
        }
        // Read once, before the checks: the update below is against this head and no later one.
        let current = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(main)"], in: root).output
        return fastForward(root: root, base: main, to: Git.run(["rev-parse", branch], in: root).output, from: current)
    }

    /// Fast-forwards `base` from `expected` (its head as the caller last saw it) to `commit`. Refused when the
    /// branch isn't at `expected` any more (something else moved it, or another merge landed first), when `commit`
    /// isn't on top of it, or when its checkout has uncommitted changes or is another worktree.
    public static func fastForward(root: String, base main: String, to commit: String, from expected: String) -> Merge {
        guard !["HEAD", ""].contains(main) else { return .refused("The repository has no main branch checked out.") }
        let current = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(main)"], in: root).output
        guard !expected.isEmpty, current == expected else {
            return .refused("\(main) is at \(current.prefix(8)), not at \(expected.prefix(8)) where it was; it moved meanwhile.")
        }
        guard Git.run(["merge-base", "--is-ancestor", expected, commit], in: root).ok else {
            return .refused("The branch isn't on top of \(main); rebase and test it first.")
        }
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        switch checkout(of: main, root: root) {
        case .some(let place) where URL(fileURLWithPath: place).resolvingSymlinksInPath().path == resolvedRoot:
            guard Git.run(["status", "--porcelain", "--untracked-files=no"], in: root).output.isEmpty else {
                return .refused("The main checkout has uncommitted changes; commit or stash them first.")
            }
            let merge = Git.run(["merge", "--ff-only", "-q", commit], in: root)
            guard merge.ok else { return .refused(merge.error) }
            let landed = Git.run(["rev-parse", "refs/heads/\(main)"], in: root).output
            return landed == commit ? .merged : .refused("\(main) ended at \(landed.prefix(8)), not \(commit.prefix(8)); it moved during the merge.")
        case .some(let place):
            return .refused("\(main) is checked out in \(place); merge there.")
        case .none:
            // Only from the head that was checked: a merge that landed in between makes this fail, not vanish.
            let update = Git.run(["update-ref", "refs/heads/\(main)", commit, expected], in: root)
            return update.ok ? .merged : .refused(update.error)
        }
    }

    /// Rebases `commit` (the audited one) onto `base` and runs the setup and test commands on the result, in a
    /// worktree of its own at `scratch`, detached, that no agent works in: what's tested is that commit and nothing
    /// a worker commits or edits meanwhile. The worktree is removed afterwards.
    public static func rebaseAndTest(root: String, commit: String, onto base: String, setup: String? = nil, test: String?,
                                     scratch: URL, timeout: TimeInterval = 1200) -> Check {
        let path = scratch.path
        if FileManager.default.fileExists(atPath: path) {
            Git.run(["worktree", "remove", "--force", path], in: root)
            try? FileManager.default.removeItem(atPath: path)
            Git.run(["worktree", "prune"], in: root)
        }
        try? FileManager.default.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let added = Git.run(["worktree", "add", "--detach", "-q", path, commit], in: root)
        guard added.ok else { return .error(added.error.isEmpty ? "Couldn't set up a worktree to test \(commit.prefix(8)) in." : added.error) }
        defer {
            Git.run(["worktree", "remove", "--force", path], in: root)
            try? FileManager.default.removeItem(atPath: path)
            Git.run(["worktree", "prune"], in: root)
        }
        guard Git.run(["rebase", "-q", base], in: path).ok else {
            Git.run(["rebase", "--abort"], in: path)
            return .conflict
        }
        let tested = Git.run(["rev-parse", "HEAD"], in: path).output
        for (name, command) in [("init_command", setup), ("test command", test)] {
            guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let run = Shell.run(executable: "/bin/zsh", args: ["-lc", command], in: path, timeout: timeout)
            guard run.ok else {
                let output = (run.output + "\n" + run.error).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed((name == "init_command" ? "init_command failed:\n" : "") + String(output.suffix(4000)))
            }
        }
        return .passed(tested)
    }

    /// Files Claude Code reads as settings or instructions (project settings and hooks under `.claude/`, `.mcp.json`,
    /// `CLAUDE.md`) that the task's branch changes from `base`, or that sit changed or new in its worktree, ignored
    /// ones included: a session started there runs what the worker put in them.
    public static func agentConfigChanges(root: String, slug: String, base: String) -> [String] {
        let committed = Git.run(["diff", "--name-only", "-z", "\(base)...\(branch(slug))"], in: root).output
            .split(separator: "\0").map(String.init)
        // Status lines are "XY path" (a rename's old path follows on its own): both readings are checked.
        let local = Git.run(["status", "--porcelain", "-z", "--untracked-files=all", "--ignored"], in: path(root: root, slug: slug)).output
            .split(separator: "\0").flatMap { [String($0), String($0.dropFirst(3))] }
        return Array(Set((committed + local).filter(isAgentConfig))).sorted()
    }

    static func isAgentConfig(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return parts.contains(".claude") || [".mcp.json", "CLAUDE.md", "CLAUDE.local.md"].contains(parts.last ?? "")
    }

    /// Removes a worker's worktree and its branch. Without `force` it refuses when either holds work that isn't
    /// merged or committed; `force` is for leftovers of merged work, or work the lead chose to abandon.
    public static func remove(root: String, slug: String, force: Bool = false) throws {
        let path = path(root: root, slug: slug)
        if FileManager.default.fileExists(atPath: path) {
            let removed = Git.run(["worktree", "remove"] + (force ? ["--force"] : []) + [path], in: root)
            guard removed.ok else { throw Failure(description: removed.error) }
        }
        let deleted = Git.run(["branch", force ? "-D" : "-d", branch(slug)], in: root)
        guard deleted.ok else { throw Failure(description: deleted.error) }
    }

    /// Where `branch` is checked out, if anywhere.
    static func checkout(of branch: String, root: String) -> String? {
        var current: String?
        for line in Git.run(["worktree", "list", "--porcelain"], in: root).output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") { current = String(line.dropFirst("worktree ".count)) }
            if line == "branch refs/heads/\(branch)" { return current }
        }
        return nil
    }
}
