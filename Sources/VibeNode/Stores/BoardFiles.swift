import Foundation
import VibeCore

/// Each lead's board as last read, kept while its file is unchanged (the app's `LeadFiles`,
/// `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift` 22-107, copied: the port map's "Copied from the app").
/// The engine looks every 3 s (on its reads queue, `LeadEngine.reads`, never its own), and a day's board is most of a MB
/// of JSON. The `Stamp` is read through `Platform.Files` (the Mac's `st_mtimespec` and Linux's `st_mtim`). The app's
/// mail is the window's and isn't read here; the decisions are kept, as the app's case reads them.
public struct BoardFiles {
    /// A file's identity, size and modification time: while they're the same, so is what it says. A board is
    /// written whole and renamed into place, so a new one is a new file.
    public struct Stamp: Equatable, Sendable {
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        public init?(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = Platform.Files.inode(info)
            size = Platform.Files.byteSize(info)
            let modified = Platform.Files.modified(info)
            seconds = Int(modified.tv_sec)
            nanoseconds = Int(modified.tv_nsec)
        }
    }

    private var boards: [String: (stamp: Stamp, board: LeadBoard)] = [:]
    private var decisionLists: [String: (stamp: Stamp, decisions: [LeadDecision])] = [:]
    private var workflows: [String: (stamp: Stamp, recordsDir: String?)] = [:]
    /// How many times a file was read (for tests).
    public private(set) var fileReads = 0
    /// The lead each board names, for what the engine needs of it (which lead sessions are replaced, which one keeps
    /// the role): even a board's stamp is a stat, which waited 3 s on a busy disk (hang-20261027-175604).
    public var names = BoardNames()

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
        names.keep(roots)
    }
}

/// The lead each board names (its pid, terminal and session): whom a message goes to, which session is the live lead
/// (the app's `LeadNames`, `LeadController.swift` 340-366, copied). Only those fields are decoded
/// (`BoardStore.loadLead`, under a millisecond for a MB of board), and only when the board's file changed. Looked at on
/// the engine's reads queue (`BoardFiles.names`).
public struct BoardNames {
    private var kept: [String: (stamp: BoardFiles.Stamp, board: LeadBoard)] = [:]
    /// How many times a board's file was read (for tests).
    public private(set) var fileReads = 0
    /// Each board looked at, on the thread that looks (for tests).
    public var looked: (String) -> Void = { _ in }

    public init() {}

    public mutating func board(_ root: String) -> LeadBoard {
        looked(root)
        let store = BoardStore(root: root)
        let stamp = BoardFiles.Stamp((store.folder as NSString).appendingPathComponent("board.json"))
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

/// Where the engine reads and writes the boards (the app's `LeadReads`, `LeadController.swift` 109-125, as the engine
/// plan's EN-D1 has it): a queue of its own, never the engine's (decoding a day's board, most of a MB of JSON, on the
/// queue every request waits on would hold them all). One at a time, in the order asked, so a read after a write sees
/// it; what's read is handed to the engine's queue.
public final class BoardReads: @unchecked Sendable {
    public let queue = DispatchQueue(label: "vibenode.lead-boards", qos: .userInitiated)
    /// Where results are handed: the engine's queue.
    public let handTo: DispatchQueue
    /// The boards as last read (only on `queue`): read again only when their files changed.
    private var files = BoardFiles()

    public init(handTo: DispatchQueue) { self.handTo = handTo }

    /// Runs `work` on the queue with the files read so far, then `then` with its result on the engine's queue.
    public func async<T>(_ work: @escaping (inout BoardFiles) -> T, then: @escaping (T) -> Void = { _ in }) {
        queue.async {
            let result = work(&self.files)
            self.handTo.async { then(result) }
        }
    }
}
