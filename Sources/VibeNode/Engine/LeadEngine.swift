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
        /// Writes an AI summary's line for a prompt, blocking (`TeamSummaryWatch`): the user's node's server gives
        /// headless Claude on Haiku (`NodeSummaries.headless`); none by default, so a test's engine asks no model but the
        /// fake it gives.
        public var summarize: Summarizer.Generate?
        /// Writes an all-done batch's summary (headline and bullets) for its prompt, blocking (`AllDoneLook`): the user's
        /// node's server gives headless Claude with `BatchSummaryPrompts.system`; none by default (the written fallback).
        public var summarizeBatch: Summarizer.Generate?
        /// Writes a briefing for its prompt, blocking (`Requests.brief`): the user's node's server gives headless Claude
        /// with `BriefingPrompts.system`; none by default (the written template).
        public var summarizeBrief: Summarizer.Generate?

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
    /// Whether an agent runs on its terminal: the lead the board names gets nothing otherwise, and nothing is typed into
    /// a terminal its agent left (a shell). On a terminal the host runs (`hosted`, the link's list), by the host's record
    /// of what it started (`HostedAgents.runs`: the session's program, started as an agent), never a process's name;
    /// elsewhere (the Mac) by the process table (`ProcessTable.info`). For tests.
    public var leadRuns: (LeadAgent, [HostSession]) -> Bool = { agent, hosted in
        HostedAgents.runs(agent, hosted: hosted) ?? (ProcessTable.info(pid: agent.pid).map { $0.tty == agent.tty && $0.agent != nil } == true)
    }
    /// What an agent is doing, from its hooks' state under `root` and its transcript under the node's home.
    let observer: LeadObserver
    /// Roots whose held messages are being sent, one after another, and roots with a message's post under way.
    var sendingHeld: Set<String> = []
    var posting: Set<String> = []
    /// The ids of the held messages taken back from `engine.json` at the start and not posted yet: only those may have
    /// gone already (posted before the server stopped), found in the lead's inbox records (`post`).
    var restoredHeld: Set<String> = []
    /// Each lead's wake-ups (`LeadWake`), by terminal and agent, with the one each root's lead has now, and the ones with
    /// a look again scheduled.
    var wakes: [String: LeadWake] = [:]
    var wakeKeys: [String: String] = [:]
    var wakeLater: Set<String> = []
    /// Terminals being typed into, and when something was last typed into each (its hooks need a moment to say it's
    /// working again; until then another would type a second prompt).
    var flushing: Set<String> = []
    var typedAt: [String: Date] = [:]
    /// The user's steered messages this node posted, by id, watched until taken (`watchSteered`).
    var steerWatched: [String: Steered] = [:]
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

    // The all-done mark (`AllDoneLook.swift`), on `queue`: the marks whose summary is being written, and the clock.
    var allDoneSummarizing: Set<String> = []
    var allDoneNow: () -> Date = Date.init

    // The prompt-audit reminder (`PromptAuditWatch.swift`), on `queue`.
    /// The projects due a prompt audit, and why, as the last look found them.
    public internal(set) var promptAuditsDue: [String: PromptAudit.Due] = [:]
    /// Whether a look is under way, and whether one ran yet (the first runs at the first refresh).
    var promptAuditLooking = false
    var promptAuditLooked = false
    /// The look every 30 minutes on the engine's clock, and the clock a reminder is judged by (a test's later).
    var promptAuditTimer: Subscription?
    var promptAuditNow: () -> Date = Date.init
    /// The record's reads and writes, one at a time, off the engine's queue.
    let promptAuditBook = DispatchQueue(label: "vibenode.lead-engine.prompt-audit", qos: .utility)

    // Cards, answers and holds (E6), on `queue`.
    /// Every card the user answers: the lead's questions and approvals, held config, base moves.
    public let cards = CardStore()
    /// Each lead's base, watched (`BaseMoveStore`): a move nobody accounts for becomes a card.
    public private(set) lazy var baseMoves: BaseMoveStore = makeBaseMoves()
    /// The `.user` messages posted to a lead's inbox, by id, with the terminal and what was posted: retired in the vault
    /// (`retireUserSeals`) once its delivered record shows them, renewed while that same line waits (`retireTaken`).
    var postedUser: [String: PostedUser] = [:]
    var retiring = false
    /// Of `postedUser`, the ids a lead start's handover withdrew (`LeadHandover.takeWaiting`): retired by name at the
    /// next look, whatever the inbox shows then.
    var withdrawnUser: Set<String> = []
    /// Of `postedUser`, how many looks each id was out of a readable inbox and out of the delivered record
    /// (`retireTaken`): retired once that's `PostedUser.goneLooks` looks, so one read between a rewriter's truncate and
    /// write retires nothing.
    var goneUser: [String: Int] = [:]
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
    /// The sessions the witness last told the vault were at work (`LeadVault.noteWorking`), by root, and when.
    var workingTold: [String: (sessions: Set<String>, at: Date)] = [:]
    /// How often the same working sessions are told the vault again (the app's `LeadController.workingEvery`).
    static let workingEvery: TimeInterval = 30
    /// Each lead's open push request (push_remote), by root, as the vault last said; the request last noted in the log,
    /// by root; the roots whose vault look is under way, and whose push the user is settling (`PushAsks.swift`). On
    /// `queue`.
    var pushAsked: [String: LeadPush.Request] = [:]
    var pushNoted: [String: String] = [:]
    var pushLooking: Set<String> = []
    var pushSettling: Set<String> = []
    /// Settles a push request (`LeadPush.settle`: the request's id, the root, push or decline, the vault), off the
    /// engine's queue. Faked in tests.
    var pushSettle: @Sendable (String, String, Bool, LeadVault) -> (request: LeadPush.Request?, outcome: LeadPush.Outcome) = { id, root, push, vault in
        LeadPush.settle(id: id, root: root, push: push, vault: vault)
    }
    /// Where those are told, one after another: a later look's never overtakes an earlier one's (`work` is concurrent).
    let workingNotes = DispatchQueue(label: "vibenode.lead-engine.working", qos: .utility)
    /// Names each computation of the witness's as it starts, on the thread that runs it (`WitnessWork`), and "applied"
    /// on the engine's queue once a look is applied (`witnessed`); tests watch or slow them. Set on `queue`.
    var witnessStep: ((String) -> Void)?
    /// How many of the witness's looks were applied for each root since this engine started (`status` gives each lead's
    /// as `looks`: what a test waits on to know looks went by). On `queue`.
    public internal(set) var witnessLooks: [String: Int] = [:]
    /// Each root's workers its witness's last look saw idle between turns with nothing waiting (lowercased session ids):
    /// what `status` says a switch would park (`SwitchPark`). On `queue`.
    var idleWorkers: [String: Set<String>] = [:]
    /// The replaced lead sessions asked to end (`endReplacedLeads`), until they are no longer live. On `queue`.
    var endingReplaced: Set<UUID> = []
    /// A test's hold on `endReplacedLeads` (a replaced lead looked at before it ends). On `queue`.
    var replacedEndsHeld = false
    /// The account's usage as the last refresh read it (`NodeUsage`): `status`'s `usage`. On `queue`.
    public internal(set) var usage: NodeUsage.Reading?
    /// Each lead's review rows waiting on a limit (`UsageWaits`), by root: the boards show them (`LiveBoards`).
    public let usageWaits = Changes<[String: ReviewUsageWait]>()
    /// The clock the account's usage is read by (a limit holds until its reset by it). Faked in tests.
    var usageNow: () -> Date = { Date() }
    /// The AI summaries (`TeamSummaryWatch`): their writer when `Options.summarize` gives a model, each team's lines by
    /// root (task id to line: the boards show them), and the summary key of each task at work, by root. On `queue`.
    var summarizer: Summarizer?
    public let teamSummaries = Changes<[String: String]>()
    var summaryKeys: [String: [String: String]] = [:]
    /// The all-done summaries' model (`Options.summarizeBatch`; a test's fake). On `queue`.
    var batchModel: Summarizer.Generate?
    /// Brief me (`Requests.brief`): the briefing's model (`Options.summarizeBrief`; a test's fake), when each scope
    /// (a project's root, "" for every project) was last briefed, its last briefing kept, and the clock. On `queue`.
    var briefModel: Summarizer.Generate?
    var briefed: [String: Double] = [:]
    var briefs: [String: (text: BriefingText, asks: Int, at: Double)] = [:]
    var briefNow: () -> Date = { Date() }
    /// The summaries may be asked for now (a model given, Settings' AI summaries on, Haiku not held back), as the last
    /// refresh found; each lead's latest decisions (newest first) by root, and the boards' copy of them with their lines;
    /// the long messages' keys asked for, by "session|entry", and their lines.
    var summariesAllowed = false
    var recentDecisions: [String: [LeadDecision]] = [:]
    public let boardDecisions = Changes<[BoardDecision]>()
    var messageKeys: [String: String] = [:]
    public let messageSummaries = Changes<String>()
    /// What the lead's chat shows beside its transcript, by the lead's chat session id (`NodeIds.session`): its board's
    /// all-done cards (`ChatValue`'s `allDone` items), oldest first (`AllDoneLook.publishChatCards`). `ChatStore` places them.
    public let chatExtras = Changes<[NodeWire.Value]>()
    /// Where the summaries' transcripts are looked at, and where their model runs: one at a time.
    let summaryReads = DispatchQueue(label: "vibenode.lead-engine.summary-reads", qos: .utility)
    let summaryRuns = DispatchQueue(label: "vibenode.lead-engine.summaries", qos: .utility)
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
    /// The working policy's watch (`SettingsWatch.swift`): each running lead told it once when it changes. None until
    /// `watchRoom`, so a test's engine tells nothing it didn't ask for.
    var policyWatch: LeadWitness.PolicyWatch?
    /// The health digest (`NodeHealth`): each refresh's time told to it. None in a test's engine unless given.
    public var health: NodeHealth?
    // Shell requests (`ShellCards.swift`), on `queue`: the stamps the host vouched for (asked once each), each request's
    // card, the messages under way, a look under way, the 15 s look and the clock. The folder and the host's seal are
    // read on `shellWork`, one step at a time.
    var shellTrusted: [String: WalletStamp] = [:]
    /// What became of each request, the engine's own (never read from the folder's answer files).
    var shellAnswers: [String: ShellAsk.Answer] = [:]
    var shellCards: [String: String] = [:]
    var shellTelling: Set<String> = []
    var shellTellingEnd: Set<String> = []
    var shellLooking = false
    var shellTimer: Subscription?
    var shellNow: () -> Date = Date.init
    let shellWork = DispatchQueue(label: "vibenode.lead-engine.shell-requests", qos: .userInitiated)
    // The developer tools notice (`ToolchainLook.swift`), on `queue`: the notices the last look found, when it ran,
    // whether one is under way; how the node's tools are asked (a test's stand-in) and the clock.
    public internal(set) var toolchainNotices: [String] = []
    var toolchainLookedAt: Date?
    var toolchainLooking = false
    /// The node's tools as a look asks them (nil: `NodeToolchain.node(home:)` in the engine's home).
    var toolchainTools: (@Sendable () -> NodeToolchain.Tools)?
    var toolchainNow: () -> Date = Date.init
    /// Boost as last written to `boost.json` (`lookAtBoost`), and when; the clock it's judged on.
    var boostWritten: (state: BoostState, at: Date)?
    /// Boost as the last look decided it (whether or not a file was written), with its mode: `status`'s `boost`.
    public internal(set) var boostDecided: (mode: BoostMode, state: BoostState)?
    var boostNow: () -> Date = Date.init
    /// The machine's load as the room watch reads it, as the leads' tools judge it (`MacLoad.steady`); faked in tests.
    var macLoad: () -> Double? = MacLoad.steady
    /// Each room look's read of the machine's memory (`MacMemory.read`), on the reads queue; faked in tests.
    var memory: () -> MacMemory? = { MacMemory.read() }

    // The lead's rotation and idle handover (main's `26923f7c`, `IdleHandover.swift`), on `queue`.
    /// The time the rotation judges by (now; a test's later).
    var handoverNow: () -> Date = Date.init
    /// When this engine started: the node keeps no record of the user's typing into a lead, so its quiet counts from here.
    let handoverStarted = Date()
    /// Roots whose idle look or handover is under way, and when each may be looked at again after a handover ended.
    var handingOver: Set<String> = []
    var handoverRetry: [String: Date] = [:]
    /// Handovers tried per lead session in its current idle stretch.
    var handoverAttempts: [UUID: IdleTries] = [:]
    /// The handover note asked of each root's lead: of which session, when, why, and the marker its reply starts with.
    var rotationAsked: [String: (session: UUID, at: Date, reason: String, marker: String)] = [:]
    /// Sends the ask for a note (the text, the root) and says whether it reached the lead; nil: delivered to the lead
    /// from VibeSwitcher. Set by tests.
    var rotationRequest: ((String, String, @escaping (Bool) -> Void) -> Void)?
    /// Each rotation look's or handover's end ("checked", "asked", "cancelled", "retained", "handed over"), on `queue`
    /// (for tests).
    var handoverEvent: (String) -> Void = { _ in }

    // Restarts (E8), on `queue`.
    /// The start time of the last host that welcomed the engine, as `engine.json` keeps it (seconds since 1970).
    var lastHostStart: Double?
    /// The roots with a lead that ran under that host (a host restart ended them).
    var knownLeads: Set<String> = []
    /// The last host restart the engine saw (its roots whose team it ended, each until a lead starts there again).
    public internal(set) var hostRestart: EngineState.Restart?
    /// What reopens each project's lead after a host restart, by root (`EngineState.Reopen`, `RestartResume.swift`).
    public internal(set) var reopen: [String: EngineState.Reopen] = [:]
    /// The user's own sessions live in the host, as last recorded (`EngineState.OpenSessions`, `SessionReopen.swift`).
    public internal(set) var openSessions: EngineState.OpenSessions?
    /// The user's own sessions that ended lately, newest first (`EngineState.Ended`, `vibeswitcher resume`).
    public internal(set) var endedSessions: [EngineState.Ended] = []
    /// When each recorded session was first seen ended (or gone from the host's list): kept in the record for
    /// `openGrace`, since a host going down (a reboot) ends its sessions and may say so before it goes.
    var openEnded: [UUID: Date] = [:]
    /// How long an ended session stays in the record (a test's shorter), and the clock it's judged by.
    var openGrace: TimeInterval = 30
    var openNow: () -> Date = Date.init
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
    /// Claude Code's popups on team sessions (`ClaudePopups.swift`): the sessions an Esc is going into now, each popup
    /// declined so far (for tests and the log), and the dialogs nothing here reads, by session, while they stay.
    var declining: Set<UUID> = []
    public internal(set) var popupsDeclined: [(session: UUID, popup: ClaudePopup)] = []
    var dialogs: [UUID: UnknownDialog] = [:]
    /// The clock an unknown dialog's time is judged by (a test's later).
    var dialogNow: () -> Date = Date.init

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
        promptAuditTimer = clock?.every(Int(Self.promptAuditEvery)) { [weak self] in self?.queue.async { self?.lookAtPromptAudits() } }
        // Each screen the session scan reads: a popup on a team session declined, a dialog nothing reads noted.
        sessions?.sawScreen = { [weak self] session, text in self?.lookAt(screen: text, of: session) }
        batchModel = options.summarizeBatch
        briefModel = options.summarizeBrief
        if let generate = options.summarize {
            let (runs, queue) = (summaryRuns, link.queue)
            let summarizer = Summarizer(generate: generate, run: { runs.async(execute: $0) }, deliver: { queue.async(execute: $0) })
            summarizer.changed = { [weak self] in self?.publishSummaries() }
            self.summarizer = summarizer
        }
    }

    /// The vault the cards are built from and the user's answers recorded in: the link's, or a test's.
    var cardVault: LeadVault { options.vault ?? link.vault }

    /// The hooks' state file of `tty` under this root.
    func stateFile(_ tty: String) -> URL { observer.stateFile(tty) }

    /// The lead's tool server (S9: from the node's build folder).
    var toolServer: String? { nodeRoot.map { $0.appendingPathComponent("bin/vibeswitcher-mcp").path } }

    /// Whether `root` is a scratch node's (not the account's own `~/.vibeswitcher`): its lead gets `VIBESWITCHER_HOME`.
    var isScratch: Bool { !NodeFolders.isUsersRoot(root, accountHome: VibePaths.accountHome) }

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
