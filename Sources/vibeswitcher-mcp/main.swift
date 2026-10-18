// The project lead's tool server (MCP over stdio): `vibeswitcher-mcp --root <repo> [--role lead|worker|verifier]
// [--task <slug>]`. Claude Code starts it for each role's session (see `LeadLaunch`): the role and task are what
// the session host says this process's session holds (see `LeadVault`), `--role` and `--task` only say what it was
// started as. The tools live in `LeadToolset`; this file connects them to the session host,
// the steer inboxes and the hooks' state.
import Darwin
import Foundation
import VibeCore

// `vibeswitcher-mcp --test-failures FILE`, for scripts/test-under-load.sh: the failing tests in a saved `swift test`
// output, as the lead's tools report them; nothing printed when it shows none.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--test-failures" {
    let output = FileManager.default.contents(atPath: CommandLine.arguments[2]).map { String(decoding: $0, as: UTF8.self) } ?? ""
    if let summary = TestFailures(output: output).summary() { print(summary) }
    exit(0)
}

// A build switching to this one asks first whether it takes the session (see `MCPHandover`).
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == MCPHandover.probeFlag { MCPHandover.answerProbe() }

// The MCP session the build before handed over, when this process ran it a moment ago (the client goes on, with no
// new initialize). The role isn't in it: the toolset asks the session host, as at a fresh start.
let handover = MCPHandover.take()
if handover != nil { FileHandle.standardError.write(Data("vibeswitcher-mcp: switched in place to the new build\n".utf8)) }

/// For MCPHandoverTests: a server with no host behind it whose tools say which build answers.
/// `VIBESWITCHER_MCP_TEST_BUILD` names the build (a script standing in for one sets it), `VIBESWITCHER_MCP_TEST_BINARY`
/// is where it's installed. `VIBESWITCHER_MCP_TEST_HOST` plays the session host: a file that's there while the host
/// answers, holding the session's role ("" for none); `VIBESWITCHER_MCP_TEST_HOLD=1` holds a switch until it answers.
final class TestBuild: MCPToolset {
    let build: String
    /// Nil: no host played.
    let role: String?
    init(_ build: String, role: String?) {
        self.build = build
        self.role = role
    }

    var tools: [MCPToolInfo] {
        guard role != "" else { return [] }
        return [MCPToolInfo(name: "build", description: "Which build answers, and its process"),
                MCPToolInfo(name: "slow", description: "Answers after a while", properties: ["seconds": .init(type: "number", description: "How long")]),
                MCPToolInfo(name: "only-\(build)", description: "A tool only this build has")]
    }

    func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult {
        guard let role else {
            if name == "slow" { Thread.sleep(forTimeInterval: arguments["seconds"] as? Double ?? 1) }
            return MCPToolResult(text: "\(build) \(getpid())")
        }
        guard !role.isEmpty else { return MCPToolResult(text: "\(build) has no role", isError: true) }
        return MCPToolResult(text: "\(build) \(role) \(getpid())")
    }
}

let environment = ProcessInfo.processInfo.environment
if let build = environment["VIBESWITCHER_MCP_TEST_BUILD"], let installed = environment["VIBESWITCHER_MCP_TEST_BINARY"] {
    let host = environment["VIBESWITCHER_MCP_TEST_HOST"]
    let toolset = MCPHostedToolset(patience: environment["VIBESWITCHER_MCP_TEST_PATIENCE"].flatMap(Double.init) ?? 120,
                                   firstDelay: 0.05, longestDelay: 0.2, attempt: {
        guard let host else { return TestBuild(build, role: nil) }
        return (try? String(contentsOfFile: host, encoding: .utf8)).map { TestBuild(build, role: $0) }
    }, giveUp: { TestBuild(build, role: "") })
    let server = MCPServer(name: "vibeswitcher", version: "1", toolset: toolset,
                           watch: BinaryWatch(path: installed, running: handover?.binary), resuming: handover)
    if let host, environment["VIBESWITCHER_MCP_TEST_HOLD"] == "1" { server.switchWhen = { FileManager.default.fileExists(atPath: host) } }
    toolset.start { server.toolsSettled() }
    server.serve()
    exit(0)
}

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
                                            let sent = (try? HostCall.send(.input(id: id, bytes: Data(HostInput.bytes(forKey: "interrupt") ?? []), reply: false))) != nil
                                            usleep(300_000)
                                            return sent
                                        })
    }

    /// A host that can't be read is an error, never "no sessions": the tools that act on that answer (start a second
    /// worker in a live worktree, remove one) refuse with it.
    func sessions() throws -> [LeadSessionInfo] {
        try HostCall.sessions().map { session in
            LeadSessionInfo(id: session.id.uuidString, cwd: session.cwd, label: session.label, live: session.isLive,
                            status: session.isLive ? activity(of: session, agent: Self.agentPid(on: session.tty)).text : nil, tty: session.tty)
        }
    }

    func transcript(of session: String) throws -> String? {
        guard let hosted = try HostCall.sessions().first(where: { $0.id.uuidString == session }) else { return nil }
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
let arguments = Array(CommandLine.arguments.dropFirst())
// The repository, as `LeadToolset` reads it from the arguments.
var root = FileManager.default.currentDirectoryPath
var words = arguments.makeIterator()
while let word = words.next() {
    switch word {
    case "--root": root = words.next() ?? root
    case "--role", "--task": _ = words.next()
    default: break
    }
}

/// Whether the session host answers `vault`'s whoami, whatever it says (a role or none): it throws only when the host
/// can't be asked (not running, or restarting after an install as it hands over to its new build).
func hostAnswers(_ vault: LeadVault) -> Bool {
    do {
        _ = try vault.whoami(root: root)
        return true
    } catch {
        return false
    }
}

// The role comes from the session host, at a fresh start as after a switch of builds (never from the build before).
// The session can start before VibeSwitcher has bound its role to it: give that a moment. A host that can't be asked
// yet is asked again, for up to two minutes; one that answers decides.
let toolset = MCPHostedToolset(attempt: {
    guard hostAnswers(.standard) else { return nil }
    let toolset = LeadToolset(arguments: arguments, runtime: runtime, wait: 3)
    // No tools: that's the host's answer, unless it couldn't be asked by then either.
    return toolset.tools.isEmpty && !hostAnswers(.standard) ? nil : toolset
}, giveUp: { LeadToolset(arguments: arguments, runtime: runtime) })
// This binary as it is now: when an app update replaces it, the server switches to the new one between requests,
// once the session host answers (the new build asks it first thing).
let watch = BinaryWatch(path: runtime.server, running: handover?.binary)
let server = MCPServer(name: "vibeswitcher", version: "1", toolset: toolset, watch: watch, resuming: handover)
let quickVault = LeadVault(folder: LeadVault.standard.folder) { try HostCall.vault($0, timeout: 1) }
server.switchWhen = { hostAnswers(quickVault) }
toolset.start { server.toolsSettled() }
server.serve()
