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

    func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String) throws -> LeadDelivery.Delivered {
        let agent: LeadAgent
        switch target {
        case .agent(let known): agent = known
        case .session(let id):
            guard let tty = try HostCall.sessions().first(where: { $0.id.uuidString == id && $0.isLive })?.tty,
                  let pid = Self.agentPid(on: tty) else {
                throw HostCall.Failure(description: "That session isn't running an agent.")
            }
            agent = LeadAgent(pid: pid, tty: tty, session: id)
        }
        let session = agent.session ?? ((try? HostCall.sessions()) ?? []).first { $0.tty == agent.tty && $0.isLive }?.id.uuidString
        return try LeadDelivery.deliver(text, from: sender, to: agent, inputIsEmpty: session.flatMap(UUID.init(uuidString:)).map { id in {
            if case .screenText(_, let screen)? = try? HostCall.request(.screen(id: id)) { return TerminalInput.isEmpty(screen) }
            return false
        } }, typeInto: session.map { id in { [weak self] text in self?.type(id, text: text) ?? false } })
    }

    func sessions() -> [LeadSessionInfo] {
        ((try? HostCall.sessions()) ?? []).map { session in
            let state = HookState.load(from: VibePaths.stateFile(tty: session.tty))
            return LeadSessionInfo(id: session.id.uuidString, cwd: session.cwd, label: session.label, live: session.isLive,
                                   status: session.isLive ? state.map(Self.describe) : nil, tty: session.tty)
        }
    }

    func transcript(of session: String) -> String? {
        guard let tty = ((try? HostCall.sessions()) ?? []).first(where: { $0.id.uuidString == session })?.tty else { return nil }
        return HookState.load(from: VibePaths.stateFile(tty: tty))?.transcriptPath
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

    static func describe(_ state: HookState) -> String {
        switch state.lastEvent {
        case "Stop", "SessionEnd": return "finished its turn"
        case "Notification", "PermissionRequest": return "needs input"
        case "PreToolUse": return state.toolDetail.map { "working: \($0)" } ?? "working"
        default: return "working"
        }
    }
}

let toolset = LeadToolset(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment,
                          runtime: HostRuntime())
MCPServer(name: "vibeswitcher", version: "1", toolset: toolset).serve()
