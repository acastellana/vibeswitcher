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

// `vibeswitcher-mcp --verifier-prompt ROOT SLUG BASE MESSAGE_FILE auto|off`, for scripts/verifier-eval.sh: what an
// audit's single verifier starts with for the branch agent/SLUG against BASE in ROOT (a scratch clone, its own
// .vibeswitcher/workflow.md), as JSON: the prompt (LeadPrompts.verifier; the task's goal is the commit's message), the
// verifier's permission settings, the model audits run on (verifier_model, else another than ~/.claude's), and why
// the security checklist is in it (null when it isn't; off: never). No board, vault, host or session is read.
if CommandLine.arguments.count == 7, CommandLine.arguments[1] == "--verifier-prompt" {
    let (root, slug, base, file, mode) = (CommandLine.arguments[2], CommandLine.arguments[3], CommandLine.arguments[4],
                                          CommandLine.arguments[5], CommandLine.arguments[6])
    var workflow = LeadWorkflow.load(from: (root as NSString).appendingPathComponent(".vibeswitcher/workflow.md"))
    workflow.baseBranch = base
    let message = (try? String(contentsOfFile: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let title = message.split(separator: "\n").first.map { String($0.prefix(80)) } ?? slug
    let task = LeadTask(slug: slug, title: title, contract: LeadContract(goal: message, acceptance: [], boundaries: [], context: ""), status: .review)
    let head = Worktrees.branch(slug)
    let security = mode == "off" ? nil : LeadToolset.securityReason(root: root, head: head, workflow: workflow, raised: nil)
    let prompt = LeadPrompts.verifier(task: task, root: root, workflow: workflow, guide: LeadRisk.reviewGuide(root: root, base: base), security: security)
    let settings: [String: Any] = ["permissions": ["allow": LeadLaunch.allow(.verifier, base: base),
                                                   "deny": LeadLaunch.deny(.verifier, base: base, records: workflow.recordsDir)],
                                   "env": LeadLaunch.environment(.verifier)]
    let model = workflow.auditModel(workerModel: LeadWorkflow.claudeModel(command: "claude", home: NSHomeDirectory()))
    let out: [String: Any] = ["prompt": prompt, "settings": settings, "model": model, "security": security ?? NSNull()]
    let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    FileHandle.standardOutput.write(data)
    exit(data.isEmpty ? 1 : 0)
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
    let watch = BinaryWatch(path: installed, running: handover?.binary)
    // `VIBESWITCHER_MCP_TEST_RETRY`: how soon a build that couldn't take over is tried again (a minute otherwise).
    if let retry = environment["VIBESWITCHER_MCP_TEST_RETRY"].flatMap(Double.init) { watch.retry = retry }
    let server = MCPServer(name: "vibeswitcher", version: "1", toolset: toolset, watch: watch, resuming: handover)
    if let host, environment["VIBESWITCHER_MCP_TEST_HOLD"] == "1" { server.switchWhen = { FileManager.default.fileExists(atPath: host) } }
    toolset.start { server.toolsSettled() }
    server.stop(on: [SIGTERM, SIGHUP])
    server.serve()
    exit(0)
}

/// The real world behind the lead's tools.
final class HostRuntime: LeadRuntime {
    /// The session host its calls go to: the host's own socket unless `socketOverride` says another. The vault's
    /// calls stay on the host's own (`LeadVault.standard`).
    let socketOverride: String?
    var socket: String { socketOverride ?? VibePaths.hostSocket.path }
    init(socketOverride: String? = nil) { self.socketOverride = socketOverride }

    var server: String {
        Bundle.main.executablePath ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    /// The command's own --model, else Claude's settings in this process's home: what the workers start with.
    func workerModel(root: String) -> String? {
        LeadWorkflow.claudeModel(command: claudeCommand(root: root), home: VibePaths.home)
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

    func spawn(cwd: String, command: String, env: [String: String], label: String, agent: String, trust: Bool) throws -> String {
        let request = SpawnRequest(cwd: cwd, command: command, env: env, cols: 120, rows: 40, keepShell: false, label: label, agent: agent)
        switch try HostCall.request(.spawn(request), socket: socket) {
        case .spawned(let session):
            // A worktree is a new folder to Claude: answer its trust question for that folder (the user started
            // the lead in this repository), unless the lead says not to (a branch that brings its own settings).
            guard trust else { return session.id.uuidString }
            TrustPrompt.answer(folder: cwd, readScreen: {
                if case .screenText(_, let text)? = try? HostCall.request(.screen(id: session.id), socket: self.socket) { return text }
                return nil
            }, send: { writes in
                try? HostCall.type(writes, into: session.id, socket: self.socket)
            })
            return session.id.uuidString
        case .error(let message): throw HostCall.Failure(description: message)
        default: throw HostCall.Failure(description: "The session host didn't start the session.")
        }
    }

    func kill(_ session: String) throws {
        guard let id = UUID(uuidString: session) else { throw HostCall.Failure(description: "\(session) isn't a session of the host's.") }
        switch try HostCall.request(.kill(id: id), socket: socket, timeout: 3) {
        case .ok: return
        case .error(let message): throw HostCall.Failure(description: message)
        default: throw HostCall.Failure(description: "The session host answered something else; it may be older than the tool server.")
        }
    }

    func loadAverage() -> Double? { MacLoad.oneMinute() }

    func forget(_ session: String) {
        guard let id = UUID(uuidString: session) else { return }
        _ = try? HostCall.request(.remove(id: id), socket: socket, timeout: 3)
    }

    /// Types `text` as the session's prompt; false when the keys didn't all go in.
    func type(_ session: String, text: String) -> Bool {
        guard let id = UUID(uuidString: session) else { return false }
        // Claude Code takes bracketed paste; Enter follows as its own write. One unit: what the app or another tool
        // server types into the session meanwhile goes in before or after it, never between its text and its Enter.
        return (try? HostCall.type(ComposerText.writes(text, bracketed: true), into: id, socket: socket)) != nil
    }

    let observer = LeadObserver()

    func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String, clearDraft: Bool) throws -> LeadDelivery.Delivered {
        let hosted: [HostSession]
        let agent: LeadAgent
        switch target {
        case .agent(let known):
            // The lead, told of a report: its inbox takes the message even when the host doesn't answer.
            hosted = (try? HostCall.sessions(socket: socket)) ?? []
            agent = known
        case .session(let id):
            hosted = try HostCall.sessions(socket: socket)
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
                                        styledScreen: { [socket] in HostCall.styledScreen(id, socket: socket) },
                                        typeInto: { [weak self] text in self?.type(id.uuidString, text: text) ?? false },
                                        clearDraft: clearDraft,
                                        clear: {
                                            // One ^C empties Claude's box (two in a row would quit it); then a moment to redraw.
                                            let sent = (try? HostCall.send(.input(id: id, bytes: Data(HostInput.bytes(forKey: "interrupt") ?? []), reply: false), socket: self.socket)) != nil
                                            usleep(300_000)
                                            return sent
                                        })
    }

    /// A host that can't be read is an error, never "no sessions": the tools that act on that answer (start a second
    /// worker in a live worktree, remove one) refuse with it.
    func sessions() throws -> [LeadSessionInfo] {
        try HostCall.sessions(socket: socket).map { session in
            let reading = session.isLive ? waiting(session, agent: Self.agentPid(on: session.tty)) : nil
            return LeadSessionInfo(id: session.id.uuidString, cwd: session.cwd, label: session.label, live: session.isLive,
                                   status: reading?.activity.text, tty: session.tty, pid: session.childPID, waiting: reading?.waiting)
        }
    }

    func transcript(of session: String) throws -> String? {
        guard let hosted = try HostCall.sessions(socket: socket).first(where: { $0.id.uuidString == session }) else { return nil }
        // An ended session's terminal may hold another agent now: only its own hooks' record counts.
        let pid = hosted.isLive ? Self.agentPid(on: hosted.tty) : nil
        return observer.transcript(hosted, hook: hosted.isLive ? observer.hook(hosted, agentPid: pid) : nil)
    }

    /// What the session's agent is doing, with the background shells it still waits on.
    private func activity(of session: HostSession, agent pid: Int32?) -> LeadActivity {
        observer.activity(session, agentPid: pid, background: background(of: pid))
    }

    /// As `activity`, with the prompt it waits on in full (see `PendingPrompt`).
    private func waiting(_ session: HostSession, agent pid: Int32?) -> (activity: LeadActivity, waiting: PendingPrompt?) {
        observer.waiting(session, agentPid: pid, background: background(of: pid))
    }

    /// The background shells of its own the agent still waits on, in words.
    private func background(of pid: Int32?) -> String? {
        var background: String?
        if let pid, let processes = ProcessTable.trySnapshot() {
            let jobs = BackgroundJobs.jobs(forAgent: pid, in: processes, arguments: {
                ProcessTable.arguments(pid: $0.pid, start: Int($0.startTime.timeIntervalSince1970), comm: $0.comm)
            })
            if let first = jobs.first {
                background = jobs.count == 1 ? "1 shell: \(first.command.prefix(80))" : "\(jobs.count) shells"
            }
        }
        return background
    }

    func currentAgent() -> LeadAgent? {
        guard let agent = ProcessTable.ancestors(of: getpid()).first(where: { $0.agent != nil }), let tty = agent.tty else { return nil }
        let session = ((try? HostCall.sessions(socket: socket)) ?? []).first { $0.tty == tty && $0.isLive }?.id.uuidString
        return LeadAgent(pid: agent.pid, tty: tty, session: session)
    }

    func isRunning(_ agent: LeadAgent) -> Bool {
        ProcessTable.info(pid: agent.pid).map { $0.tty == agent.tty && $0.agent != nil } ?? false
    }

    /// The oldest agent process on a terminal (the session's own, not a tool it runs); nil when there's none, or the
    /// process table couldn't be read in time.
    static func agentPid(on tty: String) -> Int32? {
        ProcessTable.trySnapshot()?.values.filter { $0.tty == tty && $0.agent != nil }.min { $0.startTime < $1.startTime }?.pid
    }
}

// For DroppedHostTests: VIBESWITCHER_MCP_TEST_RUNTIME_SOCKET is the host the runtime's calls go to (sessions, spawn,
// kill, input), the vault's staying on the host's own socket.
let runtime = HostRuntime(socketOverride: environment["VIBESWITCHER_MCP_TEST_RUNTIME_SOCKET"])
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

/// The server, once made: the lead's automatic steps run as its calls do (see `MCPServer.background`).
final class ServerSlot: @unchecked Sendable { var server: MCPServer? }
let slot = ServerSlot()

// The role comes from the session host, at a fresh start as after a switch of builds (never from the build before).
// The session can start before VibeSwitcher has bound its role to it: give that a moment. A host that can't be asked
// yet is asked again, for up to two minutes; one that answers decides.
let toolset = MCPHostedToolset(attempt: {
    guard hostAnswers(.standard) else { return nil }
    let toolset = LeadToolset(arguments: arguments, runtime: runtime, wait: 3)
    // Merges and audits hold the Mac-wide test and build lock around their tests, as `vs-heavy` does.
    toolset.testLock = TestLock.standard()
    // The risk check's model pass (see `LeadRisk`): headless Claude, as the all-done summary's, from the diff's stat,
    // the contract and REVIEW.md only.
    toolset.riskModel = ClaudeHeadless.risk
    // No tools: that's the host's answer, unless it couldn't be asked by then either.
    if toolset.tools.isEmpty && !hostAnswers(.standard) { return nil }
    // The lead's decision and progress logs go into the repository every few minutes (and after each merge), each
    // commit as the server's background work: an install's switch waits for it, never cutting it halfway.
    toolset.keepRecords { work in slot.server?.background(work) ?? false }
    // Finished work moves on by itself (auto_advance), each run of passes as the server's background work: an install's
    // switch waits for it, and the new build's first pass takes what's still due.
    toolset.startAdvancing { work in slot.server?.background(work) ?? false }
    return toolset
}, giveUp: {
    let toolset = LeadToolset(arguments: arguments, runtime: runtime)
    toolset.testLock = TestLock.standard()
    return toolset
})
// This binary as it is now: when an app update replaces it, the server switches to the new one between requests,
// once the session host answers (the new build asks it first thing).
let watch = BinaryWatch(path: runtime.server, running: handover?.binary)
let server = MCPServer(name: "vibeswitcher", version: "1", toolset: toolset, watch: watch, resuming: handover)
slot.server = server
let quickVault = LeadVault(folder: LeadVault.standard.folder) { try HostCall.vault($0, timeout: 1) }
server.switchWhen = { hostAnswers(quickVault) }
toolset.start { server.toolsSettled() }
// SIGTERM (the host's orphan sweep) and SIGHUP end it as its input's end does: its running calls are cancelled (a
// merge's test command stopped, its scratch worktree removed) before it exits.
server.stop(on: [SIGTERM, SIGHUP])
server.serve()
