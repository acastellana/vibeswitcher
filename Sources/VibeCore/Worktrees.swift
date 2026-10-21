import Foundation

/// Runs git (never through a shell, never prompting for credentials).
public enum Git {
    public struct Result: Equatable, Sendable {
        public var status: Int32
        public var output: String
        public var error: String
        /// It ran past its time limit and was stopped.
        public var timedOut = false
        /// The work it ran for was cancelled (see `ShellCancel`), and it was stopped.
        public var cancelled = false
        public var ok: Bool { status == 0 && !timedOut && !cancelled }
    }

    /// What git runs with here: never prompting for credentials, and without the optional locks: `git status` and the
    /// like don't take index.lock to save what they refreshed. Killed while they held it (SIGKILL; they remove it on
    /// TERM) they would leave it, and every git that changes that index refuses until someone removes it.
    public static let environment = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]

    /// A run that was stopped (out of time, or cancelled) gives no output, only `error` saying so: its callers take
    /// `output` as git's answer, and what it wrote until then isn't one (a shell it ran may even answer after its
    /// time is up, and exit 0).
    @discardableResult
    public static func run(_ args: [String], in directory: String, timeout: TimeInterval = 120, grace: TimeInterval = 5) -> Result {
        var result = Shell.run(executable: "/usr/bin/git", args: args, in: directory, env: environment, timeout: timeout, grace: grace)
        if result.timedOut || result.cancelled {
            result.output = ""
            let stopped = result.cancelled ? "git was stopped: cancelled." : "git was stopped: it ran past \(Worktrees.duration(timeout))."
            result.error = result.error.isEmpty ? stopped : stopped + "\n" + result.error
        }
        return result
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

    /// With nil, what `body` runs isn't stopped by a cancel (cleanup that must finish: removing a scratch worktree).
    /// The token that was set before is set again afterwards.
    public static func with<T>(_ token: ShellCancel?, _ body: () throws -> T) rethrows -> T {
        let outer = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = token
        defer { Thread.current.threadDictionary[key] = outer }
        return try body()
    }
}

/// What a running program wrote to one of its pipes, read as it comes, so what came before is there even when the
/// pipe never closes (something it started still holds it).
private final class PipeText: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func drain(_ handle: FileHandle) {
        while case let chunk = handle.availableData, !chunk.isEmpty {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let pid = process.processIdentifier
        // Process starts it as the leader of a process group of its own, whose id is its pid: what it starts is in it
        // too, also what has left its family since (a background job whose shell exited). Taken from the pid, not
        // looked up: a command that ends at once is gone before getpgid could ask, and its group with it. A group
        // with that id can only be the one it made (its pid isn't given out again while the group has members).
        // Never ours, whatever happens.
        let group = pid > 0 && pid != getpgrp() ? pid : nil
        // Read while it runs, so a chatty program can't fill the pipe and stall.
        // Their own threads, not the shared pool: callers block too, and many at once (parallel tests, several tool
        // calls) could leave the readers no thread to run on.
        let output = PipeText(), errors = PipeText()
        let readers = DispatchGroup()
        readers.enter()
        Thread.detachNewThread { output.drain(out.fileHandleForReading); readers.leave() }
        // Unused, its write end is still ours: reading it would never end.
        if !interleaved {
            readers.enter()
            Thread.detachNewThread { errors.drain(err.fileHandleForReading); readers.leave() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        let cancel = ShellCancel.current
        while process.isRunning, Date() < deadline, cancel?.isCancelled != true { usleep(20_000) }
        var timedOut = false, cancelled = false
        if process.isRunning {
            cancelled = cancel?.isCancelled == true
            timedOut = !cancelled
            // Out of time: its children (a test runner's workers) go too, or they'd keep running in the worktree.
            // Asked first; whatever is still there after `grace` (it ignores TERM) is killed.
            stop(process, group: group, grace: grace)
        }
        process.waitUntilExit()
        // Its output ends when everything holding the pipe has: something it started may still (a server left in the
        // background). Given `grace`, then its group is stopped; then the output is taken as it is, never waited for
        // without end. (Its group only: its own pid may be another program's by now. The group's id isn't given to a
        // new process while the group has members.)
        if readers.wait(timeout: .now() + grace) == .timedOut {
            if let group, kill(-group, SIGTERM) == 0 {
                let end = Date().addingTimeInterval(grace)
                while kill(-group, 0) == 0, Date() < end { usleep(50_000) }
                kill(-group, SIGKILL)
            }
            _ = readers.wait(timeout: .now() + grace)
        }
        return Git.Result(status: process.terminationStatus, output: output.text, error: errors.text, timedOut: timedOut, cancelled: cancelled)
    }

    /// Stops a program and everything it started: its family and its process group, asked with TERM, then, once it's
    /// gone or `grace` is over (it ignores TERM), killed.
    private static func stop(_ process: Process, group: Int32?, grace: TimeInterval) {
        let pid = process.processIdentifier
        let asked = signalFamily(of: pid, SIGTERM)
        if let group { kill(-group, SIGTERM) }
        let end = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < end { usleep(50_000) }
        signalFamily(of: pid, SIGKILL, also: asked)
        if let group { kill(-group, SIGKILL) }
    }
}

extension Shell {
    /// Signals a process and its descendants (plus `also`, an earlier walk: a descendant whose parent died since
    /// has moved to launchd), children first, each matched by pid and start time (so a pid reused meanwhile isn't
    /// hit). Returns who it signalled.
    @discardableResult
    static func signalFamily(of root: Int32, _ signal: Int32, also earlier: [ProcInfo] = []) -> [ProcInfo] {
        // The table unread in time: the root at least.
        let table = ProcessTable.trySnapshot() ?? ProcessTable.info(pid: root).map { [root: $0] } ?? [:]
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
        /// A command failed; all of its output.
        case failed(String)
        /// Rebasing onto main conflicted; the rebase was undone.
        case conflict
        /// A command (`init_command` or `test command`) ran past `after` seconds and was stopped, with everything it
        /// started; what it wrote until then. Not a failure: nothing says the work is wrong.
        case hung(command: String, after: TimeInterval, output: String)
        /// The run was cancelled (the tool call was), and stopped.
        case cancelled
        case error(String)

        public var isFailure: Bool { if case .failed = self { return true } else { return false } }
    }

    /// "45 min", "90 s": how long a time limit is, as a message says it.
    public static func duration(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? "\(Int((seconds / 60).rounded())) min" : "\(Int(seconds.rounded())) s"
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

    /// The task's worktree on something other than its branch, with nothing in progress there: a branch made in it
    /// (for a review, by a review flow) or a detached HEAD. Workers and the lead are denied `git switch` on purpose,
    /// so the lead's tools put it back (`putBack`).
    public struct OffBranch: Error, Equatable, Sendable, CustomStringConvertible {
        public var path: String
        /// The task's branch.
        public var branch: String
        /// The branch it's on instead; nil when HEAD is detached.
        public var on: String?
        /// The commit it's on.
        public var commit: String
        /// Its commits that aren't on the task's branch ("1a2b3c4d subject"), newest first.
        public var ahead: [String] = []
        public var uncommitted: [Uncommitted] = []

        /// "branch review-x" or "a detached HEAD".
        public var place: String { on.map { "branch \($0)" } ?? "a detached HEAD" }
        /// What brings its commits onto the task's branch, run there.
        public var mergeCommand: String { "git merge \(on ?? String(commit.prefix(12)))" }
        /// What commits the uncommitted files where they are: `git add` for the new ones, then one `git commit -am`.
        public var commitCommand: String {
            let new = uncommitted.filter { $0.state == "untracked" }.map(\.path)
            return (new.isEmpty ? "" : "`git add \(new.map(Self.quoted).joined(separator: " "))`, then ") + "`git commit -am \"<what they are>\"`"
        }

        public var description: String {
            var text = "\(path) is on \(place) at \(commit.prefix(8)), not on \(branch)"
            if !ahead.isEmpty {
                text += "; \(ahead.count) commit\(ahead.count == 1 ? "" : "s") there \(ahead.count == 1 ? "isn't" : "aren't") on \(branch): "
                    + ahead.prefix(5).joined(separator: "; ") + (ahead.count > 5 ? "; …" : "")
            }
            if !uncommitted.isEmpty { text += "; uncommitted: " + uncommitted.map { "\($0.path) (\($0.state))" }.joined(separator: ", ") }
            return text + "."
        }

        static func quoted(_ path: String) -> String {
            path.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? path : "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
    }

    /// The task's worktree when it's this repository's worktree but not on the task's branch (which exists), and no
    /// rebase, merge, cherry-pick, revert or bisect is in progress there (those are `interrupted`'s, or not the
    /// task's to undo); nil otherwise.
    public static func offBranch(root: String, slug: String) -> OffBranch? {
        let path = path(root: root, slug: slug), branch = branch(slug)
        guard FileManager.default.fileExists(atPath: path + "/.git") else { return nil }
        let resolved = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let top = Git.run(["rev-parse", "--show-toplevel"], in: path)
        guard top.ok, resolved(top.output) == resolved(path) else { return nil }
        let common = { (dir: String) -> String? in
            let found = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir)
            return found.ok ? resolved(found.output) : nil
        }
        guard let mine = common(path), mine == common(root) else { return nil }
        guard Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root).ok else { return nil }
        let on = Git.run(["symbolic-ref", "-q", "HEAD"], in: path).output
        guard on != "refs/heads/\(branch)" else { return nil }
        let gitPath = { (name: String) in Git.run(["rev-parse", "--path-format=absolute", "--git-path", name], in: path).output }
        for busy in ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"]
        where FileManager.default.fileExists(atPath: gitPath(busy)) { return nil }
        let commit = Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: path).output
        guard !commit.isEmpty else { return nil }
        let ahead = Git.run(["log", "--format=%h %s", "--abbrev=8", "refs/heads/\(branch)..\(commit)"], in: path).output
            .split(whereSeparator: \.isNewline).map(String.init)
        let status = Git.run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: path)
        return OffBranch(path: path, branch: branch, on: on.hasPrefix("refs/heads/") ? String(on.dropFirst("refs/heads/".count)) : nil,
                         commit: commit, ahead: ahead, uncommitted: uncommitted(porcelain: status.output))
    }

    /// Switches the task's worktree that's off its branch back onto it, returning where it was. Uncommitted files
    /// stop it (thrown as the `OffBranch`, nothing moved), unless `carry`: then they come along as `git switch`
    /// carries them, which refuses (a `Failure`, nothing moved) rather than overwrite any. The other branch, and the
    /// commit it was on, stay as they were.
    @discardableResult
    public static func putBack(root: String, slug: String, carry: Bool = false) throws -> OffBranch {
        guard let off = offBranch(root: root, slug: slug) else {
            throw Failure(description: "\(path(root: root, slug: slug)) isn't this repository's worktree on another branch or a detached HEAD.")
        }
        guard carry || off.uncommitted.isEmpty else { throw off }
        let switched = Git.run(["switch", "-q", off.branch], in: off.path)
        guard switched.ok else {
            throw Failure(description: "git switch \(off.branch) failed in \(off.path): \(switched.error.isEmpty ? switched.output : switched.error)")
        }
        guard isWorktree(root: root, slug: slug) else {
            throw Failure(description: "After git switch \(off.branch), \(off.path) still isn't on \(off.branch).")
        }
        return off
    }

    /// The task's worktree: the existing one, or a new one. An empty leftover folder is replaced; one with files
    /// in it is never touched (they might be someone's). One stopped partway through a rebase of the task's branch,
    /// or a merge on a detached HEAD, is thrown as `Interrupted`, or, with `recover`, aborted back to the branch
    /// first. A merge into the branch itself is the worker's to finish: opened as it is, unless `recover`.
    public static func open(root: String, slug: String, base: String? = nil, recover: Bool = false) throws -> String {
        if let stuck = interrupted(root: root, slug: slug) {
            if !recover, stuck.kind == .merge, !stuck.detached { return stuck.path }
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

    /// Fast-forwards main to `commit` (the tested one; the branch's head when nil). Never rewrites anything and
    /// never touches uncommitted work: uncommitted changes in the main checkout to files the merge changes, main
    /// checked out elsewhere, or a commit not on top of main is refused with the reason.
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
    /// isn't on top of it, when its checkout has uncommitted changes to files the merge changes (named), or when it's
    /// checked out in another worktree.
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
            if let lock = IndexLock.find(in: root) { return .refused(refusal(lock)) }
            // Only the uncommitted files the merge changes stop it, as they would stop git: the rest is the user's
            // work in progress, and stays as it is. git's own check still holds: --ff-only overwrites nothing.
            switch uncommitted(in: root, changedFrom: expected, to: commit) {
            case .failure(let error): return .refused(error.description)
            case .success(let overlap) where !overlap.isEmpty: return .refused(refusal(overlap))
            case .success: break
            }
            let merge = Git.run(["merge", "--ff-only", "-q", commit], in: root)
            guard merge.ok else {
                // One that came meanwhile: said whose it is, not as git's "Another git process seems to be running".
                if let lock = IndexLock.find(in: root) { return .refused(refusal(lock)) }
                return .refused(merge.error)
            }
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
    /// a worker commits or edits meanwhile. The worktree is removed afterwards, also when the run is cancelled.
    /// A command that runs past `timeout` is stopped with everything it started (`hung`); a cancel stops it the same
    /// way (`cancelled`); a rebase that fails on something else than a conflict says what failed (`error`).
    /// The commands run with HOME, CFFIXED_USER_HOME and TMPDIR in `home` (by default next to `scratch`), made empty
    /// before and removed after, as workers and verifiers run the tests: never the user's own ~/.vibeswitcher,
    /// Keychain or app.log. A failed or hung run's output starts by naming it.
    /// The commands hold the Mac-wide test and build lock (`lock`; nil: none) while they run.
    public static func rebaseAndTest(root: String, commit: String, onto base: String, setup: String? = nil, test: String?,
                                     scratch: URL, home: URL? = nil, timeout: TimeInterval = testTimeout,
                                     lock: TestLock? = TestLock.standard()) -> Check {
        let path = scratch.path
        let home = (home ?? scratch.deletingLastPathComponent().appendingPathComponent(scratch.lastPathComponent + "-home")).path
        let cancel = ShellCancel.current
        // Not stopped by the cancel: a worktree left half removed stays in git's list.
        let remove = {
            ShellCancel.with(nil) {
                Git.run(["worktree", "remove", "--force", path], in: root)
                try? FileManager.default.removeItem(atPath: path)
                Git.run(["worktree", "prune"], in: root)
                try? FileManager.default.removeItem(atPath: home)
            }
        }
        if FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: home) { remove() }
        guard cancel?.isCancelled != true else { return .cancelled }
        try? FileManager.default.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { remove() }
        let added = Git.run(["worktree", "add", "--detach", "-q", path, commit], in: root)
        guard added.ok else {
            if cancel?.isCancelled == true { return .cancelled }
            return .error(added.error.isEmpty ? "Couldn't set up a worktree to test \(commit.prefix(8)) in." : added.error)
        }
        // A worker brings its branch up to date by merging the base in. Rebasing would drop that merge and replay
        // the commits before it, conflicts and all, so such a branch lands as one commit on top of the base; either
        // way the base's history stays a line.
        if Git.run(["rev-list", "--merges", "--max-count=1", "\(base)..HEAD"], in: path).output.isEmpty {
            let rebase = Git.run(["rebase", "-q", base], in: path)
            if !rebase.ok {
                let conflict = unmerged(in: path)
                Git.run(["rebase", "--abort"], in: path)
                if cancel?.isCancelled == true { return .cancelled }
                return conflict ? .conflict : .error("Rebasing \(commit.prefix(8)) onto \(base.prefix(8)) failed, and not on a conflict: \(said(rebase))")
            }
        } else if let stopped = squash(onto: base, in: path) {
            return cancel?.isCancelled == true ? .cancelled : stopped
        }
        guard cancel?.isCancelled != true else { return .cancelled }
        let tested = Git.run(["rev-parse", "HEAD"], in: path).output
        return runChecks(setup: setup, test: test, in: path, home: home, timeout: timeout, lock: lock,
                         as: "VibeSwitcher's merge test of \(commit.prefix(8)) in \(root)").stopped ?? .passed(tested)
    }

    /// Runs `setup` then `test` (each when given) in `path` with HOME, CFFIXED_USER_HOME and TMPDIR in `home` (made
    /// here, removed by the caller), as merge and an audit's shared run do. `stopped`: nil when every command passed,
    /// else how it stopped (failed, hung, cancelled, or the home couldn't be made); `outputs`: each command that ran,
    /// with all of its output, in order. With `lock`, they run holding it (as `holder` says), after waiting for it up
    /// to `timeout`; the commands get its path in `TestLock.heldVariable`, so a script among them doesn't wait for it.
    static func runChecks(setup: String?, test: String?, in path: String, home: String, timeout: TimeInterval,
                          lock: TestLock? = nil, as holder: String = "VibeSwitcher's test run")
        -> (stopped: Check?, outputs: [(name: String, output: String)]) {
        let cancel = ShellCancel.current
        let tmp = home + "/tmp"
        do {
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return (.error("Couldn't make the scratch home \(home) to run the tests in: \(error.localizedDescription)"), [])
        }
        var header = "HOME, CFFIXED_USER_HOME and TMPDIR: \(home) (a scratch folder, removed afterwards)\n"
        var held: TestLock.Held?
        defer { held?.release() }
        let runs = [setup, test].contains { !($0 ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if let lock, runs {
            switch lock.acquire(as: holder, timeout: timeout, cancel: cancel) {
            case .held(let taken, let waited, let after):
                held = taken
                if let after { header += "Waited \(duration(waited)) for the Mac-wide test and build lock, held by \(after).\n" }
            case .busy(let who):
                return (.error("Another run held the Mac-wide test and build lock (\(lock.path)) for over \(duration(timeout)): \(who ?? "it didn't say who"). Nothing was tested; try again once it's done."), [])
            case .cancelled:
                return (.cancelled, [])
            case .failed(let text):
                return (.error(text + " Nothing was tested."), [])
            }
        }
        var outputs: [(name: String, output: String)] = []
        for (name, command) in [("init_command", setup), ("test command", test)] {
            guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // HOME only once the login shell has read the user's own startup files (their PATH, from their home); the
            // command and all it starts have the scratch one.
            let script = "export HOME=\(RecentProjects.shellQuote(home))\n" + command
            // All of it, in order: what failed may be anywhere in it, and its tail is often a build's warnings.
            var env = ["CFFIXED_USER_HOME": home, "TMPDIR": tmp + "/"]
            if let lock, held != nil { env[TestLock.heldVariable] = lock.path }
            let run = Shell.run(executable: "/bin/zsh", args: ["-lc", script], in: path, env: env, timeout: timeout, interleaved: true)
            outputs.append((name, header + run.output))
            if run.cancelled || cancel?.isCancelled == true { return (.cancelled, outputs) }
            if run.timedOut { return (.hung(command: name, after: timeout, output: header + run.output), outputs) }
            guard run.ok else {
                return (.failed((name == "init_command" ? "init_command failed:\n" : "") + header + run.output), outputs)
            }
        }
        return (nil, outputs)
    }

    /// An audit's shared run (audit_finders 2 or 3): `setup` and `test` on exactly `commit`, as the branch is (not
    /// rebased), in a detached worktree of its own at `scratch` under a scratch home, both removed afterwards. Each
    /// command's whole output goes to `<logs>/init.log` and `<logs>/test.log` for the finders to read, with
    /// `<logs>/run.txt` saying how it went (written last: a folder without it holds no finished run).
    public static func auditRun(root: String, commit: String, setup: String?, test: String?, scratch: URL, home: URL,
                                logs: URL, timeout: TimeInterval = testTimeout, lock: TestLock? = TestLock.standard()) -> AuditRun {
        let path = scratch.path, homePath = home.path
        let remove = {
            ShellCancel.with(nil) {
                Git.run(["worktree", "remove", "--force", path], in: root)
                try? FileManager.default.removeItem(atPath: path)
                Git.run(["worktree", "prune"], in: root)
                try? FileManager.default.removeItem(atPath: homePath)
            }
        }
        if FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: homePath) { remove() }
        try? FileManager.default.removeItem(at: logs)
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return AuditRun(outcome: .error("Couldn't make \(logs.path) for the run's logs: \(error.localizedDescription)"), logs: []) }
        defer { remove() }
        let added = Git.run(["worktree", "add", "--detach", "-q", path, commit], in: root)
        guard added.ok else {
            return AuditRun(outcome: .error(added.error.isEmpty ? "Couldn't set up a worktree to test \(commit.prefix(8)) in." : added.error), logs: [])
        }
        let (stopped, outputs) = runChecks(setup: setup, test: test, in: path, home: homePath, timeout: timeout, lock: lock,
                                           as: "VibeSwitcher's audit run of \(commit.prefix(8)) in \(root)")
        var files: [String] = []
        for (name, output) in outputs {
            let file = logs.appendingPathComponent(name == "init_command" ? "init.log" : "test.log")
            if (try? Data(output.utf8).write(to: file, options: .atomic)) != nil { files.append(file.path) }
        }
        let outcome: AuditRun.Outcome
        switch stopped {
        case nil: outcome = outputs.contains { $0.name == "test command" } ? .passed : .noTests
        case .failed: outcome = .failed(outputs.last?.name ?? "test command")
        case .hung(let command, let after, _): outcome = .hung(command, after: after)
        case .cancelled: outcome = .cancelled
        case .error(let text): outcome = .error(text)
        case .passed, .conflict: outcome = .error("unexpected")
        }
        if case .cancelled = outcome { return AuditRun(outcome: outcome, logs: files) }
        try? Data((outcome.text + "\n").utf8).write(to: logs.appendingPathComponent("run.txt"), options: .atomic)
        return AuditRun(outcome: outcome, logs: files)
    }

    /// An audit's shared build and test run: how it went and its logs.
    public struct AuditRun: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable {
            case passed
            /// No test_command: only init_command ran, if any.
            case noTests
            /// That command failed (init_command or the test command).
            case failed(String)
            case hung(String, after: TimeInterval)
            case cancelled
            case error(String)

            /// "the test command passed", "init_command failed", …: what the finders and the lead are told.
            public var text: String {
                switch self {
                case .passed: return "the test command passed"
                case .noTests: return "no test_command is set, so no tests ran"
                case .failed(let command): return "\(command) failed"
                case .hung(let command, let after): return "\(command) hung, stopped after \(Worktrees.duration(after))"
                case .cancelled: return "cancelled"
                case .error(let text): return "it couldn't run: \(text)"
                }
            }
        }
        public var outcome: Outcome
        /// The logs written, init.log first.
        public var logs: [String]

        public init(outcome: Outcome, logs: [String]) {
            self.outcome = outcome
            self.logs = logs
        }
    }

    /// How long the merge queue's commands may run before they're taken as hung: generous, a full build and test run
    /// on a slow Mac takes a fraction of it.
    public static let testTimeout: TimeInterval = 45 * 60

    /// A rebase or merge at `path` stopped on a conflict: it left files unmerged.
    static func unmerged(in path: String) -> Bool {
        !Git.run(["diff", "--name-only", "--diff-filter=U"], in: path).output.isEmpty
    }

    /// What git said when a command failed.
    static func said(_ result: Git.Result) -> String {
        let text = [result.error, result.output].first { !$0.isEmpty } ?? ""
        return text.isEmpty ? "git exited with status \(result.status)." : String(text.suffix(1500))
    }

    /// Replaces the detached HEAD at `path` with one commit on `base` holding the branch's changes, titled after the
    /// branch's own commits (merges left out) and authored by the last of them. Nil when that's done; `conflict` when
    /// they conflict with `base`; `error`, saying what failed, when something else stops it (a hook, a missing commit).
    static func squash(onto base: String, in path: String) -> Check? {
        let tip = Git.run(["rev-parse", "HEAD"], in: path).output
        let subjects = Git.run(["log", "--reverse", "--no-merges", "--format=%s", "\(base)..\(tip)"], in: path).output
            .split(whereSeparator: \.isNewline).map(String.init)
        let author = Git.run(["log", "-1", "--no-merges", "--format=%an <%ae>", "\(base)..\(tip)"], in: path).output
        let checkout = Git.run(["checkout", "-q", "--detach", base], in: path)
        guard checkout.ok else { return .error("Checking out \(base.prefix(8)) to put the branch on failed: \(said(checkout))") }
        let merge = Git.run(["merge", "--squash", "-q", tip], in: path)
        guard merge.ok else {
            let conflict = unmerged(in: path)
            Git.run(["reset", "-q", "--hard"], in: path)
            return conflict ? .conflict : .error("Squashing \(tip.prefix(8)) onto \(base.prefix(8)) failed, and not on a conflict: \(said(merge))")
        }
        // Nothing of its own beyond what it merged: the base is the result, as a rebase would leave it.
        if Git.run(["diff", "--cached", "--quiet"], in: path).ok { return nil }
        let message = (subjects.first.map { [$0] } ?? ["Changes from \(tip.prefix(8))"])
            + (subjects.count > 1 ? [""] + subjects.dropFirst().map { "- \($0)" } : [])
        let committed = Git.run(["commit", "-q", "-m", message.joined(separator: "\n")] + (author.isEmpty ? [] : ["--author", author]), in: path)
        return committed.ok ? nil : .error("Committing the branch squashed onto \(base.prefix(8)) failed: \(said(committed))")
    }

    /// Files Claude Code reads as settings or instructions (project settings and hooks under `.claude/`, `.mcp.json`,
    /// `CLAUDE.md`) that the task's branch changes from `base` (`committedAgentConfig`), or that sit changed or new at
    /// its worktree's root, ignored ones included (`localAgentConfig`): a session started there runs what the worker
    /// put in them.
    public static func agentConfigChanges(root: String, slug: String, base: String) -> [String] {
        Array(Set(committedAgentConfig(root: root, slug: slug, base: base) + localAgentConfig(root: root, slug: slug))).sorted()
    }

    /// The settings or instructions files the branch's commits change from `base`: what would merge.
    public static func committedAgentConfig(root: String, slug: String, base: String) -> [String] {
        Git.run(["diff", "--name-only", "-z", "\(base)...\(branch(slug))"], in: root).output
            .split(separator: "\0").map(String.init).filter { isAgentConfig($0) }.sorted()
    }

    /// Settings or instructions files changed or new in the worktree, not committed, that Claude reads in a session
    /// started there: under the root's `.claude/`, `.mcp.json` at the root, and `CLAUDE*.md` in any folder (read when
    /// it works on files there). Ignored ones ("!! path") count only when Claude reads them, not its own lock and state
    /// files. A `.claude/` deeper down (a scratch home a bench left) is no setting of this worktree's: it's a leftover
    /// (`leftovers`).
    public static func localAgentConfig(root: String, slug: String) -> [String] {
        status(in: path(root: root, slug: slug), ignored: true).filter { entry in
            let parts = entry.path.split(separator: "/")
            let read = parts.first == ".claude" || entry.path == ".mcp.json" || ["CLAUDE.md", "CLAUDE.local.md"].contains(parts.last ?? "")
            return read && isAgentConfig(entry.path, ignored: entry.code == "!!")
        }.map(\.path).sorted()
    }

    /// An untracked file in a worktree: nothing of it merges, and the worker should have removed it.
    public struct Leftover: Equatable, Sendable {
        public var path: String
        public var bytes: Int64
        /// "path (2.0 KB)".
        public var text: String { "\(path) (\(Leftover.size(bytes)))" }

        /// "512 B", "2.0 KB", "3.4 MB", "1.2 GB".
        public static func size(_ bytes: Int64) -> String {
            let units = ["KB", "MB", "GB"]
            guard bytes >= 1024 else { return "\(max(0, bytes)) B" }
            var value = Double(bytes) / 1024, unit = 0
            while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
            return String(format: "%.1f %@", value, units[unit])
        }
    }

    /// The untracked files in the task's worktree (git-ignored ones, like build output, aren't), by path, each with its
    /// size.
    public static func leftovers(root: String, slug: String) -> [Leftover] {
        let folder = path(root: root, slug: slug)
        return status(in: folder, ignored: false).filter { $0.code == "??" }.map { entry in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder + "/" + entry.path))?[.size] as? NSNumber
            return Leftover(path: entry.path, bytes: size?.int64Value ?? 0)
        }.sorted { $0.path < $1.path }
    }

    /// `git status` in `folder`, every untracked file listed (and ignored ones with `ignored`): each entry's code
    /// ("??", "!!", " M", "R ") and path, a rename's or copy's old path as an entry of its own with the same code.
    static func status(in folder: String, ignored: Bool) -> [(code: String, path: String)] {
        let fields = Git.run(["status", "--porcelain", "-z", "--untracked-files=all"] + (ignored ? ["--ignored"] : []), in: folder).output
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [(code: String, path: String)] = []
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard field.count > 3 else { continue }
            let code = String(field.prefix(2))
            entries.append((code, String(field.dropFirst(3))))
            if code.contains("R") || code.contains("C"), index < fields.count {
                entries.append((code, fields[index]))
                index += 1
            }
        }
        return entries
    }

    /// What `base` brought since `commit` (a task's branch) last took it in: the commits since their merge-base, each
    /// with the files it touched, and the files the base and the branch each changed since then.
    public struct BaseSince: Equatable, Sendable {
        public struct Commit: Equatable, Sendable {
            public var sha: String
            public var subject: String
            public var files: [String]
            /// "abc1234 subject".
            public var line: String { "\(sha) \(subject)" }
        }

        public var mergeBase: String
        /// Newest first.
        public var commits: [Commit]
        public var baseFiles: [String]
        public var branchFiles: [String]

        /// Files both sides changed: a branch that hasn't taken in what the base did to them breaks or conflicts
        /// at merge, rebased onto the base.
        public var overlap: [String] { Set(baseFiles).intersection(branchFiles).sorted() }

        /// The base's commits that touched any of `files`, newest first.
        public func commits(touching files: [String]) -> [Commit] {
            let wanted = Set(files)
            return commits.filter { !wanted.isDisjoint(with: $0.files) }
        }
    }

    /// `BaseSince` for `commit` on `base` (both refs or shas), or what git said when it can't be told.
    public static func baseSince(root: String, base: String, commit: String) -> Swift.Result<BaseSince, Failure> {
        let found = Git.run(["merge-base", base, commit], in: root)
        guard found.ok, !found.output.isEmpty else {
            return .failure(Failure(description: "git merge-base \(base) \(commit.prefix(8)) failed: \(said(found))"))
        }
        let mergeBase = found.output
        // Renames as a deletion and an addition: both paths count.
        func changed(to tip: String) -> Swift.Result<[String], Failure> {
            let diff = Git.run(["diff", "--name-only", "--no-renames", "-z", mergeBase, tip], in: root)
            guard diff.ok else { return .failure(Failure(description: "git diff \(mergeBase.prefix(8)) \(tip.prefix(8)) failed: \(said(diff))")) }
            return .success(diff.output.split(separator: "\0").map(String.init))
        }
        // "\u{1}sha\u{2}subject\0\nfile\0file\0" per commit; a merge with what it brought to the base's line.
        let log = Git.run(["log", "-z", "--name-only", "--no-renames", "--diff-merges=first-parent", "--format=%x01%h%x02%s", "\(mergeBase)..\(base)"], in: root)
        guard log.ok else { return .failure(Failure(description: "git log \(mergeBase.prefix(8))..\(base) failed: \(said(log))")) }
        let commits = log.output.split(separator: "\u{1}").compactMap { chunk -> BaseSince.Commit? in
            var parts = chunk.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty else { return nil }
            let header = parts.removeFirst().split(separator: "\u{2}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let files = parts.map { $0.hasPrefix("\n") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
            return BaseSince.Commit(sha: header[0], subject: header.count > 1 ? header[1] : "", files: files)
        }
        return changed(to: base).flatMap { baseFiles in
            changed(to: commit).map { BaseSince(mergeBase: mergeBase, commits: commits, baseFiles: baseFiles, branchFiles: $0) }
        }
    }

    /// The files a merge of `commit` into `base` conflicts in (empty: it merges cleanly), from a trial merge that
    /// touches no worktree, index or ref (`git merge-tree --write-tree`); what git said when it can't be told.
    public static func trialMerge(root: String, base: String, commit: String) -> Swift.Result<[String], Failure> {
        let merged = Git.run(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", base, commit], in: root)
        // "tree\0file\0file\0": status 0 clean, 1 conflicted; 1 is also what a ref it can't merge gives, with no tree.
        let parts = merged.output.split(separator: "\0").map(String.init)
        guard merged.status == 0 || merged.status == 1, !merged.timedOut, !merged.cancelled,
              let tree = parts.first, tree.count >= 40, tree.allSatisfy(\.isHexDigit) else {
            return .failure(Failure(description: "git merge-tree \(base) \(commit.prefix(8)) failed: \(said(merged))"))
        }
        return .success(merged.status == 0 ? [] : Array(parts.dropFirst()))
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

    /// An uncommitted file in a checkout, and how: "modified", "staged", "staged and modified", "untracked" or
    /// "unmerged". A rename counts by both its names.
    public struct Uncommitted: Equatable, Sendable {
        public var path: String
        public var state: String
    }

    /// The uncommitted files in `checkout` (staged, unstaged and untracked; ignored ones aren't) at paths that change
    /// from `from` to `to`, files added or removed included.
    public static func uncommitted(in checkout: String, changedFrom from: String, to: String) -> Swift.Result<[Uncommitted], Failure> {
        let diff = Git.run(["diff", "--name-only", "-z", "--no-renames", from, to], in: checkout)
        guard diff.ok else { return .failure(Failure(description: "Can't tell which files the merge changes: \(diff.error)")) }
        let changed = Set(diff.output.split(separator: "\0").map(String.init))
        guard !changed.isEmpty else { return .success([]) }
        let status = Git.run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: checkout)
        guard status.ok else { return .failure(Failure(description: "Can't read the main checkout's uncommitted changes: \(status.error)")) }
        return .success(uncommitted(porcelain: status.output).filter { changed.contains($0.path) })
    }

    /// The files in `git status --porcelain=v2 -z` output.
    static func uncommitted(porcelain: String) -> [Uncommitted] {
        var found: [Uncommitted] = []
        var entries = porcelain.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            // "1 XY sub mH mI mW hH hI path", "2 XY … score path" then the old path, "u XY … path", "? path".
            let fields = { (count: Int) in entry.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false).map(String.init) }
            switch entry.first {
            case "?":
                found.append(Uncommitted(path: String(entry.dropFirst(2)), state: "untracked"))
            case "1", "2":
                let parts = fields(entry.first == "1" ? 8 : 9)
                guard let path = parts.last, parts.count >= 2 else { continue }
                let xy = Array(parts[1])
                let staged = xy.first != ".", modified = xy.last != "."
                let state = staged && modified ? "staged and modified" : staged ? "staged" : "modified"
                found.append(Uncommitted(path: path, state: state))
                if entry.first == "2", let old = entries.next() { found.append(Uncommitted(path: String(old), state: state)) }
            case "u":
                if let path = fields(10).last { found.append(Uncommitted(path: path, state: "unmerged")) }
            default:
                continue
            }
        }
        return found
    }

    /// Why a merge into the main checkout can't go on over `files`, its uncommitted changes the merge would change.
    public static func refusal(_ files: [Uncommitted]) -> String {
        let named = files.map { "\($0.path) (\($0.state))" }.joined(separator: ", ")
        let (which, them) = files.count == 1 ? ("a file", "it") : ("files", "them")
        return "The main checkout has uncommitted changes to \(which) this merge changes: \(named). Commit or stash \(them) first; the checkout's other uncommitted changes can stay."
    }

    /// Why a merge into the main checkout can't go on while `lock` is there, and what to do. A stale one is left: the
    /// main checkout is the user's too, and their own sessions run git there.
    public static func refusal(_ lock: IndexLock) -> String {
        if !lock.checked {
            return "\(lock). It's left there; merge again in a while, and if it's still there, tell the user (`lsof '\(lock.path)'` shows who has it open) before anyone removes it."
        }
        return lock.stale
            ? "\(lock). VibeSwitcher leaves it: the main checkout is shared with the user's own sessions. Once nothing of theirs runs git there, it can be removed (`rm '\(lock.path)'`); then merge again."
            : "\(lock). git can't move the branch in that checkout until it's done; merge again then."
    }

    /// The main checkout's index.lock when `base` is checked out there: what a merge into it would fail on.
    public static func indexLock(blocking base: String, root: String) -> IndexLock? {
        let resolved = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        guard let place = checkout(of: base, root: root), resolved(place) == resolved(root) else { return nil }
        return IndexLock.find(in: root)
    }
}

/// A checkout's index.lock. git makes it to change the index (or to save one it refreshed) and removes it when it's
/// done, also when it's stopped with TERM, HUP or INT; only a git killed outright (SIGKILL) leaves it, and then every
/// git that changes that index refuses until it's removed.
public struct IndexLock: Equatable, Sendable, CustomStringConvertible {
    public struct Holder: Equatable, Sendable {
        public var pid: Int32
        /// Its command line ("git commit -m …").
        public var command: String
    }

    public var path: String
    /// The checkout whose index it locks.
    public var checkout: String
    public var size: Int
    /// When it was last written (made, for one git never wrote into).
    public var modified: Date
    /// The live process that holds it: one with it open, else a git running in its checkout (a `git commit` waiting
    /// for its editor keeps it closed). Nil when there's none, or when that wasn't found out (`checked`).
    public var holder: Holder?
    /// Whether the search for its holder finished in its time. It reads the whole process table, which on a loaded
    /// Mac can take minutes.
    public var checked = true
    var inode: UInt64

    /// Nobody holds it, as far as a search that finished could tell.
    public var stale: Bool { checked && holder == nil }

    /// Who holds a lock, as far as a search could tell before its deadline.
    public enum Holding: Equatable, Sendable {
        case held(Holder)
        case none
        /// The deadline came first.
        case unknown
    }

    /// Looks for the holder of the lock at `path` in `checkout`, giving up (`unknown`) at the deadline.
    public typealias Search = @Sendable (_ path: String, _ checkout: String, _ deadline: Date) -> Holding

    public func age(now: Date = Date()) -> TimeInterval { max(0, now.timeIntervalSince(modified)) }

    public var description: String {
        if let holder { return "\(path) is held by pid \(holder.pid) (\(holder.command)), at work in \(checkout)" }
        let written = "It's \(size) bytes, last written \(LeadToolset.age(age())) ago (\(LeadBoard.clock(modified.timeIntervalSince1970)))"
        guard checked else { return "\(path) is there, and VibeSwitcher couldn't check who holds it in time. \(written)" }
        return "\(path) is stale: no process has it open and no git runs in \(checkout). \(written), left by a git that was killed outright"
    }

    /// The index.lock of the checkout at `checkout` (the main one or a worktree), with its holder; nil when there's none.
    /// Its holder is looked for for at most `timeLimit`, and never on the main thread (the search reads the whole
    /// process table: on a loaded Mac that froze the window for minutes): then it's not `checked`.
    public static func find(in checkout: String, timeLimit: TimeInterval = 10, search: @escaping Search = holder) -> IndexLock? {
        let asked = Git.run(["rev-parse", "--path-format=absolute", "--git-path", "index.lock"], in: checkout)
        guard asked.ok, !asked.output.isEmpty else { return nil }
        return at(asked.output, checkout: checkout, timeLimit: timeLimit, search: search)
    }

    static func at(_ path: String, checkout: String, timeLimit: TimeInterval, search: @escaping Search) -> IndexLock? {
        // Looked at again after the search for its holder: one that went meanwhile was a git at work, now done; one
        // made again meanwhile is looked at anew.
        for _ in 0..<3 {
            guard let before = file(path) else { return nil }
            let holding = Thread.isMainThread ? .unknown : look(path, checkout: checkout, timeLimit: timeLimit, search: search)
            guard let after = file(path) else { return nil }
            guard after.inode == before.inode else { continue }
            var lock = IndexLock(path: path, checkout: checkout, size: after.size, modified: after.modified, inode: after.inode)
            switch holding {
            case .held(let holder): lock.holder = holder
            case .none: break
            case .unknown: lock.checked = false
            }
            return lock
        }
        return nil
    }

    /// The search on a thread of its own, waited for until `timeLimit`: the process table can't be read in pieces,
    /// and a read that takes minutes mustn't hold up a merge. One still running then ends on its own (it stops at the
    /// deadline wherever it can); its answer is dropped.
    private static func look(_ path: String, checkout: String, timeLimit: TimeInterval, search: @escaping Search) -> Holding {
        final class Answer: @unchecked Sendable {
            let lock = NSLock()
            var holding = Holding.unknown
        }
        let answer = Answer(), done = DispatchSemaphore(value: 0)
        let deadline = Date().addingTimeInterval(timeLimit)
        Thread.detachNewThread {
            let holding = search(path, checkout, deadline)
            answer.lock.lock()
            answer.holding = holding
            answer.lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeLimit) == .success else { return .unknown }
        answer.lock.lock()
        defer { answer.lock.unlock() }
        return answer.holding
    }

    private static func file(_ path: String) -> (inode: UInt64, size: Int, modified: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        return (inode, (attributes[.size] as? NSNumber)?.intValue ?? 0, attributes[.modificationDate] as? Date ?? Date())
    }

    /// Removes it if it's still this file, stale and at least `minimumAge` old (a git that has only just made it may
    /// not have been seen yet), as a search for its holder made now says. Never one a process holds, nor one whose
    /// holder couldn't be checked. Whether it was removed.
    public func removeIfStale(minimumAge: TimeInterval = 60, timeLimit: TimeInterval = 10, search: @escaping Search = Self.holder) -> Bool {
        guard stale, let now = Self.at(path, checkout: checkout, timeLimit: timeLimit, search: search),
              now.inode == inode, now.stale, now.age() >= minimumAge else { return false }
        return unlink(path) == 0
    }

    /// The path as the kernel names an open file and a working directory (`/private/var/…`, which Foundation's
    /// resolvingSymlinksInPath turns back into `/var/…`).
    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The search `find` makes by default: gits with the file open or running in the checkout, then any other process
    /// with it open.
    public static let holder: Search = { path, checkout, deadline in holder(of: path, checkout: checkout, deadline: deadline) }

    private static func holder(of path: String, checkout: String, deadline: Date) -> Holding {
        let resolved = real
        let target = resolved(path)
        // A list that couldn't be read says nothing: not that nobody holds it. Names only: the whole table (with
        // ttys, see `ProcessTable.names`) stalled for a minute on a busy Mac, past every time limit.
        guard let names = ProcessTable.names() else { return .unknown }
        let me = getpid()
        let command = { (pid: Int32) -> Holding in
            let words = ProcessTable.readArguments(pid: pid)
            let line = words.isEmpty ? names[pid] ?? "" : words.joined(separator: " ")
            return .held(Holder(pid: pid, command: line.count > 120 ? line.prefix(119) + "…" : line))
        }
        let pids = names.keys.filter { $0 > 0 && $0 != me }.sorted()
        // The gits first: they're few, and the holder is nearly always one.
        let gits = pids.filter { names[$0] == "git" || names[$0]?.hasPrefix("git-") == true }
        for pid in gits {
            guard Date() < deadline else { return .unknown }
            if opens(pid, target) { return command(pid) }
        }
        let place = resolved(checkout)
        for pid in gits {
            guard Date() < deadline else { return .unknown }
            guard let cwd = ProcessTable.cwd(pid: pid).map(resolved), cwd == place || cwd.hasPrefix(place + "/") else { continue }
            // The main checkout holds the worktrees' folders too: only a git working on this index.
            let its = Git.run(["rev-parse", "--path-format=absolute", "--git-path", "index.lock"], in: cwd)
            if its.ok, resolved(its.output) == target { return command(pid) }
        }
        // Then any other process with it open, in the time that's left.
        let checked = Set(gits)
        for pid in pids where !checked.contains(pid) {
            guard Date() < deadline else { return .unknown }
            if opens(pid, target) { return command(pid) }
        }
        return Date() < deadline ? .none : .unknown
    }

    /// Whether the process has the file at `path` open.
    private static func opens(_ pid: Int32, _ path: String) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 8)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let open = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if open == path { return true }
        }
        return false
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

    /// The files the compiler's errors are in ("/path/File.swift:51:10: error: …"), in the order they first appear.
    public var errorFiles: [String] {
        var files: [String] = []
        for line in errors {
            guard let match = line.range(of: #"^.+?(?=:\d+(:\d+)?: error: )"#, options: .regularExpression) else { continue }
            let file = String(line[match])
            if !files.contains(file) { files.append(file) }
        }
        return files
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

extension Worktrees {
    /// What `commitFiles` did.
    public enum FilesCommit: Equatable, Sendable {
        /// `commit`, whose only parent is `parent`, is the branch's head now.
        case committed(commit: String, parent: String)
        /// The files are as the branch has them: nothing to commit.
        case unchanged
        case failed(String)
    }

    /// Commits `paths` (relative to the repository), as they are in `root`'s working tree, onto `branch` as one commit
    /// whose only parent is the branch's head, touching nothing else: the tree is built in an index of its own, and
    /// the branch moves only from the head that was read (`update-ref` with the old value). When the branch is checked
    /// out at `root`, only those paths' entries in its index are set to what was committed (before the branch moves:
    /// so a stop between the two leaves them staged, never undone), and put back if the branch couldn't move; every
    /// other staged or unstaged change there stays exactly as it was. A held index.lock is waited for up to
    /// `lockWait`, never removed. A path missing from the working tree is left as the branch has it. With `contents`,
    /// a path's text is what it gives (a snapshot taken under the caller's lock) instead of the working tree's; with
    /// `expected`, only on top of that head.
    public static func commitFiles(root: String, branch: String, paths: [String], contents: [String: Data] = [:], message: String,
                                   from expected: String? = nil, lockWait: TimeInterval = 5) -> FilesCommit {
        let git = { (args: [String], env: [String: String]) in
            Shell.run(executable: "/usr/bin/git", args: args, in: root, env: Git.environment.merging(env) { $1 }, timeout: 60)
        }
        let said = { (result: Git.Result) in result.error.isEmpty ? result.output : result.error }
        let head = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root).output
        guard !head.isEmpty else { return .failed("There's no branch \(branch).") }
        if let expected, expected != head { return .failed("\(branch) is at \(head.prefix(8)), not at \(expected.prefix(8)); it moved meanwhile.") }
        let resolved = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let place = checkout(of: branch, root: root)
        if let place, resolved(place) != resolved(root) { return .failed("\(branch) is checked out in \(place), not here.") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vibeswitcher-files-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        do { try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true) } catch { return .failed("\(error)") }
        var blobs: [(path: String, blob: String)] = []
        for path in paths {
            guard let data = contents[path] ?? FileManager.default.contents(atPath: (root as NSString).appendingPathComponent(path)) else { continue }
            // Hashed from a copy, as the path's own (its attributes' filters apply).
            let copy = (scratch as NSString).appendingPathComponent("\(blobs.count)")
            guard FileManager.default.createFile(atPath: copy, contents: data) else { return .failed("Couldn't copy \(path) to hash it.") }
            let hashed = git(["hash-object", "-w", "--path=\(path)", "--", copy], [:])
            guard hashed.ok, !hashed.output.isEmpty else { return .failed("git hash-object \(path) failed: \(said(hashed))") }
            blobs.append((path, hashed.output))
        }
        guard !blobs.isEmpty else { return .unchanged }
        // The tree: the head's, with these files.
        let index = (scratch as NSString).appendingPathComponent("index")
        let own = ["GIT_INDEX_FILE": index]
        let read = git(["read-tree", head], own)
        guard read.ok else { return .failed("git read-tree failed: \(said(read))") }
        for (path, blob) in blobs {
            let added = git(["update-index", "--add", "--cacheinfo", "100644,\(blob),\(path)"], own)
            guard added.ok else { return .failed("git update-index failed: \(said(added))") }
        }
        let tree = git(["write-tree"], own)
        guard tree.ok, !tree.output.isEmpty else { return .failed("git write-tree failed: \(said(tree))") }
        guard tree.output != Git.run(["rev-parse", "\(head)^{tree}"], in: root).output else { return .unchanged }
        let made = git(["-c", "commit.gpgsign=false", "commit-tree", tree.output, "-p", head, "-m", message], [:])
        guard made.ok, !made.output.isEmpty else { return .failed("git commit-tree failed: \(said(made))") }
        let commit = made.output
        // The checkout's index, for these paths only: what was there, then what's committed.
        let checkedOut = place != nil
        var before: [String: String] = [:]
        if checkedOut {
            let listed = git(["ls-files", "-s", "-z", "--"] + blobs.map(\.path), [:])
            guard listed.ok else { return .failed("git ls-files failed: \(said(listed))") }
            for entry in listed.output.split(separator: "\0") {
                // "<mode> <blob> <stage>\t<path>"
                let parts = entry.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let fields = parts[0].split(separator: " ")
                if fields.count == 3 { before[String(parts[1])] = "\(fields[0]),\(fields[1])" }
            }
            let set = withIndexLock(root: root, wait: lockWait) {
                git(["update-index", "--add"] + blobs.flatMap { ["--cacheinfo", "100644,\($0.blob),\($0.path)"] }, [:])
            }
            guard set.ok else { return .failed("The checkout's index couldn't be updated, nothing was committed: \(said(set))") }
        }
        let moved = git(["update-ref", "-m", "commit: \(message.split(whereSeparator: \.isNewline).first ?? "")",
                         "refs/heads/\(branch)", commit, head], [:])
        guard moved.ok else {
            if checkedOut {
                // Back as it was: the entry it had, or none.
                let args = blobs.flatMap { entry in
                    before[entry.path].map { ["--cacheinfo", "\($0),\(entry.path)"] } ?? ["--force-remove", entry.path]
                }
                _ = withIndexLock(root: root, wait: lockWait) { git(["update-index", "--add"] + args, [:]) }
            }
            return .failed("\(branch) moved meanwhile, nothing was committed: \(said(moved))")
        }
        return .committed(commit: commit, parent: head)
    }

    /// Runs a git command that takes `root`'s index.lock, again for up to `wait` while another git holds it.
    static func withIndexLock(root: String, wait: TimeInterval, _ run: () -> Git.Result) -> Git.Result {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            let result = run()
            guard !result.ok, result.error.contains("index.lock"), Date() < deadline else { return result }
            usleep(200_000)
        }
    }
}
