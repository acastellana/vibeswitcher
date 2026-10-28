import Darwin
import Foundation

/// What the archived tasks add to the scorecard (`LeadScorecard`): their parts of its sums, kept on the board as they
/// leave it, so the Team tab's numbers count every merge from board.json alone.
public struct LeadArchivedScores: Codable, Equatable, Sendable {
    /// Merged tasks (not folded or abandoned), and those of them whose audit rounds to pass are known.
    public var merged = 0
    public var counted = 0
    /// Their audit rounds to pass, summed, and how many passed the first.
    public var rounds = 0
    public var firstPass = 0
    public var reverts = 0
    public var withoutTests = 0
    public var unaudited = 0

    public init() {}

    /// Adds `task`'s part (`sign` 1), or takes it out (-1).
    mutating func count(_ task: LeadTask, sign: Int) {
        guard LeadScorecard.counts(task) else { return }
        // Only the task's own numbers: questions count in the scorecard from the board's, not the tasks'.
        let score = LeadTaskScore(task, questions: [])
        merged += sign
        if let passed = score.roundsToPass {
            counted += sign
            rounds += sign * passed
            if passed == 1 { firstPass += sign }
        }
        if score.revertedBy != nil { reverts += sign }
        if score.mergedWithoutTests == true { withoutTests += sign }
        if score.mergedUnaudited == true { unaudited += sign }
    }
}

/// The board's archive (`board-archive.jsonl`): board.json keeps what's live (planned, running, review, kept, blocked
/// and failed tasks) and what finished within `archiveAge`; older merged, folded, abandoned and reverted tasks move
/// here, one JSON line each, appended (those of the open batch leave a slim copy on the board: `archivedBatch`). Only the lead's tool server moves them (on its start, and at most every `archiveEvery` after a merge),
/// never the app: its views read board.json alone. The lead's tools that need a finished task find it here
/// (`withArchive`, `restore`).
extension BoardStore {
    /// How long a finished task stays on board.json.
    public static let archiveAge: Double = 86_400
    /// The tool server archives at most this often after merges.
    public static let archiveEvery: Double = 3_600

    /// Merged, folded, abandoned or reverted `archiveAge` ago, with nothing of it left on disk (a worktree still there
    /// is cleanup's to find on the board). A failed task stays, whatever its worktree: the lead may start it again.
    public static func archivable(_ task: LeadTask, now: Double) -> Bool {
        [.done, .folded, .abandoned, .reverted].contains(task.status) && task.worktree == nil
            && now - LeadTeams.finishedAt(task) >= archiveAge
    }

    /// What the open batch reads of an archived task (its card, its receipts, its summary's goal), kept on the board.
    static func batchCopy(_ task: LeadTask) -> LeadTask {
        var copy = LeadTask(id: task.id, slug: task.slug, title: task.title,
                            contract: LeadContract(goal: task.contract.goal, acceptance: [], boundaries: [], context: ""), status: task.status)
        copy.createdAt = task.createdAt
        copy.since = task.since
        copy.merged = task.merged
        copy.receipt = task.receipt
        copy.foldedInto = task.foldedInto
        copy.abandonedBecause = task.abandonedBecause
        return copy
    }

    /// Moves the board's finished tasks older than `archiveAge` to the archive, under the board's lock: their lines
    /// are appended and synced first, then the board is written without them (atomically), their scores kept in its
    /// tally. A crash between the two leaves them on the board and in the archive: the next run appends none of them
    /// again (a line equal to the task is there) and finishes the move; a line cut short by a crash is cut off first
    /// (its task is still on the board). Returns how many moved.
    @discardableResult
    public func archive(now: Double = Date().timeIntervalSince1970) throws -> Int {
        try locked {
            var board = try read()
            let leaving = board.tasks.filter { Self.archivable($0, now: now) }
            guard !leaving.isEmpty else { return 0 }
            let batch = Set(BatchSummary.batch(board).map(\.id))
            let archived = Dictionary(try readArchive(repair: true).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            try appendToArchive(leaving.filter { archived[$0.id] != $0 })
            let ids = Set(leaving.map(\.id))
            board.tasks.removeAll { ids.contains($0.id) }
            var scores = board.archivedScores ?? LeadArchivedScores()
            for task in leaving { scores.count(task, sign: 1) }
            board.archivedScores = scores
            // The open batch's copies: these that belong to it, and those still in it.
            let copies = leaving.filter { batch.contains($0.id) }.map(Self.batchCopy)
            let copied = Set(copies.map(\.id))
            let kept = (board.archivedBatch ?? []).filter { batch.contains($0.id) && !copied.contains($0.id) } + copies
            board.archivedBatch = kept.isEmpty ? nil : kept
            try write(board)
            return leaving.count
        }
    }

    /// The archived tasks, each as its last line has it, in the order they were first archived. Read again only when
    /// the file changed. Never on the app's main thread (`archiveReadsOnMainThread`).
    public func archived() -> [LeadTask] {
        if Thread.isMainThread { Self.noteArchiveReadOnMainThread() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: archiveFile),
              let size = (attributes[.size] as? NSNumber)?.intValue, let changed = attributes[.modificationDate] as? Date else { return [] }
        archiveLock.lock()
        defer { archiveLock.unlock() }
        if let cache = archiveCache, cache.size == size, cache.changed == changed { return cache.tasks }
        let tasks = (try? readArchive(repair: false)) ?? []
        archiveCache = (size, changed, tasks)
        return tasks
    }

    /// `board` with the archived tasks it doesn't hold, all in the order they were made: what the lead's tools that
    /// need finished tasks read (board(task), revert, status's counts, receipts, slugs). Its scorecard counts every
    /// task as before the archive (the tally is cleared: they're all here).
    public func withArchive(_ board: LeadBoard) -> LeadBoard {
        let archived = archived()
        guard !archived.isEmpty else { return board }
        let live = Set(board.tasks.map(\.id))
        var full = board
        full.tasks = (archived.filter { !live.contains($0.id) } + board.tasks).enumerated()
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }.map(\.element)
        full.archivedScores = nil
        full.archivedBatch = nil
        return full
    }

    /// The board and its archive (`withArchive`).
    public func loadAll() -> LeadBoard { withArchive(load()) }

    /// Every slug taken, on the board or in the archive: a new task's slug is none of them.
    public func takenSlugs(_ board: LeadBoard) -> Set<String> {
        Set(board.tasks.map(\.slug)).union(archived().map(\.slug))
    }

    /// The task `id` (or slug) on `board`, as `update` read it: an archived one is brought back onto it first (in the
    /// order tasks were made, its score out of the tally), to change it there; it leaves again with the next archive.
    /// Its index, nil when it's on neither.
    public func restore(_ id: String, into board: inout LeadBoard) -> Int? {
        if let index = board.taskIndex(id) { return index }
        guard let task = archived().first(where: { $0.id == id || $0.slug == id }) else { return nil }
        restoring[task.id] = task.status
        var scores = board.archivedScores ?? LeadArchivedScores()
        scores.count(task, sign: -1)
        board.archivedScores = scores
        board.archivedBatch?.removeAll { $0.id == task.id }
        if board.archivedBatch?.isEmpty == true { board.archivedBatch = nil }
        let index = board.tasks.firstIndex { $0.createdAt > task.createdAt } ?? board.tasks.endIndex
        board.tasks.insert(task, at: index)
        return index
    }

    /// How many times the archive was read on the main thread, in this process: the app reads none there.
    public static var archiveReadsOnMainThread: Int {
        archiveCounter.lock()
        defer { archiveCounter.unlock() }
        return mainThreadArchiveReads
    }

    private static let archiveCounter = NSLock()
    nonisolated(unsafe) private static var mainThreadArchiveReads = 0

    private static func noteArchiveReadOnMainThread() {
        archiveCounter.lock()
        mainThreadArchiveReads += 1
        archiveCounter.unlock()
    }

    /// The archive's lines as tasks, each as last written, in the order first archived; a line that doesn't read (cut
    /// short by a crash) is skipped. `repair` (under the board's lock): a last line cut short is cut off the file.
    private func readArchive(repair: Bool) throws -> [LeadTask] {
        guard let data = FileManager.default.contents(atPath: archiveFile) else { return [] }
        let whole = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        if repair, whole < data.count, Darwin.truncate(archiveFile, off_t(whole)) != 0 {
            throw BoardError(text: "\(archiveFile) ends in a line cut short, and it couldn't be cut off (\(String(cString: strerror(errno)))); nothing was archived.")
        }
        let decoder = JSONDecoder()
        var tasks: [String: LeadTask] = [:], order: [String] = []
        for line in data[..<whole].split(separator: 0x0A) {
            guard let task = try? decoder.decode(LeadTask.self, from: Data(line)) else { continue }
            if tasks.updateValue(task, forKey: task.id) == nil { order.append(task.id) }
        }
        return order.compactMap { tasks[$0] }
    }

    /// Appends `tasks` to the archive, a line each, in one write, then syncs it to disk.
    private func appendToArchive(_ tasks: [LeadTask]) throws {
        guard !tasks.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for task in tasks {
            data.append(try encoder.encode(task))
            data.append(0x0A)
        }
        let fd = open(archiveFile, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw BoardError(text: "\(archiveFile) can't be opened to append (\(String(cString: strerror(errno)))); nothing was archived.") }
        defer { close(fd) }
        var written = 0
        while written < data.count {
            let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + written, data.count - written) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { throw BoardError(text: "\(archiveFile) couldn't be appended to (\(String(cString: strerror(errno)))); nothing was archived.") }
            written += wrote
        }
        guard fsync(fd) == 0 else { throw BoardError(text: "\(archiveFile) couldn't be synced (\(String(cString: strerror(errno)))); nothing was archived.") }
    }
}
