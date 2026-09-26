import AppKit
import Combine
import Foundation
import VibeCore

/// Polls processes, hook state files and Terminal tabs; publishes the ordered list of sessions.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var terminalAccess: TerminalAccess = .unknown
    @Published private(set) var hooksInstalled: [Agent: Bool] = [:]
    /// Several sessions are native tabs of one window, but we can't read the tab order (no Accessibility).
    @Published private(set) var tabOrderUnavailable = false
    /// Called when a session newly turns red (needs input) or green (done, unseen).
    var onAttention: ((Session) -> Void)?
    /// Set from Preferences; changing it re-sorts on the next refresh.
    var order: SessionOrder = .screen { didSet { if order != oldValue { refresh() } } }

    private let scanner = SessionScanner()
    private let queue = DispatchQueue(label: "vibeswitcher.scan", qos: .utility)
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var scanning = false
    private var rescanRequested = false
    private var forceTerminalRequested = false

    // Scan-queue only.
    private var tabs: [String: TerminalTab] = [:]
    private var backgroundWork: [String: String] = [:]
    private var lastTerminalQuery = Date.distantPast
    private var lastScreenQuery = Date.distantPast

    // Main-thread only.
    private let launchedAt = Date()
    private var observed: [String: (status: SessionStatus, since: Date)] = [:]
    private var acknowledged: [String: Date] = [:]
    private var displayed: [String: SessionStatus] = [:]
    private var watcherRefreshPending = false
    /// Claude sessions whose turn looks finished; only their screens are read for background work.
    private var quietClaudeTTYs: Set<String> = []
    private let names = NameStore()
    /// Project folders seen running an agent, feeding the "New session" menu.
    private(set) var observedProjects: [String: Date] =
        (UserDefaults.standard.dictionary(forKey: "observedProjects") as? [String: Date]) ?? [:]

    func start() {
        refreshHookStatus()
        refresh()
        // Hook updates arrive through the state-directory watcher right away; the timer only has to
        // notice sessions starting/ending, title changes and the viewing ring.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.5
        // Switching apps changes which session you're viewing; don't wait for the next poll.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.refresh(forceTerminal: true)
        }
        watchStateDirectory()
    }

    func refreshHookStatus() {
        hooksInstalled = Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0, HookInstaller.isInstalled(agent: $0)) })
    }

    /// Gives a session your own name (nil or empty resets it to the project name).
    func rename(_ session: Session, to name: String?) {
        names.set(name, for: session.nameKeys)
        refresh()
    }

    private func noteProject(_ root: String, at now: Date) {
        // Persist at most every 10 minutes per folder; this runs on every scan.
        if let last = observedProjects[root], now.timeIntervalSince(last) < 600 { return }
        observedProjects[root] = now
        UserDefaults.standard.set(observedProjects, forKey: "observedProjects")
    }

    /// Marks a finished session as seen, turning it from green (done) to grey (idle).
    func acknowledge(_ session: Session) {
        acknowledged[session.tty] = Date()
        refresh()
    }

    func refresh(forceTerminal: Bool = false) {
        guard !scanning else {
            rescanRequested = true
            forceTerminalRequested = forceTerminalRequested || forceTerminal
            return
        }
        scanning = true
        let quiet = quietClaudeTTYs
        // While you're in Terminal, check which tab you're on every second so the "viewing" ring keeps up.
        let terminalInterval: TimeInterval =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalBridge.bundleID ? 1.5 : 4
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            let raw = self.scanner.scan(now: now)
            var access: TerminalAccess?
            // AppleScript is the expensive part; query at most every 2s unless forced.
            if forceTerminal || now.timeIntervalSince(self.lastTerminalQuery) >= terminalInterval - 0.05 {
                let result = TerminalBridge.tabs()
                self.tabs = result.tabs
                access = result.access
                self.lastTerminalQuery = now
                // Screen text is only needed for Claude's footer (background agents/tasks that aren't
                // processes); it's the most expensive query, so read it less often.
                if forceTerminal || now.timeIntervalSince(self.lastScreenQuery) >= 6 {
                    self.backgroundWork = TerminalBridge.screens(for: quiet)
                        .compactMapValues { BackgroundWork.summary(fromScreen: $0) }
                    self.lastScreenQuery = now
                }
            }
            let tabs = self.tabs
            let background = self.backgroundWork
            DispatchQueue.main.async {
                if let access, access != self.terminalAccess {
                    self.terminalAccess = access
                    AppStatus.write(sessions: self.sessions, terminalAccess: access)
                }
                self.apply(raw: raw, tabs: tabs, background: background, now: now)
                self.scanning = false
                if self.rescanRequested {
                    let force = self.forceTerminalRequested
                    self.rescanRequested = false
                    self.forceTerminalRequested = false
                    self.refresh(forceTerminal: force)
                }
            }
        }
    }

    /// Synchronous scan on the calling (main) thread, used by `--snapshot`.
    func refreshNow() {
        let now = Date()
        let result = TerminalBridge.tabs()
        terminalAccess = result.access
        let raw = scanner.scan(now: now)
        let quiet = Set(raw.filter { $0.agent == .claude }.map(\.tty))
        let background = TerminalBridge.screens(for: quiet).compactMapValues { BackgroundWork.summary(fromScreen: $0) }
        apply(raw: raw, tabs: result.tabs, background: background, now: now)
    }

    private func apply(raw: [RawSession], tabs: [String: TerminalTab], background: [String: String], now: Date) {
        var quiet: Set<String> = []
        let currentDesktops = Spaces.currentDesktops()
        let terminalFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalBridge.bundleID
        var result: [Session] = []
        for item in raw {
            let tab = tabs[item.tty]
            let parsed = tab.map { StatusRules.parseTitle($0.title) }
            // Claude uses ✳ (idle) and spinners (busy); Codex only shows a braille spinner while busy.
            let activity: TitleActivity = item.agent == .claude ? (parsed?.activity ?? .none)
                : (parsed?.activity == .busy ? .busy : .none)
            let resolved = StatusRules.resolve(hook: item.hook, title: activity, now: now.timeIntervalSince1970)

            let since: Date
            if let previous = observed[item.tty], previous.status == resolved {
                since = previous.since
            } else if observed[item.tty] == nil {
                // First sighting: sessions that were already finished when we launched count as seen.
                since = item.hook.map { Date(timeIntervalSince1970: $0.lastEventAt) } ?? .distantPast
            } else {
                since = now
            }
            observed[item.tty] = (resolved, since)

            // Looking at the tab right now counts as having seen it.
            let viewing = terminalFront && tab.map { $0.isSelected && $0.isOnScreenTab && $0.windowOrder == 1 } == true
            if viewing { acknowledged[item.tty] = now }
            let seenAt = acknowledged[item.tty] ?? launchedAt
            var status: SessionStatus = (resolved == .done && since <= seenAt) ? .idle : resolved
            var waitingOn: String?
            if item.agent == .claude, status == .done || status == .idle {
                quiet.insert(item.tty)
                // Turn over but background work still running. Prefer the real processes (what and how
                // long); fall back to Claude's footer for background agents/tasks that aren't processes.
                if let jobs = BackgroundJobs.summary(item.backgroundJobs, now: now) ?? background[item.tty] {
                    status = .background
                    waitingOn = jobs
                }
            }

            var session = Session(
                tty: item.tty, agent: item.agent, pid: item.pid, startedAt: item.startedAt, cwd: item.cwd,
                project: item.project,
                task: SessionNaming.task(fromTitle: parsed?.text, project: item.project, firstPrompt: item.hook?.firstPrompt),
                status: status, statusSince: since,
                detail: waitingOn.map { "Waiting on \($0)" } ?? detail(for: status, hook: item.hook, agent: item.agent),
                hasHooks: item.hook != nil, inTerminalApp: tab != nil)
            session.isCurrent = viewing
            session.screenPosition = tab?.position
            session.terminalWindowID = tab?.windowID
            // Only the visible tab counts: a window full of session tabs sits on one desktop, but
            // you can only be looking at the selected one.
            session.onCurrentDesktop = tab?.isSelected == true && tab?.isOnScreenTab == true
                && (tab?.position?.desktop.map { currentDesktops.contains($0) } ?? false)
            if status == .working, let hook = item.hook, hook.lastEvent == "PreToolUse", let started = hook.toolStartedAt {
                session.activity = hook.toolDetail
                session.activitySince = Date(timeIntervalSince1970: started)
            }
            session.nameKeys = SessionKeys.keys(pid: item.pid, startedAt: item.startedAt, sessionId: item.hook?.sessionId)
            session.customName = names.name(for: session.nameKeys)
            if let root = item.projectRoot { noteProject(root, at: now) }
            if !viewing, let previous = displayed[item.tty], previous != status {
                if status == .needsInput {
                    onAttention?(session)
                } else if status == .done {
                    // Background work shows up in the footer a moment after the turn ends; only report
                    // "done" if it is still done once that has had time to appear.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.displayed[session.tty] == .done,
                              let current = self.sessions.first(where: { $0.tty == session.tty }) else { return }
                        self.onAttention?(current)
                    }
                }
            }
            displayed[item.tty] = status
            result.append(session)
        }
        let live = Set(raw.map(\.tty))
        observed = observed.filter { live.contains($0.key) }
        acknowledged = acknowledged.filter { live.contains($0.key) }
        displayed = displayed.filter { live.contains($0.key) }
        names.prune(liveKeys: Set(result.flatMap(\.nameKeys)))
        quietClaudeTTYs = quiet

        let frames = result.compactMap { $0.screenPosition?.frame }
        let hasTabGroups = Set(frames.map { "\($0)" }).count < frames.count
        let unavailable = hasTabGroups && !TabOrder.isTrusted
        if unavailable != tabOrderUnavailable { tabOrderUnavailable = unavailable }
        let ordered = SessionOrdering.sort(result, by: order)
        if ordered != sessions {
            // The debug status file only records statuses; don't rewrite it for detail/timer changes.
            let signature: (Session) -> String = { "\($0.tty)\($0.status.rawValue)\($0.screenPosition?.tabIndex ?? 0)" }
            let statusesChanged = ordered.map(signature) != sessions.map(signature)
            sessions = ordered
            if statusesChanged { AppStatus.write(sessions: ordered, terminalAccess: terminalAccess) }
        }
    }

    private func detail(for status: SessionStatus, hook: HookState?, agent: Agent) -> String? {
        switch status {
        case .needsInput:
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

    /// Hook writes land as atomic renames in the state dir; react to them immediately instead of waiting for the timer.
    private func watchStateDirectory() {
        try? FileManager.default.createDirectory(at: VibePaths.stateDir, withIntermediateDirectories: true)
        let fd = open(VibePaths.stateDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        // Busy sessions write several hook events per second; coalesce them into one refresh.
        source.setEventHandler { [weak self] in
            guard let self, !self.watcherRefreshPending else { return }
            self.watcherRefreshPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.watcherRefreshPending = false
                self.refresh()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}
