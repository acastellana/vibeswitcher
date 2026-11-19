import Foundation

/// Each lead's board and decisions as last read, kept while their files are unchanged. The lead controller looks
/// every 3 s (off the main thread, see `LeadReads`), and a day's board is most of a MB of JSON (its decisions, dates
/// to parse).
public struct LeadFiles {
    /// A file's identity, size and modification time: while they're the same, so is what it says. A board is
    /// written whole and renamed into place, so a new one is a new file.
    public struct Stamp: Equatable {
        let inode: UInt64
        let size: Int64
        let modified: timespec

        public init?(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = Platform.Files.inode(info)
            size = Platform.Files.byteSize(info)
            modified = Platform.Files.modified(info)
        }

        public static func == (a: Stamp, b: Stamp) -> Bool {
            a.inode == b.inode && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    private var boards: [String: (stamp: Stamp, board: LeadBoard)] = [:]
    private var decisionLists: [String: (stamp: Stamp, decisions: [LeadDecision])] = [:]
    private var workflows: [String: (stamp: Stamp, recordsDir: String?)] = [:]
    private var mailLists: [String: (stamp: Stamp, mail: [LeadMail.Record])] = [:]
    /// How many times a file was read (for tests).
    public private(set) var fileReads = 0
    /// The lead each board names, for what the 3 s refresh needs of it (which lead sessions are replaced, which one
    /// keeps the role): even a board's stamp is a stat, which waited 3 s on a busy disk (hang-20261027-175604).
    public var names = LeadNames()

    public init() {}

    public mutating func board(_ root: String) -> LeadBoard {
        let store = BoardStore(root: root)
        let stamp = Stamp((store.folder as NSString).appendingPathComponent("board.json"))
        if let stamp, let kept = boards[root], kept.stamp == stamp { return kept.board }
        fileReads += 1
        let board = store.load()
        boards[root] = stamp.map { ($0, board) }
        return board
    }

    public mutating func decisions(_ root: String) -> [LeadDecision] {
        let store = BoardStore(root: root)
        let stamp = Stamp(store.recordPath("decisions.md"))
        if let stamp, let kept = decisionLists[root], kept.stamp == stamp { return kept.decisions }
        fileReads += 1
        let decisions = store.decisions()
        decisionLists[root] = stamp.map { ($0, decisions) }
        return decisions
    }

    /// The project's lead mail (`LeadMail.load`, oldest first): read again only when its file changed.
    public mutating func mail(_ root: String) -> [LeadMail.Record] {
        guard let stamp = Stamp(LeadMail.file(root: root).path) else {
            mailLists[root] = nil
            return []
        }
        if let kept = mailLists[root], kept.stamp == stamp { return kept.mail }
        fileReads += 1
        let mail = LeadMail.load(root: root)
        mailLists[root] = (stamp, mail)
        return mail
    }

    /// Where the lead's records are kept (`BoardStore.recordsDir`, from its workflow.md).
    public mutating func recordsDir(_ root: String) -> String? {
        let store = BoardStore(root: root)
        let stamp = Stamp((store.folder as NSString).appendingPathComponent("workflow.md"))
        if let stamp, let kept = workflows[root], kept.stamp == stamp { return kept.recordsDir }
        if stamp != nil { fileReads += 1 }
        let dir = store.recordsDir
        workflows[root] = stamp.map { ($0, dir) }
        return dir
    }

    /// Only these roots still have a lead.
    public mutating func keep(_ roots: Set<String>) {
        boards = boards.filter { roots.contains($0.key) }
        decisionLists = decisionLists.filter { roots.contains($0.key) }
        workflows = workflows.filter { roots.contains($0.key) }
        mailLists = mailLists.filter { roots.contains($0.key) }
    }
}

/// Where the lead controller reads and writes the boards, and reads its teams' transcripts and inboxes: a queue of its
/// own, never the main thread (decoding a day's board there, most of a MB of JSON, froze the window for a second at a
/// time, and so did thirty transcripts). One at a time, in the order asked, so a read after a write sees it; what's
/// read is handed to the main thread (`handTo`: the app's; the node hands it to its engine's queue).
public final class LeadReads: @unchecked Sendable {
    public let queue = DispatchQueue(label: "VibeSwitcher.lead-boards", qos: .userInitiated)
    /// Where results are handed: the main thread in the app.
    public let handTo: DispatchQueue
    /// The boards and decisions as last read (only on `queue`): read again only when their files changed.
    private var files = LeadFiles()

    public init(handTo: DispatchQueue = .main) { self.handTo = handTo }

    /// Runs `work` on the queue with the files read so far, then `then` with its result on `handTo` (the main thread).
    public func async<T>(_ work: @escaping (inout LeadFiles) -> T, then: @escaping (T) -> Void = { _ in }) {
        queue.async {
            let result = work(&self.files)
            self.handTo.async { then(result) }
        }
    }
}

/// The lead each board names (its pid, terminal and session): whom a message goes to, whether a wake-up or a flush
/// still goes to the same lead, which session is the live lead. Only those fields are decoded (`BoardStore.loadLead`,
/// under a millisecond for a MB of board), and only when the board's file changed. Looked at on `LeadReads`' queue
/// (`LeadFiles.names`): even the stat waited 3 s on a busy disk (hang-20261027-175604).
public struct LeadNames {
    private var kept: [String: (stamp: LeadFiles.Stamp, board: LeadBoard)] = [:]
    /// How many times a board's file was read (for tests).
    public private(set) var fileReads = 0
    /// Each board looked at, on the thread that looks (for tests).
    public var looked: (String) -> Void = { _ in }

    public init() {}

    public mutating func board(_ root: String) -> LeadBoard {
        looked(root)
        let store = BoardStore(root: root)
        let stamp = LeadFiles.Stamp((store.folder as NSString).appendingPathComponent("board.json"))
        if let stamp, let hit = kept[root], hit.stamp == stamp { return hit.board }
        fileReads += 1
        let board = store.loadLead()
        kept[root] = stamp.map { ($0, board) }
        return board
    }

    /// Only these roots still have a lead.
    public mutating func keep(_ roots: Set<String>) {
        kept = kept.filter { roots.contains($0.key) }
    }
}
