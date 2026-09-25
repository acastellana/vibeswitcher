import AppKit
import Combine
import Foundation
import VibeCore

/// Polls processes, hook state files and Terminal tabs; publishes the ordered list of sessions.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var terminalAccess: TerminalAccess = .unknown
    @Published private(set) var hooksInstalled: [Agent: Bool] = [:]

    private let scanner = SessionScanner()
    private let queue = DispatchQueue(label: "vibeswitcher.scan", qos: .utility)
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var scanning = false
    private var rescanRequested = false

    // Scan-queue only.
    private var tabs: [String: TerminalTab] = [:]
    private var lastTerminalQuery = Date.distantPast

    // Main-thread only.
    private let launchedAt = Date()
    private var observed: [String: (status: SessionStatus, since: Date)] = [:]
    private var acknowledged: [String: Date] = [:]

    func start() {
        refreshHookStatus()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        watchStateDirectory()
    }

    func refreshHookStatus() {
        hooksInstalled = Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0, HookInstaller.isInstalled(agent: $0)) })
    }

    /// Marks a finished session as seen, turning it from green (done) to grey (idle).
    func acknowledge(_ session: Session) {
        acknowledged[session.tty] = Date()
        refresh()
    }

    func refresh(forceTerminal: Bool = false) {
        guard !scanning else { rescanRequested = true; return }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            let raw = self.scanner.scan(now: now)
            var access: TerminalAccess?
            // AppleScript is the expensive part; query at most every 2s unless forced.
            if forceTerminal || now.timeIntervalSince(self.lastTerminalQuery) >= 2 {
                let result = TerminalBridge.tabs()
                self.tabs = result.tabs
                access = result.access
                self.lastTerminalQuery = now
            }
            let tabs = self.tabs
            DispatchQueue.main.async {
                if let access { self.terminalAccess = access }
                self.apply(raw: raw, tabs: tabs, now: now)
                self.scanning = false
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.refresh()
                }
            }
        }
    }

    /// Synchronous scan on the calling (main) thread, used by `--snapshot`.
    func refreshNow() {
        let now = Date()
        let result = TerminalBridge.tabs()
        terminalAccess = result.access
        apply(raw: scanner.scan(now: now), tabs: result.tabs, now: now)
    }

    private func apply(raw: [RawSession], tabs: [String: TerminalTab], now: Date) {
        let terminalFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalBridge.bundleID
        var result: [Session] = []
        for item in raw {
            let tab = tabs[item.tty]
            let parsed = tab.map { StatusRules.parseTitle($0.title) }
            // Claude's ✳/spinner glyph is meaningful; Codex titles carry no activity glyph.
            let activity = item.agent == .claude ? (parsed?.activity ?? .none) : .none
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
            if terminalFront, let tab, tab.isSelected, tab.windowOrder == 1 {
                acknowledged[item.tty] = now
            }
            let seenAt = acknowledged[item.tty] ?? launchedAt
            let status: SessionStatus = (resolved == .done && since <= seenAt) ? .idle : resolved

            result.append(Session(
                tty: item.tty, agent: item.agent, pid: item.pid, startedAt: item.startedAt, cwd: item.cwd,
                title: displayTitle(parsed: parsed?.text, cwd: item.cwd, agent: item.agent),
                status: status, statusSince: since,
                detail: detail(for: status, hook: item.hook, hasHooks: item.hook != nil, agent: item.agent),
                hasHooks: item.hook != nil, inTerminalApp: tab != nil))
        }
        let live = Set(raw.map(\.tty))
        observed = observed.filter { live.contains($0.key) }
        acknowledged = acknowledged.filter { live.contains($0.key) }

        let ordered = SessionOrdering.sort(result)
        if ordered != sessions { sessions = ordered }
    }

    private func displayTitle(parsed: String?, cwd: String?, agent: Agent) -> String {
        if let parsed, !parsed.isEmpty, parsed != "Terminal", parsed != agent.rawValue { return parsed }
        if let cwd { return (cwd as NSString).lastPathComponent }
        return agent.displayName
    }

    private func detail(for status: SessionStatus, hook: HookState?, hasHooks: Bool, agent: Agent) -> String? {
        switch status {
        case .needsInput:
            if let notice = hook?.notice { return notice }
            switch hook?.toolName {
            case "AskUserQuestion", "request_user_input": return "Asking you a question"
            case "ExitPlanMode": return "Plan ready for review"
            default: return "Waiting for you"
            }
        case .working:
            if let prompt = hook?.lastPrompt { return "› " + prompt }
            return hook?.toolName.map { "Running \($0)" }
        case .done, .idle:
            return hook?.lastMessage
        case .unknown:
            guard !hasHooks else { return nil }
            return agent == .codex ? "No live status yet: run /hooks in this Codex session and trust vibeswitcher-hook"
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
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}
