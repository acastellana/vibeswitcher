import Foundation

/// Which hosted sessions are agents, and which process is each one's agent, from the session host's own record of what
/// it started, never from a process's name (the node, Linux).
///
/// The session host starts every lead, worker and verifier itself (`SpawnRequest`): it records the agent the request
/// names (`HostSession.agent`), the program it started (`childPID`, its pid and start ticks as `HostedSession`'s
/// `programToken`) and the terminal it gave it (`tty`), and carries that record across a handover
/// (`HostHandover.Session.info`; the program isn't restarted, so `childPID` stays its pid). A hosted terminal's agent is
/// that program: `bash --noprofile --norc -c '<command>'` execs a role's one simple command in its own place, so the
/// program the host started is the agent; while it is still that shell (a command it didn't exec), the agent is the
/// shell's oldest child on the terminal. Nothing else on the terminal is: not a tool the agent runs, not a process a
/// plain shell session (`agent` nil) runs, whatever it is named. Which role a session holds stays the vault's binding.
///
/// `ProcessTable.identify` named a process an agent by `comm` or `argv[0]`, which any process of the user's can choose:
/// the first real node's lead, run as `~/.local/share/claude/versions/2.1.328`, was taken for no agent and heard nothing
/// for hours (`VersionedClaude`, 2026-11-19). Each reader here answers `nil` for a terminal the host didn't start (the
/// user's own terminals, a hook's or scan's), and always on the Mac (`enabled`), so the caller falls back to the process
/// table there, as before. Callers: the engine's `leadRuns` (delivery and wake-ups), `NodeSessions`' scan (`overlay`),
/// and the tool server's `currentAgent`, `isRunning` (`runsForTeam`), `steer` and `agentPid(on:)` (one-line hooks).
public enum HostedAgents {
    /// The node's (Linux): the Mac app has no node, and its sessions keep the process table's answer.
    public static var enabled: Bool { !Platform.CodeIdentity.isAvailable }

    /// How a reader looks at the processes (tests give a table).
    public struct Reader {
        public var info: (Int32) -> ProcInfo?
        public var arguments: (Int32) -> [String]
        public var table: () -> [Int32: ProcInfo]?

        public init(info: @escaping (Int32) -> ProcInfo?, arguments: @escaping (Int32) -> [String],
                    table: @escaping () -> [Int32: ProcInfo]?) {
            self.info = info
            self.arguments = arguments
            self.table = table
        }

        public static let live = Reader(info: { ProcessTable.info(pid: $0) }, arguments: { ProcessTable.commandLine(pid: $0) },
                                        table: { ProcessTable.trySnapshot() })

        /// A table's reader: argv from `arguments`, by pid.
        public static func table(_ table: [Int32: ProcInfo], arguments: [Int32: [String]] = [:]) -> Reader {
            Reader(info: { table[$0] }, arguments: { arguments[$0] ?? [] }, table: { table })
        }
    }

    /// The live session the host runs on `tty`.
    static func session(on tty: String?, in hosted: [HostSession]) -> HostSession? {
        guard let tty else { return nil }
        return hosted.first { $0.isLive && $0.tty == tty }
    }

    /// The agent the host recorded for `session`, nil for a plain shell.
    public static func agent(of session: HostSession) -> Agent? { session.agent.flatMap(Agent.init(rawValue:)) }

    /// The process that is `session`'s agent: the program the host started, on the session's terminal, or while that is
    /// still the host's shell, the shell's oldest child there. Nil when the session isn't live, was started as no agent,
    /// or its program isn't on its terminal now.
    public static func agentPid(of session: HostSession, reader: Reader = .live) -> Int32? {
        guard session.isLive, agent(of: session) != nil, let program = reader.info(session.childPID), program.tty == session.tty else { return nil }
        guard isHostShell(reader.arguments(session.childPID)) else { return session.childPID }
        return reader.table()?.values.filter { $0.ppid == session.childPID && $0.tty == session.tty }.min { $0.startTime < $1.startTime }?.pid
    }

    /// argv of the shell the host starts a command in (`Platform.Tools.sessionShellArguments`), before it execs it.
    static func isHostShell(_ argv: [String]) -> Bool {
        let shell = Array(Platform.Tools.sessionShellArguments(shell: "/bin/bash", command: "", keepShell: false).dropLast())
        return argv.count > shell.count && Array(argv.prefix(shell.count)) == shell
    }

    /// `decided` when a reader here decided (its `.some(nil)`: no agent), else what `fallback` (the process table) says.
    public static func decided(_ decided: LeadAgent??, or fallback: () -> LeadAgent?) -> LeadAgent? {
        if let decided { return decided }
        return fallback()
    }

    /// The agent running on `tty`, as `LeadAgent.running(on:session:in:)` gives it: `.some(nil)` when the host runs a
    /// session there with no agent of its record running; nil when the host runs none there (or not `enabled`): the
    /// process table decides.
    public static func running(on tty: String, session id: String?, hosted: [HostSession], reader: Reader = .live,
                               enabled: Bool = enabled) -> LeadAgent?? {
        guard enabled, let session = session(on: tty, in: hosted) else { return nil }
        guard let pid = agentPid(of: session, reader: reader) else { return .some(nil) }
        return .some(LeadAgent(pid: pid, tty: tty, session: id ?? session.id.uuidString, agent: agent(of: session)))
    }

    /// Whether `agent` is the agent of the session the host runs on its terminal; nil when the host runs none there (or
    /// not `enabled`): the process table decides.
    public static func runs(_ agent: LeadAgent, hosted: [HostSession], reader: Reader = .live, enabled: Bool = enabled) -> Bool? {
        guard enabled, let session = session(on: agent.tty, in: hosted) else { return nil }
        return agentPid(of: session, reader: reader) == agent.pid
    }

    /// `runs`, for a tool server, which the host shows only its own team's sessions (`mayKill`: a worker's list holds no
    /// lead): a terminal not in `hosted` is decided too, by `agent.pid` still being a process on it, never by its name.
    /// A worker can't see through the host that it's the lead's program; the engine, which sees every session, checks
    /// that (`runs`) before anything is typed into the lead, and the vault's binding names the session. Nil only when not
    /// `enabled`.
    public static func runsForTeam(_ agent: LeadAgent, hosted: [HostSession], reader: Reader = .live, enabled: Bool = enabled) -> Bool? {
        guard enabled else { return nil }
        return runs(agent, hosted: hosted, reader: reader, enabled: true) ?? (reader.info(agent.pid)?.tty == agent.tty)
    }

    /// The agent a process with these `ancestors` (nearest first) runs under: the nearest that is a hosted session's
    /// agent. `.some(nil)` when one of them is a hosted session's program but none is its agent (a plain shell session,
    /// or a process under one that only names itself an agent); nil when none is a hosted session's (or not `enabled`).
    public static func current(ancestors: [ProcInfo], hosted: [HostSession], reader: Reader = .live, enabled: Bool = enabled) -> LeadAgent?? {
        guard enabled else { return nil }
        var inHosted = false
        for process in ancestors {
            guard let session = session(on: process.tty, in: hosted) else { continue }
            if process.pid == session.childPID { inHosted = true }
            if agentPid(of: session, reader: reader) == process.pid, let tty = process.tty {
                return .some(LeadAgent(pid: process.pid, tty: tty, session: session.id.uuidString, agent: agent(of: session)))
            }
        }
        return inHosted ? .some(nil) : nil
    }

    /// `table` with each hosted terminal's agent as the host recorded it: a hosted session's agent process is that agent
    /// (whatever its name), every other process on a hosted terminal is none. Every other terminal's processes are as
    /// the table read them on the user's node; on a scratch node (`scratch`) none is an agent: it lists no session it
    /// didn't start. Not `enabled`: `table` as it is.
    public static func overlay(_ table: [Int32: ProcInfo], hosted: [HostSession], scratch: Bool, reader: Reader? = nil,
                               enabled: Bool = enabled) -> [Int32: ProcInfo] {
        guard enabled else { return table }
        let reader = reader ?? .table(table, arguments: [:]).with(arguments: { ProcessTable.commandLine(pid: $0) })
        let live = Dictionary(hosted.filter(\.isLive).map { ($0.tty, $0) }, uniquingKeysWith: { $1 })
        let agents = Dictionary(live.compactMap { tty, session in agentPid(of: session, reader: reader).map { (tty, ($0, agent(of: session))) } },
                                uniquingKeysWith: { $1 })
        var result = table
        for (pid, process) in table {
            let agent: Agent?
            if let tty = process.tty, live[tty] != nil {
                agent = agents[tty].flatMap { $0.0 == pid ? $0.1 : nil }
            } else if scratch {
                agent = nil
            } else {
                continue
            }
            guard agent != process.agent || process.identityUnknown else { continue }
            result[pid] = ProcInfo(pid: pid, ppid: process.ppid, tty: process.tty, comm: process.comm, startTime: process.startTime,
                                   agent: agent, identityUnknown: false)
        }
        return result
    }
}

extension HostedAgents.Reader {
    /// This reader, its argv read by `arguments`.
    func with(arguments: @escaping (Int32) -> [String]) -> HostedAgents.Reader {
        HostedAgents.Reader(info: info, arguments: arguments, table: table)
    }
}
