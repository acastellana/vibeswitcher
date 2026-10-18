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
    /// With `interleaved`, stderr goes to the same pipe as stdout, so `output` holds both in the order they were
    /// written (a build's warnings and the test results after them) and `error` is empty.
    public static func run(executable: String, args: [String], in directory: String, env: [String: String] = [:],
                           timeout: TimeInterval = 120, grace: TimeInterval = 5, interleaved: Bool = false) -> Git.Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = interleaved ? out : err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Git.Result(status: -1, output: "", error: "\(error)") }
        // Read while it runs, so a chatty program can't fill the pipe and stall.
        // Their own threads, not the shared pool: callers block too, and many at once (parallel tests, several tool
        // calls) could leave the readers no thread to run on.
        var output = Data(), errors = Data()
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread { output = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        // Unused, its write end is still ours: reading it would never end.
        if !interleaved {
            group.enter()
            Thread.detachNewThread { errors = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        }
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
        /// A command failed; its output (all of it from the commit's rebaseAndTest, the tail from the slug's).
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

    /// A rebase or merge of the task's branch that its worktree stopped partway through (a refused `--continue`, a
    /// session that ended in the middle).
    public struct Interrupted: Error, Equatable, Sendable, CustomStringConvertible {
        public enum Kind: String, Sendable { case rebase, merge }
        public var kind: Kind
        public var path: String
        public var branch: String
        /// The branch's commit now: where the abort must leave it.
        public var head: String
        /// What it rebases onto, or what it merges in ("1a2b3c4d (main)").
        public var onto: String
        /// The rebase's pick it stopped at, and how many there are.
        public var step: Int?
        public var steps: Int?
        /// The commit being applied (REBASE_HEAD) or merged (MERGE_HEAD), with its subject.
        public var stoppedAt: String?
        /// A merge that was started with HEAD detached at the branch's commit.
        public var detached = false
        public var staged: [String] = []
        public var conflicted: [String] = []
        /// Why aborting would lose commits (the branch moved since the rebase began, and the abort would put it
        /// back); nil when it's safe.
        public var unsafe: String?

        public var description: String {
            var text: String
            switch kind {
            case .rebase:
                text = "\(path) stopped partway through rebasing \(branch) onto \(onto)"
                if let step, let steps { text += ", at pick \(step) of \(steps) (\(max(step - 1, 0)) done)" }
            case .merge:
                text = "\(path) stopped partway through merging \(onto) into \(branch)" + (detached ? " (HEAD detached)" : "")
            }
            if let stoppedAt { text += "; stopped on \(stoppedAt)" }
            text += ". Staged: " + (staged.isEmpty ? "nothing" : staged.joined(separator: ", "))
            if !conflicted.isEmpty { text += "; unresolved: " + conflicted.joined(separator: ", ") }
            return text + ". \(branch) is at \(head.prefix(8))."
        }
    }

    /// The rebase or merge the task's worktree is in the middle of, when it's this repository's worktree and the
    /// operation is on the task's branch (rebasing it, or merging into it); nil otherwise, also for a folder that
    /// belongs to something else.
    public static func interrupted(root: String, slug: String) -> Interrupted? {
        let path = path(root: root, slug: slug), branch = branch(slug)
        guard FileManager.default.fileExists(atPath: path + "/.git") else { return nil }
        let resolved = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let top = Git.run(["rev-parse", "--show-toplevel"], in: path)
        guard top.ok, resolved(top.output) == resolved(path) else { return nil }
        // A worktree of this repository, not a repository of its own checked out there.
        let common = { (dir: String) -> String? in
            let found = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir)
            return found.ok ? resolved(found.output) : nil
        }
        guard let mine = common(path), mine == common(root) else { return nil }
        let head = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root).output
        guard !head.isEmpty else { return nil }
        let gitPath = { (name: String) in Git.run(["rev-parse", "--path-format=absolute", "--git-path", name], in: path).output }
        let read = { (file: String) in (try? String(contentsOfFile: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let exists = { (file: String) in FileManager.default.fileExists(atPath: file) }
        // "1a2b3c4d (main)": the commit and the other branches at it.
        let name = { (commit: String) -> String in
            let short = Git.run(["rev-parse", "--short=8", commit], in: path).output
            let at = Git.run(["for-each-ref", "--points-at", commit, "--format=%(refname:short)", "refs/heads"], in: path).output
                .split(whereSeparator: \.isNewline).map(String.init).filter { $0 != branch }
            return at.isEmpty ? short : "\(short) (\(at.joined(separator: ", ")))"
        }
        let subject = { (ref: String) -> String? in
            let shown = Git.run(["log", "-1", "--format=%h %s", ref], in: path)
            return shown.ok && !shown.output.isEmpty ? shown.output : nil
        }
        let conflicted = Git.run(["diff", "--name-only", "--diff-filter=U"], in: path).output
            .split(whereSeparator: \.isNewline).map(String.init)
        let staged = Git.run(["diff", "--cached", "--name-only"], in: path).output
            .split(whereSeparator: \.isNewline).map(String.init).filter { !conflicted.contains($0) }
        // rebase-merge for `rebase` and `rebase -i`; rebase-apply for the old apply backend.
        for (folder, current, last) in [("rebase-merge", "msgnum", "end"), ("rebase-apply", "next", "last")] {
            let dir = gitPath(folder)
            guard exists(dir) else { continue }
            // Another branch's rebase (or `git am`, which names none) isn't this task's to undo.
            guard read(dir + "/head-name") == "refs/heads/\(branch)" else { return nil }
            var stuck = Interrupted(kind: .rebase, path: path, branch: branch, head: head, onto: read(dir + "/onto").map(name) ?? "?",
                                    step: read(dir + "/" + current).flatMap { Int($0) }, steps: read(dir + "/" + last).flatMap { Int($0) },
                                    stoppedAt: exists(gitPath("REBASE_HEAD")) ? subject("REBASE_HEAD") : nil,
                                    staged: staged, conflicted: conflicted)
            // The abort puts the branch back where the rebase began: anything committed to it since would go.
            if let began = read(dir + "/orig-head"), began != head {
                stuck.unsafe = "\(branch) is at \(head.prefix(8)), not at \(began.prefix(8)) where the rebase began; aborting would move it back and lose what's in between"
            }
            return stuck
        }
        guard exists(gitPath("MERGE_HEAD")), let merging = read(gitPath("MERGE_HEAD"))?.split(whereSeparator: \.isNewline).first else { return nil }
        let on = Git.run(["symbolic-ref", "-q", "HEAD"], in: path).output
        let detached = on.isEmpty
        // Into the branch, or into a detached HEAD at its commit; a merge on anything else isn't this task's.
        guard on == "refs/heads/\(branch)" || detached && Git.run(["rev-parse", "HEAD"], in: path).output == head else { return nil }
        return Interrupted(kind: .merge, path: path, branch: branch, head: head, onto: name(String(merging)),
                           stoppedAt: subject("MERGE_HEAD"), detached: detached, staged: staged, conflicted: conflicted)
    }

    /// Aborts the rebase or merge the task's worktree stopped in, back on its branch at the same commit (what's
    /// staged in the middle of it goes; the branch's commits stay). Refused when aborting would move the branch.
    @discardableResult
    public static func recover(root: String, slug: String) throws -> String {
        guard let stuck = interrupted(root: root, slug: slug) else {
            throw Failure(description: "\(path(root: root, slug: slug)) isn't in the middle of a rebase or merge of \(branch(slug)).")
        }
        if let unsafe = stuck.unsafe { throw Failure(description: "Not recovered: \(unsafe).") }
        let abort = Git.run([stuck.kind.rawValue, "--abort"], in: stuck.path)
        let after = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(stuck.branch)"], in: root).output
        if after != stuck.head {
            // Never expected (checked above), and never left so: the branch goes back to its commits.
            Git.run(["update-ref", "refs/heads/\(stuck.branch)", stuck.head] + (after.isEmpty ? [] : [after]), in: root)
            throw Failure(description: "git \(stuck.kind.rawValue) --abort moved \(stuck.branch) to \(after.prefix(8)); it was put back at \(stuck.head.prefix(8)).")
        }
        guard abort.ok else {
            throw Failure(description: "git \(stuck.kind.rawValue) --abort failed in \(stuck.path): \(abort.error.isEmpty ? abort.output : abort.error)")
        }
        if stuck.detached { Git.run(["checkout", "-q", stuck.branch], in: stuck.path) }
        let head = Git.run(["rev-parse", "HEAD"], in: stuck.path).output
        guard isWorktree(root: root, slug: slug), head == stuck.head, interrupted(root: root, slug: slug) == nil else {
            throw Failure(description: "After git \(stuck.kind.rawValue) --abort, \(stuck.path) isn't back on \(stuck.branch) at \(stuck.head.prefix(8)) (HEAD is at \(head.prefix(8))).")
        }
        return stuck.path
    }

    /// The task's worktree: the existing one, or a new one. An empty leftover folder is replaced; one with files
    /// in it is never touched (they might be someone's). One stopped partway through a rebase or merge of the
    /// task's branch is thrown as `Interrupted`, or, with `recover`, aborted back to the branch first.
    public static func open(root: String, slug: String, base: String? = nil, recover: Bool = false) throws -> String {
        if let stuck = interrupted(root: root, slug: slug) {
            guard recover else { throw stuck }
            return try self.recover(root: root, slug: slug)
        }
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
        // A worker brings its branch up to date by merging the base in. Rebasing would drop that merge and replay
        // the commits before it, conflicts and all, so such a branch lands as one commit on top of the base; either
        // way the base's history stays a line.
        if Git.run(["rev-list", "--merges", "--max-count=1", "\(base)..HEAD"], in: path).output.isEmpty {
            guard Git.run(["rebase", "-q", base], in: path).ok else {
                Git.run(["rebase", "--abort"], in: path)
                return .conflict
            }
        } else if !squash(onto: base, in: path) {
            return .conflict
        }
        let tested = Git.run(["rev-parse", "HEAD"], in: path).output
        for (name, command) in [("init_command", setup), ("test command", test)] {
            guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // All of it, in order: what failed may be anywhere in it, and its tail is often a build's warnings.
            let run = Shell.run(executable: "/bin/zsh", args: ["-lc", command], in: path, timeout: timeout, interleaved: true)
            guard run.ok else {
                return .failed((name == "init_command" ? "init_command failed:\n" : "") + run.output)
            }
        }
        return .passed(tested)
    }

    /// Replaces the detached HEAD at `path` with one commit on `base` holding the branch's changes, titled after the
    /// branch's own commits (merges left out) and authored by the last of them. False when they conflict with `base`.
    static func squash(onto base: String, in path: String) -> Bool {
        let tip = Git.run(["rev-parse", "HEAD"], in: path).output
        let subjects = Git.run(["log", "--reverse", "--no-merges", "--format=%s", "\(base)..\(tip)"], in: path).output
            .split(whereSeparator: \.isNewline).map(String.init)
        let author = Git.run(["log", "-1", "--no-merges", "--format=%an <%ae>", "\(base)..\(tip)"], in: path).output
        guard Git.run(["checkout", "-q", "--detach", base], in: path).ok else { return false }
        guard Git.run(["merge", "--squash", "-q", tip], in: path).ok else {
            Git.run(["reset", "-q", "--hard"], in: path)
            return false
        }
        // Nothing of its own beyond what it merged: the base is the result, as a rebase would leave it.
        if Git.run(["diff", "--cached", "--quiet"], in: path).ok { return true }
        let message = (subjects.first.map { [$0] } ?? ["Changes from \(tip.prefix(8))"])
            + (subjects.count > 1 ? [""] + subjects.dropFirst().map { "- \($0)" } : [])
        return Git.run(["commit", "-q", "-m", message.joined(separator: "\n")] + (author.isEmpty ? [] : ["--author", author]), in: path).ok
    }

    /// Files Claude Code reads as settings or instructions (project settings and hooks under `.claude/`, `.mcp.json`,
    /// `CLAUDE.md`) that the task's branch changes from `base`, or that sit changed or new in its worktree, ignored
    /// ones included: a session started there runs what the worker put in them.
    public static func agentConfigChanges(root: String, slug: String, base: String) -> [String] {
        let committed = Git.run(["diff", "--name-only", "-z", "\(base)...\(branch(slug))"], in: root).output
            .split(separator: "\0").map(String.init)
        // Status lines are "XY path" (a rename's old path follows on its own): both readings are checked. Ignored
        // ones ("!! path") count only when Claude reads them as settings or instructions, not its own lock and state
        // files.
        let local = Git.run(["status", "--porcelain", "-z", "--untracked-files=all", "--ignored"], in: path(root: root, slug: slug)).output
            .split(separator: "\0").flatMap { entry in
                [String(entry), String(entry.dropFirst(3))].filter { isAgentConfig($0, ignored: entry.hasPrefix("!! ")) }
            }
        return Array(Set(committed.filter { isAgentConfig($0) } + local)).sorted()
    }

    /// Under `.claude/`, what Claude Code reads as settings or instructions (the rest there is its own state: locks,
    /// scheduled-task bookkeeping).
    static let agentConfigFolders: Set<String> = ["commands", "agents", "skills", "hooks", "output-styles", "rules"]

    /// A file Claude Code reads as settings or instructions. A git-ignored one counts only when it's one Claude
    /// reads (`settings*.json`, `.mcp.json`, `CLAUDE*.md`, what's under `agentConfigFolders`), not one it writes
    /// for itself (`.claude/scheduled_tasks.lock`).
    static func isAgentConfig(_ path: String, ignored: Bool = false) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        let name = parts.last ?? ""
        if [".mcp.json", "CLAUDE.md", "CLAUDE.local.md"].contains(name) { return true }
        guard let claude = parts.firstIndex(of: ".claude") else { return false }
        guard ignored else { return true }
        let inside = parts[(claude + 1)...]
        if inside.count == 1 { return name.hasPrefix("settings") && name.hasSuffix(".json") || name == "CLAUDE.md" }
        return inside.first.map(agentConfigFolders.contains) ?? false
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

/// What a failed test run's output says went wrong, so a message can lead with it instead of the output's tail
/// (often a build's warnings): the tests that failed and their failure lines, else the errors that stopped it.
public struct TestFailures: Equatable, Sendable {
    /// The failing tests, in the order they first failed.
    public var tests: [String] = []
    /// Their failure lines: Swift Testing's ✘ issue lines with the ↳ details under them, XCTest's error: lines.
    public var lines: [String] = []
    /// Swift Testing's closing line ("✘ Test run with 547 tests failed after … with 1 issue.").
    public var run: String?
    /// Tests that started and never ended (the test process crashed or was stopped).
    public var unfinished: [String] = []
    /// Error lines that name no test: the compiler's, a crash's.
    public var errors: [String] = []

    public init(output: String) {
        // Lines since the last issue line, while they may still be part of it.
        var started: [String] = [], ended: Set<String> = [], inIssue: Int?
        for raw in output.components(separatedBy: "\n") {
            let plain = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            let line = plain.trimmingCharacters(in: .whitespaces)
            if let count = inIssue {
                if line.hasPrefix("↳ ") { lines.append(line); continue }
                // An expectation's source can span lines ("Expectation failed: eventually(timeout: 30) {" … "}").
                if count < 20, !line.isEmpty, line.range(of: #"^\S (Test|Suite|Passing) "#, options: .regularExpression) == nil {
                    lines.append(plain.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
                    inIssue = count + 1
                    continue
                }
            }
            inIssue = nil
            if let name = Self.swiftTesting(line, " recorded an issue") {
                add(name)
                lines.append(line)
                inIssue = 0
            } else if let name = Self.swiftTesting(line, " failed after") {
                // A failure with no issue line of its own (a time limit) still shows.
                if !tests.contains(name) { lines.append(line) }
                add(name)
                ended.insert(name)
            } else if let name = Self.swiftTesting(line, " started.", marks: ["◇"]) {
                started.append(name)
            } else if let name = Self.swiftTesting(line, " passed after", marks: ["✔", "􁁛", "➜", "􀟈"]) ?? Self.swiftTesting(line, " skipped") {
                ended.insert(name)
            } else if line.range(of: #"^[✘􀢄] Test run with "#, options: .regularExpression) != nil {
                run = line
            } else if let match = line.range(of: #": error: -?\[?[^ :\]]+[ .][^ :\]]+\]? : "#, options: .regularExpression) {
                // XCTest: "File.swift:12: error: -[Module.Suite testName] : XCTAssertEqual failed: …"
                add(Self.xcTestName(String(line[match]).dropFirst(": error: ".count).dropLast(3)))
                lines.append(line)
            } else if let match = line.range(of: #"^Test Case '[^']+' failed"#, options: .regularExpression) {
                add(Self.xcTestName(line[match].dropFirst("Test Case '".count).prefix { $0 != "'" }))
            } else if line.range(of: #"(^|:\d+(:\d+)?: )error: |Fatal error: "#, options: .regularExpression) != nil,
                      !errors.contains(line) {
                errors.append(line)
            }
        }
        unfinished = started.filter { !ended.contains($0) }
    }

    private mutating func add(_ name: String) {
        if !tests.contains(name) { tests.append(name) }
    }

    /// The name in a Swift Testing event line ("✘ Test answerIsRight() recorded an issue at …"), when it's `event`.
    private static func swiftTesting(_ line: String, _ event: String, marks: [String] = ["✘", "􀢄"]) -> String? {
        for mark in marks where line.hasPrefix(mark + " Test ") {
            let rest = line.dropFirst(mark.count + " Test ".count)
            guard !rest.hasPrefix("run with "), !rest.hasPrefix("run started"), let end = rest.range(of: event) else { return nil }
            // A parameterized test's issue says which arguments: "param(n:) recorded an issue with 1 argument n → 2".
            return String(rest[..<end.lowerBound])
        }
        return nil
    }

    /// "-[Module.Suite testName]" or "Suite.testName" as "Suite.testName".
    private static func xcTestName<S: StringProtocol>(_ raw: S) -> String {
        let parts = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-[]")).split(separator: " ")
        guard parts.count == 2 else { return String(raw) }
        return "\(parts[0].split(separator: ".").last ?? parts[0]).\(parts[1])"
    }

    /// For a message: the failing tests and their lines, else what never finished and the errors, at most `limit`
    /// characters. Nil when the output says neither.
    public func summary(limit: Int = 4000) -> String? {
        var head: [String] = [], body: [String] = []
        if !tests.isEmpty {
            let more = tests.count > 20 ? ", and \(tests.count - 20) more" : ""
            head = ["Failing tests (\(tests.count)): \(tests.prefix(20).joined(separator: ", "))\(more)"]
            body = lines + [run].compactMap { $0 }
        } else if !unfinished.isEmpty || !errors.isEmpty {
            if !unfinished.isEmpty { head.append("Started and never finished: \(unfinished.joined(separator: ", "))") }
            body = errors + [run].compactMap { $0 }
            if !errors.isEmpty { head.append(unfinished.isEmpty ? "No test failed by name; the errors:" : "The errors:") }
        } else {
            return nil
        }
        var text = head.joined(separator: "\n")
        for (index, line) in body.enumerated() {
            guard text.count + line.count + 1 <= limit else {
                text += "\n… and \(body.count - index) more lines."
                break
            }
            text += "\n" + line
        }
        return text
    }
}
