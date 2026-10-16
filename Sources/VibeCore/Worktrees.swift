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

/// Runs a program and captures its output.
public enum Shell {
    public static func run(executable: String, args: [String], in directory: String, env: [String: String] = [:],
                           timeout: TimeInterval = 120) -> Git.Result {
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
        var output = Data(), errors = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { output = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errors = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        group.wait()
        return Git.Result(status: process.terminationStatus,
                          output: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                          error: String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Workers' worktrees (`<repo>/.vibeswitcher/worktrees/<slug>` on `agent/<slug>`) and the merge queue's git steps.
public enum Worktrees {
    public enum Check: Equatable, Sendable {
        case passed
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

    /// A new worktree on a new branch from main.
    @discardableResult
    public static func create(root: String, slug: String) throws -> String {
        // Worktrees live inside the repo: keep them out of its status first.
        try BoardStore(root: root).ensureExcluded()
        let path = path(root: root, slug: slug)
        let result = Git.run(["worktree", "add", "-q", "-b", branch(slug), path, mainBranch(root: root)], in: root)
        guard result.ok else { throw Failure(description: result.error.isEmpty ? "git worktree add failed" : result.error) }
        return path
    }

    /// Puts the branch on top of main and runs the checks there.
    public static func rebaseAndTest(root: String, slug: String, test: String?, timeout: TimeInterval = 1200) -> Check {
        let path = path(root: root, slug: slug)
        guard FileManager.default.fileExists(atPath: path) else { return .error("No worktree for \(slug).") }
        let rebase = Git.run(["rebase", mainBranch(root: root)], in: path)
        guard rebase.ok else {
            Git.run(["rebase", "--abort"], in: path)
            return .conflict
        }
        guard let test, !test.trimmingCharacters(in: .whitespaces).isEmpty else { return .passed }
        let run = Shell.run(executable: "/bin/zsh", args: ["-lc", test], in: path, timeout: timeout)
        if run.ok { return .passed }
        let output = (run.output + "\n" + run.error).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(String(output.suffix(4000)))
    }

    /// Fast-forwards main to the branch. Never rewrites anything and never touches uncommitted work: a dirty main
    /// checkout, main checked out elsewhere, or a branch not on top of main is refused with the reason.
    public static func merge(root: String, slug: String) throws -> Merge {
        let main = mainBranch(root: root)
        let branch = branch(slug)
        guard Git.run(["merge-base", "--is-ancestor", main, branch], in: root).ok else {
            return .refused("The branch isn't on top of \(main); rebase and test it first.")
        }
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        switch checkout(of: main, root: root) {
        case .some(let place) where URL(fileURLWithPath: place).resolvingSymlinksInPath().path == resolvedRoot:
            guard Git.run(["status", "--porcelain", "--untracked-files=no"], in: root).output.isEmpty else {
                return .refused("The main checkout has uncommitted changes; commit or stash them first.")
            }
            let merge = Git.run(["merge", "--ff-only", "-q", branch], in: root)
            return merge.ok ? .merged : .refused(merge.error)
        case .some(let place):
            return .refused("\(main) is checked out in \(place); merge there.")
        case .none:
            let target = Git.run(["rev-parse", branch], in: root).output
            let current = Git.run(["rev-parse", main], in: root).output
            let update = Git.run(["update-ref", "refs/heads/\(main)", target, current], in: root)
            return update.ok ? .merged : .refused(update.error)
        }
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
