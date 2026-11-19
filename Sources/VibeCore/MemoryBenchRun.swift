import Darwin
import Foundation

extension MemoryBench {
    /// One run of the benches (`go`), blocking, on a thread of its own: main's head (`base` of `root`, VibeSwitcher's
    /// checkout) in a scratch worktree at `folder`/checkout, never the checkout itself or its build folder; the benches
    /// there under the checkout's own `vs-heavy`, which holds a Mac-wide slot, ends the run past `timeoutMinutes` and
    /// everything it started with it; the record appended to `stats`/`statsName`; and the worktree removed, whatever
    /// happened. Every path is `folder` and fixed names under it; a folder that isn't a plain folder of this user's (a
    /// link, another owner's), a base that isn't a plain branch name or a head that isn't a commit stops it before
    /// anything runs. The benches start the app's binary from the worktree's build on scratch homes (`scripts/test.sh`,
    /// the benches' own): never the running app, its home or its Keychain.
    public struct Run: Sendable {
        public var root: String
        public var base: String
        /// `VibePaths.root`/`folderName` in the app.
        public var folder: URL
        /// `VibePaths.statsDir` in the app.
        public var stats: URL
        /// The command run in the worktree, nil for the benches (`command`); tests give a small script.
        public var command: [String]?
        /// Added to the command's environment (the login shell's PATH: swift and node, which an app started from Finder
        /// lacks).
        public var environment: [String: String]
        /// Shell.run's own limit, past vs-heavy's: a vs-heavy that never ends.
        public var timeout: TimeInterval

        public init(root: String, base: String, folder: URL, stats: URL, command: [String]? = nil, environment: [String: String] = [:],
                    timeout: TimeInterval = TimeInterval(MemoryBench.timeoutMinutes + 10) * 60) {
            self.root = root
            self.base = base
            self.folder = folder
            self.stats = stats
            self.command = command
            self.environment = environment
            self.timeout = timeout
        }

        public enum Outcome: Equatable, Sendable {
            /// It ran, and this line went into the stats file.
            case recorded(Record)
            /// Cancelled (`ShellCancel.current`): the conditions changed. Nothing recorded.
            case gaveUp
            /// It couldn't start, and why: nothing recorded.
            case refused(String)
        }

        /// The worktree's path: a fixed name in `folder`.
        public var checkout: URL { folder.appendingPathComponent("checkout", isDirectory: true) }
        /// The last run's whole output, kept for a look.
        public var log: URL { folder.appendingPathComponent("last-run.log") }

        /// The benches, run from the worktree's own scripts: its vs-heavy holding a slot, test.sh's --perf.
        public static func command(commit: String) -> [String] {
            ["/bin/bash", "Resources/bin/vs-heavy", "--as", "VibeSwitcher's memory benches of \(commit.prefix(8))",
             "--timeout", "\(MemoryBench.timeoutMinutes)m",
             "/bin/bash", "scripts/test.sh", "--perf", "--filter", MemoryBench.filter, "--skip", MemoryBench.skip]
        }

        /// A branch name as a ref's last parts may be: letters, digits, `._/-`, no `..`, not starting with `-` or `/`.
        static func plainBranch(_ name: String) -> Bool {
            !name.isEmpty && name.count <= 100 && !name.hasPrefix("-") && !name.hasPrefix("/") && !name.contains("..")
                && !name.hasSuffix("/") && !name.hasSuffix(".lock")
                && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._/-".contains($0)) }
        }

        /// A plain folder (not a link) this user owns; false for anything else, or nothing there.
        static func ownFolder(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
        }

        /// Nothing at `path` (not even a dangling link).
        static func nothing(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) != 0 && errno == ENOENT
        }

        /// Removes the worktree: git's record of it first, then the folder, but only a plain folder of this user's at
        /// that fixed path; a link there is left, and said. Not stopped by a cancel. Nil when it's gone.
        @discardableResult
        public func removeCheckout() -> String? {
            let path = checkout.path
            return ShellCancel.with(nil) {
                if Self.nothing(path) {
                    Git.run(["worktree", "prune"], in: root)
                    return nil
                }
                guard Self.ownFolder(folder.path), Self.ownFolder(path) else {
                    return "\(path) isn't a plain folder of yours: left as it is"
                }
                SessionStrays.endInside(folder: path)
                Git.run(["worktree", "remove", "--force", path], in: root)
                if !Self.nothing(path) {
                    // Checked again just before: a plain folder of ours, which removeItem removes without following a link in it.
                    guard Self.ownFolder(path) else { return "\(path) isn't a plain folder of yours: left as it is" }
                    do { try FileManager.default.removeItem(atPath: path) } catch { return "couldn't remove \(path): \(error)" }
                }
                Git.run(["worktree", "prune"], in: root)
                return nil
            }
        }

        /// The run. `now` gives the clock (the record's time and duration).
        public func go(now: () -> Date = Date.init) -> Outcome {
            let began = now()
            let load = LoadRecorder.averages().map { $0.map { ($0 * 100).rounded() / 100 } }
            guard Self.plainBranch(base) else { return .refused("the base \(base) isn't a plain branch name") }
            guard Self.ownFolder(root) else { return .refused("\(root) isn't a folder of yours") }
            do { try VibePaths.ensurePrivate(folder) } catch { return .refused("couldn't make \(folder.path): \(error)") }
            guard Self.ownFolder(folder.path) else { return .refused("\(folder.path) isn't a plain folder of yours") }
            let head = Git.run(["rev-parse", "--verify", "-q", "refs/heads/\(base)^{commit}"], in: root)
            let commit = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.ok, commit.count == 40, commit.allSatisfy(\.isHexDigit) else { return .refused("\(base) has no commit in \(root)") }
            // One a crash left.
            if let left = removeCheckout() { return .refused(left) }
            guard ShellCancel.current?.isCancelled != true else { return .gaveUp }
            defer { removeCheckout() }
            let added = Git.run(["worktree", "add", "--detach", "-q", checkout.path, commit], in: root)
            guard added.ok else {
                if ShellCancel.current?.isCancelled == true { return .gaveUp }
                return .refused("couldn't add the worktree: \(added.error.prefix(300))")
            }
            let argv = command ?? Self.command(commit: commit)
            let ran = Shell.run(executable: argv[0], args: Array(argv.dropFirst()), in: checkout.path, env: environment,
                                timeout: timeout, grace: 20, interleaved: true, ownSession: true)
            try? VibePaths.writePrivate(Data(ran.output.utf8), to: log)
            if ran.cancelled { return .gaveUp }
            let budgets = Budget.parse(ran.output)
            // vs-heavy's own --timeout says 124; Shell.run's limit is the backstop.
            let (result, note) = Record.result(budgets: budgets, exitStatus: ran.status, timedOut: ran.timedOut || ran.status == 124)
            let file = stats.appendingPathComponent(MemoryBench.statsName)
            var record = Record(t: LoadStats.stamp(began), day: LoadStats.day(began), commit: commit, result: result,
                                durationS: Int(now().timeIntervalSince(began).rounded()), budgets: budgets, load: load, note: note)
            if result == "fail" {
                record.lastPass = Record.all(in: file).last { $0.result == "pass" }?.commit
                record.sincePass = record.lastPass.flatMap { subjects(from: $0, to: commit) }
            }
            do {
                try LoadStats.append(try record.line(), to: MemoryBench.statsName, in: stats)
            } catch {
                return .refused("couldn't append to \(file.path): \(error)")
            }
            return .recorded(record)
        }

        /// The subjects of the commits after `from` up to `to`, newest first, at most `sinceLimit`; nil when git can't
        /// say (a commit gone).
        func subjects(from: String, to: String) -> [String]? {
            guard from.allSatisfy(\.isHexDigit), to.allSatisfy(\.isHexDigit) else { return nil }
            let log = Git.run(["log", "--no-merges", "--format=%s", "-n", "\(MemoryBench.sinceLimit)", "\(from)..\(to)"], in: root)
            guard log.ok else { return nil }
            return log.output.split(whereSeparator: \.isNewline).map { String($0.prefix(200)) }
        }
    }
}

/// Runs the memory benches when `MemoryBench.decide` says, looked at once a minute (`tick`): on a queue of its own,
/// the run itself on a thread of its own. While one runs each tick checks `MemoryBench.stillFine` and cancels it when
/// the conditions changed (it's tried again later); `sleeping` cancels it at once. Awake is the sources' word and its
/// own: not between `sleeping` and `woke`, nor for `MemoryBench.awakeAfterWake` after `woke`. Every source is injectable.
public final class MemoryBenchWatch: @unchecked Sendable {
    public struct Sources {
        /// Settings' switch.
        public var enabled: () -> Bool
        public var conditions: () -> MemoryBench.Conditions
        /// The run, when it's time, for the projects the leads run in (`tick`'s): nil when there's nothing to run (no
        /// VibeSwitcher checkout among them). Called on the watch's queue.
        public var plan: ([String]) -> MemoryBench.Run?
        public var now: () -> Date
        /// Runs it (`Run.go`, by default); called on the run's thread with the cancel token set.
        public var go: (MemoryBench.Run) -> MemoryBench.Run.Outcome
        /// Heard after each run, on the run's thread: the app-health watch looks at once.
        public var ended: (MemoryBench.Run.Outcome) -> Void
        public var log: (String) -> Void

        public init(enabled: @escaping () -> Bool, conditions: @escaping () -> MemoryBench.Conditions,
                    plan: @escaping ([String]) -> MemoryBench.Run?, now: @escaping () -> Date = Date.init,
                    go: @escaping (MemoryBench.Run) -> MemoryBench.Run.Outcome = { $0.go() },
                    ended: @escaping (MemoryBench.Run.Outcome) -> Void = { _ in }, log: @escaping (String) -> Void = { _ in }) {
            self.enabled = enabled
            self.conditions = conditions
            self.plan = plan
            self.now = now
            self.go = go
            self.ended = ended
            self.log = log
        }
    }

    private let sources: Sources
    private let stateFile: URL
    private let queue = DispatchQueue(label: "vibeswitcher.memory-bench", qos: .utility)
    /// The queue's.
    private var state: MemoryBench.State
    private var running: ShellCancel?
    /// What was last said of a run that couldn't start, so it's said once.
    private var lastSaid: String?
    private var asleep = false
    private var woke: Date?

    public init(sources: Sources, stateFile: URL) {
        self.sources = sources
        self.stateFile = stateFile
        let data = try? Data(contentsOf: stateFile)
        state = data.flatMap { try? JSONDecoder().decode(MemoryBench.State.self, from: $0) } ?? MemoryBench.State()
    }

    /// Whether a run is under way.
    public var isRunning: Bool { queue.sync { running != nil } }
    public var current: MemoryBench.State { queue.sync { state } }

    /// Looks: starts a run when it's time, gives up one under way whose conditions changed. `roots`: the projects the
    /// leads run in, read by the caller (the main thread's). Returns at once; the look is on the watch's queue.
    public func tick(roots: [String] = []) {
        queue.async { self.look(roots: roots) }
    }

    /// The Mac is going to sleep: a run under way is given up, and none starts until it has woken.
    public func sleeping() {
        queue.sync {
            asleep = true
            giveUp("the Mac is going to sleep")
        }
    }

    /// The Mac woke.
    public func woke(at date: Date) {
        queue.sync {
            asleep = false
            woke = date
        }
    }

    /// The app quits: a run under way is stopped (its worktree is removed at the next run).
    public func stop() {
        queue.sync { giveUp("the app is quitting") }
    }

    private func conditions(now: Date) -> MemoryBench.Conditions {
        var conditions = sources.conditions()
        if asleep || woke.map({ now.timeIntervalSince($0) < MemoryBench.awakeAfterWake }) == true { conditions.awake = false }
        return conditions
    }

    private func look(roots: [String]) {
        let enabled = sources.enabled()
        let now = sources.now()
        if running != nil {
            if !enabled { giveUp("turned off in Settings"); return }
            if let why = MemoryBench.stillFine(conditions(now: now)) { giveUp(why) }
            return
        }
        guard enabled else { return }
        let decision = MemoryBench.decide(now: now, state: state, conditions: conditions(now: now))
        guard decision == .run else { return }
        guard let plan = sources.plan(roots) else {
            // Said once, not every minute.
            if lastSaid != "no checkout" { say("no VibeSwitcher checkout among the leads' projects: not run") }
            lastSaid = "no checkout"
            return
        }
        lastSaid = nil
        let cancel = ShellCancel()
        running = cancel
        say("starting on \(plan.base) of \(plan.root)")
        let go = sources.go, ended = sources.ended
        Thread.detachNewThread { [weak self] in
            let outcome = ShellCancel.with(cancel) { go(plan) }
            self?.queue.sync { self?.finished(outcome, began: now, cancel: cancel) }
            ended(outcome)
        }
    }

    private func finished(_ outcome: MemoryBench.Run.Outcome, began: Date, cancel: ShellCancel) {
        if running === cancel { running = nil }
        switch outcome {
        case .recorded(let record):
            state.lastRun = began.timeIntervalSince1970
            say("ran: \(record.result) in \(record.durationS) s at \(record.commit.prefix(8))" + (record.note.map { ": \($0)" } ?? ""))
        case .gaveUp:
            state.gaveUp = sources.now().timeIntervalSince1970
        case .refused(let why):
            // Not tried again today: what stopped it is said, and stays so until it's fixed.
            state.lastRun = began.timeIntervalSince1970
            say("couldn't run: \(why)")
        }
        save()
    }

    private func giveUp(_ why: String) {
        guard let running, !running.isCancelled else { return }
        running.cancel()
        say("giving up the run: \(why); tried again later")
    }

    private func say(_ text: String) { sources.log("memory bench: " + text) }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? VibePaths.ensurePrivate(stateFile.deletingLastPathComponent())
        try? VibePaths.writePrivate(data, to: stateFile)
    }
}
