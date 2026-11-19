import Foundation
import VibeCore

/// Each lead's board, as the `boards` stream carries it (the parity table's gap 4): one `BoardValue` per project that
/// has a lead (`LeadStore`), sent through `changes` as its board changes. Read-only: nothing here writes a board.
///
/// - **Which file.** `<root>/.vibeswitcher/board.json`, the root the lead store holds (the node's own, never a path a
///   board names). A link there, or a file over `mostBytes`, isn't read: the value says the board can't be read and
///   carries no tasks. So does a file that isn't a board this build knows.
/// - **When it is read.** At once when the board's folder changes (`Platform.FolderWatch`: a board is written whole and
///   renamed into place, so its folder's entries change), and at each of the clock's looks (every `lookEvery` s): for a
///   folder made after the lead, a change the watch missed, and a finished task that is a day old. A read whose file is
///   unchanged (its `LeadFiles.Stamp`) decodes nothing; a value equal to the last sends nothing (`Changes`). Reads are
///   off the engine's queue (`reads`), one at a time a board; a change during one reads again after it.
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
    private let now: @Sendable () -> Date
    private let note: @Sendable (String) -> Void
    private let reads = DispatchQueue(label: "vibenode.live.boards", qos: .utility)
    private var feeds: [String: Feed] = [:]
    private var watching: Subscription?
    private var ticks: [Subscription] = []

    /// One project's board: its root, the watch on its folder, and the file as last read (touched on `reads` only).
    private final class Feed {
        let project: String
        let root: String
        let file: BoardFile
        var watch: Platform.FolderWatch?
        var reading = false
        var again = false

        init(project: String, root: String) {
            self.project = project
            self.root = root
            file = BoardFile(path: (BoardStore(root: root).folder as NSString).appendingPathComponent("board.json"))
        }

        var folder: String { (file.path as NSString).deletingLastPathComponent }
    }

    /// `leads`: the lead store's changes (each project's root). `now`: what a finished task's day is counted from.
    public init(queue: DispatchQueue, leads: Changes<LeadStore.Lead>, now: @escaping @Sendable () -> Date = { Date() },
                note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.queue = queue
        self.leads = leads
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
        if let clock {
            ticks.append(clock.every(Self.lookEvery) { [weak self] in self?.lookAll() })
        }
    }

    public func stop() {
        ticks = []
        watching = nil
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
        reads.async { [weak self] in
            let loaded = feed.file.load()
            let value = BoardValue.value(project: feed.project, root: feed.root, board: loaded.board, refusal: loaded.refusal, now: now())
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

/// One board's file as last read: decoded again only when its stamp changed. On `LiveBoards`' reads queue only.
final class BoardFile: @unchecked Sendable {
    let path: String
    private var stamp: LeadFiles.Stamp?
    private var kept: (board: LeadBoard?, refusal: String?)?

    init(path: String) { self.path = path }

    /// The board (an empty one when there is no file yet), or why it can't be read; `fresh` when this read decoded it
    /// (not the copy kept from the last).
    func load() -> (board: LeadBoard?, refusal: String?, fresh: Bool) {
        let now = LeadFiles.Stamp(path)
        if let kept, now != nil, now == stamp { return (kept.board, kept.refusal, false) }
        let read = Self.read(path)
        stamp = now
        kept = read
        return (read.board, read.refusal, true)
    }

    /// The board at `path`: none there is an empty one; a link, a file over `LiveBoards.mostBytes`, one that can't be
    /// opened or isn't a board this build knows is refused, saying why.
    static func read(_ path: String, mostBytes: Int = LiveBoards.mostBytes) -> (board: LeadBoard?, refusal: String?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return (LeadBoard(), nil) }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return (nil, "the board isn't a regular file") }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= mostBytes else { return (nil, "the board is \(size >> 20) MB, more than the \(mostBytes >> 20) MB read") }
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, "the board couldn't be opened") }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: mostBytes + 1) ?? Data() else { return (nil, "the board couldn't be read") }
        guard data.count <= mostBytes else { return (nil, "the board is more than the \(mostBytes >> 20) MB read") }
        guard let board = try? JSONDecoder().decode(LeadBoard.self, from: data) else {
            return (nil, "the board isn't one this build reads")
        }
        return (board, nil)
    }
}
