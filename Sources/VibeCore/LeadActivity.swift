import Foundation

/// What a team member's agent is doing, as the lead's tools tell it and act on it.
///
/// Nothing tells this alone. The hooks' state file (one per terminal) says what the last hook event was, but hooks
/// fire only at a turn's steps: a tool that runs for minutes fires nothing, and the file can be missing (a terminal
/// the app's scan didn't take for an agent's has its file deleted 15 s after each write). The transcript has every
/// step as it's taken, but not the prompts on screen (a permission, a question). So both are read, and the one
/// written last wins; no state at all is `unknown`, never idle.
public enum LeadActivity: Equatable, Sendable {
    /// Mid-turn; what it's doing, when the hooks said.
    case working(String?)
    /// Stopped on a question or a permission prompt (what it asks, when known).
    case needsInput(String?)
    /// Between turns; `background` is work of its own it still waits on (its turn resumes when that reports back).
    case idle(background: String?)
    /// Its turn ended on an API error rather than on its reply: it's between turns, but not done.
    case apiError(String)
    /// Neither its hooks nor its transcript say anything yet.
    case unknown

    /// It takes a typed prompt now (anything else gets messages at its next step, through its hooks).
    public var betweenTurns: Bool {
        switch self {
        case .idle, .apiError: return true
        case .working, .needsInput, .unknown: return false
        }
    }

    /// One line for the lead's status and sessions.
    public var text: String {
        switch self {
        case .working(let detail): return detail.map { "working: \($0)" } ?? "working"
        case .needsInput(let asked): return asked.map { "needs input: \($0)" } ?? "needs input"
        case .idle(nil): return "finished its turn"
        case .idle(let background?): return "finished its turn; its background work still runs (\(background))"
        case .apiError(let error): return "its turn ended on an API error (\(error)); message it to go on"
        case .unknown: return "running (nothing from its hooks or transcript yet)"
        }
    }

    /// The hooks' last event and the transcript's tail, put together: the one written later wins, except that a
    /// prompt on screen (which the transcript can't show) stands while the transcript only shows the call that raised it.
    public static func resolve(hook: HookState?, transcript: TranscriptTail?, background: String? = nil) -> LeadActivity {
        let fromHook = hook.map(StatusRules.status(for:))
        let hookAt = hook?.lastEventAt ?? -.infinity
        if let transcript, hook == nil || (transcript.at ?? -.infinity) > hookAt {
            switch transcript.state {
            case .toolCall where fromHook == .needsInput:
                return .needsInput(hook?.request ?? hook?.notice)
            case .toolCall, .thinking:
                return .working(fromHook == .working ? hook?.toolDetail : nil)
            case .turnOver(let error):
                return error.map(LeadActivity.apiError) ?? .idle(background: background)
            }
        }
        switch fromHook {
        case .working?:
            return .working(hook?.toolDetail)
        case .needsInput?:
            return .needsInput(hook?.request ?? hook?.notice)
        case .done?, .idle?:
            // Claude's "waiting for your input" notice a minute after a turn that ended on an error is still that error.
            if case .turnOver(let error?)? = transcript?.state { return .apiError(error) }
            return .idle(background: background)
        default:
            return .unknown
        }
    }
}

/// What VibeSwitcher reads about a window session's agent without asking it anything: its hooks' state, its
/// transcript and what that says it's doing. Paths are injectable for tests.
public struct LeadObserver {
    public var home: String
    public var stateFile: (String) -> URL

    public init(home: String = NSHomeDirectory(), stateFile: @escaping (String) -> URL = VibePaths.stateFile(tty:)) {
        self.home = home
        self.stateFile = stateFile
    }

    /// The hooks' state for the session's terminal, when it's this session's: a terminal outlives its session, and
    /// a state file left by an earlier agent there says nothing about this one.
    public func hook(_ session: HostSession, agentPid: Int32?) -> HookState? {
        guard let state = HookState.load(from: stateFile(session.tty)) else { return nil }
        if let agentPid, let pid = state.agentPid, pid != agentPid { return nil }
        if state.lastEventAt < session.startedAt.timeIntervalSince1970 - 2 { return nil }
        return state
    }

    /// Its transcript: where its hooks say it is, or else found in Claude's folder for its directory by the name it
    /// was started with (see `TranscriptLocator`). Only paths inside the agents' own folders.
    public func transcript(_ session: HostSession, hook: HookState?) -> String? {
        if let path = hook?.transcriptPath, TranscriptReader.checkedURL(path, home: home) != nil { return path }
        guard session.agent == nil || session.agent == Agent.claude.rawValue else { return nil }
        let name = session.command.flatMap(LeadLaunch.name(inCommand:))
        return TranscriptLocator.claude(cwd: session.cwd, name: name, startedAt: session.startedAt, home: home)
            .flatMap { TranscriptReader.checkedURL($0, home: home) != nil ? $0 : nil }
    }

    public func activity(_ session: HostSession, agentPid: Int32?, background: String? = nil) -> LeadActivity {
        reading(session, agentPid: agentPid, background: background).activity
    }

    /// The activity with the transcript's tail it was read from (when its last step was written).
    public func reading(_ session: HostSession, agentPid: Int32?, background: String? = nil) -> (activity: LeadActivity, tail: TranscriptTail?) {
        let hook = hook(session, agentPid: agentPid)
        let tail = transcript(session, hook: hook).flatMap { TranscriptTail.read(url: URL(fileURLWithPath: $0)) }
        return (LeadActivity.resolve(hook: hook, transcript: tail, background: background), tail)
    }

    /// For an agent outside the window (no session to search by): its hooks' state, if it's this agent's, and the
    /// transcript they name.
    public func activity(of agent: LeadAgent) -> LeadActivity {
        var hook = HookState.load(from: stateFile(agent.tty))
        if let pid = hook?.agentPid, pid != agent.pid { hook = nil }
        let tail = hook?.transcriptPath.flatMap { TranscriptReader.checkedURL($0, home: home) }.flatMap { TranscriptTail.read(url: $0.0) }
        return LeadActivity.resolve(hook: hook, transcript: tail)
    }
}
