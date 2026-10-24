import Foundation

/// The lead's decision log, progress log and incident log in the repository: `<records_dir>/decisions.md`,
/// `progress.md` and `incidents.md` (`records_dir:` in workflow.md, `docs/lead` by default), committed to the base branch by the lead's tool server, so
/// the plan's reasoning survives a deleted `.vibeswitcher`, another Mac or a new lead. The board stays local.
///
/// The lead itself may not edit files or run git that writes; its tool server commits for it, batched (after each
/// merge, and at most every `interval` otherwise), as small commits of their own that touch only those two files
/// (`Worktrees.commitFiles`): the user's own staged and unstaged changes in the main checkout stay as they are. A
/// commit takes the same lock as a merge into the branch, so none lands between a merge's rebase-and-test and its
/// fast-forward, and it records the branch's new head in the vault as the lead's own (only the lead's session may),
/// so the next merge's check that nothing else moved the branch takes it.
public final class LeadRecords: @unchecked Sendable {
    public enum Kind: CaseIterable, Sendable {
        case decisions, progress, incidents

        public var name: String {
            switch self {
            case .decisions: return "decisions.md"
            case .progress: return "progress.md"
            case .incidents: return "incidents.md"
            }
        }
        var header: String {
            switch self {
            case .decisions: return "# Decisions\n\n"
            case .progress: return "# Progress\n\n"
            case .incidents: return "# Incidents\n\n"
            }
        }
        /// How each entry's first line starts.
        var marker: String { self == .progress ? "- " : "## " }
    }

    /// What a flush did.
    public enum Outcome: Equatable, Sendable {
        case committed(String)
        /// Nothing new to commit.
        case unchanged
        /// The workflow keeps the logs in `.vibeswitcher` (no `records_dir`), or the folder isn't a git repository.
        case local
        /// Not now (a merge into the branch runs, or the branch moved and the move isn't taken yet): the next flush.
        case waiting(String)
        case failed(String)
    }

    public static let subject = "Lead: decisions and progress"

    /// No trailer (Co-Authored-By or any other): a project's workflow may refuse them (genswap's regression_command
    /// does), and these commits land on its base among its own.
    static func message(_ dir: String) -> String {
        "\(subject)\n\nThe project lead's \(dir)/decisions.md, \(dir)/progress.md and \(dir)/incidents.md, committed by VibeSwitcher for the lead "
            + "(its tool server); nothing else is in this commit."
    }

    /// The records' paths in the repository with `records_dir` `dir`.
    public static func paths(_ dir: String) -> [String] { Kind.allCases.map { "\(dir)/\($0.name)" } }

    let store: BoardStore
    let vault: LeadVault
    /// The least time between two commits, but for the one after a merge.
    public var interval: TimeInterval = 300
    /// How long a commit waits for a held index.lock in the main checkout.
    var lockWait: TimeInterval = 5
    private let lock = NSLock()
    private var lastFlush: Date
    private var lastOutcome: Outcome?
    private var timer: DispatchSourceTimer?

    public init(store: BoardStore, vault: LeadVault, now: Date = Date()) {
        self.store = store
        self.vault = vault
        lastFlush = now
    }

    deinit { timer?.cancel() }

    var root: String { store.root }

    /// Commits the logs to `base` now, when they changed. Each outcome but `unchanged` and `local` shows in status
    /// (`statusLine`) until a later one replaces it; nothing written is lost: what isn't committed stays in the files.
    @discardableResult
    public func flush(base: String, now: Date = Date()) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        lastFlush = now
        let outcome = commit(base: base)
        lastOutcome = outcome
        return outcome
    }

    /// A flush when `interval` has passed since the last one; nil when it isn't due.
    @discardableResult
    public func tick(base: String, now: Date = Date()) -> Outcome? {
        lock.lock()
        let due = now.timeIntervalSince(lastFlush) >= interval
        lock.unlock()
        return due ? flush(base: base, now: now) : nil
    }

    /// Ticks every `every` seconds on a queue of its own while this lives; `base` gives the branch, or nil to skip
    /// (the session no longer holds the lead's role).
    public func start(every: TimeInterval = 30, base: @escaping @Sendable () -> String?) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "vibeswitcher.lead-records"))
        timer.schedule(deadline: .now() + every, repeating: every)
        timer.setEventHandler { [weak self] in
            guard let self, let branch = base() else { return }
            self.tick(base: branch)
        }
        timer.resume()
        self.timer = timer
    }

    /// For status: a commit that failed or waits, and where the entries are meanwhile.
    public var statusLine: String? {
        lock.lock()
        defer { lock.unlock() }
        let kept = store.recordsDir.map { "they're kept in \($0)/ and committed on the next try (after the next merge, or within \(Int(interval / 60)) min)" } ?? ""
        switch lastOutcome {
        case .failed(let why)?: return "Records: committing decisions.md and progress.md failed: \(why) Nothing is lost: \(kept)."
        case .waiting(let why)?: return "Records: decisions.md and progress.md wait to be committed: \(why) \(kept.prefix(1).uppercased() + kept.dropFirst())."
        default: return nil
        }
    }

    private func commit(base: String) -> Outcome {
        guard let dir = store.recordsDir, Git.run(["rev-parse", "--git-dir"], in: root).ok else { return .local }
        do { try store.withRecordsLock { try Self.migrate(store) } } catch { return .failed("moving the old logs from .vibeswitcher failed (\(error)).") }
        let paths = Self.paths(dir)
        guard changed(paths, on: base) else { return .unchanged }
        // As a merge into the branch does: one at a time, and never between its tests and its fast-forward.
        let baseLock = Self.baseLock(vault: vault, root: root, base: base)
        try? vault.ensurePrivate(baseLock.deletingLastPathComponent())
        guard let held = FileLock.attempt(baseLock.path) else { return .waiting("a merge into \(base) is running.") }
        defer { held.release() }
        let head = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(base)"], in: root).output
        guard !head.isEmpty else { return .failed("there's no branch \(base).") }
        // On top of a head the lead hasn't taken, the commit would take it too: the next merge decides on it first.
        if let known = vault.head(root: root, branch: base), known != head {
            return .waiting("\(base) moved since the lead last left it (\(known.prefix(8)) → \(head.prefix(8))), not through merge; committed once a merge takes the move.")
        }
        // Only the lead's session (or the app) records where the branch is: asked before anything is committed.
        do { try vault.setHead(head, root: root, branch: base) } catch { return .failed("\(error)") }
        // The logs as they are now, read under the records' lock (never half an entry); git runs after, without it.
        let snapshot: [String: Data]
        do {
            snapshot = try store.withRecordsLock {
                paths.reduce(into: [:]) { taken, path in taken[path] = FileManager.default.contents(atPath: (root as NSString).appendingPathComponent(path)) }
            }
        } catch { return .failed("\(error)") }
        let result = Worktrees.commitFiles(root: root, branch: base, paths: paths, contents: snapshot, message: Self.message(dir),
                                           from: head, lockWait: lockWait)
        switch result {
        case .unchanged: return .unchanged
        case .failed(let why): return .failed(why)
        case .committed(let commit, _):
            do { try vault.setHead(commit, root: root, branch: base) } catch {
                return .failed("committed \(commit.prefix(8)) on \(base), but couldn't record it as the lead's (\(error)): the next merge asks the user about it.")
            }
            return .committed(commit)
        }
    }

    /// Whether any of `paths` in the working tree differs from `base`'s.
    private func changed(_ paths: [String], on base: String) -> Bool {
        paths.contains { path in
            guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(path)) else { return false }
            let here = Git.run(["hash-object", "--", path], in: root).output
            let there = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(base):\(path)"], in: root).output
            return here.isEmpty || here != there
        }
    }

    /// The lock a merge into `base` holds from its check of the branch to its fast-forward (`LeadToolset.merge`).
    static func baseLock(vault: LeadVault, root: String, base: String) -> URL {
        vault.scratch(root: root, "merge-into-\(LeadVault.hash(base).prefix(16)).lock")
    }

    // MARK: Moving the old logs

    /// Moves `.vibeswitcher/decisions.md`, `progress.md` and `incidents.md` into `records_dir` once: their entries go before the ones
    /// already there (but those it already has), redacted, and the old file is renamed `<name>.moved`. Called under
    /// the records' lock.
    static func migrate(_ store: BoardStore) throws {
        guard store.recordsDir != nil else { return }
        for kind in Kind.allCases {
            let local = (store.folder as NSString).appendingPathComponent(kind.name)
            guard let old = try? String(contentsOfFile: local, encoding: .utf8) else { continue }
            let path = store.recordPath(kind.name)
            let current = try? String(contentsOfFile: path, encoding: .utf8)
            try write(merged(old: Redaction.secrets(in: old), into: current, kind: kind), to: path, in: store)
            let moved = local + ".moved"
            try? FileManager.default.removeItem(atPath: moved)
            try FileManager.default.moveItem(atPath: local, toPath: moved)
        }
    }

    /// Writes a record's whole text, with its folder. In the project's `.vibeswitcher/` it's private (0600, in 0700
    /// folders) like everything there; in `records_dir` it's one of the repository's own files, committed, so it gets
    /// the repository's usual modes.
    static func write(_ text: String, to path: String, in store: BoardStore) throws {
        let folder = (path as NSString).deletingLastPathComponent
        guard (folder + "/").hasPrefix(store.folder + "/") else {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        try VibePaths.ensurePrivate(URL(fileURLWithPath: folder, isDirectory: true))
        try VibePaths.writePrivate(Data(text.utf8), to: URL(fileURLWithPath: path))
    }

    /// `current` (or a new log) with `old`'s entries before its own, each only once, in the order of their times.
    static func merged(old: String, into current: String?, kind: Kind) -> String {
        let (_, olds) = entries(old, kind: kind)
        let (preamble, news) = entries(current ?? "", kind: kind)
        var seen = Set<String>()
        let all = (olds + news).filter { seen.insert($0).inserted }
        // Each entry's time ("2026-10-19 11:05"), or the one before it's when it has none; the same time keeps the order.
        var last = ""
        let keyed = all.enumerated().map { index, entry -> (String, Int, String) in
            let stamp = entry.dropFirst(kind.marker.count).prefix(16)
            if stamp.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil { last = String(stamp) }
            return (last, index, entry)
        }
        let ordered = keyed.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        return (current == nil || preamble.isEmpty ? kind.header : preamble) + ordered.joined()
    }

    /// A log's text before its first entry, and its entries (each from its marker line to the next one), each ending
    /// as `append` ends one.
    static func entries(_ text: String, kind: Kind) -> (preamble: String, entries: [String]) {
        var preamble: [String] = []
        var found: [[String]] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix(kind.marker) { found.append([line]) }
            else if found.isEmpty { preamble.append(line) }
            else { found[found.count - 1].append(line) }
        }
        let ending = kind == .progress ? "\n" : "\n\n"
        let entries = found.map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + ending }
        let head = preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (head.isEmpty ? "" : head + "\n\n", entries)
    }
}
