import AppKit
import Combine
import Foundation
import VibeCore

/// How many reports have waited for each lead too long to be woken for (see `LeadWake.waiting`), by the lead's
/// terminal: its strip shows them.
final class ReportsWaiting: ObservableObject {
    static let shared = ReportsWaiting()
    @Published private(set) var count: [String: Int] = [:]

    func set(_ count: Int, tty: String) {
        if (self.count[tty] ?? 0) != count { self.count[tty] = count > 0 ? count : nil }
    }

    /// Only these terminals still have a lead.
    func keep(_ ttys: Set<String>) {
        if !Set(count.keys).isSubset(of: ttys) { count = count.filter { ttys.contains($0.key) } }
    }
}

/// Each lead's board and decisions as last read, kept while their files are unchanged. The lead controller looks
/// every 3 s (off the main thread, see `LeadReads`), and a day's board is most of a MB of JSON (its decisions, dates
/// to parse).
struct LeadFiles {
    /// A file's identity, size and modification time: while they're the same, so is what it says. A board is
    /// written whole and renamed into place, so a new one is a new file.
    struct Stamp: Equatable {
        let inode: UInt64
        let size: Int64
        let modified: timespec

        init?(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = info.st_ino
            size = info.st_size
            modified = info.st_mtimespec
        }

        static func == (a: Stamp, b: Stamp) -> Bool {
            a.inode == b.inode && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    private var boards: [String: (stamp: Stamp, board: LeadBoard)] = [:]
    private var decisionLists: [String: (stamp: Stamp, decisions: [LeadDecision])] = [:]
    private var workflows: [String: (stamp: Stamp, recordsDir: String?)] = [:]
    /// How many times a file was read (for tests).
    private(set) var fileReads = 0
    /// The lead each board names, for what the 3 s refresh needs of it (which lead sessions are replaced, which one
    /// keeps the role): even a board's stamp is a stat, which waited 3 s on a busy disk (hang-20261027-175604).
    var names = LeadNames()

    mutating func board(_ root: String) -> LeadBoard {
        let store = BoardStore(root: root)
        let stamp = Stamp((store.folder as NSString).appendingPathComponent("board.json"))
        if let stamp, let kept = boards[root], kept.stamp == stamp { return kept.board }
        fileReads += 1
        let board = store.load()
        boards[root] = stamp.map { ($0, board) }
        return board
    }

    mutating func decisions(_ root: String) -> [LeadDecision] {
        let store = BoardStore(root: root)
        let stamp = Stamp(store.recordPath("decisions.md"))
        if let stamp, let kept = decisionLists[root], kept.stamp == stamp { return kept.decisions }
        fileReads += 1
        let decisions = store.decisions()
        decisionLists[root] = stamp.map { ($0, decisions) }
        return decisions
    }

    /// Where the lead's records are kept (`BoardStore.recordsDir`, from its workflow.md).
    mutating func recordsDir(_ root: String) -> String? {
        let store = BoardStore(root: root)
        let stamp = Stamp((store.folder as NSString).appendingPathComponent("workflow.md"))
        if let stamp, let kept = workflows[root], kept.stamp == stamp { return kept.recordsDir }
        if stamp != nil { fileReads += 1 }
        let dir = store.recordsDir
        workflows[root] = stamp.map { ($0, dir) }
        return dir
    }

    /// Only these roots still have a lead.
    mutating func keep(_ roots: Set<String>) {
        boards = boards.filter { roots.contains($0.key) }
        decisionLists = decisionLists.filter { roots.contains($0.key) }
        workflows = workflows.filter { roots.contains($0.key) }
    }
}

/// Where the lead controller reads and writes the boards, and reads its teams' transcripts and inboxes: a queue of its
/// own, never the main thread (decoding a day's board there, most of a MB of JSON, froze the window for a second at a
/// time, and so did thirty transcripts). One at a time, in the order asked, so a read after a write sees it; what's
/// read is handed to the main thread.
final class LeadReads: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VibeSwitcher.lead-boards", qos: .userInitiated)
    /// The boards and decisions as last read (only on `queue`): read again only when their files changed.
    private var files = LeadFiles()

    /// Runs `work` on the queue with the files read so far, then `then` with its result on the main thread.
    func async<T>(_ work: @escaping (inout LeadFiles) -> T, then: @escaping (T) -> Void = { _ in }) {
        queue.async {
            let result = work(&self.files)
            DispatchQueue.main.async { then(result) }
        }
    }
}

/// What the witness reads of a lead's team at each look, on `LeadReads`' queue: a team's transcripts are a few hundred
/// KB each to parse (thirty of them froze the window when read on the main thread). The sessions as they were when the
/// look began, what each member it watches is doing (`LeadObserver.watching`), the oldest message waiting for each
/// worker, and the project's workflow.
struct TeamReading {
    typealias Watched = (activity: LeadActivity, tail: TranscriptTail?, progress: TranscriptProgress?)

    /// The window's sessions, and the scan's agents in them, by host session id.
    var hosted: [String: HostSession] = [:]
    var sessions: [String: Session] = [:]
    var watched: [String: Watched] = [:]
    var held: [String: SteerMessage] = [:]
    /// The live workers with a run in line for the Mac-wide test and build lock (see `LeadWitness.Seen.lockWait`).
    var lockWaits: [String: TestLock.Wait] = [:]
    var workflow = LeadWorkflow()
    /// The lead's loop runs with workflow.md's auto_advance on: a verifier that ends without a verdict is its to
    /// audit again (see `LeadWitness.leftToAdvance`). Looked at only while a task is in review.
    var advancing = false
    /// The live members with no agent in the scan whose agent's process has exited, by a process table read here (see
    /// `HostSession.agentRuns`): only these have quit. One whose agent waits on a background command runs on.
    var agentGone: Set<String> = []

    /// The member `id`'s agent quit, leaving its session's shell open: the scan has no agent on it a minute on
    /// (`scanSaysQuit`, see `TableRead.agentQuit`), and its agent's own process has exited (`agentGone`).
    func agentQuit(_ id: String, session: Session?, scanSaysQuit: Bool) -> Bool {
        session == nil && scanSaysQuit && agentGone.contains(id)
    }

    /// A worker's transcript is read whatever it shows: a stall is one that reads as working too (see `LeadStall`). A
    /// verifier's while it doesn't show working: a turn that ended on an API error reads as finished or waiting, and
    /// its transcript says which it was.
    static func read(root: String, board: LeadBoard, hosted: [String: HostSession], sessions: [String: Session],
                     observer: LeadObserver) -> TeamReading {
        var team = TeamReading(hosted: hosted, sessions: sessions)
        let workers = Set(board.tasks.compactMap(\.worker))
        for id in board.tasks.flatMap({ [$0.worker, $0.verifier] }).compactMap({ $0 }) where team.watched[id] == nil {
            guard let info = hosted[id], info.isLive, let session = sessions[id], session.status != .working || workers.contains(id) else { continue }
            team.watched[id] = observer.watching(info, agentPid: session.pid)
            if workers.contains(id) {
                team.held[id] = SteerInbox.pending(tty: session.tty).filter { $0.agentPid == session.pid }.min { $0.at < $1.at }
            }
        }
        let folders = workers.compactMap { id in hosted[id].flatMap { $0.isLive ? (id, $0.cwd) : nil } }
        if !folders.isEmpty, let lock = TestLock.standard() {
            team.lockWaits = lock.waits(for: Dictionary(folders, uniquingKeysWith: { first, _ in first }))
        }
        team.workflow = LeadWorkflow.load(from: (BoardStore(root: root).folder as NSString).appendingPathComponent("workflow.md"))
        team.advancing = team.workflow.autoAdvance && board.tasks.contains { $0.status == .review } && LeadAdvance.running(BoardStore(root: root))
        // The table is read only when the scan lacks a member's agent (rare), here off the main thread.
        let unseen = board.tasks.flatMap { [$0.worker, $0.verifier] }.compactMap { $0 }.compactMap { id in
            hosted[id].flatMap { $0.isLive && sessions[id] == nil ? (id: id, session: $0) : nil }
        }
        if !unseen.isEmpty, let table = ProcessTable.trySnapshot() {
            team.agentGone = Set(unseen.filter { !$0.session.agentRuns(in: table) }.map(\.id))
        }
        return team
    }
}

/// The lead each board names (its pid, terminal and session): whom a message goes to, whether a wake-up or a flush
/// still goes to the same lead, which session is the live lead. Only those fields are decoded (`BoardStore.loadLead`,
/// under a millisecond for a MB of board), and only when the board's file changed. Looked at on `LeadReads`' queue
/// (`LeadFiles.names`): even the stat waited 3 s on a busy disk (hang-20261027-175604).
struct LeadNames {
    private var kept: [String: (stamp: LeadFiles.Stamp, board: LeadBoard)] = [:]
    /// How many times a board's file was read (for tests).
    private(set) var fileReads = 0
    /// Each board looked at, on the thread that looks (for tests).
    var looked: (String) -> Void = { _ in }

    mutating func board(_ root: String) -> LeadBoard {
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
    mutating func keep(_ roots: Set<String>) {
        kept = kept.filter { roots.contains($0.key) }
    }
}

/// The app's side of project leads: starting them, keeping their boards loaded, answering their questions, and
/// being their witness (telling a lead when one of its workers needs input, stops without reporting, or dies).
final class LeadController: ObservableObject {
    /// Each running lead's board, by repository root.
    @Published private(set) var boards: [String: LeadBoard] = [:]
    /// Each running lead's decisions (`BoardStore.decisions`), by repository root.
    @Published private(set) var decisions: [String: [LeadDecision]] = [:]
    /// Where each running lead's records are kept (`BoardStore.recordsDir`, nil: in .vibeswitcher), by repository
    /// root, read with its board: the Team tab says so without reading workflow.md as it draws.
    @Published private(set) var recordsDirs: [String: String?] = [:]
    /// The Team rows as last made, for the Team tab and the sidebar (see `TeamRowsCache`).
    let teamRows = TeamRowsCache()
    /// The Team view's plain-language lines.
    let summaries = TeamSummaryModel()
    /// The all-done cards: each board clearing after merges, its summary, and the user opening the lead.
    let allDone: AllDoneWatch
    /// The leads' bases, when they moved other than through merges (see `BaseMoves`).
    let baseMoves: BaseMoves
    /// The Mac kept awake while a team works.
    let keepAwake: KeepAwake

    private let host: HostClient
    private let store: SessionStore
    /// The project's Claude command (its launch preset), flags included.
    private let claudeCommand: (String) -> String
    /// What a board says to the user (a question, its all-done card, something broken): the app's notifier decides
    /// whether it notifies (`AlertRules`).
    var alert: (AlertRules.LeadEvent) -> Void = { _ in }
    var select: (UUID) -> Void = { _ in }
    private var timer: Heartbeat.Subscription?
    /// Questions told about (by id and version: a revision is news too).
    private var seenQuestions: Set<String> = []
    /// When the app started: a question older than that was told before it (see `AlertRules.look`).
    private let launchedAt = Date().timeIntervalSince1970
    /// What became of an answer that didn't land as one (the question was withdrawn, or answered already), by
    /// question id: its card says so.
    @Published private(set) var answerNotices: [String: String] = [:]
    /// Witness events already told, so each is told once.
    private var told: Set<String> = []
    /// When the witness first saw each verifier that auto_advance audits again end without a verdict (by root and
    /// session; see `LeadWitness.leftToAdvance`).
    private var advanceSeen: [String: Date] = [:]
    /// Each project's free disk space, watched (see `LeadWitness.Disk`), by root.
    private var disks: [String: LeadWitness.Disk] = [:]
    /// The bytes free on the volume holding a path, as the disk watch reads them (see `DiskSpace.free`; a test run's
    /// is roomy). Faked in tests.
    var freeSpace: (String) -> Int64? = DiskSpace.free(at:)
    /// The Mac's power source, read once a minute: a hold under the battery limit in Settings, and the resume after
    /// it, is told to every running lead (see `LeadWitness.Power`). None until the app gives it the reader
    /// (`watchPower`): benches and tests read nothing.
    private var power: LeadWitness.Power?
    private var powerTimer: Heartbeat.Subscription?
    /// The working policy in Settings › Project lead, told to each running lead once when it changes and once when
    /// this build first runs (see `LeadWitness.PolicyWatch`); none until the app starts it (`watchPolicy`).
    var policyWatch: LeadWitness.PolicyWatch?
    private var policyTimer: Heartbeat.Subscription?
    /// The Mac-wide test and build slots, looked at once a minute: one held long is told to every running lead (see
    /// `LeadWitness.HeavySlots`); none until the app starts it (`watchHeavySlots`).
    private var heavySlots: LeadWitness.HeavySlots?
    private var heavySlotsTimer: Heartbeat.Subscription?
    /// The leads refused for the Mac's room or load, looked at once a minute: each is woken once there's room, whichever
    /// project's sessions ended (see `LeadWitness.RoomWaits`); none until the app starts it (`watchRoom`).
    private var roomWaits: LeadWitness.RoomWaits?
    private var roomTimer: Heartbeat.Subscription?
    /// The Mac's 1-minute load as the room watch reads it (see `MacLoad.oneMinute`); faked in tests.
    var macLoad: () -> Double? = MacLoad.oneMinute
    /// Ended team sessions the host has been asked to drop.
    private var forgetting: Set<UUID> = []
    /// Ends the sessions of finished tasks from the vault's roster, in every project (see `RoleSweep`); nil in tests
    /// that don't give it a vault of their own.
    private var roleSweep: RoleSweep?
    /// A look of `roleSweep` under way, and when the last began.
    private var sweeping = false
    private var sweptAt = Date.distantPast
    /// What the roster said each verifier submitted, by session: its end is expected (see `LeadWitness.Seen`).
    private var submitted: [String: Double] = [:]
    /// What the roster said of each worker's and verifier's tools: when it was bound, and when they connected (see
    /// `LeadWitness.Seen.boundAt`).
    private var toolTimes: [String: (bound: Double, tools: Double?)] = [:]
    /// Sessions that never got their tools, asked to end, and when last (asked again a minute on while they run).
    private var endingNoTools: [String: Date] = [:]
    /// Terminals being flushed, and when a message was last typed into each (its hooks need a moment to say it's
    /// working again; until then another flush would type a second prompt).
    private var flushing: Set<String> = []
    private var typedAt: [String: Date] = [:]
    /// Each lead's wake-ups (see `LeadWake`), by terminal and agent, and the ones with a look-again scheduled.
    private var wakes: [String: LeadWake] = [:]
    private var wakeLater: Set<String> = []
    /// Messages for a lead that isn't running right now (restarting): delivered once a lead runs there again.
    /// Each in the order it was sent (`order`, taken on the main thread as it's sent, and kept when it's held again):
    /// whether it's held is known only once the boards' queue has looked, and one sent later may be held first.
    private var held: [String: [(order: Int, text: String, sender: SteerMessage.Sender)]] = [:]
    private var sent = 0
    /// What the team's agents are doing, from their hooks and transcripts together (see `LeadActivity`).
    private let observer = LeadObserver()
    /// Roots whose lead is being prepared (off the main thread) right now.
    private var startingLeads: Set<String> = []
    /// Starts asked for before the host said which sessions run (right after a relaunch), by root: decided then.
    private var pendingStarts: [String: (goal: String?, show: Bool, askAboutMovedHead: Bool)] = [:]
    /// The leads found running (after a relaunch, an install) whose role the vault binds to their session: bound
    /// again, by root. Each live lead session is looked at once.
    @Published private(set) var keptLeads: [String: UUID] = [:]
    private var adopting: Set<UUID> = []
    private var hostWelcome: AnyCancellable?
    /// The boards and decisions, and the teams' transcripts, read off the main thread (the boards written there too, to
    /// keep the order; `baseMoves` writes there as well).
    private let reads: LeadReads
    /// The lead each board names, for the starts and the once-a-minute notices that look it up on the main thread
    /// (`leadSessions`). Messages, wake-ups, flushes and the 3 s refresh read it off the main thread (`LeadFiles.names`).
    private var names = LeadNames()
    /// Each board looked at for the lead it names, on the thread that looks (for tests).
    var boardLooked: (String) -> Void = { _ in } {
        didSet {
            let looked = boardLooked
            names.looked = looked
            reads.async { files in files.names.looked = looked }
        }
    }
    /// A refresh is reading the boards; one asked for meanwhile runs once it's done.
    private var refreshing = false
    private var refreshAgain = false
    private let vault: LeadVault
    /// Leads whose role another session of their project holds now (VibeSwitcher started a new lead), by window
    /// session: the window says so, and what's typed into them goes to the live lead (see `ReplacedLead`).
    @Published private(set) var replacedLeads: [UUID: ReplacedLead] = [:]
    /// Lead sessions a start replaced, by root: replaced from that moment, before the new lead's board names it.
    private var replacing: [UUID: String] = [:]
    /// The lead session each root's board named at the last look (read off the main thread, see `markReplaced`).
    private var holders: [String: UUID] = [:]
    /// A look at the boards for `markReplaced` or `keepRunningLeads` is under way: none other is asked for meanwhile
    /// (on a disk slow enough to stall a stat, they'd queue up ahead of the boards' writes).
    private var marking = false
    /// How many starts replaced a lead so far: a look begun before one is stale (it may name the replaced lead still).
    private var replacements = 0
    private var keepingRunning = false
    /// What's typed into each replaced lead so far.
    private var lines: [UUID: HostInput.Line] = [:]
    /// The leads' inboxes, and the home whose agents' folders hold transcripts (scratch ones in tests).
    private let inbox: URL
    private let home: String
    /// Whether the lead the board names runs on its terminal. Faked in tests (their leads aren't Claude).
    var leadRuns: (LeadAgent) -> Bool = { agent in ProcessTable.info(pid: agent.pid).map { $0.tty == agent.tty && $0.agent != nil } == true }
    /// Asks the user (an alert): the index of the button chosen. Faked in tests.
    var confirm: (_ title: String, _ text: String, _ buttons: [String]) -> Int = LeadController.runAlert
    /// Answers Claude's trust question in a lead the app started (off in tests: no real host to ask).
    var answersTrust = true

    init(host: HostClient, store: SessionStore, vault: LeadVault = .standard, inbox: URL = VibePaths.root,
         home: String = VibePaths.home, keepAwake: KeepAwake = KeepAwake(), sweepsRoles: Bool = false, claudeCommand: @escaping (String) -> String) {
        self.host = host
        self.keepAwake = keepAwake
        self.store = store
        self.vault = vault
        self.inbox = inbox
        self.home = home
        let reads = LeadReads()
        self.reads = reads
        baseMoves = BaseMoves(vault: vault, reads: reads)
        allDone = AllDoneWatch(reads: reads)
        self.claudeCommand = claudeCommand
        summaries.lookup = { [weak host, weak store] id in
            (host?.sessions.first { $0.id.uuidString == id }, store?.sessions.first { $0.hostID?.uuidString == id }?.transcriptPath)
        }
        roleSweep = sweepsRoles ? RoleSweep(roster: { try vault.roster() }, end: { [weak host] session in
            DispatchQueue.main.async { host?.kill(session.id) }
        }, tell: { [weak self] text in
            DispatchQueue.main.async { self?.tellStranded(text) }
        }) : nil
        roleSweep?.submitted = { [weak self] submitted in
            DispatchQueue.main.async { self?.submitted = submitted }
        }
        roleSweep?.tools = { [weak self] tools in
            DispatchQueue.main.async { self?.toolTimes = tools }
        }
        allDone.enabled = { [weak summaries] in summaries?.enabled ?? false }
        allDone.changed = { [weak self] _ in self?.refresh() }
        timer = Heartbeat.shared.every(3) { [weak self] in self?.refresh() }
        // Whatever is typed into a replaced lead (its terminal, the composer, the phone) comes here, never to it.
        host.inputGate = { [weak self] id, bytes in self?.takeInput(bytes, for: id) ?? false }
        // The host's welcome says which sessions run: the starts that waited for it, and the running leads, go on.
        hostWelcome = host.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.startPending()
            self?.keepRunningLeads()
        }
        // A move it asks about is a card in the lead's chat, no alert: you commit on the base yourself. Only a merge it
        // refused waits on you (`AlertRules.baseMoved`, at each refresh).
        baseMoves.onTaken = { [weak self] root, move, taker in
            guard let self else { return }
            let span = "\(move.count) on \(move.branch) (\(move.from.prefix(8)) → \(move.to.prefix(8)))"
            switch taker {
            case .vault: return
            case .typed:
                self.deliver("VibeSwitcher took the \(span) as the user's: they ran it from its window. Merges start from there now.",
                             from: .system("VibeSwitcher, from what the user sent in the window"), root: root)
            case .you:
                self.deliver("The user accepted the \(span) in VibeSwitcher: merges start from there now.",
                             from: .system("the user, in the window"), root: root)
            }
        }
    }

    static var serverPath: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
    }

    /// A goal from `vibeswitcher --lead` comes as a distributed notification, which any process can post.
    static let commandLineNote = "any process on this Mac can send one, so it isn't vouched for as the user's"
    static let commandLine = SteerMessage.Sender.system("vibeswitcher --lead on the command line; \(commandLineNote)")

    /// The live window sessions that are leads, by root. Where a replaced lead runs on beside the one that replaced
    /// it: the one the board names, else the newest.
    private var leadSessions: [String: HostSession] {
        Self.leadSessions(host.sessions) { names.board($0).leadSession }
    }

    /// The live window sessions among `sessions` that are leads, by root; `named` reads the lead session a root's board
    /// names (only where two leads share a root).
    private static func leadSessions(_ sessions: [HostSession], named: (String) -> String?) -> [String: HostSession] {
        var result: [String: HostSession] = [:]
        for session in sessions where session.isLive && LeadTeams.role(label: session.label) == .lead {
            let root = (session.cwd as NSString).standardizingPath
            if let other = result[root] {
                let named = named(root)
                if other.id.uuidString == named || (session.id.uuidString != named && session.startedAt < other.startedAt) { continue }
            }
            result[root] = session
        }
        return result
    }

    /// The roots with a live lead in the window (no board read: which of two leads it is doesn't matter here).
    private var leadRoots: Set<String> {
        Set(host.sessions.filter { $0.isLive && LeadTeams.role(label: $0.label) == .lead }.map { ($0.cwd as NSString).standardizingPath })
    }

    /// The lead a row is, if it is one: its root (the folder its window session started in, wherever its agent has
    /// `cd`'d since) and board.
    func lead(for row: WindowRow) -> (root: String, board: LeadBoard)? {
        guard let id = row.hostID, let session = host.sessions.first(where: { $0.id == id }), LeadTeams.role(label: session.label) == .lead
        else { return nil }
        let root = (session.cwd as NSString).standardizingPath
        guard let board = boards[root] else { return nil }
        return (root, board)
    }

    /// The user opened this lead: its all-done cards are seen, and the sidebar's check goes at once.
    func seeAllDone(for row: WindowRow) {
        guard let lead = lead(for: row), lead.board.hasUnseenAllDone, let seen = allDone.see(root: lead.root, board: lead.board) else { return }
        boards[lead.root] = seen
    }

    // MARK: Starting

    /// Starts the project lead for the repository holding `folder`, or shows the one already running. A `goal` (from
    /// `vibeswitcher --lead`) goes into its first prompt (or to the running lead), not as the user's: any process can
    /// post that notification. `show: false` leaves the window's selection alone.
    /// `askAboutMovedHead`: you asked in the app (not the notification), so a moved branch is yours to take.
    func startLead(in folder: String, goal: String? = nil, show: Bool = true, askAboutMovedHead: Bool = true) {
        // git can be slow (a network volume, a git shim): find the repository off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let top = Git.run(["rev-parse", "--show-toplevel"], in: folder)
            let root = (top.output as NSString).standardizingPath
            let hasCommits = top.ok && !top.output.isEmpty && Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).ok
            // No commits at all, and you asked in the app for this repository's top folder: what its first commit would
            // hold. A start from outside the app (anything can post it) offers no commit, nor does a folder inside
            // the repository (a stray git init in a parent, your home folder), nor one with commits elsewhere (an
            // orphan branch, a fetch).
            let chosen = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
            let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
            let offers = top.ok && !top.output.isEmpty && !hasCommits && askAboutMovedHead && chosen == root && root != home
                && FolderRepository.isEmptyRepository(root)
            let firstCommit = offers ? FolderRepository.plan(for: root, scratch: FileManager.default.temporaryDirectory) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                guard top.ok, !top.output.isEmpty else {
                    return self.alert("A project lead needs a git repository.", "\(folder) isn't in one. Run git init (and make a first commit) first.")
                }
                guard hasCommits else {
                    guard let firstCommit else {
                        return self.alert("The repository has no commits yet.", "Workers branch from main: make a first commit in \(root), then start the lead.")
                    }
                    return self.offerFirstCommit(firstCommit, root: root, goal: goal, show: show)
                }
                self.startLead(root: root, goal: goal, show: show, askAboutMovedHead: askAboutMovedHead)
            }
        }
    }

    /// A repository with no commits yet: the first commit a folder in no repository gets (`FolderRepository`), if you
    /// say so, then its lead.
    private func offerFirstCommit(_ plan: Result<FolderRepository.Plan, ProjectCreation.Problem>, root: String, goal: String?, show: Bool) {
        let name = (root as NSString).lastPathComponent
        switch plan {
        case .failure(let problem):
            alert("“\(name)” has no commits yet.", "Workers start from a commit, and its files couldn't be listed: \(problem.message)")
        case .success(let plan):
            let question = ProjectFolderStart.emptyRepositoryQuestion(plan)
            guard confirm(question.title, question.text, ProjectFolderStart.emptyRepositoryButtons) == 0 else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let problem = FolderRepository.make(plan)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let problem { return self.alert("“\(name)” couldn't get a first commit.", problem.message) }
                    self.startLead(root: root, goal: goal, show: show, askAboutMovedHead: true)
                }
            }
        }
    }

    /// What a start does with the lead that may be running already.
    enum StartPlan: Equatable {
        /// The host hasn't said yet which sessions run (the app just relaunched): decided once it has.
        case wait
        /// No lead runs for the project.
        case start
        /// The lead runs (and holds its role, or nothing here may replace it): shown, never replaced.
        case show(UUID)
        /// The lead runs without its role (the vault binds it to no session, or another): you're asked first.
        case askToReplace(UUID)
    }

    /// `running`: the project's live lead session, if any; `holdsRole`: whether the vault binds the lead's role to it
    /// (nil: the vault couldn't be asked); `fromUser`: you asked in the app (not `vibeswitcher --lead`, which anything
    /// can post).
    static func plan(hostState: HostClient.State, running: UUID?, holdsRole: Bool?, fromUser: Bool) -> StartPlan {
        if hostState == .connecting { return .wait }
        guard let running else { return .start }
        return holdsRole == false && fromUser ? .askToReplace(running) : .show(running)
    }

    private func startLead(root: String, goal: String?, show: Bool, askAboutMovedHead: Bool) {
        guard let running = leadSessions[root] else {
            if Self.plan(hostState: host.state, running: nil, holdsRole: nil, fromUser: askAboutMovedHead) == .wait {
                // A relaunched app's session list is empty until the host's welcome: that's no sign no lead runs.
                pendingStarts[root] = (goal, show, askAboutMovedHead)
                return
            }
            return prepareLead(root: root, goal: goal, show: show, askAboutMovedHead: askAboutMovedHead)
        }
        // Whether it holds its role, the vault says (off the main thread: it's a call to the host); held, it's bound
        // to its session again, as at a relaunch.
        let vault = self.vault
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let holds: Bool?
            do { holds = try vault.rebindLead(root: root, session: running.id.uuidString) != nil } catch { holds = nil }
            DispatchQueue.main.async {
                guard let self else { return }
                switch Self.plan(hostState: self.host.state, running: running.id, holdsRole: holds, fromUser: askAboutMovedHead) {
                case .wait:
                    self.pendingStarts[root] = (goal, show, askAboutMovedHead)
                case .start:
                    self.prepareLead(root: root, goal: goal, show: show, askAboutMovedHead: askAboutMovedHead)
                case .show(let id):
                    if let goal { self.deliver("New goal: \(goal)", from: Self.commandLine, root: root) }
                    if show { self.select(id) }
                case .askToReplace(let id):
                    if self.askToReplace(root: root, running: running) {
                        self.prepareLead(root: root, goal: goal, show: show, askAboutMovedHead: askAboutMovedHead)
                    } else if show {
                        self.select(id)
                    }
                }
            }
        }
    }

    /// The starts that waited for the host's sessions, decided now that they're known.
    private func startPending() {
        guard host.state != .connecting, !pendingStarts.isEmpty else { return }
        let pending = pendingStarts
        pendingStarts = [:]
        for (root, start) in pending { startLead(root: root, goal: start.goal, show: start.show, askAboutMovedHead: start.askAboutMovedHead) }
    }

    /// The leads still running when the app starts again (a relaunch, an install handed their sessions over): each
    /// keeps its role, bound again to its session when the vault binds it there; none is replaced. One the vault
    /// gives no role stays as it is (its tools say so); Project Lead then asks before starting another.
    private func keepRunningLeads() {
        guard host.state != .connecting, !keepingRunning else { return }
        keepingRunning = true
        // Which lead holds each root's role, from its board read off the main thread (see `LeadFiles.names`).
        let sessions = host.sessions
        reads.async({ files in Self.leadSessions(sessions) { files.names.board($0).leadSession } }) { [weak self] running in
            guard let self else { return }
            self.keepingRunning = false
            guard self.host.state != .connecting else { return }
            self.keepRunning(running)
        }
    }

    private func keepRunning(_ running: [String: HostSession]) {
        for (root, session) in running where adopting.insert(session.id).inserted {
            let vault = self.vault
            let project = (root as NSString).lastPathComponent
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let kept: LeadVault.Member?
                do { kept = try vault.rebindLead(root: root, session: session.id.uuidString) } catch {
                    Breadcrumbs.shared.note("lead: couldn't bind the running lead of \(project) again: \(error)")
                    DispatchQueue.main.async { self?.adopting.remove(session.id) }  // Tried again on the next refresh.
                    return
                }
                Breadcrumbs.shared.note(kept != nil
                    ? "lead: kept the running lead of \(project) (session \(session.id.uuidString.prefix(8)))"
                    : "lead: the running lead of \(project) (session \(session.id.uuidString.prefix(8))) holds no role in the vault; left as it is")
                guard kept != nil else { return }
                DispatchQueue.main.async { self?.keptLeads[root] = session.id }
            }
        }
    }

    private func prepareLead(root: String, goal: String?, show: Bool, askAboutMovedHead: Bool) {
        // The lead's vault lives in the session host: an older one still serving its sessions can't hold it (and
        // one too old to hand over stays until restarted).
        if case .outdated = host.state, !host.hostCapabilities.contains(HostProtocol.Capability.leadVault) {
            return offerHostRestart()
        }
        // Preparing runs git (the board's folder, the base branch): off the main thread, one start per root at a time.
        guard startingLeads.insert(root).inserted else { return }
        let project = (root as NSString).lastPathComponent
        let base = claudeCommand(root)
        let boardStore = BoardStore(root: root)
        let vault = self.vault
        let (inbox, home) = (self.inbox, self.home)
        // The lead this start may replace, and where its conversation is: the new lead reads its last turns.
        let running = leadSessions[root]
        let transcripts = Dictionary(store.sessions.compactMap { session in
            session.hostID.flatMap { id in session.transcriptPath.map { (id.uuidString, $0) } }
        }, uniquingKeysWith: { $1 })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var issued: String?
            var replacedSession: UUID?
            var waiting: [SteerMessage] = []
            // In its prompt: it isn't told it again (see `LeadWitness.PolicyWatch`).
            let policy = WorkingPolicy.load()
            let prepared = Result<(grant: String, launch: LeadLaunch.Prepared), Error> {
                let workflowPath = try boardStore.prepare()
                var workflow = LeadWorkflow.load(from: workflowPath)
                workflow.baseBranch = workflow.baseBranch ?? boardStore.load().baseBranch
                // Only the app makes a lead (the session host tells the app from the team): its grant (the lead's
                // tools, once bound to its session). Merges check nothing else moved the branch since the lead last
                // left it; a start takes the branch as it is only when you say so here, shown the move (a start asked
                // for from outside the app never does: anything can ask).
                let branch = workflow.baseBranch ?? Worktrees.mainBranch(root: root)
                var takeHead = false
                if askAboutMovedHead, let moved = vault.headMoved(root: root, branch: branch) {
                    takeHead = DispatchQueue.main.sync { self?.askToTakeHead(branch: branch, moved) ?? false }
                }
                let grant = try vault.startLead(root: root, branch: branch, takeHead: takeHead)
                issued = grant
                // The role is the new session's from now on: the lead it replaces gets nothing more, and what waited
                // for it goes to the new one (see `LeadHandover`).
                let handover = try LeadHandover.begin(boardStore, inbox: inbox)
                waiting = handover.waiting
                if let replaced = handover.replaced {
                    Breadcrumbs.shared.note("lead: replacing the lead on \(replaced.tty); \(waiting.count) message(s) for it go to the new one")
                }
                let name = "lead-\(Slug.make(project, taken: []))"
                // The replaced lead (the one the board named, else the session running as the lead) is marked as such
                // in the window from now on, and what the user told it there goes to the new lead first.
                var handed: (tty: String, turnsFile: String)?
                let old = handover.replaced.flatMap { $0.session.flatMap(UUID.init(uuidString:)) } ?? running?.id
                if let old, let tty = handover.replaced?.tty ?? running?.tty {
                    replacedSession = old
                    let transcript = transcripts[old.uuidString]
                        ?? running.flatMap { TranscriptLocator.claude(cwd: root, name: name, startedAt: $0.startedAt, home: home) }
                    let turns = transcript.flatMap { LastTurns.read(transcript: $0, tty: tty, home: home) }
                    if let file = try LeadLaunch.writeTurns(turns, root: root) { handed = (tty, file) }
                    Breadcrumbs.shared.note("lead: the replaced lead on \(tty) " + (handed != nil ? "left its last turns for the new one"
                        : "left no turns (\(transcript == nil ? "no transcript" : "nothing the user said"))"))
                }
                DispatchQueue.main.sync {
                    guard let self, let old = replacedSession else { return }
                    // Replaced from now on: the start released the role, so no board read is waited for.
                    self.replacing[old] = root
                    self.replacements += 1
                    self.holders[root] = nil
                    self.markReplaced(holders: self.holders)
                }
                let launch = try LeadLaunch.prepare(
                    role: .lead, root: root, task: nil, base: base,
                    prompt: LeadPrompts.lead(project: project, root: root, workflow: workflow, policy: policy),
                    start: LeadPrompts.leadStart(root: root, goal: goal, note: Self.commandLineNote, replaced: handed),
                    server: Self.serverPath, name: name, folder: vault.runFolder(root: root, name: name), cwd: root)
                return (grant, launch)
            }
            if case .failure = prepared, let issued { try? vault.revoke(issued, root: root) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.startingLeads.remove(root)
                for message in waiting { self.hold(message.text, from: message.from, root: root) }
                switch prepared {
                case .failure(let error):
                    self.replacing = self.replacing.filter { $0.value != root }
                    self.alert("The lead didn't start.", "\(error)")
                case .success(let (grant, launch)):
                    self.spawnLead(root: root, project: project, grant: grant, launch: launch, policy: policy, show: show)
                }
            }
        }
    }

    private func spawnLead(root: String, project: String, grant: String, launch: LeadLaunch.Prepared, policy: String, show: Bool) {
        let boardStore = BoardStore(root: root)
        let vault = self.vault
        host.spawn(SpawnRequest(cwd: root, command: launch.command, env: launch.environment, cols: 120, rows: 40, keepShell: false,
                                label: "Lead · \(project)", agent: "claude")) { [weak self] result in
            switch result {
            case .success(let session):
                // The lead's tool server asks for its role as it starts (and waits a moment for this).
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try vault.bind(grant, root: root, session: session.id.uuidString) } catch {
                        Breadcrumbs.shared.note("lead: its role wasn't bound to its session: \(error)")
                    }
                }
                self?.reads.async { _ in try? boardStore.update { board in LeadHandover.started(session.id.uuidString, on: &board) } }
                self?.policyWatch?.started(session.id.uuidString, with: policy)
                // You chose to start the lead here: answer Claude's trust question for this folder.
                if self?.answersTrust == true { self?.answerTrust(session.id, folder: root) }
                if show { self?.select(session.id) }
                self?.refresh()
            case .failure(let error):
                DispatchQueue.global(qos: .userInitiated).async { try? vault.revoke(grant, root: root) }
                self?.replacing = self?.replacing.filter { $0.value != root } ?? [:]
                self?.alert("The lead didn't start.", error.message)
            }
        }
    }

    // MARK: Questions

    /// Your answer: recorded on the board and delivered to the lead (steered in while it works, typed while idle).
    /// `question` is the card as you saw it: the answer is tied to that version, so if the lead revised it meanwhile
    /// it's told which wording you answered; if the lead had withdrawn it, the card says so and the lead gets your
    /// answer as a note. An answer approving a held merge ("Approve <commit>") is recorded in the vault too, where
    /// merge looks for it (see `LeadVault.recordApproval`).
    /// The phone's answers come here too (`from: .phone`), tied to the version the phone showed (`saw`), and only to an
    /// open question; `done` hears what came of it (and what became of an approval), on the main thread.
    func answer(_ question: LeadQuestion, root: String, with text: String, saw: Int? = nil, from source: LeadQuestion.AnswerSource = .mac,
                done: ((LeadAnswerOutcome, String?) -> Void)? = nil) {
        let store = BoardStore(root: root)
        let vault = self.vault
        let seen = saw ?? question.version
        reads.async({ _ -> (LeadAnswerOutcome, String?) in
            let outcome = (try? store.update { board in
                board.answer(question.id, with: text, saw: seen, from: source, openOnly: source == .phone)
            }) ?? .missing
            guard case .answered(let answered, _) = outcome else { return (outcome, nil) }
            do {
                guard let tasks = try vault.recordApproval(text, of: answered, root: root) else { return (outcome, nil) }
                return (outcome, tasks.isEmpty ? "No task's branch is at that commit now, so the approval wasn't recorded: merge won't take it." : nil)
            } catch {
                return (outcome, "Your approval wasn't recorded, so merge won't take it: \(error)")
            }
        }) { [weak self] outcome, approval in
            guard let self else { return }
            switch outcome {
            case .answered: self.answerNotices[question.id] = approval
            case .withdrawn(let withdrawn):
                self.answerNotices[question.id] = "Withdrawn before your answer: \(withdrawn.withdrawReason ?? "no reason given"). The lead got your answer as a note."
            case .afterAutoDecision(let decided):
                self.answerNotices[question.id] = "The timer had run out: the lead went ahead with ‘\(decided.proposal ?? "")’. Your answer reached it as a note."
            case .alreadyAnswered(let answered):
                self.answerNotices[question.id] = "Already answered: \(answered.answer ?? answered.proposal ?? ""). Your new answer wasn't sent."
            case .missing:
                self.answerNotices[question.id] = "That question is no longer on the board. Your answer wasn't sent."
            case .notOpen:
                break   // the phone says so: nothing changed on the board, nor on the Mac's card
            }
            if let message = outcome.message(given: text) { self.deliver(message, from: .user, root: root) }
            self.refresh()
            done?(outcome, approval)
        }
    }

    /// You hold a question with a timer: the timer stops, it waits for your answer like any other, and the lead is
    /// told not to go ahead.
    func hold(_ question: LeadQuestion) {
        guard let root = boards.first(where: { $0.value.questions.contains { $0.id == question.id } })?.key else { return }
        let store = BoardStore(root: root)
        reads.async({ _ in Result { try store.update { board in try board.hold(question.id) } } }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let held):
                self.answerNotices[question.id] = nil
                self.deliver("The user is holding your question \(held.short) “\(held.text)”: its timer is off, so don't go ahead with ‘\(held.proposal ?? "")’; "
                             + "wait for their answer.", from: .user, root: root)
            case .failure(let error):
                self.answerNotices[question.id] = "\(error)"
            }
            self.refresh()
        }
    }

    /// Runs out the timers of the leads' questions (see `BoardStore.runTimers`; on the boards' queue, it reads the
    /// board): the lead is told to go ahead with each proposal no one answered, once. Asked of the board as last read
    /// first (`files`): decoding a day's board every 3 s to find no timer due was most of the app's CPU while its
    /// teams worked (2026-10-20: 0.9 % of a core of 8 %, with three leads).
    private static func runTimers(_ roots: Set<String>, files: inout LeadFiles,
                                  now: Double = Date().timeIntervalSince1970) -> [String: [(question: LeadQuestion, message: String)]] {
        var fired: [String: [(question: LeadQuestion, message: String)]] = [:]
        for root in roots where files.board(root).hasExpired(now: now) {
            if let expired = try? BoardStore(root: root).runTimers(now: now), !expired.isEmpty { fired[root] = expired }
        }
        return fired
    }

    private func tell(timers fired: [String: [(question: LeadQuestion, message: String)]]) {
        // No alert: the lead went ahead, so it no longer waits on you (the question's card says so).
        for (root, expired) in fired {
            for (_, message) in expired { deliver(message, from: .system("timer"), root: root) }
        }
    }

    /// Steered in while the lead works; while it's idle the message waits in its inbox and `flush` types it as soon
    /// as its input box is empty (never into your draft; a draft you send takes it along). The board is read, and the
    /// message posted, on the boards' queue (a stat of a board waited 3 s on a busy disk, hang-20261027-175604): one
    /// at a time, in the order delivered. `then` hears on the main thread whether it reached the lead's inbox (false:
    /// held until a lead runs).
    private func deliver(_ text: String, from sender: SteerMessage.Sender, root: String, order: Int? = nil,
                         then: @escaping (Bool) -> Void = { _ in }) {
        let (leadRuns, inbox) = (self.leadRuns, self.inbox)
        let order = order ?? next()
        // The board as it is now names the lead that holds the role (none while a new one starts, see
        // `LeadHandover`); if that one is gone (a restart under way), the message would be dropped by the next lead's
        // hook: keep it until a lead runs again. Only the lead's fields are read here (see `LeadNames`).
        reads.async({ files in
            guard let agent = LeadHandover.named(files.names.board(root)), leadRuns(agent) else { return false }
            return (try? LeadDelivery.deliver(text, from: sender, to: agent, state: HookState.load(from: VibePaths.stateFile(tty: agent.tty)),
                                              inputIsEmpty: nil, typeInto: nil, root: inbox)) != nil
        }) { [weak self] went in
            guard let self else { return }
            if went {
                self.wake(root: root)
            } else {
                self.hold(text, from: sender, root: root, order: order)
                Breadcrumbs.shared.note("lead: holding a message for \((root as NSString).lastPathComponent) (no lead running)")
            }
            then(went)
        }
    }

    private func next() -> Int {
        sent += 1
        return sent
    }

    /// Kept until a lead runs, among what's held in the order it was sent.
    private func hold(_ text: String, from sender: SteerMessage.Sender, root: String, order: Int? = nil) {
        let order = order ?? next()
        var waiting = held[root] ?? []
        waiting.insert((order, text, sender), at: waiting.firstIndex { $0.order > order } ?? waiting.endIndex)
        held[root] = waiting
    }

    // MARK: Replaced leads

    /// Input for a window session, before it's sent (`HostClient.inputGate`): a replaced lead's never reaches its
    /// program. What's typed there makes a line (see `HostInput.Line`), and Enter sends it to the live lead (see
    /// `route`). Returns whether it was taken.
    func takeInput(_ bytes: Data, for id: UUID) -> Bool {
        guard replacedLeads[id] != nil else { return false }
        var line = lines[id] ?? HostInput.Line()
        let submitted = line.feed(bytes)
        lines[id] = line
        if replacedLeads[id]?.draft != line.draft { replacedLeads[id]?.draft = line.draft }
        for text in submitted { route(text, typedInto: id) }
        return true
    }

    /// Text sent to a replaced lead's session (typed, pasted, from the composer or the phone) goes to the live lead
    /// instead, as the user's message (sealed on the way, as every message of theirs), saying where it was typed; the
    /// replaced session says where it went. Returns false when `id` isn't a replaced lead.
    @discardableResult
    func route(_ text: String, typedInto id: UUID) -> Bool {
        guard let replaced = replacedLeads[id] else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let at = Date().timeIntervalSince1970
        deliver(replaced.routed(trimmed), from: .user, root: replaced.root) { [weak self] went in
            self?.replacedLeads[id]?.notice = ReplacedLead.notice(trimmed, to: replaced.project, at: at, held: !went)
            Breadcrumbs.shared.note("lead: \(trimmed.count) chars typed into the replaced lead on \(replaced.tty) "
                                    + (went ? "went to" : "wait for") + " the lead of \(replaced.project)")
        }
        return true
    }

    /// Which lead sessions are replaced: another holds the role (`StatusRules.replacedLeads`), or a start replaced
    /// them and the new lead is still starting. What was said of each is kept. The boards are read off the main
    /// thread (a stat of one waited 3 s on a busy disk, hang-20261027-175604), the sessions marked on it.
    private func markReplaced() {
        guard !marking else { return }
        marking = true
        let roots = leadRoots
        let replacements = replacements
        reads.async({ files in
            files.names.keep(roots)
            var holders: [String: UUID] = [:]
            for root in roots {
                if let id = files.names.board(root).leadSession.flatMap(UUID.init(uuidString:)) { holders[root] = id }
            }
            return holders
        }) { [weak self] holders in
            guard let self else { return }
            self.marking = false
            guard self.replacements == replacements else { return }  // The next refresh looks again.
            self.holders = holders
            self.markReplaced(holders: holders)
        }
    }

    /// Marks the lead sessions live now, with `holders` the lead session each root's board names.
    private func markReplaced(holders: [String: UUID]) {
        let live = host.sessions.filter { $0.isLive && LeadTeams.role(label: $0.label) == .lead }
        let roots = Dictionary(uniqueKeysWithValues: live.map { ($0.id, ($0.cwd as NSString).standardizingPath) })
        replacing = replacing.filter { roots[$0.key] != nil }
        let replacedBy = StatusRules.replacedLeads(roots.map { (id: $0.key, root: $0.value) }, holders: holders)
        var marked: [UUID: ReplacedLead] = [:]
        for session in live {
            let root = roots[session.id]!
            guard replacedBy[session.id] != nil || (replacing[session.id] == root && holders[root] != session.id) else { continue }
            var lead = replacedLeads[session.id] ?? ReplacedLead(root: root, project: (root as NSString).lastPathComponent, tty: session.tty, live: nil)
            lead.live = replacedBy[session.id]
            lead.draft = lines[session.id]?.draft ?? ""
            marked[session.id] = lead
        }
        lines = lines.filter { marked[$0.key] != nil }
        if marked != replacedLeads { replacedLeads = marked }
    }

    /// Wakes an idle lead that reports wait for (see `LeadWake`): one short prompt for all of them, typed into its
    /// empty box between turns, and none again until it has taken a turn. Your own words waiting for it (an
    /// answer) are typed as they are instead, and the reports go along with them. Always the lead the board names
    /// at that moment, looked up again before anything is typed: a lead replaced meanwhile gets nothing.
    private func wake(root: String) {
        let (sessions, observer, inbox) = (host.sessions, observer, inbox)
        // The lead the board names, what waits for it, and what it's doing (its transcript), read off the main thread.
        reads.async({ files -> (lead: LeadAgent, pending: [SteerMessage], activity: LeadActivity?)? in
            guard let lead = LeadHandover.named(files.names.board(root)) else { return nil }
            let hosted = lead.session.flatMap(UUID.init(uuidString:)).flatMap { id in sessions.first { $0.id == id } }
            let pending = SteerInbox.pending(tty: lead.tty, root: inbox).filter { $0.agentPid == lead.pid }
            return (lead, pending, pending.first?.from == .user ? nil : hosted.map { observer.activity($0, agentPid: lead.pid) })
        }) { [weak self] read in
            guard let self, let read else { return }
            self.wake(root: root, lead: read.lead, pending: read.pending, activity: read.activity)
        }
    }

    private func wake(root: String, lead: LeadAgent, pending: [SteerMessage], activity: LeadActivity?) {
        let reports = LeadWake.reports(pending, agentPid: lead.pid)
        let now = Date().timeIntervalSince1970
        ReportsWaiting.shared.set(LeadWake.waiting(reports, now: now), tty: lead.tty)
        if pending.first?.from == .user { return flush(lead, lead: root) }
        let key = "\(lead.tty)#\(lead.pid)"
        guard let id = lead.session.flatMap(UUID.init(uuidString:)), let activity else { return }
        var state = wakes[key] ?? LeadWake()
        let step = state.step(reports: reports, activity: activity, now: now)
        wakes[key] = state
        switch step {
        case .none:
            return
        case .later(let due):
            guard wakeLater.insert(key).inserted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - now) + 0.2) { [weak self] in
                self?.wakeLater.remove(key)
                self?.wake(root: root)
            }
        case .ready:
            // A prompt typed a moment ago (its hooks haven't said it's working yet) is one in flight too.
            guard !flushing.contains(lead.tty), Date().timeIntervalSince(typedAt[lead.tty] ?? .distantPast) > 10 else { return }
            flushing.insert(lead.tty)
            host.styledScreen(id) { [weak self] screen in
                guard let self else { return }
                // Still the lead the board names, and what waits now (its hook may have taken some meanwhile), read off
                // the main thread.
                let inbox = self.inbox
                self.reads.async({ files in
                    LeadHandover.named(files.names.board(root)) == lead
                        ? LeadWake.reports(SteerInbox.pending(tty: lead.tty, root: inbox), agentPid: lead.pid) : nil
                }) { [weak self] reports in
                    guard let self else { return }
                    self.flushing.remove(lead.tty)
                    guard let reports else { return }
                    // Typed only into an empty box: Claude's dim suggestion counts as empty, a draft or a dialog waits
                    // for the next try.
                    var state = self.wakes[key] ?? LeadWake()
                    state.type(reports: reports, box: screen.map(LeadDelivery.box(in:))) { text in
                        self.typedAt[lead.tty] = Date()
                        self.type(text, into: id)
                        Breadcrumbs.shared.note("lead: woke the lead on \(lead.tty) for \(reports.count) report(s)")
                        return true
                    }
                    self.wakes[key] = state
                }
            }
        }
    }

    /// Types what waits for an idle agent in a window session, once its input box is empty. Only between turns: a
    /// missing or stale state file isn't an idle agent (its transcript says whether it's mid-turn). A lead's (`lead`:
    /// its root) only while the board still names it.
    private func flush(_ agent: LeadAgent, lead root: String? = nil) {
        guard let id = agent.session.flatMap(UUID.init(uuidString:)), let hosted = host.sessions.first(where: { $0.id == id }),
              !flushing.contains(agent.tty), Date().timeIntervalSince(typedAt[agent.tty] ?? .distantPast) > 10 else { return }
        let (observer, inbox) = (observer, inbox)
        // Whether something waits for it and it's between turns: its inbox and its transcript, read off the main thread.
        reads.async({ _ in
            SteerInbox.pending(tty: agent.tty, root: inbox).contains { $0.agentPid == agent.pid } && observer.activity(hosted, agentPid: agent.pid).betweenTurns
        }) { [weak self] ready in
            guard ready, let self else { return }
            self.type(waiting: agent, id: id, lead: root)
        }
    }

    /// What waits for an agent between turns, typed once its box is empty (see `flush`).
    private func type(waiting agent: LeadAgent, id: UUID, lead root: String?) {
        guard !flushing.contains(agent.tty), Date().timeIntervalSince(typedAt[agent.tty] ?? .distantPast) > 10 else { return }
        flushing.insert(agent.tty)
        host.styledScreen(id) { [weak self] screen in
            guard let self else { return }
            // Claude's dim suggested prompt isn't a draft: typing replaces it.
            let (empty, inbox) = (screen.map { LeadDelivery.box(in: $0) == .empty } ?? false, self.inbox)
            // A lead's only while its board still names it: the board and the inbox read off the main thread, what's
            // taken from the inbox typed on it.
            self.reads.async({ files -> String? in
                if let root, LeadHandover.named(files.names.board(root)) != agent { return nil }
                guard empty else { return nil }
                var typed: String?
                LeadDelivery.flush(agent, betweenTurns: true, inputIsEmpty: { true }, typeInto: { text in
                    typed = text
                    return true
                }, root: inbox)
                return typed
            }) { [weak self] text in
                guard let self else { return }
                self.flushing.remove(agent.tty)
                guard let text else { return }
                self.typedAt[agent.tty] = Date()
                self.type(text, into: id)
            }
        }
    }

    /// Answers Claude's trust question about `folder` in the new session, carefully (see `TrustPrompt.answer`).
    private func answerTrust(_ id: UUID, folder: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            TrustPrompt.answer(folder: folder, readScreen: {
                if case .screenText(_, let text)? = try? HostCall.request(.screen(id: id)) { return text }
                return nil
            }, send: { writes in
                for write in writes { try? HostCall.send(.input(id: id, bytes: Data(write.bytes), reply: false)) }
            })
        }
    }

    /// As one unit, in order with what else is typed into that session (the composer's messages, the phone's replies).
    private func type(_ text: String, into id: UUID) {
        host.send(id, writes: ComposerText.writes(text, bracketed: true))
    }

    // MARK: Refresh and witness

    /// Every 3 s (and after your answers): starts that waited and running leads go on, replaced leads are marked;
    /// then the boards and decisions are read off the main thread, shown, and the lead told what it needs to know, on
    /// the main thread.
    func refresh() {
        startPending()
        keepRunningLeads()
        markReplaced()
        sweepRoles()
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        let roots = leadRoots
        // The sessions as they are now, for the witness to read its teams' transcripts with (see `TeamReading`).
        let hosted = Dictionary(host.sessions.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        let sessions = Dictionary(store.sessions.compactMap { session in session.hostID.map { ($0.uuidString, session) } },
                                  uniquingKeysWith: { first, _ in first })
        let observer = observer
        reads.async({ files in
            let fired = Self.runTimers(roots, files: &files)
            var loaded: [String: LeadBoard] = [:]
            for root in roots { loaded[root] = files.board(root) }
            let decisions = Dictionary(uniqueKeysWithValues: roots.map { ($0, files.decisions($0)) })
            let records = Dictionary(uniqueKeysWithValues: roots.map { ($0, files.recordsDir($0)) })
            let refusals = Dictionary(uniqueKeysWithValues: roots.compactMap { root in LeadVault.BaseMoveRefusal.load(root: root).map { (root, $0) } })
            files.keep(roots)
            let teams = Dictionary(uniqueKeysWithValues: loaded.map { root, board in
                (root, TeamReading.read(root: root, board: board, hosted: hosted, sessions: sessions, observer: observer))
            })
            return (fired, loaded, decisions, teams, records, refusals)
        }) { [weak self] fired, loaded, decisions, teams, records, refusals in
            guard let self else { return }
            if records != self.recordsDirs { self.recordsDirs = records }
            self.refreshed(roots: roots, fired: fired, loaded: loaded, decisions: decisions, teams: teams, refusals: refusals)
            self.refreshing = false
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    /// What a refresh read, on the main thread.
    private func refreshed(roots: Set<String>, fired: [String: [(question: LeadQuestion, message: String)]], loaded: [String: LeadBoard],
                           decisions read: [String: [LeadDecision]], teams: [String: TeamReading],
                           refusals: [String: LeadVault.BaseMoveRefusal]) {
        dispatchPrecondition(condition: .onQueue(.main))
        tell(timers: fired)
        let previous = boards
        if loaded != boards { boards = loaded }
        // A lead with a question for you open needs you, its terminal idle or not.
        store.leadsAsking = LeadTeams.asking(loaded)
        teamRows.keep { key in roots.contains { key == $0 || key.hasSuffix("|" + $0) } }
        if read != decisions { decisions = read }
        baseMoves.look(roots)
        for (root, board) in loaded {
            for event in AlertRules.look(previous: previous[root], board: board, project: (root as NSString).lastPathComponent,
                                         seen: &seenQuestions, launchedAt: launchedAt) {
                alert(event)
            }
            // A base move that refused one of its merges waits on you (told once per move).
            if let event = AlertRules.baseMoved(baseMoves.asking[root], refused: refusals[root], root: root, leadTTY: board.leadTTY) {
                alert(event)
            }
            witness(root: root, board: board, team: teams[root] ?? TeamReading())
            allDone.look(root: root, previous: previous[root], board: board)
        }
        forgetFinished(loaded)
        keepAwake.update(working: KeepAwake.working(loaded, teams: teams))
        // A lead that ended, or another agent on its terminal now: its wake-ups and its waiting count go.
        let leads = Set(loaded.values.compactMap { board in board.leadTTY.flatMap { tty in board.leadPid.map { "\(tty)#\($0)" } } })
        wakes = wakes.filter { leads.contains($0.key) }
        ReportsWaiting.shared.keep(Set(loaded.values.compactMap(\.leadTTY)))
    }

    /// Every 6 s at most, off the main thread: the finished tasks' role sessions end, in every project (see `RoleSweep`).
    private func sweepRoles(now: Date = Date()) {
        guard let roleSweep, !sweeping, now.timeIntervalSince(sweptAt) >= 6 else { return }
        sweeping = true
        sweptAt = now
        let hosted = host.sessions
        let agents = Dictionary(store.sessions.compactMap { session in session.hostID.map { ($0, session) } }, uniquingKeysWith: { first, _ in first })
        roleSweep.queue.async { [weak self] in
            roleSweep.look(hosted: hosted, idleSince: { hosted in
                // Idle since its turn ended; with no agent known on it (its shell left), since it started.
                guard let agent = agents[hosted.id] else { return hosted.startedAt.timeIntervalSince1970 }
                return agent.status == .working ? nil : agent.statusSince.timeIntervalSince1970
            }, agent: { hosted in
                let pid = agents[hosted.id]?.pid ?? hosted.childPID
                return (pid, ProcessTable.residentBytes(pid: pid))
            })
            DispatchQueue.main.async { self?.sweeping = false }
        }
    }

    /// Reads the power source with `read` once a minute from now on (the first a minute in: the host has said which
    /// leads run by then), holding work below `limit` (the setting, read at each look).
    func watchPower(limit: @escaping () -> Int, _ read: @escaping () -> PowerState?) {
        power = LeadWitness.Power(read: read, limit: limit)
        powerTimer = Heartbeat.shared.every(60) { [weak self] in self?.lookAtPower() }
    }

    /// Looks at the Mac-wide test and build slots once a minute from now on: a slot held long is told to every
    /// running lead once (see `LeadWitness.HeavySlots`).
    func watchHeavySlots(_ watch: LeadWitness.HeavySlots = LeadWitness.HeavySlots()) {
        heavySlots = watch
        heavySlotsTimer = Heartbeat.shared.every(60) { [weak self] in self?.lookAtHeavySlots() }
    }

    /// A slot held long: to each running lead, as the witness.
    func lookAtHeavySlots() {
        guard let text = heavySlots?.look() else { return }
        for root in leadSessions.keys { deliver(text, from: .system("witness"), root: root) }
    }

    /// Looks once a minute from now on for leads refused for the Mac's room or load that have room now.
    func watchRoom(_ waits: LeadWitness.RoomWaits = LeadWitness.RoomWaits()) {
        roomWaits = waits
        roomTimer = Heartbeat.shared.every(60) { [weak self] in self?.lookAtRoom() }
    }

    /// The Mac has room again: one message to each lead that was refused for it, as the witness, against every
    /// project's team sessions the host lists and the Mac-wide limits in Settings.
    func lookAtRoom(limits: MacLimits = MacLimits.load()) {
        guard let roomWaits else { return }
        let mac = MacLoad.count(host.sessions.map { ($0.label, $0.cwd, $0.isLive) }, load: macLoad())
        for (root, text) in roomWaits.look(mac: mac, limits: limits) { deliver(text, from: .system("witness"), root: root) }
    }

    /// Tells each running lead the working policy once a minute from now on, when it isn't the one it has (the first a
    /// minute in: the host has said which leads run by then).
    func watchPolicy(_ watch: LeadWitness.PolicyWatch = LeadWitness.PolicyWatch()) {
        policyWatch = watch
        policyTimer = Heartbeat.shared.every(60) { [weak self] in self?.lookAtPolicy() }
    }

    /// The working policy, to each running lead that hasn't got it (changed since, started before this build, or
    /// compacted since it was told), as the witness; Settings looks at once after a save. The leads' transcripts are
    /// read off the main thread for their compactions.
    func lookAtPolicy() {
        guard let watch = policyWatch else { return }
        let running = leadSessions
        let ids = Set(running.values.map(\.id))
        let transcripts = Dictionary(store.sessions.compactMap { session in
            session.hostID.flatMap { id in ids.contains(id) ? session.transcriptPath.map { (id.uuidString, $0) } : nil }
        }, uniquingKeysWith: { $1 })
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let compactions = transcripts.compactMapValues { TranscriptTail.lastCompaction(url: URL(fileURLWithPath: $0)) }
            DispatchQueue.main.async {
                guard let self, let news = watch.look(running: running.values.map(\.id.uuidString), compactions: compactions) else { return }
                for (root, session) in running where news.leads.contains(session.id.uuidString) {
                    self.deliver(news.text, from: .system("witness"), root: root)
                }
            }
        }
    }

    /// A hold on battery, or the resume after one: to each running lead, as the witness.
    func lookAtPower() {
        guard let text = power?.look() else { return }
        for root in leadSessions.keys {
            deliver(text, from: .system("witness"), root: root)
            // The lead's tool server looks again at what it held (see `LeadAdvance`).
            LeadAdvance.nudge(root: root)
        }
    }

    /// VibeSwitcher's own health (see `AppHealthWatcher`): to the leads of the projects whose workflow.md has
    /// watch_app_logs: true, as VibeSwitcher's report ("app health"); no other lead gets it. False when no running
    /// lead's project has it on (the watcher tries again later).
    func tellAppHealth(_ text: String) -> Bool {
        let roots = Self.appHealthRoots(Set(leadSessions.keys).union(boards.keys))
        for root in roots { deliver(text, from: .system(AppHealth.sender), root: root) }
        return !roots.isEmpty
    }

    /// The projects among `roots` whose workflow.md (the main checkout's, not a worktree's) has watch_app_logs on.
    static func appHealthRoots(_ roots: Set<String>) -> [String] {
        roots.sorted().filter { root in
            LeadWorkflow.load(from: (BoardStore(root: root).folder as NSString).appendingPathComponent("workflow.md")).watchAppLogs
        }
    }

    /// The stranded role sessions, in every project: to each running lead, as the witness (its team's, so no alert).
    private func tellStranded(_ text: String) {
        for root in leadSessions.keys { deliver(text, from: .system("witness"), root: root) }
    }

    /// A task merged or abandoned: its ended workers and verifiers leave the session list (everywhere it's shown:
    /// the host drops them). The lead's cleanup does this too; this catches tasks finished some other way.
    private func forgetFinished(_ boards: [String: LeadBoard]) {
        forgetting.formIntersection(host.sessions.map(\.id))
        for (root, board) in boards {
            for id in LeadTeams.finished(host.sessions, root: root, board: board) where forgetting.insert(id).inserted {
                host.remove(id)
            }
        }
    }

    /// Tells the lead what its team can't (see `LeadWitness`), and types waiting messages into idle team members. What
    /// the team's transcripts and inboxes say was read off the main thread, with the sessions as they were then (`team`).
    private func witness(root: String, board: LeadBoard, team: TeamReading) {
        let hosted = team.hosted
        var seen: [String: LeadWitness.Seen] = [:]
        let now = Date()
        let workers = Set(board.tasks.compactMap(\.worker))
        for id in board.tasks.flatMap({ [$0.worker, $0.verifier] }).compactMap({ $0 }) {
            guard let info = hosted[id] else { continue }
            let session = team.sessions[id]
            // A turn that ended on an API error reads as finished or waiting; its transcript says which it was. A
            // worker's transcript is read whatever it shows: a stall is one that reads as working too (see `LeadStall`).
            var apiError: (text: String, at: Double?)?
            var watched: (activity: LeadActivity, tail: TranscriptTail?, progress: TranscriptProgress?)?
            var shells: [BackgroundJob] = []
            var held: SteerMessage?
            if let session, let reading = team.watched[id] {
                watched = reading
                if session.status != .working, case .apiError(let error) = reading.activity { apiError = (error, reading.tail?.at) }
                if workers.contains(id) {
                    // Its shells: mid-turn the command its turn runs, between turns what it waits on (status names them
                    // too); see `LeadWitness.Seen`. From the store's last scan, which reads the process table off the main
                    // thread. Reading it here froze the window for minutes at a time on a loaded Mac (sysctl walks every process).
                    shells = session.backgroundJobs
                    held = team.held[id]
                }
            }
            // No agent in the scan a minute on: "agent ended · shell", as good as ended. A minute on as of when the scan's
            // process table was read, and from a table that could tell what runs on its terminal: while it can't be read
            // (a loaded Mac), or its process there couldn't be told (mid-exec), it's unknown, not ended.
            // And its agent's own process has exited (`TeamReading.agentGone`): one waiting on a background command runs on.
            let quit = team.agentQuit(id, session: session, scanSaysQuit: store.agentQuit(info))
            seen[id] = LeadWitness.Seen(live: info.isLive, exit: info.exit?.status, cause: info.exit?.cause, status: session?.status,
                                        since: session?.statusSince, detail: session?.detail, pending: watched?.tail?.pending,
                                        agentQuit: quit, apiError: apiError?.text,
                                        apiErrorAt: apiError?.at, activity: watched?.activity,
                                        lastActivity: watched?.progress?.lastWritten, compactedAt: watched?.progress?.compactedAt,
                                        shells: shells, heldSince: held?.at, heldFrom: held.map { Self.sender($0.from) },
                                        started: info.startedAt.timeIntervalSince1970, submittedAt: submitted[id],
                                        boundAt: toolTimes[id]?.bound, toolsAt: toolTimes[id]?.tools, lockWait: team.lockWaits[id])
            if info.isLive, let session { flush(LeadAgent(pid: session.pid, tty: session.tty, session: id)) }
        }
        // A worker or verifier whose tools never connected only holds a Mac slot: it ends (`events` tells the lead).
        for id in LeadWitness.withoutTools(board: board, seen: seen, now: now) {
            guard let uuid = UUID(uuidString: id), endingNoTools[id].map({ now.timeIntervalSince($0) >= 60 }) ?? true else { continue }
            endingNoTools[id] = now
            Breadcrumbs.shared.note("witness: ending session \(id.prefix(8)) in \((root as NSString).lastPathComponent): its tools never connected")
            host.kill(uuid)
        }
        // Sessions that ended together (a stray kill, the app relaunched over them) are told in one message.
        // A verifier that ended without a verdict, which auto_advance audits again: its loop looks now (an agent that
        // quit leaving its shell open writes nothing in the project's folder), and the lead hears of it in its report;
        // past `LeadWitness.advanceGrace` with no retry, from here as ever.
        var advanced: Set<String> = []
        if team.advancing {
            var firstSeen: [String: Date] = [:]
            for verifier in LeadWitness.endedForAdvance(board: board, seen: seen, now: now) {
                let key = "\(root)|\(verifier)"
                if advanceSeen[key] == nil {
                    advanceSeen[key] = now
                    LeadAdvance.nudge(root: root)
                }
                firstSeen[verifier] = advanceSeen[key]
            }
            advanced = LeadWitness.leftToAdvance(board: board, seen: seen, now: now, firstSeen: firstSeen)
        }
        for message in LeadWitness.messages(board: board, seen: seen, now: now, advanced: advanced, told: { told.contains("\(root)|\($0)") }) {
            message.keys.forEach { told.insert("\(root)|\($0)") }
            deliver(message.text, from: .system("witness"), root: root)
        }
        // Low disk space, once per episode; what takes it is sized off the main thread.
        var disk = disks[root] ?? LeadWitness.Disk(free: freeSpace, file: DiskWatch.file)
        let workflow = team.workflow
        if let free = disk.check(root: root, workflow: workflow) {
            let sizing = disk
            let cwds = host.sessions.map(\.cwd)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let text = sizing.text(free: free, root: root, board: board, workflow: workflow, cwds: cwds)
                DispatchQueue.main.async { self?.deliver(text, from: .system("witness"), root: root) }
            }
        }
        disks[root] = disk
        // Working time, and the stop at a task's time budget (see `LeadBudget`): counted on the board as it is when
        // written, so each budget is told once, to its worker and to the lead. Here only its running tasks are looked
        // at, and nothing is copied or written: the count is written off the main thread, under the board's lock.
        let working = LeadBudget.working(board: board, seen: seen)
        let budget = workflow.taskBudgetMinutes, at = now.timeIntervalSince1970
        if board.notesWork(working, defaultMinutes: budget, now: at) {
            let sessions = team.sessions
            reads.async({ _ in
                (try? BoardStore(root: root).update { $0.noteWork(working, defaultMinutes: budget, now: at).reached }) ?? []
            }) { [weak self] reached in
                for task in reached {
                    let agent = task.worker.flatMap { worker in sessions[worker].map { LeadAgent(pid: $0.pid, tty: $0.tty, session: worker) } }
                    self?.stopForBudget(task, root: root, worker: agent, defaultMinutes: budget)
                }
            }
        }
        // On the board too, for status and the Team view, until the worker moves again.
        let stalls = LeadWitness.stalls(board: board, seen: seen, now: now)
        var noted = board
        if noted.noteStalls(stalls) { reads.async { _ in try? BoardStore(root: root).update { $0.noteStalls(stalls) } } }
        // A lead runs again: what was held for it goes now.
        if let waiting = held.removeValue(forKey: root) {
            for message in waiting { deliver(message.text, from: message.sender, root: root, order: message.order) }
        }
        wake(root: root)
    }

    /// A task's worker reached its time budget: it's told to stop and report over_budget (in its inbox, typed in if
    /// it's between turns), and the lead is told. Nothing is ended.
    private func stopForBudget(_ task: LeadTask, root: String, worker: LeadAgent?, defaultMinutes: Int) {
        let minutes = task.overBudget?.minutes ?? LeadBudget.minutes(task, default: defaultMinutes) ?? 0
        Breadcrumbs.shared.note("witness: \(task.slug) in \((root as NSString).lastPathComponent) reached its \(minutes) min budget")
        if let worker {
            let state = HookState.load(from: VibePaths.stateFile(tty: worker.tty))
            _ = try? LeadDelivery.deliver(LeadBudget.stopText(task, minutes: minutes), from: .system("time budget"), to: worker,
                                          state: state, inputIsEmpty: nil, typeInto: nil, root: inbox)
            flush(worker)
        }
        deliver(LeadBudget.leadText(task, minutes: minutes), from: .system("witness"), root: root)
    }

    /// Who a waiting message is from, in words.
    private static func sender(_ sender: SteerMessage.Sender) -> String {
        switch sender {
        case .user: return "the user"
        case .lead(let name): return name
        case .system(let about): return "VibeSwitcher (\(about))"
        }
    }

    private func offerHostRestart() {
        let live = host.sessions.filter(\.isLive).count
        let alert = NSAlert()
        alert.messageText = "The session host is older than the lead."
        alert.informativeText = host.canHandOver
            ? "The lead's vault lives in the session host. Restart it to this app's version; its sessions keep running."
            : "The lead's vault lives in the session host, and the one running predates it (and can't update in place). "
                + "Restarting it ends its \(live == 1 ? "live session" : "\(live) live sessions"); hosts from now on update without ending any."
        alert.addButton(withTitle: host.canHandOver ? "Restart Session Host" : "Restart Session Host (ends \(live))")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { host.restartHost() }
    }

    /// The lead's branch moved since the lead last left it, not through its merges: whether to take it as it is now.
    private func askToTakeHead(branch: String, _ moved: (recorded: String, now: String)) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(branch) moved since the lead last left it, and not through its merges."
        alert.informativeText = "It was at \(moved.recorded.prefix(8)) and is at \(moved.now.prefix(8)) (`git log \(moved.recorded.prefix(8))..\(branch)` "
            + "shows what came in). If you moved it, take it as it is: merges start from there. Otherwise keep it checked, and the lead's merges "
            + "stay refused until it's back where the lead left it."
        alert.addButton(withTitle: "Keep Checking")
        alert.addButton(withTitle: "I Moved It: Take \(branch) As It Is")
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The project's lead runs without its role: whether to start a new one (the running one is told where to go on
    /// when it next uses its tools; its conversation stays where it is).
    private func askToReplace(root: String, running: HostSession) -> Bool {
        let project = (root as NSString).lastPathComponent
        let chosen = confirm("The lead of \(project) is running, but without its role.",
                             "Its session (‘\(running.label)’, \(running.id.uuidString.prefix(8))) still runs, with its conversation, but the "
                                + "session host no longer gives it the lead's role, so its tools are off. A new lead takes the role: the "
                                + "running one is then told, when it next uses its tools, to send you to the new one. The new lead reads its "
                                + "last turns with you first, and what you type into it from then on goes to the new lead.",
                             ["Show the Running Lead", "Start a New Lead"])
        return chosen == 1
    }

    private func alert(_ title: String, _ text: String) {
        _ = confirm(title, text, ["OK"])
    }

    static func runAlert(_ title: String, _ text: String, _ buttons: [String]) -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate()
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
