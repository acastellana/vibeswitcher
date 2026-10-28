import Foundation

/// The lead's decision log, progress log and incident log in the repository: `<records_dir>/decisions.md`,
/// `progress.md` and `incidents.md` (`records_dir:` in workflow.md, `docs/lead` by default), committed to the base branch by the lead's tool server, so
/// the plan's reasoning survives a deleted `.vibeswitcher`, another Mac or a new lead, and `decisions-archive.md`, where
/// `archive_decisions` moves the decisions every lead start no longer needs to read. The board stays local.
///
/// The lead itself may not edit files or run git that writes; its tool server commits for it, batched (after each
/// merge, and at most every `interval` otherwise), as small commits of their own that touch only those two files
/// (`Worktrees.commitFiles`): the user's own staged and unstaged changes in the main checkout stay as they are. A
/// commit takes the same lock as a merge into the branch, so none lands between a merge's rebase-and-test and its
/// fast-forward, and it records the branch's new head in the vault as the lead's own (only the lead's session may),
/// so the next merge's check that nothing else moved the branch takes it.
public final class LeadRecords: @unchecked Sendable {
    public enum Kind: CaseIterable, Sendable {
        case decisions, progress, incidents, archive

        public var name: String {
            switch self {
            case .decisions: return "decisions.md"
            case .progress: return "progress.md"
            case .incidents: return "incidents.md"
            case .archive: return "decisions-archive.md"
            }
        }
        var header: String {
            switch self {
            case .decisions: return "# Decisions\n\n"
            case .progress: return "# Progress\n\n"
            case .incidents: return "# Incidents\n\n"
            case .archive: return "# Archived decisions\n\nMoved here from decisions.md by archive_decisions, unchanged: superseded, obsolete or now enforced by a check.\n\n"
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
        "\(subject)\n\nThe project lead's \(dir)/decisions.md, \(dir)/progress.md, \(dir)/incidents.md and \(dir)/decisions-archive.md, committed by VibeSwitcher for the lead "
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
    /// What a commit does between two tries of a held index.lock (`Worktrees.withIndexLock`); nil waits 200 ms.
    var lockPause: (() -> Void)?
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
        due(now) ? flush(base: base, now: now) : nil
    }

    private func due(_ now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return now.timeIntervalSince(lastFlush) >= interval
    }

    /// Ticks every `every` seconds on a queue of its own while this lives; `base` gives the branch, or nil to skip
    /// (the session no longer holds the lead's role). A due tick runs through `run`, the tool server's
    /// `MCPServer.background`: an install's switch of builds waits for it as for a call, so the commit is never cut
    /// between the branch's update and the vault's head (which the next merge would take for a move outside the
    /// lead). False from `run` (the server is ending) skips it. The queue waits for each, so ticks never overlap.
    public func start(every: TimeInterval = 30, run: @escaping (@escaping () -> Void) -> Bool = { $0(); return true },
                      base: @escaping @Sendable () -> String?) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "vibeswitcher.lead-records"))
        timer.schedule(deadline: .now() + every, repeating: every)
        timer.setEventHandler { [weak self] in
            guard let self, self.due() else { return }
            let done = DispatchSemaphore(value: 0)
            let started = run {
                // Not stopped by the server's cancel either (as merge's fast-forward): a commit is seconds, and one
                // cut there leaves the branch moved and the vault's head not.
                ShellCancel.with(nil) {
                    if let branch = base() { self.tick(base: branch) }
                }
                done.signal()
            }
            if started { done.wait() }
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
                                           from: head, lockWait: lockWait, lockPause: lockPause)
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
            // The archive's batches (each under its own `# Archived` line) go after the ones already there, as they are.
            let text = kind == .archive
                ? (current.map { $0 + (old.hasPrefix(kind.header) ? String(old.dropFirst(kind.header.count)) : old) } ?? old)
                : merged(old: Redaction.secrets(in: old), into: current, kind: kind)
            try write(text, to: path, in: store)
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

    // MARK: Archiving decisions

    /// A refused archive: nothing was moved.
    public struct Refusal: Error, Equatable {
        public let text: String
    }

    /// What `archive` moved: the moved entries' headings, and how many entries decisions.md and the archive hold now.
    public struct Archived: Equatable, Sendable {
        public var moved: [String]
        public var kept: Int
        public var archived: Int
    }

    /// decisions.md's size past which status asks the lead to archive (`archive_decisions`): every lead start reads it.
    public static let archiveEntries = 60
    public static let archiveBytes = 40 * 1024

    /// How decisions.md's one line pointing to the archive starts (it's replaced, never added again).
    static let pointerPrefix = "Archived decisions: "

    /// Moves the decisions `names` names from decisions.md to decisions-archive.md (`archive_decisions`), under the
    /// records' lock, as the commit reads them. Each moves byte for byte, its date with it, appended to the archive under
    /// one `# Archived <time>: <reason>` line for the call (the archive is only ever appended to); decisions.md keeps
    /// the rest as they were, in their order, and one pointer line to the archive under its title. A name is an entry's
    /// heading (without `## `) or its start up to a word, e.g. its stamp `2026-10-17 12:15` (which fits one stamped
    /// `2026-10-17 12:15:04` too); one that names no entry,
    /// or several, refuses the whole call with nothing changed.
    static func archive(_ names: [String], reason: String, in store: BoardStore, now: Date = Date()) throws -> Archived {
        let reason = Redaction.secrets(in: reason.split(whereSeparator: \.isNewline).joined(separator: " ")).trimmingCharacters(in: .whitespaces)
        guard !reason.isEmpty else { throw Refusal(text: "Nothing was archived: say why (reason): superseded, obsolete, or now enforced by a check.") }
        let wanted = names.map { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.hasPrefix("## ") ? String(trimmed.dropFirst(3)) : trimmed).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { throw Refusal(text: "Nothing was archived: name the entries (entries), each by its heading or its stamp.") }
        return try store.withRecordsLock {
            try migrate(store)
            let path = store.recordPath(Kind.decisions.name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw Refusal(text: "Nothing was archived: there's no decisions.md yet.")
            }
            let (preamble, entries) = rawEntries(text)
            let headings = entries.map(heading)
            // Each heading with its stamp's seconds dropped too: docs/process/lead-rules.md names entries by the minute.
            let minutes = headings.map { $0.replacingOccurrences(of: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}):\d{2}"#, with: "$1", options: .regularExpression) }
            var chosen = Set<Int>()
            var problems: [String] = []
            for name in wanted {
                let matches = headings.indices.filter { index in
                    [headings[index], minutes[index]].contains { $0 == name || $0.hasPrefix(name + " ") }
                }
                switch matches.count {
                case 0: problems.append("“\(name)” names no entry in decisions.md")
                case 1: chosen.insert(matches[0])
                default:
                    let which = matches.prefix(4).map { "“\(clipped(headings[$0], 70))”" }.joined(separator: ", ")
                    problems.append("“\(name)” names \(matches.count) entries (\(which)): name each by more of its heading")
                }
            }
            guard problems.isEmpty else { throw Refusal(text: "Nothing was archived: " + problems.joined(separator: "; ") + ".") }
            let moved = entries.indices.filter(chosen.contains).map { entries[$0] }
            let kept = entries.indices.filter { !chosen.contains($0) }.map { entries[$0] }

            // The archive first, appended to: should decisions.md's write fail after it, an entry is in both, never in neither.
            let archivePath = store.recordPath(Kind.archive.name)
            let before = try? String(contentsOfFile: archivePath, encoding: .utf8)
            if before == nil { try write(Kind.archive.header, to: archivePath, in: store) }
            let gap = (before ?? Kind.archive.header).hasSuffix("\n\n") ? "" : (before ?? "").hasSuffix("\n") ? "\n" : "\n\n"
            // An entry that ended the file without a newline gets one after it here, so the next starts on its own line.
            let batch = gap + "# Archived \(LeadDecision.stamp(now)): \(reason)\n\n" + moved.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined()
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: archivePath))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(batch.utf8))

            let archived = rawEntries((before ?? "") + batch).entries.count
            let day = String(LeadDecision.stamp(now).prefix(10))
            let pointer = pointerPrefix + "\(archived) \(archived == 1 ? "entry" : "entries") (superseded, obsolete or now enforced by a check) "
                + "\(archived == 1 ? "is" : "are") in \(Kind.archive.name), moved there unchanged (last on \(day))."
            try write(pointed(preamble, pointer) + kept.joined(), to: path, in: store)
            return Archived(moved: moved.map(heading), kept: kept.count, archived: archived)
        }
    }

    /// A decisions log's text before its first entry, and its entries (each from its `## <stamp>` heading to the next
    /// one), exactly as they are: joined, they give back the text byte for byte.
    static func rawEntries(_ text: String) -> (preamble: String, entries: [String]) {
        let lines = text.components(separatedBy: "\n")
        var preamble = ""
        var found: [String] = []
        for (index, line) in lines.enumerated() {
            let piece = line + (index < lines.count - 1 ? "\n" : "")
            if line.range(of: #"^## \d{4}-\d{2}-\d{2} \d{2}:\d{2}(:\d{2})?(\s|$)"#, options: .regularExpression) != nil { found.append(piece) }
            else if found.isEmpty { preamble += piece }
            else { found[found.count - 1] += piece }
        }
        return (preamble, found)
    }

    /// An entry's heading, without `## `.
    static func heading(_ entry: String) -> String {
        String(entry.prefix { $0 != "\n" }.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    /// `preamble` with `pointer` in place of its pointer line, or under its title when it has none yet.
    static func pointed(_ preamble: String, _ pointer: String) -> String {
        var lines = preamble.components(separatedBy: "\n")
        if let at = lines.firstIndex(where: { $0.hasPrefix(pointerPrefix) }) {
            lines[at] = pointer
        } else if let title = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines.insert(contentsOf: ["", pointer], at: title + 1)
            // "# Decisions" with nothing under it: the entries still start after a blank line.
            if lines.count == title + 3 { lines += ["", ""] }
        } else {
            lines.insert(contentsOf: [pointer, ""], at: 0)
        }
        return lines.joined(separator: "\n")
    }

    private static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// For status, once decisions.md passes `archiveEntries` entries or `archiveBytes`: a line asking the lead to
    /// archive what no longer holds; nil below. `rules`: the repository's inventory of them, when it has one.
    static func archiveNudge(entries: Int, bytes: Int, rules: String?) -> String? {
        guard entries > archiveEntries || bytes > archiveBytes else { return nil }
        let listed = rules.map { " (\($0) lists them)" } ?? ""
        return "decisions.md has \(entries) entries (\(bytes / 1024) KB), and every lead start reads it: archive_decisions the superseded "
            + "and obsolete ones, and those a check now enforces\(listed). They move to \(Kind.archive.name) unchanged."
    }
}
