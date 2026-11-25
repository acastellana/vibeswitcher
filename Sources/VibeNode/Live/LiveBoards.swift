import Foundation
import VibeCore

/// Each lead's board, as the `boards` stream carries it (the parity table's gap 4): one `BoardValue` per project that
/// has a lead (`LeadStore`), sent through `changes` as its board changes. Read-only: nothing here writes a board.
///
/// - **Which file.** `<root>/.vibeswitcher/board.json`, the root the lead store holds (the node's own, never a path a
///   board names), opened once below the root with no link followed (`Platform.Files.readRegular`): a `.vibeswitcher`
///   or a `board.json` that is a link, a board that isn't a regular file (a FIFO opens without waiting and is refused),
///   or one over `mostBytes` isn't read: the value says the board can't be read and carries no tasks. So does a file
///   that isn't a board this build knows.
/// - **When it is read.** At once when the board's folder changes (`Platform.FolderWatch`: a board is written whole and
///   renamed into place, so its folder's entries change), and at each of the clock's looks (every `lookEvery` s): for a
///   folder made after the lead, a change the watch missed, and a finished task that is a day old. A read whose file is
///   unchanged (its `BoardFiles.Stamp`) decodes nothing; a value equal to the last sends nothing (`Changes`). Reads are
///   off the engine's queue, each board on a queue of its own (one stuck on its disk stalls no other board), one at a
///   time a board; a change during one reads again after it.
/// - **No timer between a write and its delta** but the read itself: the watch's change, the read, the value, the hub's
///   frame, each on the next turn of its queue.
///
/// On `queue` (the engine's): the leads' changes, the watches and the reads' results.
public final class LiveBoards: @unchecked Sendable {
    /// The largest board read (a day's board is most of a MB).
    public static let mostBytes = 32 << 20
    /// How often the clock looks, in seconds.
    public static let lookEvery = 30

    public let queue: DispatchQueue
    /// Each project's board value, by project id.
    public let changes = Changes<NodeWire.Value>()
    private let leads: Changes<LeadStore.Lead>
    /// Each lead's review rows waiting on a limit, by root (`LeadEngine.usageWaits`): a row's state says so.
    private let usageWaits: Changes<[String: ReviewUsageWait]>?
    /// Each lead's AI summaries, by root (`LeadEngine.teamSummaries`): a task at work carries its line.
    private let summaries: Changes<[String: String]>?
    private var waitsWatch: Subscription?
    private var summariesWatch: Subscription?
    /// Each lead's latest decisions with their lines, by root (`LeadEngine.boardDecisions`).
    private let decisions: Changes<[BoardDecision]>?
    private var decisionsWatch: Subscription?
    /// Each lead's read marks, by root (`LeadEngine.deliveryMarks`): an answered question carries `delivered`.
    private let deliveries: Changes<NodeWire.Value>?
    private var deliveriesWatch: Subscription?
    private let now: @Sendable () -> Date
    private let note: @Sendable (String) -> Void
    private var feeds: [String: Feed] = [:]
    private var watching: Subscription?
    private var ticks: [Subscription] = []

    /// One project's board: its root, the watch on its folder, the queue it is read on and the file as last read
    /// (touched on `reads` only).
    private final class Feed {
        let project: String
        let root: String
        let file: BoardFile
        let records: BoardRecordsFile
        let reads = DispatchQueue(label: "vibenode.live.board", qos: .utility)
        var watch: Platform.FolderWatch?
        var reading = false
        var again = false

        init(project: String, root: String) {
            self.project = project
            self.root = root
            file = BoardFile(root: root)
            records = BoardRecordsFile(root: root)
        }

        var folder: String { (file.path as NSString).deletingLastPathComponent }
    }

    /// `leads`: the lead store's changes (each project's root). `now`: what a finished task's day is counted from.
    /// `usageWaits`: the engine's review rows waiting on a limit, by root; a change reads that board's value again.
    /// `summaries`: the engine's AI summaries, by root; a change reads that board's value again.
    public init(queue: DispatchQueue, leads: Changes<LeadStore.Lead>, usageWaits: Changes<[String: ReviewUsageWait]>? = nil,
                summaries: Changes<[String: String]>? = nil, decisions: Changes<[BoardDecision]>? = nil,
                deliveries: Changes<NodeWire.Value>? = nil,
                now: @escaping @Sendable () -> Date = { Date() }, note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.deliveries = deliveries
        self.queue = queue
        self.leads = leads
        self.usageWaits = usageWaits
        self.summaries = summaries
        self.decisions = decisions
        self.now = now
        self.note = note
    }

    /// The leads followed and their boards read, and the clock's looks from now on. On `queue`, once.
    public func start(clock: NodeClock?) {
        dispatchPrecondition(condition: .onQueue(queue))
        watching = leads.subscribe(on: queue) { [weak self] batch in
            guard let self else { return }
            for change in batch { self.lead(change.id, root: change.value?.root) }
        }
        for (project, lead) in leads.values.sorted(by: { $0.key < $1.key }) { self.lead(project, root: lead.root) }
        waitsWatch = usageWaits?.subscribe(on: queue) { [weak self] batch in self?.readAgain(roots: Set(batch.map(\.id))) }
        summariesWatch = summaries?.subscribe(on: queue) { [weak self] batch in self?.readAgain(roots: Set(batch.map(\.id))) }
        decisionsWatch = decisions?.subscribe(on: queue) { [weak self] batch in self?.readAgain(roots: Set(batch.map(\.id))) }
        deliveriesWatch = deliveries?.subscribe(on: queue) { [weak self] batch in self?.readAgain(roots: Set(batch.map(\.id))) }
        if let clock {
            ticks.append(clock.every(Self.lookEvery) { [weak self] in self?.lookAll() })
            ticks.append(clock.every(Self.unwatchedEvery) { [weak self] in self?.lookUnwatched() })
        }
    }

    public func stop() {
        ticks = []
        watching = nil
        waitsWatch = nil
        summariesWatch = nil
        decisionsWatch = nil
        deliveriesWatch = nil
        queue.async { [self] in
            for feed in feeds.values { feed.watch?.stop() }
            feeds = [:]
        }
    }

    /// The boards' values now, by project.
    public var values: [String: NodeWire.Value] { changes.values }

    /// Every board read again (a file unchanged decodes nothing). On `queue`.
    public func lookAll() {
        dispatchPrecondition(condition: .onQueue(queue))
        for feed in feeds.values {
            if feed.watch == nil { watch(feed) }
            read(feed)
        }
    }

    /// How often a board whose folder isn't watched (none could be made: no folder yet, or the system had no watch left)
    /// is looked at: as often as a session's state is scanned, so a board without its watch is as quick as one with.
    public static let unwatchedEvery = 2

    /// Whether `project`'s board folder is watched now. On `queue`; for the tests.
    func isWatched(_ project: String) -> Bool { feeds[project]?.watch != nil }

    /// Each board without a watch asked for one again and read. On `queue`.
    public func lookUnwatched() {
        dispatchPrecondition(condition: .onQueue(queue))
        for feed in feeds.values where feed.watch == nil {
            watch(feed)
            read(feed)
        }
    }

    /// The boards at `roots` read again (what the engine adds to them changed). On `queue`.
    private func readAgain(roots: Set<String>) {
        for feed in feeds.values where roots.contains(feed.root) { read(feed) }
    }

    /// `project`'s lead is at `root` now (nil: it has none): its board followed, or no longer.
    private func lead(_ project: String, root: String?) {
        let root = root.map { ($0 as NSString).standardizingPath }
        if let feed = feeds[project], feed.root == root { return }
        if let old = feeds.removeValue(forKey: project) { old.watch?.stop() }
        guard let root else { return changes.send(project, nil) }
        let feed = Feed(project: project, root: root)
        feeds[project] = feed
        watch(feed)
        read(feed)
    }

    private func watch(_ feed: Feed) {
        guard let made = Platform.FolderWatch(path: feed.folder) else { return }
        feed.watch = made
        made.deliver(on: queue) { [weak self, weak feed, weak made] change in
            guard let self, let feed, self.feeds[feed.project] === feed else { return }
            if change.contains(.folderGone) {
                made?.stop()
                if feed.watch === made { feed.watch = nil }
            }
            self.read(feed)
        }
    }

    /// The board read off the engine's queue, and its value sent. One read at a time a board; a change during one
    /// reads again after it.
    private func read(_ feed: Feed) {
        guard !feed.reading else {
            feed.again = true
            return
        }
        feed.reading = true
        let now = self.now
        let waits = usageWaits?.values[feed.root] ?? [:]
        let lines = summaries?.values[feed.root] ?? [:]
        let decided = decisions?.values[feed.root] ?? []
        let delivered = deliveries?.values[feed.root]?["answers"]?.object ?? [:]
        feed.reads.async { [weak self] in
            let loaded = feed.file.load()
            // The workers its queue's forecast runs on: workflow.md's max_workers.
            let workers = LeadWorkflow.load(from: (feed.folder as NSString).appendingPathComponent("workflow.md")).maxWorkers
            let value = BoardValue.value(project: feed.project, root: feed.root, board: loaded.board, refusal: loaded.refusal, now: now(),
                                         usageWaits: waits, summaries: lines, decisions: decided, records: feed.records.load(), workers: workers,
                                         goals: loaded.goals, delivered: delivered)
            self?.queue.async { [weak self] in
                guard let self else { return }
                feed.reading = false
                guard self.feeds[feed.project] === feed else { return }
                if let refusal = loaded.refusal, loaded.fresh { self.note("the board at \(ConfigSeal.inert(feed.root, limit: 200)) isn't shown: \(refusal)") }
                self.changes.send(feed.project, value)
                if feed.again {
                    feed.again = false
                    self.read(feed)
                }
            }
        }
    }
}

/// One board's file as last read: decoded again only when its stamp changed. On its feed's reads queue only.
final class BoardFile: @unchecked Sendable {
    /// Where the board is under its root.
    static let components = [".vibeswitcher", "board.json"]
    let root: String
    let path: String
    private var stamp: BoardFiles.Stamp?
    private var kept: (board: LeadBoard?, refusal: String?, goals: LeadGoalsFile)?
    private var goalsStamp: BoardFiles.Stamp?

    init(root: String) {
        self.root = root
        path = ([root] + Self.components).joined(separator: "/")
    }

    /// The board (an empty one when there is no file yet), or why it can't be read; `fresh` when this read decoded it
    /// (not the copy kept from the last).
    func load() -> (board: LeadBoard?, refusal: String?, fresh: Bool, goals: LeadGoalsFile) {
        let now = BoardFiles.Stamp(path)
        let goalsNow = BoardFiles.Stamp(([root] + Self.goalsComponents).joined(separator: "/"))
        if let kept, now != nil, now == stamp, goalsNow == goalsStamp { return (kept.board, kept.refusal, false, kept.goals) }
        let read = Self.read(root: root)
        stamp = now
        goalsStamp = goalsNow
        kept = read
        return (read.board, read.refusal, true, read.goals)
    }

    /// Where the project's goals are under its root (`GoalStore`), beside the board.
    static let goalsComponents = [".vibeswitcher", "goals.json"]
    /// The most bytes the goals' file is read at.
    static let goalsBytes = 1 << 20

    /// The board under `root`: none there is an empty one; a link on the way, a file that isn't regular or is over
    /// `mostBytes`, one that can't be read or isn't a board this build knows is refused, saying why.
    /// The goals beside it (goals.json, read the same careful way; none when absent or unreadable), or, while there's no
    /// such file, those a board written by a build that kept them in it still holds.
    static func read(root: String, mostBytes: Int = LiveBoards.mostBytes) -> (board: LeadBoard?, refusal: String?, goals: LeadGoalsFile) {
        var goals = LeadGoalsFile()
        var hasFile = false
        if case .data(let data) = Platform.Files.readRegular(in: root, path: goalsComponents, limit: goalsBytes) {
            hasFile = true
            goals = (try? JSONDecoder().decode(LeadGoalsFile.self, from: data)) ?? LeadGoalsFile()
        }
        switch Platform.Files.readRegular(in: root, path: components, limit: mostBytes) {
        case .absent: return (LeadBoard(), nil, goals)
        case .refused(let why): return (nil, "the board isn't read: \(why)", goals)
        case .data(let data):
            guard let board = try? JSONDecoder().decode(LeadBoard.self, from: data) else { return (nil, "the board isn't one this build reads", goals) }
            if !hasFile, let legacy = LeadGoalsFile.legacy(boardData: data) { goals = legacy }
            return (board, nil, goals)
        }
    }
}
