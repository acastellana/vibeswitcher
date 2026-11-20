import Foundation
import VibeCore

/// The node's one session list (the engine plan's E3), rebuilt from the app's `SessionStore`
/// (`Sources/VibeSwitcher/SessionStore.swift`: refresh and apply, the details, the state folder's watch; the quiet
/// sessions' screens, `HostClient.refreshScreens`; the port map's row) and grown from stage 1's `LocalSessions`: every
/// `claude` or `codex` on a terminal (the app's scan, `SessionScanner`), joined with what the hooks wrote for its
/// terminal under the node's root, with the host's session on that terminal (its `hostID`, `startFolder` and team role),
/// and with what its program reports (OSC 7501) or its title shows, resolved by `StatusRules`. Each a `VibeCore`
/// `Session`, as the witness reads it, keyed by the node's ids (`NodeIds.session(host:)` for a hosted one, else
/// `NodeIds.session(terminal:)`), on a change stream.
///
/// What scans: the 2 s client on the engine's `NodeClock`; the host's sessions changing (one starting or ending, or its
/// program reporting a new status: `HostLink.changes`); the state folder's watch (`Platform.FolderWatch`, which the
/// hook's renames wake, coalesced 0.4 s); a quiet Claude session's screen read with something new in its footer
/// (`HostLink.screen`, every 6 s at most). Not Terminal.app's tabs, Spaces, presence, attention, nudges, names, pauses
/// or the ledger: those are the Mac's (the port map says so). A finished turn counts as seen by the app's rule
/// (`SessionStore`'s `acknowledged`): one that ended before this store started, or before someone looked at it since
/// (`acknowledge`: a web page with the session open sends `seen`), reads `idle`, not `done`.
///
/// Its state is on `queue` (the engine's, and its link's): read there, and its calls may be made from any thread. Each
/// scan reads the process table and the state files on a serial queue of its own, never `queue` (the app's "off the
/// main thread", EN-D1). It takes its root as a parameter and never reads this process's `VibePaths`.
///
/// Unlike the app's scan, a terminal the host runs has the agent the host started there, whatever its program is named,
/// and nothing else on it is one (`HostedAgents.overlay`: a role run by Claude Code's versioned binary, or by any other
/// name, is listed; a `claude` a plain shell session runs isn't); and a scratch node (`onlyHosted`: the server's start
/// gives it for a root other than the account's) lists no session its host didn't start, so a test's node never lists the machine's own.
public final class NodeSessions: @unchecked Sendable {
    /// How often it scans and looks.
    public struct Timing {
        /// The scan's period on the clock, in seconds.
        public var scanEvery = 2
        /// How long after a change in the state folder it scans: a busy session's hook writes several events a second.
        public var watchCoalesce: TimeInterval = 0.4
        /// The quiet Claude sessions' screens are asked at most this often (by the store's `now`).
        public var screenEvery: TimeInterval = 6
        /// The screens of hosted sessions that need you are asked at most this often, for the question open there
        /// (`prompts`).
        public var promptEvery: TimeInterval = 2
        /// A state folder that couldn't be watched is tried again this long after (by the store's `now`), at a scan.
        public var watchRetry: TimeInterval = 60

        public init() {}
    }

    public let queue: DispatchQueue
    /// The node's root: the hooks' state files are in its `state` folder.
    public let root: URL
    /// Where the hooks write: `<root>/state`.
    public var stateFolder: URL { root.appendingPathComponent("state", isDirectory: true) }

    /// The sessions as the last scan found them, ordered by terminal. On `queue`.
    public private(set) var sessions: [Session] = []
    /// Your names for sessions and those you paused (`SessionMarks`), laid on each session at every scan; none: no
    /// names, no pauses.
    public var marks: SessionMarks?
    /// Every change to `sessions`, by the node's id for each (`NodeSessions.id(of:)`): its new value, or nil once it's
    /// gone.
    public let changes = Changes<Session>()
    /// The question open on each hosted agent session's screen (`SessionPrompt`), by the node's id for the session: set
    /// while its screen shows one, nil once it doesn't, or the session is working or gone (2026-11-20, the parity
    /// table's gap 6). Read off the screens of those that need you every `promptEvery` s, and of the quiet ones
    /// (done, idle, unknown) with their background work, every `screenEvery` s: Claude's trust question at a start
    /// comes before any hook says it needs you.
    public let prompts = Changes<SessionPrompt>()
    /// The process table `sessions` come from: when it was read and the terminals it couldn't tell an agent on or not.
    /// Set after `sessions`, so a reader never pairs a newer table with older sessions (an agent the newer table finds
    /// would read as quit). On `queue`.
    public private(set) var tableRead = TableRead()
    /// Whether each agent's hooks are installed in the node's home (`HookInstaller`), read at `start()` and at
    /// `refreshHookStatus()`. On `queue`.
    public private(set) var hooksInstalled: [Agent: Bool] = [:]
    /// Scans that have landed, for tests to wait on one (`refresh` returns before its scan runs). On `queue`.
    public private(set) var scansApplied = 0

    /// The roots of the leads' boards with a question for the user open (`LeadTeams.asking`, set by the engine as it
    /// reads them, E6): those leads' sessions need the user (`Session.leadAsks`), told at once, not at the next scan. On
    /// `queue`.
    public var leadsAsking: Set<String> = [] {
        didSet {
            guard leadsAsking != oldValue else { return }
            let marked = sessions.map { session in
                var session = session
                session.leadAsks = LeadTeams.asks(session, asking: leadsAsking)
                return session
            }
            if marked != sessions { publish(marked) }
        }
    }

    private let home: String
    private let link: HostLink?
    private let clock: NodeClock?
    private let timing: Timing
    private let now: @Sendable () -> Date
    private let note: (String) -> Void
    private let scanner: SessionScanner
    /// The host's live sessions as the scan under way has them, for its process table (`HostedAgents.overlay`). On
    /// `scanQueue`, set before each scan.
    private let scanHosted: Locked<[HostSession]>
    private let scanQueue = DispatchQueue(label: "vibenode.sessions.scan", qos: .utility)
    private let onQueue = DispatchSpecificKey<ObjectIdentifier>()

    // On `queue`.
    private var started = false
    private var stopped = false
    private var scanning = false
    private var rescanRequested = false
    private var ticks: Subscription?
    private var hostChanges: Subscription?
    private var watch: Platform.FolderWatch?
    private var watchRefreshPending = false
    /// When the state folder last couldn't be watched (nil: since it last could, or never tried), and whether that's
    /// been said.
    private var watchFailedAt: Date?
    private var watchFailureNoted = false
    /// The host's live sessions, by terminal.
    private var hosted: [String: HostSession] = [:]
    /// Each terminal's status and since when it holds.
    private var observed: [String: (status: SessionStatus, since: Date)] = [:]
    /// When each terminal's session was last looked at (`acknowledge`, the app's `acknowledged`): a finished turn that
    /// ended by then reads `idle`.
    private var acknowledged: [String: Date] = [:]
    /// When this store started (the app's `launchedAt`): a turn that had ended by then counts as seen.
    private var launchedAt = Date.distantPast
    /// Hook-less sessions seen mid-turn: only those can be "done" off the title alone.
    private var turns = TurnWitness()
    /// Claude sessions whose turn looks finished; only their screens are read for background work.
    private var quietClaude: Set<String> = []
    /// The quiet hosted sessions' screens, by terminal, as last read.
    private var screens: [String: String] = [:]
    private var lastScreenAsk = Date.distantPast
    /// Hosted sessions whose screen may show a question (`prompts`): those that need you (`asking`), and the quiet ones.
    private var asking: Set<String> = []
    private var promptable: Set<String> = []
    private var lastPromptAsk = Date.distantPast

    /// `root`: the node's root (the hooks' state folder is in it). `home`: the node's home, where the agents' own config
    /// (their hooks) and transcripts are. `queue`: the engine's; with a `link`, the link's. `clock`: the engine's, whose
    /// client scans every `Timing.scanEvery` s (none: only on `refresh()`, the host's changes and the watch). `scanner`:
    /// this machine's processes and `<root>/state` by default; tests give a fake process table. `now`: the scan's time
    /// and the screens' (tests give their own, so ages don't depend on how long a loaded machine takes). `onlyHosted`: a
    /// scratch node's, which lists no session its host didn't start (the default scanner's). `note`: the server's log.
    public init(root: URL, home: String, queue: DispatchQueue, link: HostLink? = nil, clock: NodeClock? = nil, timing: Timing = Timing(),
                scanner: SessionScanner? = nil, onlyHosted: Bool = false, now: @escaping @Sendable () -> Date = { Date() },
                note: @escaping (String) -> Void = { _ in }) {
        self.root = root
        self.home = home
        self.queue = queue
        self.link = link
        self.clock = clock
        self.timing = timing
        self.now = now
        self.note = note
        let state = root.appendingPathComponent("state", isDirectory: true)
        // A hosted terminal's agent is the one the host started (whatever its name), and a scratch node lists no session
        // it didn't start (`HostedAgents.overlay`).
        let hostedNow = Locked<[HostSession]>([])
        scanHosted = hostedNow
        self.scanner = scanner ?? SessionScanner(processes: {
            ProcessTable.trySnapshot().map { HostedAgents.overlay($0, hosted: hostedNow.get(), scratch: onlyHosted) }
        }, stateDir: { state })
        queue.setSpecific(key: onQueue, value: ObjectIdentifier(self))
    }

    deinit {
        ticks?.cancel()
        hostChanges?.cancel()
        watch?.stop()
    }

    /// This node's id for `session`: its host session's (`NodeIds.session(host:)`) when the host runs it, else its
    /// terminal's (`NodeIds.session(terminal:)`).
    public static func id(of session: Session) -> String {
        session.hostID.map(NodeIds.session(host:)) ?? NodeIds.session(terminal: session.tty)
    }

    /// Reads the hooks' status, scans, and from then on scans on the clock, the host's changes and the state folder's
    /// watch. Once.
    public func start() {
        perform { [self] in
            guard !started, !stopped else { return }
            started = true
            launchedAt = now()
            refreshHookStatus()
            if let link {
                hosted = Self.live(link.changes.values.values)
                hostChanges = link.changes.subscribe(on: queue) { [weak self] _ in
                    guard let self, let link = self.link else { return }
                    self.updateHosted(Array(link.changes.values.values))
                }
            }
            watchStateFolder()
            scan()
            if let clock {
                ticks = clock.every(timing.scanEvery) { [weak self] in self?.refresh() }
            }
        }
    }

    /// Stops the clock's client, the host's changes and the watch. Once; a scan under way still lands, and from then on
    /// nothing scans (`refresh()` included) and no screen is asked.
    public func stop() {
        perform { [self] in
            stopped = true
            ticks = nil
            hostChanges = nil
            watch?.stop()
            watch = nil
        }
    }

    /// The app's `SessionStore.acknowledge`: the session `id` (`id(of:)`) counts as seen now, so its finished turn reads
    /// `idle` at once and at every scan (a turn that ends later is `done` again). `then`: whether the store has that
    /// session, on `queue`. From any thread.
    public func acknowledge(_ id: String, then: @escaping (Bool) -> Void = { _ in }) {
        perform { [self] in
            guard let found = sessions.first(where: { Self.id(of: $0) == id }) else { return then(false) }
            let at = now()
            acknowledged[found.tty] = at
            let marked = sessions.map { session -> Session in
                guard session.tty == found.tty, session.status == .done, session.statusSince <= at else { return session }
                var seen = session
                seen.status = .idle
                return seen
            }
            if marked != sessions { publish(marked) }
            then(true)
        }
    }

    /// The app's reminders about sessions left alone (`Nudges.due`, `AlertRules.nudge`; parity: "Reminders about waiting
    /// or stuck sessions", 2026-11-20), as `status` notices while each stands: a session waiting on you for 10 minutes
    /// since it began to or since someone last looked at it (`acknowledge`), or one its hooks say works with no hook event
    /// for 15. A team's are silent, a lead's only while it waits on you (`AlertRules.nudge`), a paused one's too. A wait from before this
    /// store started counts from its start. Every word a session wrote is inert. On `queue`.
    public func reminderNotices() -> [String] {
        let at = now()
        return sessions.compactMap { session in
            guard !session.isPaused else { return nil }
            let activity = session.hasHooks && session.status == .working ? session.eventAt.map(Date.init(timeIntervalSince1970:)) : nil
            guard let due = Nudges.due(status: session.status, statusSince: max(session.statusSince, launchedAt), lastSeen: acknowledged[session.tty],
                                       lastActivity: activity, now: at),
                  let alert = AlertRules.nudge(due.nudge, for: session, settings: AlertRules.Settings()) else { return nil }
            let subtitle = alert.subtitle.map { " (\(ConfigSeal.inert($0, limit: 160)))" } ?? ""
            let body = alert.body.isEmpty ? "" : ": " + ConfigSeal.inert(alert.body, limit: 200)
            return "reminder: \(ConfigSeal.inert(alert.title, limit: 160))\(subtitle), on \(ConfigSeal.inert(session.tty, limit: 20))\(body)"
        }
    }

    /// Scans now (after the one under way, when one is). Not once stopped.
    public func refresh() {
        perform { [self] in scan() }
    }

    /// Reads again whether each agent's hooks are installed in the node's home, off `queue`.
    public func refreshHookStatus() {
        let home = self.home
        scanQueue.async { [weak self] in
            let installed = Dictionary(uniqueKeysWithValues: Agent.allCases.map { agent -> (Agent, Bool) in
                let url = HookInstaller.configURL(for: agent, home: home)
                let config = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                return (agent, HookInstaller.isComplete(in: config ?? [:], agent: agent))
            })
            self?.perform { self?.hooksInstalled = installed }
        }
    }

    /// Whether the agent of a hosted session started for one has quit, leaving its shell: the scan has no agent on its
    /// terminal, and the table it read (a minute after the session started, and able to tell what runs on that
    /// terminal) says so (`TableRead.agentQuit`, the rule the app's rows and witness use). A session whose agent the
    /// scan has is never quit. On `queue`.
    public func agentQuit(_ hosted: HostSession) -> Bool {
        !sessions.contains { $0.tty == hosted.tty } && tableRead.agentQuit(hosted)
    }

    // MARK: Scans

    /// `work` on `queue`: now when called there, else after what's queued.
    private func perform(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: onQueue) == ObjectIdentifier(self) { work() } else { queue.async(execute: work) }
    }

    /// The host's sessions changed. Titles change many times a second while an agent works (its spinner); the regular
    /// scan picks them up, so only a session starting or ending, or its program reporting a new status (OSC 7501),
    /// scans here. On `queue`.
    private func updateHosted(_ sessions: [HostSession]) {
        let fresh = Self.live(sessions)
        let changed = Set(fresh.keys) != Set(hosted.keys)
            || fresh.contains { tty, session in session.programStatus != hosted[tty]?.programStatus }
        hosted = fresh
        if changed { scan() }
    }

    /// The host's live sessions, by terminal.
    private static func live<S: Sequence>(_ sessions: S) -> [String: HostSession] where S.Element == HostSession {
        Dictionary(sessions.filter(\.isLive).map { ($0.tty, $0) }, uniquingKeysWith: { $1 })
    }

    /// The scan: the quiet hosted Claude sessions' screens asked when it's time, then the process table and the state
    /// files read on the scan queue, and what they gave applied back on `queue`. One at a time: one asked while one runs
    /// follows it. None once stopped. On `queue`.
    private func scan() {
        guard !stopped else { return }
        guard !scanning else {
            rescanRequested = true
            return
        }
        scanning = true
        if watch == nil, started, watchFailedAt.map({ now().timeIntervalSince($0) >= timing.watchRetry }) ?? true {
            watchStateFolder()
        }
        let hosted = self.hosted
        let quiet = quietClaude.union(promptable.subtracting(asking)).intersection(hosted.keys)
        if !quiet.isEmpty, now().timeIntervalSince(lastScreenAsk) >= timing.screenEvery {
            lastScreenAsk = now()
            askScreens(quiet)
        }
        let urgent = asking.intersection(hosted.keys)
        if !urgent.isEmpty, now().timeIntervalSince(lastPromptAsk) >= timing.promptEvery {
            lastPromptAsk = now()
            askScreens(urgent, keep: false)
        }
        let screens = self.screens
        let (scanner, now, home, scanHosted) = (self.scanner, self.now, self.home, self.scanHosted)
        scanQueue.async { [weak self] in
            scanHosted.set(Array(hosted.values))
            let time = now()
            let raw = scanner.scan(now: time)
            let read = TableRead(at: scanner.readAt, undecided: scanner.undecided)
            let transcripts = Self.transcripts(for: raw, home: home)
            var background: [String: String] = [:]
            for (tty, screen) in screens where hosted[tty] != nil {
                background[tty] = BackgroundWork.summary(fromScreen: screen)
            }
            self?.perform {
                guard let self else { return }
                self.apply(raw: raw, hosted: hosted, background: background, transcripts: transcripts, now: time)
                if read != self.tableRead { self.tableRead = read }
                self.scansApplied += 1
                self.scanning = false
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.scan()
                }
            }
        }
    }

    /// Reads these hosted sessions' screens (by terminal) into `screens` (the app's `HostClient.refreshScreens`); a
    /// screen whose footer says something new scans again. On `queue`.
    /// The question on each screen read goes to `prompts`. `keep`: the quiet ones' read, whose screens are kept for
    /// their background work (an urgent read keeps none). On `queue`.
    private func askScreens(_ ttys: Set<String>, keep: Bool = true) {
        guard let link, !stopped else { return }
        if keep { screens = screens.filter { ttys.contains($0.key) } }
        for (tty, session) in hosted where ttys.contains(tty) {
            link.screen(session.id) { [weak self] text in
                self?.perform {
                    guard let self, !self.stopped, self.hosted[tty]?.id == session.id else { return }
                    if self.promptable.contains(tty) { self.prompt(text.flatMap(SessionPrompt.menu(on:)), id: NodeIds.session(host: session.id)) }
                    guard keep else { return }
                    let before = self.screens[tty].flatMap { BackgroundWork.summary(fromScreen: $0) }
                    self.screens[tty] = text
                    if text.flatMap({ BackgroundWork.summary(fromScreen: $0) }) != before { self.scan() }
                }
            }
        }
    }

    /// `menu` is the question on the screen of the session `id` now: kept with when it was first seen while the same
    /// question shows (its cursor may move), sent as new when another one does, removed when none does. On `queue`.
    private func prompt(_ menu: ScreenMenu?, id: String) {
        let before = prompts.values[id]
        guard let menu else {
            if before != nil { prompts.send(id, nil) }
            return
        }
        let at = before.flatMap { $0.menu.sameQuestion(as: menu) ? $0.at : nil } ?? now()
        let fresh = SessionPrompt(menu: menu, at: at)
        if fresh != before { prompts.send(id, fresh) }
    }

    /// Off `queue`: each session's transcript, if its hook named one inside the agents' folders in `home`.
    private static func transcripts(for raw: [RawSession], home: String) -> [String: String] {
        var paths: [String: String] = [:]
        for item in raw {
            if let path = item.hook?.transcriptPath, let checked = TranscriptReader.checkedURL(path, home: home) {
                paths[item.tty] = checked.0.path
            }
        }
        return paths
    }

    /// The app's `SessionStore.apply`, its node part: each session's status (hooks, else its program's report, else its
    /// title) and since when, its background work, its detail, and the fields of `Session` the engine reads. On
    /// `queue`.
    private func apply(raw: [RawSession], hosted: [String: HostSession], background: [String: String], transcripts: [String: String],
                       now: Date) {
        var quiet: Set<String> = []
        var needsYou: Set<String> = []
        var mayAsk: Set<String> = []
        var result: [Session] = []
        for item in raw {
            let window = hosted[item.tty]
            let parsed = window.map { StatusRules.parseTitle($0.title) }
            // Claude uses ✳ (idle) and spinners (busy); Codex only shows a braille spinner while busy.
            let activity: TitleActivity = item.agent == .claude ? (parsed?.activity ?? .none)
                : (parsed?.activity == .busy ? .busy : .none)
            let seenBusy = turns.observe(tty: item.tty, pid: item.pid, title: activity)
            // Hooks, else what the program reports over OSC 7501, else the title (`StatusRules.resolve`).
            let program = item.hook == nil ? window?.liveProgramStatus : nil
            var status = StatusRules.resolve(hook: item.hook, program: program, title: activity, now: now.timeIntervalSince1970,
                                             seenBusy: seenBusy)

            let since: Date
            if let previous = observed[item.tty], previous.status == status {
                since = previous.since
            } else if observed[item.tty] == nil {
                // First sighting: since its last hook event, or its program's report, else since ever.
                since = item.hook.map { Date(timeIntervalSince1970: $0.lastEventAt) } ?? program?.since ?? .distantPast
            } else {
                since = now
            }
            observed[item.tty] = (status, since)
            // The app's seen rule: a finished turn that ended before this store started, or before someone last looked
            // at the session, reads idle.
            if status == .done, since <= (acknowledged[item.tty] ?? launchedAt) { status = .idle }

            if window != nil, status != .working, status != .background {
                mayAsk.insert(item.tty)
                if status == .needsInput { needsYou.insert(item.tty) }
            }
            var waitingOn: String?
            if item.agent == .claude, status == .done || status == .idle {
                quiet.insert(item.tty)
                // Turn over but background work still running. Prefer the real processes (what and how long); fall
                // back to Claude's footer for background agents and tasks that aren't processes.
                if let jobs = BackgroundJobs.summary(item.backgroundJobs, now: now) ?? background[item.tty] {
                    status = .background
                    waitingOn = jobs
                }
            }

            var session = Session(
                tty: item.tty, agent: item.agent, pid: item.pid, startedAt: item.startedAt, cwd: item.cwd, project: item.project,
                task: SessionNaming.task(fromTitle: parsed?.text, project: item.project, firstPrompt: item.hook?.firstPrompt),
                status: status, statusSince: since,
                detail: waitingOn.map { "Waiting on \($0)" } ?? program.flatMap(StatusRules.detail(for:))
                    ?? Self.detail(for: status, hook: item.hook, agent: item.agent),
                hasHooks: item.hook != nil, inTerminalApp: false)
            session.eventAt = item.hook?.lastEventAt
            session.hookEvent = item.hook?.lastEvent
            session.transcriptPath = transcripts[item.tty]
            session.hostID = window?.id
            session.startFolder = window?.cwd
            session.teamRole = LeadTeams.role(label: window?.label)
            session.leadAsks = LeadTeams.asks(session, asking: leadsAsking)
            session.agentSessionID = item.hook?.sessionId
            session.backgroundJobs = item.backgroundJobs
            if let marks {
                session.nameKeys = SessionMarks.keys(of: session)
                session.customName = marks.name(for: session.nameKeys)
                session.pausedUntil = marks.pausedUntil(for: session.nameKeys, now: now)
            }
            if status == .working, let hook = item.hook, hook.lastEvent == "PreToolUse", let started = hook.toolStartedAt {
                session.activity = hook.toolDetail
                session.activitySince = Date(timeIntervalSince1970: started)
            }
            result.append(session)
        }
        let live = Set(raw.map(\.tty))
        marks?.prune(liveKeys: Set(result.flatMap(\.nameKeys)), now: now)
        observed = observed.filter { live.contains($0.key) }
        acknowledged = acknowledged.filter { live.contains($0.key) }
        turns.prune(liveTTYs: live)
        quietClaude = quiet
        // A session that started working, or went, has no question open: its prompt goes (a quiet one's stays until
        // its screen is read again).
        let askingFirst = needsYou.subtracting(asking)
        asking = needsYou
        promptable = mayAsk
        let promptIDs = Set(mayAsk.compactMap { hosted[$0].map { NodeIds.session(host: $0.id) } })
        for id in prompts.values.keys where !promptIDs.contains(id) { prompts.send(id, nil) }
        // One that has just come to need you is read at the next turn, not up to `promptEvery` later.
        if !askingFirst.isEmpty, link != nil {
            lastPromptAsk = now
            queue.async { [weak self] in self?.askScreens(askingFirst, keep: false) }
        }
        let ordered = result.sorted { ($0.tty, $0.pid) < ($1.tty, $1.pid) }
        if ordered != sessions { publish(ordered) }
    }

    /// `sessions` is now `fresh`: each changed one sent by its id, each gone sent as removed. On `queue`.
    private func publish(_ fresh: [Session]) {
        let gone = Set(sessions.map(Self.id(of:))).subtracting(fresh.map(Self.id(of:)))
        sessions = fresh
        for id in gone.sorted() { changes.send(id, nil) }
        for session in fresh { changes.send(Self.id(of: session), session) }
    }

    /// What a session waits on or works at, by its status and its hook (the app's `SessionStore.detail(for:hook:agent:)`,
    /// copied).
    public static func detail(for status: SessionStatus, hook: HookState?, agent: Agent) -> String? {
        switch status {
        case .needsInput:
            if let request = hook?.request { return request }
            if let notice = hook?.notice { return notice }
            switch hook?.toolName {
            case "AskUserQuestion", "request_user_input": return "Asking you a question"
            case "ExitPlanMode": return "Plan ready for review"
            default: return "Waiting for you"
            }
        case .working:
            if let prompt = hook?.lastPrompt, !SessionNaming.isSystemPrompt(prompt) { return "› " + prompt }
            return hook?.toolName.map { "Running \($0)" }
        case .done, .idle, .background:
            return hook?.lastMessage
        case .unknown:
            guard hook == nil else { return nil }
            return agent == .codex ? "No live status: this Codex session started before the hooks; restart it"
                                   : "No live status yet: waiting for this session's first hook event"
        }
    }

    // MARK: The state folder

    /// Hook writes land as renames in the state folder: a scan for them at once (coalesced), not at the clock's next.
    /// The folder is made (0700) when it isn't there. One that can't be watched (a 9p file system, no inotify instance
    /// left) is scanned on the clock alone, said once, and tried again at a scan `Timing.watchRetry` on; one removed is
    /// watched again at the next scan. On `queue`.
    private func watchStateFolder() {
        let folder = stateFolder
        try? VibePaths.ensurePrivate(folder)
        guard let made = Platform.FolderWatch(path: folder.path) else {
            watchFailedAt = now()
            if !watchFailureNoted {
                watchFailureNoted = true
                note("sessions: the state folder can't be watched; hook events are seen at the next scan")
            }
            return
        }
        watch = made
        watchFailedAt = nil
        watchFailureNoted = false
        made.deliver(on: queue) { [weak self, weak made] change in
            guard let self else { return }
            if change.contains(.folderGone) {
                made?.stop()
                if self.watch === made { self.watch = nil }
            }
            guard !self.watchRefreshPending, !self.stopped else { return }
            self.watchRefreshPending = true
            self.queue.asyncAfter(deadline: .now() + self.timing.watchCoalesce) { [weak self] in
                guard let self else { return }
                self.watchRefreshPending = false
                // `scan()` starts none once stopped.
                self.scan()
            }
        }
    }
}
