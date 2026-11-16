import Foundation
import VibeCore

/// The node's lead engine (the engine plan's E4 on; rebuilt from the non-UI duties of the app's `LeadController`): its
/// queues, its stores and their wiring. It runs on one serial queue (`queue`, the link's: EN-D1) and does its blocking
/// reads (boards, git, the vault) elsewhere: the boards on `reads` (`BoardReads`, in the order asked, as the app's
/// `LeadReads`), git and the vault's calls on a utility queue. Every root it takes is a parameter, never this process's
/// `VibePaths.root` (one root per test).
///
/// E4 gives it starting a lead (`startLead`, in `LeadStart.swift`) and the lead store; E5 delivery to the lead the vault
/// binds, held messages at rest (`engine.json`) and waking the lead (`Delivery.swift`, `Wake.swift`, `EngineState.swift`);
/// E6 cards and answers; E7 the refresh every 3 s on its clock, the witness and the room watch (`Refresh.swift`,
/// `Witness.swift`, `RoomWatch.swift`); E8 restarts (`Restarts.swift`: the server's start binds the running leads again
/// and tells them which questions the user no longer sees; a host restart says the team is gone).
public final class LeadEngine: @unchecked Sendable {
    /// What a start did: started a lead (its session and the program it runs), showed the one running (its session),
    /// waits for the host's welcome (and goes on then), or refused, saying why.
    public enum StartOutcome: Equatable, Sendable {
        case started(session: UUID, program: String, notes: [String])
        case shown(session: UUID, notes: [String])
        case waiting
        case refused(String)
    }

    /// How the engine is set up beyond its roots: each has the node's value by default, a test's instead.
    public struct Options {
        /// The link `claude` is found by (EN-D13; `NodePreflight.claudeLink(root:)` by default).
        public var claudeLink: String?
        /// The git it runs.
        public var git = Platform.Tools.git
        /// Whether its host's vault holds its first look (stage 2's Task 10e, S7): the user's node's host always does
        /// while fresh, a scratch host only when its test says (`--hold-first-look`). Then `lead` is refused until
        /// `config accept` and `base accept` are done for the project.
        public var firstLook = false
        /// Answers Claude's trust question in a lead it started (the user asked for the lead there).
        public var answersTrust = true
        /// The node's home: the agents' transcripts (the replaced lead's last turns, what a lead is doing). `VibePaths.home`
        /// by default.
        public var home: String?
        /// The vault's record of the user's actions, which a held `.user` message passes after a restart (EN-D9): the
        /// server gives the vault's (`VaultUserActions`); none by default, so none passes.
        public var userActions: UserActions = NoUserActions()
        /// The vault the cards are built from and the answers recorded in (E6): the link's (`HostLink.vault`) by default.
        public var vault: LeadVault?
        /// Ends the role sessions of finished tasks from the vault's roster, in every project (`RoleSweep`, E7): the
        /// server's engine does; off by default, so a test's engine ends nothing it didn't ask for.
        public var sweepsRoles = false
        /// The Mac-wide test and build lock the witness reads its workers' waits from (`TestLock.standard()` for the
        /// user's node, which the server gives); none by default, so a test's engine reads no lock outside its root.
        public var lock: TestLock?

        public init() {}
    }

    public let root: URL
    /// The build's folder: the lead's tool server is `<nodeRoot>/bin/vibeswitcher-mcp` (S9), never derived from this
    /// process's own image. Nil: no lead can start.
    public let nodeRoot: URL?
    public let link: HostLink
    public let clock: NodeClock?
    public let sessions: NodeSessions?
    /// The engine's queue: the link's.
    public let queue: DispatchQueue
    /// Where the boards are read and written, in order.
    public let reads: BoardReads
    /// Where git and the vault are asked: never `queue`.
    let work = DispatchQueue(label: "vibenode.lead-engine.work", qos: .userInitiated, attributes: .concurrent)
    public let leads = LeadStore()
    let options: Options
    let preflight: NodePreflight
    let note: (String) -> Void
    /// Each board looked at for the lead it names, on the thread that looks (for tests): every look is on `reads`.
    public var boardLooked: (String) -> Void = { _ in } {
        didSet {
            let looked = boardLooked
            reads.async { files in files.names.looked = looked }
        }
    }
    /// Each spawn request the engine makes, before it goes (for tests). On `queue`.
    public var spawning: (SpawnRequest) -> Void = { _ in }
    /// Each look at what a start needs (`NodePreflight.check`), on the thread that looks (for tests). Set on `queue`
    /// before the start is asked.
    public var preflightLooked: () -> Void = {}

    // On `queue`.
    /// Starts asked for before the host said which sessions run, by root, each as asked: decided once it has (the
    /// app's `pendingStarts`; `startPending`).
    var pendingStarts: [String: (program: String, starts: [PendingStart])] = [:]
    /// Roots whose start is under way: the first request, then each that joined it (with what it asked, which
    /// `finish` takes up once the first is over).
    var starting: [String: [JoinedStart]] = [:]
    /// `stop` is under way: no start goes on.
    public private(set) var stopping = false
    /// The session each root's board named at the last look.
    var holders: [String: UUID] = [:]
    private var watch: Subscription?

    // Delivery and wake (E5), on `queue`.
    /// Whether an agent runs on its terminal (`ProcessTable.info`): the lead the board names gets nothing otherwise, and
    /// nothing is typed into a terminal its agent left (a shell). For tests.
    public var leadRuns: (LeadAgent) -> Bool = { agent in
        ProcessTable.info(pid: agent.pid).map { $0.tty == agent.tty && $0.agent != nil } == true
    }
    /// What an agent is doing, from its hooks' state under `root` and its transcript under the node's home.
    let observer: LeadObserver
    /// Roots whose held messages are being sent, one after another, and roots with a message's post under way.
    var sendingHeld: Set<String> = []
    var posting: Set<String> = []
    /// Each lead's wake-ups (`LeadWake`), by terminal and agent, with the one each root's lead has now, and the ones with
    /// a look again scheduled.
    var wakes: [String: LeadWake] = [:]
    var wakeKeys: [String: String] = [:]
    var wakeLater: Set<String> = []
    /// Terminals being typed into, and when something was last typed into each (its hooks need a moment to say it's
    /// working again; until then another would type a second prompt).
    var flushing: Set<String> = []
    var typedAt: [String: Date] = [:]
    /// Each steer inbox read (its terminal), on the thread that reads (for tests): every one is on `reads`.
    public var inboxRead: (String) -> Void = { _ in }
    /// Each step of typing into a session (for tests). On `queue`.
    public var wakeStep: (WakeStep) -> Void = { _ in }
    /// What's typed into each session, as the writes sent (for tests). On `queue`.
    public var typing: (UUID, [HostInput.Write]) -> Void = { _, _ in }
    /// Sends what's typed as one unit and tells whether the host took all of it, on `queue` (for tests: nil, the link's
    /// `type`).
    var typeUnit: ((_ writes: [HostInput.Write], _ id: UUID, _ confirmed: @escaping (Bool) -> Void) -> Void)?
    /// The engine's refresh every 3 s on its clock (`refresh`, E7).
    private var refreshTimer: Subscription?

    // Cards, answers and holds (E6), on `queue`.
    /// Every card the user answers: the lead's questions and approvals, held config, base moves.
    public let cards = CardStore()
    /// Each lead's base, watched (`BaseMoveStore`): a move nobody accounts for becomes a card.
    public private(set) lazy var baseMoves: BaseMoveStore = makeBaseMoves()
    /// The `.user` messages posted to a lead's inbox, by id, with the terminal: retired in the vault (`retireUserSeals`)
    /// once its delivered record shows them.
    var postedUser: [String: String] = [:]
    var retiring = false
    /// The user's messages being recorded in the vault before they're delivered (`tellAsUser`), by root: what's sent to
    /// that lead meanwhile waits behind them.
    var recordingUser: [String: Int] = [:]
    /// A look at what the vault holds (`lookAtConfig`) is under way.
    var lookingAtConfig = false

    // The refresh, the witness and the room watch (E7), on `queue`.
    /// The time the refresh runs the questions' timers at (now; a test's later).
    var timersNow: () -> Double = { Date().timeIntervalSince1970 }
    /// Each lead's board as the last refresh read it, by root.
    public internal(set) var boards: [String: LeadBoard] = [:]
    /// A refresh's reads are under way, and another was asked meanwhile (it runs once they're in).
    var refreshing = false
    var refreshAgain = false
    /// What the last refresh's notices say for `status`, by root, while they stand: a base move that refused a merge of
    /// the running lead's waits on the user (`AlertRules.baseMoved`).
    public internal(set) var notices: [String: [String]] = [:]
    /// The standing notices' keys, so each is logged once while it stands.
    var noticed: Set<String> = []
    /// How long the machine has slept since this engine started, noted at each witness look (`MacSleepLog`).
    var macSleep = MacSleepLog()
    var missingJobs = LeadWitness.MissingJobs()
    /// Witness events already told, by root and key, so each is told once.
    var told: Set<String> = []
    /// When the witness first saw each verifier that auto_advance audits again end without a verdict (by root and
    /// session; see `LeadWitness.leftToAdvance`), and each worker it released.
    var advanceSeen: [String: Date] = [:]
    /// Names each computation of the witness's as it starts, on the thread that runs it (`WitnessWork`), and "applied"
    /// on the engine's queue once a look is applied (`witnessed`); tests watch or slow them. Set on `queue`.
    var witnessStep: ((String) -> Void)?
    /// How many of the witness's looks were applied for each root since this engine started (`status` gives each lead's
    /// as `looks`: what a test waits on to know looks went by). On `queue`.
    public internal(set) var witnessLooks: [String: Int] = [:]
    /// Each project's free disk space, watched (`LeadWitness.Disk`), by root: on `reads` only.
    let disks = DiskWatches()
    /// The bytes free on the volume holding a path, as the disk watch reads them (`DiskSpace.free`). Faked in tests.
    var freeSpace: (String) -> Int64? = DiskSpace.free(at:)
    /// Makes a project's lead tool server look again (`LeadAdvance.nudge`): an ended verifier auto_advance audits
    /// again, a worker it releases. Faked in tests.
    var nudgeAdvance: (String) -> Void = { LeadAdvance.nudge(root: $0) }
    /// Ended team sessions of finished tasks the host has been asked to drop.
    var forgetting: Set<UUID> = []
    /// Ends the sessions of finished tasks (`RoleSweep`), when `Options.sweepsRoles`.
    var roleSweep: RoleSweep?
    /// A look of `roleSweep` under way, and when the last began.
    var sweeping = false
    var sweptAt = Date.distantPast
    /// What the roster said each verifier submitted, by session: its end is expected (see `LeadWitness.Seen`).
    var submitted: [String: Double] = [:]
    /// What the roster said of each worker's and verifier's tools: when it was bound, and when they connected (see
    /// `LeadWitness.Seen.boundAt`).
    var toolTimes: [String: (bound: Double, tools: Double?)] = [:]
    /// Sessions that never got their tools, asked to end, and when last (asked again a minute on while they run).
    var endingNoTools: [String: Date] = [:]
    /// The leads refused for the machine's room or load (`LeadWitness.RoomWaits`): each told once there's room, on the
    /// room watch's 60 s client (`watchRoom`); none until it's started.
    var roomWaits: LeadWitness.RoomWaits?
    var roomTimer: Subscription?
    /// The machine's load as the room watch reads it, as the leads' tools judge it (`MacLoad.steady`); faked in tests.
    var macLoad: () -> Double? = MacLoad.steady
    /// Each room look's read of the machine's memory (`MacMemory.read`), on the reads queue; faked in tests.
    var memory: () -> MacMemory? = { MacMemory.read() }

    // Restarts (E8), on `queue`.
    /// The start time of the last host that welcomed the engine, as `engine.json` keeps it (seconds since 1970).
    var lastHostStart: Double?
    /// The roots with a lead that ran under that host (a host restart ended them).
    var knownLeads: Set<String> = []
    /// The last host restart the engine saw (its roots whose team it ended, each until a lead starts there again).
    public internal(set) var hostRestart: EngineState.Restart?
    /// Whether this engine took a welcome yet: its first is the server's start, where the running leads are bound again
    /// and told which questions the user no longer sees.
    var welcomedOnce = false
    /// Lead sessions whose role was asked to be bound again (`keepRunningLeads`), once each; and a binding that failed
    /// (tried again at the next refresh).
    var adopting: Set<UUID> = []
    var keepingRunning = false
    var rebindAgain = false
    /// The running leads the vault gives no role, by root, while each runs: `status` says so.
    public internal(set) var roleless: [String: Roleless] = [:]

    /// `root`: the node's root (its policy, limits, sessions' temporary folders; a scratch node's lead gets it as
    /// `VIBESWITCHER_HOME`). `nodeRoot`: the build's folder. `link`: the host. `clock`: the engine's clock.
    /// `sessions`: the node's session list (the replaced lead's transcript), when there is one.
    public init(root: URL, nodeRoot: URL?, link: HostLink, clock: NodeClock?, sessions: NodeSessions? = nil, options: Options = Options(),
                note: @escaping (String) -> Void = { _ in }) {
        self.root = root
        self.nodeRoot = nodeRoot
        self.link = link
        self.clock = clock
        self.sessions = sessions
        self.options = options
        self.note = note
        queue = link.queue
        reads = BoardReads(handTo: link.queue)
        preflight = NodePreflight(claudeLink: options.claudeLink ?? NodePreflight.claudeLink(root: root), git: options.git)
        let states = root.appendingPathComponent("state", isDirectory: true)
        observer = LeadObserver(home: options.home ?? VibePaths.home, stateFile: { states.appendingPathComponent("\($0).json") })
        restoreState()
        leads.heldChanged = { [weak self] in self?.saveState() }
        watch = link.changes.subscribe(on: link.queue) { [weak self] _ in self?.sessionsChanged() }
        if options.sweepsRoles { roleSweep = makeRoleSweep() }
        refreshTimer = clock?.every(3) { [weak self] in self?.refresh() }
    }

    /// The vault the cards are built from and the user's answers recorded in: the link's, or a test's.
    var cardVault: LeadVault { options.vault ?? link.vault }

    /// The hooks' state file of `tty` under this root.
    func stateFile(_ tty: String) -> URL { observer.stateFile(tty) }

    /// The lead's tool server (S9: from the node's build folder).
    var toolServer: String? { nodeRoot.map { $0.appendingPathComponent("bin/vibeswitcher-mcp").path } }

    /// Whether `root` is a scratch node's (not the account's own `~/.vibeswitcher`): its lead gets `VIBESWITCHER_HOME`.
    var isScratch: Bool { !VibePaths.isAccountRoot(root, accountHome: VibePaths.accountHome) }

    /// The node's home: its agents' transcripts.
    var home: String { options.home ?? VibePaths.home }

    /// Where the lead's session gets its TMPDIR (`SessionTemp.root` for this root): the shared temporary folder's
    /// `vibeswitcher-<uid>` for the user's own root, `<root>/tmp` for a scratch one (as `HostLink`'s sweep reads them).
    var temporaryRoot: URL {
        isScratch ? root.appendingPathComponent("tmp", isDirectory: true)
            : URL(fileURLWithPath: "\(Platform.Files.sharedTemporaryRoot)/vibeswitcher-\(getuid())", isDirectory: true)
    }

    /// The host welcomed the link (each welcome, `HostLink.onWelcome`): what waited for its sessions goes on. On `queue`.
    public func welcomed() {
        startPending()
        sessionsChanged()
        restartLook()
    }

    /// `stop` is under way: no start goes on from now, and what waits for one is refused. On `queue`.
    public func stopStarting() {
        stopping = true
        if !pendingStarts.isEmpty {
            note("lead: \(pendingStarts.values.map(\.starts.count).reduce(0, +)) starts that waited for the host's welcome dropped: the node is stopping")
        }
        pendingStarts = [:]
    }

    /// `stop` was refused: starts are taken again. On `queue`.
    public func startAgain() { stopping = false }

    static let stoppingRefusal = "the node is stopping: no lead starts"

    /// The host's list changed: each project's lead sessions again.
    private func sessionsChanged() {
        leads.update(sessions: link.sessions, holders: holders)
        noteKnownLeads()
    }
}
