// The project lead's tool server (MCP over stdio): `vibeswitcher-mcp --root <repo> [--role lead|worker|verifier]
// [--task <slug>]`. Claude Code starts it for each role's session (see `LeadLaunch`), with the session's capability
// in `VIBESWITCHER_LEAD_CAPABILITY`: the role and task are the capability's (see `LeadVault`), `--role` and `--task`
// only say what it was started as. The tools live in `LeadToolset`; this file connects them to the session host,
// the steer inboxes and the hooks' state.
import Darwin
import Foundation
import VibeCore

/// The real world behind the lead's tools.
final class HostRuntime: LeadRuntime {
    var server: String {
        Bundle.main.executablePath ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    func claudeCommand(root: String) -> String {
        // The same command the app starts Claude with (its preferences), so workers run like your own sessions.
        let preferences = UserDefaults(suiteName: "dev.vibeswitcher.VibeSwitcher")
        let presets = LaunchPresets.load(from: VibePaths.presetsFile,
                                         claudeCommand: preferences?.string(forKey: "claudeCommand") ?? "claude",
                                         codexCommand: preferences?.string(forKey: "codexCommand") ?? "codex")
        let preset = presets.presets(for: root).first { $0.agent == .claude && $0.place == .window }
            ?? presets.presets(for: root).first { $0.agent == .claude }
        return preset.flatMap(LaunchPlan.command(for:)) ?? "claude"
    }

    func spawn(cwd: String, command: String, label: String, agent: String, trust: Bool) throws -> String {
        let request = SpawnRequest(cwd: cwd, command: command, env: [:], cols: 120, rows: 40, keepShell: false, label: label, agent: agent)
        switch try HostCall.request(.spawn(request)) {
        case .spawned(let session):
            // A worktree is a new folder to Claude: answer its trust question for that folder (the user started
            // the lead in this repository), unless the lead says not to (a branch that brings its own settings).
            guard trust else { return session.id.uuidString }
            TrustPrompt.answer(folder: cwd, readScreen: {
                if case .screenText(_, let text)? = try? HostCall.request(.screen(id: session.id)) { return text }
                return nil
            }, send: { writes in
                for write in writes {
                    if write.delay > 0 { usleep(useconds_t(write.delay * 1_000_000)) }
                    try? HostCall.send(.input(id: session.id, bytes: Data(write.bytes), reply: false))
                }
            })
            return session.id.uuidString
        case .error(let message): throw HostCall.Failure(description: message)
        default: throw HostCall.Failure(description: "The session host didn't start the session.")
        }
    }

    func kill(_ session: String) {
        guard let id = UUID(uuidString: session) else { return }
        _ = try? HostCall.request(.kill(id: id), timeout: 3)
    }

    func forget(_ session: String) {
        guard let id = UUID(uuidString: session) else { return }
        _ = try? HostCall.request(.remove(id: id), timeout: 3)
    }

    /// Types `text` as the session's prompt; false when the keys didn't all go out.
    func type(_ session: String, text: String) -> Bool {
        guard let id = UUID(uuidString: session) else { return false }
        // Claude Code takes bracketed paste; Enter follows as its own write.
        for write in ComposerText.writes(text, bracketed: true) {
            if write.delay > 0 { usleep(useconds_t(write.delay * 1_000_000)) }
            guard (try? HostCall.send(.input(id: id, bytes: Data(write.bytes), reply: false))) != nil else { return false }
        }
        return true
    }

    let observer = LeadObserver()

    func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String, clearDraft: Bool) throws -> LeadDelivery.Delivered {
        let hosted: [HostSession]
        let agent: LeadAgent
        switch target {
        case .agent(let known):
            // The lead, told of a report: its inbox takes the message even when the host doesn't answer.
            hosted = (try? HostCall.sessions()) ?? []
            agent = known
        case .session(let id):
            hosted = try HostCall.sessions()
            guard let tty = hosted.first(where: { $0.id.uuidString == id && $0.isLive })?.tty, let pid = Self.agentPid(on: tty) else {
                throw HostCall.Failure(description: "That session isn't running an agent.")
            }
            agent = LeadAgent(pid: pid, tty: tty, session: id)
        }
        let session = hosted.first { hosted in hosted.isLive && (agent.session.map { $0 == hosted.id.uuidString } ?? (hosted.tty == agent.tty)) }
        // Not a window session: only its hooks can take the message.
        guard let session else {
            return try LeadDelivery.deliver(text, from: sender, to: agent, activity: observer.activity(of: agent), screen: nil, typeInto: nil)
        }
        let id = session.id
        return try LeadDelivery.deliver(text, from: sender, to: agent, activity: activity(of: session, agent: agent.pid),
                                        styledScreen: { HostCall.styledScreen(id) },
                                        typeInto: { [weak self] text in self?.type(id.uuidString, text: text) ?? false },
                                        clearDraft: clearDraft,
                                        clear: {
                                            // One ^C empties Claude's box (two in a row would quit it); then a moment to redraw.
                                            try? HostCall.send(.input(id: id, bytes: Data(HostInput.bytes(forKey: "interrupt") ?? []), reply: false))
                                            usleep(300_000)
                                        })
    }

    func sessions() -> [LeadSessionInfo] {
        ((try? HostCall.sessions()) ?? []).map { session in
            LeadSessionInfo(id: session.id.uuidString, cwd: session.cwd, label: session.label, live: session.isLive,
                            status: session.isLive ? activity(of: session, agent: Self.agentPid(on: session.tty)).text : nil, tty: session.tty)
        }
    }

    func transcript(of session: String) -> String? {
        guard let hosted = ((try? HostCall.sessions()) ?? []).first(where: { $0.id.uuidString == session }) else { return nil }
        // An ended session's terminal may hold another agent now: only its own hooks' record counts.
        let pid = hosted.isLive ? Self.agentPid(on: hosted.tty) : nil
        return observer.transcript(hosted, hook: hosted.isLive ? observer.hook(hosted, agentPid: pid) : nil)
    }

    /// What the session's agent is doing, with the background shells it still waits on.
    private func activity(of session: HostSession, agent pid: Int32?) -> LeadActivity {
        var background: String?
        if let pid, let processes = ProcessTable.trySnapshot() {
            let jobs = BackgroundJobs.jobs(forAgent: pid, in: processes, arguments: {
                ProcessTable.arguments(pid: $0.pid, start: Int($0.startTime.timeIntervalSince1970), comm: $0.comm)
            })
            if let first = jobs.first {
                background = jobs.count == 1 ? "1 shell: \(first.command.prefix(80))" : "\(jobs.count) shells"
            }
        }
        return observer.activity(session, agentPid: pid, background: background)
    }

    func currentAgent() -> LeadAgent? {
        guard let agent = ProcessTable.ancestors(of: getpid()).first(where: { $0.agent != nil }), let tty = agent.tty else { return nil }
        let session = ((try? HostCall.sessions()) ?? []).first { $0.tty == tty && $0.isLive }?.id.uuidString
        return LeadAgent(pid: agent.pid, tty: tty, session: session)
    }

    func isRunning(_ agent: LeadAgent) -> Bool {
        ProcessTable.info(pid: agent.pid).map { $0.tty == agent.tty && $0.agent != nil } ?? false
    }

    /// The oldest agent process on a terminal (the session's own, not a tool it runs).
    static func agentPid(on tty: String) -> Int32? {
        ProcessTable.snapshot().values.filter { $0.tty == tty && $0.agent != nil }.min { $0.startTime < $1.startTime }?.pid
    }
}

let runtime = HostRuntime()
// This binary as it is now: an app update replaces it under the running server, which then says so in its results.
let watch = BinaryWatch(path: runtime.server)
let toolset = LeadToolset(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment,
                          runtime: runtime)
MCPServer(name: "vibeswitcher", version: "1", toolset: toolset, watch: watch).serve()
