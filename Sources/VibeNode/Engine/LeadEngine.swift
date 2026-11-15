import Foundation
import VibeCore

/// The node's lead engine (the engine plan's E4 on; rebuilt from the non-UI duties of the app's `LeadController`): its
/// queues, its stores and their wiring. It runs on one serial queue (`queue`, the link's: EN-D1) and does its blocking
/// reads (boards, git, the vault) elsewhere: the boards on `reads` (`BoardReads`, in the order asked, as the app's
/// `LeadReads`), git and the vault's calls on a utility queue. Every root it takes is a parameter, never this process's
/// `VibePaths.root` (one root per test).
///
/// E4 gives it starting a lead (`startLead`, in `LeadStart.swift`) and the lead store; E5 to E8 add delivery, cards,
/// the refresh and restarts.
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
        /// The node's home: the agents' transcripts (the replaced lead's last turns). `VibePaths.home` by default.
        public var home: String?

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

    // On `queue`.
    /// Starts asked for before the host said which sessions run, by root: decided once it has (the app's
    /// `pendingStarts`). Each with what waited on it.
    var pendingStarts: [String: PendingStart] = [:]
    /// Roots whose start is under way, with every request waiting on it: a second ask joins the first.
    var starting: [String: [(StartOutcome) -> Void]] = [:]
    /// `stop` is under way: no start goes on.
    public private(set) var stopping = false
    /// The session each root's board named at the last look.
    var holders: [String: UUID] = [:]
    private var watch: Subscription?

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
        watch = link.changes.subscribe(on: link.queue) { [weak self] _ in self?.sessionsChanged() }
    }

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
    }

    /// `stop` is under way: no start goes on from now, and what waits for one is refused. On `queue`.
    public func stopStarting() {
        stopping = true
        if !pendingStarts.isEmpty { note("lead: \(pendingStarts.count) starts that waited for the host's welcome dropped: the node is stopping") }
        pendingStarts = [:]
    }

    /// `stop` was refused: starts are taken again. On `queue`.
    public func startAgain() { stopping = false }

    static let stoppingRefusal = "the node is stopping: no lead starts"

    /// The host's list changed: each project's lead sessions again.
    private func sessionsChanged() {
        leads.update(sessions: link.sessions, holders: holders)
    }
}
