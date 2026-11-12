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
    /// The wait on the user of the questions the archive took, in seconds: the scorecard's minutes still count them.
    /// Optional: boards before the questions' archive have none.
    public var questionSeconds: Double?

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
/// here, one JSON line each, appended (those of the open batch leave a slim copy on the board: `archivedBatch`). Past
/// `LeadBoard.keptUpdates` updates and `LeadBoard.keptClosedQuestions` closed questions, the oldest move here too, as
/// lines of their own (`{"update":…}`, `{"question":…}`). Only the lead's tool server moves them (on its start, and at most every `archiveEvery` after a merge or a post_update),
/// never the app: its views read board.json alone. The lead's tools that need a finished task, an old update or a closed
/// question find it here (`withArchive`, `restore`).
extension LeadQuestion {
    /// When it was answered, withdrawn or auto-decided (the first of them); nil while it's open.
    public var closedAt: Double? { [answeredAt, withdrawnAt, autoDecidedAt].compactMap { $0 }.min() }
}

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

    /// The closed questions past the cap, the oldest closed first: all but the `keptClosedQuestions` latest closed,
    /// except those about a task still on `slugs` (the board's): its score and receipt count them.
    static func leavingQuestions(_ board: LeadBoard, onBoard slugs: Set<String>) -> [LeadQuestion] {
        let closed = board.questions.filter { !$0.isOpen }.sorted { ($0.closedAt ?? $0.askedAt) < ($1.closedAt ?? $1.askedAt) }
        return closed.dropLast(LeadBoard.keptClosedQuestions).filter { question in question.task.map { !slugs.contains($0) } ?? true }
    }

    /// Moves the board's finished tasks older than `archiveAge`, its updates past `LeadBoard.keptUpdates` and its
    /// closed questions past `LeadBoard.keptClosedQuestions` (`leavingQuestions`) to the archive, under the board's
    /// lock: their lines are appended and synced first, then the board is written without them (atomically), their
    /// scores kept in its tally. A crash between the two leaves them on the board and in the archive: the next run
    /// appends none of them again (a line equal to it is there) and finishes the move; a line cut short by a crash is
    /// cut off first (what it held is still on the board). Returns how many moved.
    @discardableResult
    public func archive(now: Double = Date().timeIntervalSince1970) throws -> Int {
        try locked {
            var board = try read()
            let leaving = board.tasks.filter { Self.archivable($0, now: now) }
            let ids = Set(leaving.map(\.id))
            let leavingUpdates = Array(board.updates.prefix(max(0, board.updates.count - LeadBoard.keptUpdates)))
            let leavingQuestions = Self.leavingQuestions(board, onBoard: Set(board.tasks.filter { !ids.contains($0.id) }.map(\.slug)))
            guard !leaving.isEmpty || !leavingUpdates.isEmpty || !leavingQuestions.isEmpty else { return 0 }
            let batch = Set(BatchSummary.batch(board).map(\.id))
            let archive = try readArchive(repair: true)
            let archivedTasks = Dictionary(archive.tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let archivedUpdates = Dictionary(archive.updates.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let archivedQuestions = Dictionary(archive.questions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            try appendToArchive(tasks: leaving.filter { archivedTasks[$0.id] != $0 },
                                updates: leavingUpdates.filter { archivedUpdates[$0.id] != $0 },
                                questions: leavingQuestions.filter { archivedQuestions[$0.id] != $0 })
            board.tasks.removeAll { ids.contains($0.id) }
            let goneUpdates = Set(leavingUpdates.map(\.id)), goneQuestions = Set(leavingQuestions.map(\.id))
            board.updates.removeAll { goneUpdates.contains($0.id) }
            board.questions.removeAll { goneQuestions.contains($0.id) }
            var scores = board.archivedScores ?? LeadArchivedScores()
            for task in leaving { scores.count(task, sign: 1) }
            if !leavingQuestions.isEmpty {
                scores.questionSeconds = (scores.questionSeconds ?? 0) + leavingQuestions.reduce(0) { $0 + $1.waitingOnUser(now: now) }
            }
            board.archivedScores = scores
            // The open batch's copies: these that belong to it, and those still in it.
            let copies = leaving.filter { batch.contains($0.id) }.map(Self.batchCopy)
            let copied = Set(copies.map(\.id))
            let kept = (board.archivedBatch ?? []).filter { batch.contains($0.id) && !copied.contains($0.id) } + copies
            board.archivedBatch = kept.isEmpty ? nil : kept
            try write(board)
            return leaving.count + leavingUpdates.count + leavingQuestions.count
        }
    }

    /// What the archive holds, each as its last line has it, in the order first archived.
    struct ArchiveContents: Sendable {
        var tasks: [LeadTask] = []
        var updates: [LeadUpdate] = []
        var questions: [LeadQuestion] = []
        var isEmpty: Bool { tasks.isEmpty && updates.isEmpty && questions.isEmpty }
    }

    /// The archive as last read; read again only when the file changed. Never on the app's main thread
    /// (`archiveReadsOnMainThread`).
    func archiveContents() -> ArchiveContents {
        if Thread.isMainThread { Self.noteArchiveReadOnMainThread() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: archiveFile),
              let size = (attributes[.size] as? NSNumber)?.intValue, let changed = attributes[.modificationDate] as? Date else { return ArchiveContents() }
        archiveLock.lock()
        defer { archiveLock.unlock() }
        if let cache = archiveCache, cache.size == size, cache.changed == changed { return cache.contents }
        let contents = (try? readArchive(repair: false)) ?? ArchiveContents()
        archiveCache = (size, changed, contents)
        return contents
    }

    /// The archived tasks, each as its last line has it, in the order they were first archived.
    public func archived() -> [LeadTask] { archiveContents().tasks }

    /// The updates the archive took (`archive`), oldest first.
    public func archivedUpdates() -> [LeadUpdate] { archiveContents().updates }

    /// The closed questions the archive took (`archive`), oldest first.
    public func archivedQuestions() -> [LeadQuestion] { archiveContents().questions }

    /// `board` with the archived tasks, updates and questions it doesn't hold, each in the order made: what the lead's
    /// tools that need finished tasks read (board(task), revert, status's counts, receipts, slugs, questions). Its
    /// scorecard counts every task as before the archive (the tally is cleared: they're all here).
    public func withArchive(_ board: LeadBoard) -> LeadBoard {
        let archive = archiveContents()
        guard !archive.isEmpty else { return board }
        var full = board
        if !archive.tasks.isEmpty {
            let live = Set(board.tasks.map(\.id))
            full.tasks = (archive.tasks.filter { !live.contains($0.id) } + board.tasks).enumerated()
                .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }.map(\.element)
        }
        if !archive.updates.isEmpty {
            let live = Set(board.updates.map(\.id))
            full.updates = (archive.updates.filter { !live.contains($0.id) } + board.updates).enumerated()
                .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        }
        if !archive.questions.isEmpty {
            let live = Set(board.questions.map(\.id))
            full.questions = (archive.questions.filter { !live.contains($0.id) } + board.questions).enumerated()
                .sorted { ($0.element.askedAt, $0.offset) < ($1.element.askedAt, $1.offset) }.map(\.element)
        }
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
        let archive = archiveContents()
        guard let task = archive.tasks.first(where: { $0.id == id || $0.slug == id }) else { return nil }
        restoring[task.id] = task.status
        var scores = board.archivedScores ?? LeadArchivedScores()
        scores.count(task, sign: -1)
        // Its questions the archive took come back with it: its score counts them while it's on the board.
        let onBoard = Set(board.questions.map(\.id))
        let asked = archive.questions.filter { $0.task == task.slug && !onBoard.contains($0.id) }
        if !asked.isEmpty {
            scores.questionSeconds = (scores.questionSeconds ?? 0) - asked.reduce(0) { $0 + $1.waitingOnUser() }
            board.questions = (board.questions + asked).enumerated()
                .sorted { ($0.element.askedAt, $0.offset) < ($1.element.askedAt, $1.offset) }.map(\.element)
        }
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

    /// An update or a question in the archive's file: one line, `{"update":…}` or `{"question":…}`.
    private struct ArchivedLine: Codable {
        var update: LeadUpdate?
        var question: LeadQuestion?
    }

    /// The archive's lines, each as last written, in the order first archived; a line that doesn't read (cut short by
    /// a crash) is skipped. `repair` (under the board's lock): a last line cut short is cut off the file.
    private func readArchive(repair: Bool) throws -> ArchiveContents {
        guard let data = FileManager.default.contents(atPath: archiveFile) else { return ArchiveContents() }
        let whole = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        if repair, whole < data.count, Sys.truncate(archiveFile, off_t(whole)) != 0 {
            throw BoardError(text: "\(archiveFile) ends in a line cut short, and it couldn't be cut off (\(String(cString: strerror(errno)))); nothing was archived.")
        }
        let decoder = JSONDecoder()
        var tasks: [String: LeadTask] = [:], taskOrder: [String] = []
        var updates: [String: LeadUpdate] = [:], updateOrder: [String] = []
        var questions: [String: LeadQuestion] = [:], questionOrder: [String] = []
        for line in data[..<whole].split(separator: 0x0A) {
            let bytes = Data(line)
            if let task = try? decoder.decode(LeadTask.self, from: bytes) {
                if tasks.updateValue(task, forKey: task.id) == nil { taskOrder.append(task.id) }
            } else if let other = try? decoder.decode(ArchivedLine.self, from: bytes) {
                if let update = other.update, updates.updateValue(update, forKey: update.id) == nil { updateOrder.append(update.id) }
                if let question = other.question, questions.updateValue(question, forKey: question.id) == nil { questionOrder.append(question.id) }
            }
        }
        return ArchiveContents(tasks: taskOrder.compactMap { tasks[$0] }, updates: updateOrder.compactMap { updates[$0] },
                               questions: questionOrder.compactMap { questions[$0] })
    }

    /// Appends `tasks`, `updates` and `questions` to the archive, a line each, in one write, then syncs it to disk.
    private func appendToArchive(tasks: [LeadTask], updates: [LeadUpdate], questions: [LeadQuestion]) throws {
        guard !tasks.isEmpty || !updates.isEmpty || !questions.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for task in tasks {
            data.append(try encoder.encode(task))
            data.append(0x0A)
        }
        for update in updates {
            data.append(try encoder.encode(ArchivedLine(update: update)))
            data.append(0x0A)
        }
        for question in questions {
            data.append(try encoder.encode(ArchivedLine(question: question)))
            data.append(0x0A)
        }
        let fd = open(archiveFile, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw BoardError(text: "\(archiveFile) can't be opened to append (\(String(cString: strerror(errno)))); nothing was archived.") }
        defer { close(fd) }
        var written = 0
        while written < data.count {
            let wrote = data.withUnsafeBytes { Sys.write(fd, $0.baseAddress! + written, data.count - written) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { throw BoardError(text: "\(archiveFile) couldn't be appended to (\(String(cString: strerror(errno)))); nothing was archived.") }
            written += wrote
        }
        guard fsync(fd) == 0 else { throw BoardError(text: "\(archiveFile) couldn't be synced (\(String(cString: strerror(errno)))); nothing was archived.") }
    }
}
