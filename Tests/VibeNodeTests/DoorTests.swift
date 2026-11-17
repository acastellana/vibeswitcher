import Foundation
import Testing
@testable import VibeCore

/// What stands for a box's init (the session sandbox plan's SB1) until the shim builds one: a listener at a scratch
/// path (the door), each connection it takes handed whole over the porter's door line, as init hands it, and closed
/// here.
final class DoorStandIn: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let source: DispatchSourceRead

    init(_ scratch: Scratch, rig: PorterRig) throws {
        path = try scratch.shortFolder("door").appendingPathComponent("door").path
        listener = try UnixSocket.listen(path: path)
        source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: DispatchQueue(label: "door-stand-in"))
        let listening = listener
        source.setEventHandler {
            while true {
                let connection = Platform.Sockets.accept(listening)
                guard connection >= 0 else { return }
                _ = Platform.Sockets.sendDescriptor(connection, over: rig.doorLine)
                Sys.close(connection)
            }
        }
        source.setCancelHandler { Sys.close(listening) }
        source.resume()
    }

    deinit { source.cancel() }
}

/// What stands for the host on a session's connector (SB5's `SessionConnector`): each byte asked on it is answered with
/// one end of a new stream pair, and the other end served as a host serves a connection: a welcome to the hello, every
/// steered message's seal valid to the vault, `.ok` to the rest. It counts what it was asked.
final class ConnectorHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "connector-host")
    private var sources: [DispatchSourceRead] = []
    private var decoders: [Int32: HostFrameDecoder] = [:]
    private(set) var asked: [HostRequest] = []
    private(set) var connections = 0

    init(connector: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: connector, queue: queue)
        source.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            guard recv(connector, &byte, 1, 0) == 1, let self, let pair = Platform.Sockets.pair(type: Platform.Sockets.stream) else { return }
            _ = Platform.Sockets.sendDescriptor(pair.1, over: connector)
            Sys.close(pair.1)
            self.connections += 1
            self.serve(pair.0)
        }
        source.resume()
        sources.append(source)
    }

    var count: Int { queue.sync { connections } }
    var requests: [HostRequest] { queue.sync { asked } }

    private func serve(_ fd: Int32) {
        UnixSocket.configure(fd)
        decoders[fd] = HostFrameDecoder()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Sys.read(fd, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            guard count > 0 else { return self.drop(fd) }
            self.decoders[fd]?.append(Data(buffer[0..<count]))
            while let frame = try? self.decoders[fd]?.next() {
                guard let envelope = try? HostCoding.decode(HostRequestEnvelope.self, from: frame.payload) else { continue }
                self.asked.append(envelope.request)
                switch envelope.request {
                case .hello:
                    self.send(.welcome(protocolVersion: HostProtocol.version, hostBuild: 42, sessions: [], capabilities: [], pid: 4242,
                                       startedAt: Date()), replyTo: envelope.seq, on: fd)
                case .vault(.verify(let messages)):
                    self.send(.vault(.verified(messages.map { _ in true })), replyTo: envelope.seq, on: fd)
                default:
                    self.send(.ok, replyTo: envelope.seq, on: fd)
                }
            }
        }
        source.setCancelHandler { Sys.close(fd) }
        source.resume()
        sources.append(source)
    }

    private func send(_ event: HostEvent, replyTo: Int?, on fd: Int32) {
        guard let payload = try? HostCoding.encode(HostEventEnvelope(replyTo: replyTo, event: event)) else { return }
        let frame = HostFrame.encode(.control, payload)
        _ = frame.withUnsafeBytes { Platform.Sockets.send(fd, $0.baseAddress, $0.count) }
    }

    private func drop(_ fd: Int32) {
        decoders[fd] = nil
    }

    deinit { sources.forEach { $0.cancel() } }
}

/// The door end to end (the session sandbox plan's SB4): the built tool server and hook as relays inside (only the door
/// variable says so), the built tool server as the porter outside, a door stand-in for init and a connector stand-in
/// for the host. "Inside" and "outside" are two scratch homes: what a helper writes lands in the outside one.
@Suite(.timeLimit(.minutes(5)))
struct DoorTests {
    private let scratch = Scratch()
    static let worker = SessionHelper(role: "worker", root: "/r/main", task: "t1")
    /// The hook's contract with its agent: it answers within 3 s (`vibeswitcher-hook`'s alarm).
    static let hookBudget: TimeInterval = 3

    /// The porter, its door and its host, with the outside's VibeSwitcher folder short enough for a decoy at its host
    /// socket's path.
    struct World {
        let rig: PorterRig
        let door: DoorStandIn
        let host: ConnectorHost
        /// Outside: the porter's VibeSwitcher folder.
        let outside: URL
        /// Inside: the relays' home folder.
        let inside: URL
    }

    func world(_ helper: SessionHelper = Self.worker, environment extra: [String: String] = [:]) throws -> World {
        let outside = try scratch.shortFolder("out")
        let rig = try PorterRig(scratch, helper: helper, hostSocket: outside.appendingPathComponent("host.sock").path,
                                environment: extra.merging(["VIBESWITCHER_HOME": outside.path]) { $1 })
        let inside = scratch.url("inside")
        try FileManager.default.createDirectory(at: inside.appendingPathComponent("home"), withIntermediateDirectories: true)
        return World(rig: rig, door: try DoorStandIn(scratch, rig: rig), host: ConnectorHost(connector: rig.connector),
                     outside: outside, inside: inside)
    }

    /// The relays' environment: the inside's scratch home, the door, and `extra`.
    func insideEnvironment(_ world: World, _ extra: [String: String] = [:]) -> [String: String] {
        scratchEnvironment(world.inside, extra.merging([DoorProtocol.variable: world.door.path]) { $1 })
    }

    /// The built tool server started with `arguments` in `environment`, its stdin and stdout pipes kept here.
    func startToolServer(_ arguments: [String], environment: [String: String]) throws -> (pid: pid_t, pipes: RelayPipes) {
        let pipes = try RelayPipes()
        var spawn = Platform.Spawn(executable: builtProducts.appendingPathComponent("vibeswitcher-mcp").path,
                                   arguments: ["vibeswitcher-mcp"] + arguments)
        spawn.environment = environment.map { "\($0.key)=\($0.value)" }
        spawn.stdin = .descriptor(pipes.given[0])
        spawn.stdout = .descriptor(pipes.given[1])
        spawn.stderr = .descriptor(pipes.given[2])
        let started = spawn.start()
        pipes.closeGiven()
        return (try started.get(), pipes)
    }

    /// One hook event through `hook` (the built one), run by a stand-in for Claude Code on a terminal of its own (a
    /// `sh` named `claude`, under `script`). `ready` is told the agent's pid and terminal before the event goes in. The
    /// relay's exit status, what it printed, the agent's pid and terminal, and how long the hook took.
    struct HookRun {
        var status: Int32?
        var output: String
        var agent: pid_t
        var tty: String
        var took: TimeInterval
    }

    func runHook(_ event: [String: Any], environment: [String: String], ready: (pid_t, String) throws -> Void = { _, _ in }) async throws -> HookRun {
        let folder = scratch.url("agent")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let agent = folder.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(atPath: agent.path, withDestinationPath: "/bin/sh")
        try JSONSerialization.data(withJSONObject: event).write(to: folder.appendingPathComponent("event.json"))
        let hook = builtProducts.appendingPathComponent("vibeswitcher-hook").path
        let script = """
            cd \(FakeClaude.quoted(folder.path)) || exit 1
            echo $$ $(tty) > who.tmp && mv who.tmp who
            while [ ! -e go ]; do sleep 0.02; done
            started=$(date +%s%N)
            \(FakeClaude.quoted(hook)) claude < event.json > out
            echo $? $(( $(date +%s%N) - started )) > status.tmp && mv status.tmp status
            """
        try script.write(to: folder.appendingPathComponent("agent.sh"), atomically: true, encoding: .utf8)
        var spawn = Platform.Spawn(executable: "/usr/bin/script", arguments: [
            "script", "-q", "-e", "-c", "\(FakeClaude.quoted(agent.path)) \(FakeClaude.quoted(folder.appendingPathComponent("agent.sh").path))", "/dev/null"])
        spawn.environment = environment.map { "\($0.key)=\($0.value)" }
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        spawn.stderr = .path("/dev/null", flags: O_WRONLY)
        let runner = try spawn.start().get()
        defer { kill(runner, SIGKILL); _ = collected(runner, by: MacTime.real.awake() + 10) }
        let who = folder.appendingPathComponent("who")
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: who.path) })
        let words = try String(contentsOf: who, encoding: .utf8).split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let pid = try #require(words.first.flatMap { pid_t($0) })
        let tty = try #require(words.dropFirst().first.map { "tty" + $0.dropFirst("/dev/".count).replacingOccurrences(of: "/", with: "") })
        try ready(pid, tty)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("go").path, contents: Data())
        let statusFile = folder.appendingPathComponent("status")
        _ = await eventually(timeout: 60) { FileManager.default.fileExists(atPath: statusFile.path) }
        // "<status> <nanoseconds the hook took>", as the agent's shell measured it.
        let ended = ((try? String(contentsOf: statusFile, encoding: .utf8)) ?? "").split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let status = ended.first.flatMap { Int32($0) }
        let took = ended.dropFirst().first.flatMap { Double($0) }.map { $0 / 1e9 } ?? .infinity
        let output = (try? String(contentsOf: folder.appendingPathComponent("out"), encoding: .utf8)) ?? ""
        return HookRun(status: status, output: output, agent: pid, tty: tty, took: took)
    }

    static let prompt: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "door-session", "prompt": "hi",
                                        "cwd": "/r/main/.vibeswitcher/worktrees/t1"]

    // MARK: Tests

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no door"))
    func aToolCallMadeInsideIsAnsweredByTheToolServerOutside() async throws {
        // The porter's own environment naming a door: a helper that kept it would relay to the porter again.
        let world = try world(environment: testBuildEnvironment("outside").merging([DoorProtocol.variable: "/run/vibeswitcher/door"]) { $1 })
        // Were the relay to serve itself, it would answer as "inside".
        let relay = try startToolServer([MCPKeeper.flag, "--role", "lead", "--root", "/etc"],
                                        environment: insideEnvironment(world, testBuildEnvironment("inside")))
        relay.pipes.write(buildToolCall)
        let line = relay.pipes.line(containing: "outside ")
        let helper = try #require(answeringPid(line, build: "outside"), "\(String(describing: line)) \(world.rig.log)")
        #expect(helper != relay.pid)
        if case .brief(let brief) = Platform.Processes.brief(helper) { #expect(brief.ppid == world.rig.pid) }
        #expect(Platform.Processes.arguments(helper).dropFirst() == ["--role", "worker", "--root", "/r/main", "--task", "t1"])
        // Its input's end ends the helper, and the relay with its status.
        relay.pipes.closeInput()
        let status = await offPool { collected(relay.pid, by: MacTime.real.awake() + 60) }
        #expect(status == 0)
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no door"))
    func aHooksEventWritesTheStateFileOfItsSessionsTerminal() async throws {
        let world = try world()
        let run = try await runHook(Self.prompt, environment: insideEnvironment(world))
        #expect(run.status == 0, "\(world.rig.log)")
        let state = world.outside.appendingPathComponent("state/\(run.tty).json")
        let written = try #require(HookState.load(from: state), "\(world.rig.log)")
        #expect(written.lastEvent == "UserPromptSubmit")
        #expect(written.agentPid == run.agent)
        #expect(written.tty == run.tty)
        // Nothing of it inside.
        #expect(!FileManager.default.fileExists(atPath: world.inside.appendingPathComponent("vibeswitcher/state").path))
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no door"))
    func aHooksOutputAndExitStatusComeBack() async throws {
        let world = try world()
        let run = try await runHook(Self.prompt, environment: insideEnvironment(world)) { pid, tty in
            let message = SteerMessage(text: "through the door", from: .lead("lead"), agentPid: pid)
            try SteerInbox.post(message, tty: tty, root: world.outside, sealer: SteerSeal(seal: { _ in "sealed" }, verify: { _ in nil }))
        }
        #expect(run.status == 0)
        #expect(run.output.contains("through the door"), "\(run.output) \(world.rig.log)")

        // A helper's status other than 0 comes back as the relay's own.
        let failing = try self.world(environment: testBuildEnvironment("outside").merging(["VIBESWITCHER_MCP_TEST_EXIT": "3"]) { $1 })
        let relay = try startToolServer([MCPKeeper.flag, "--role", "worker", "--root", "/r/main"], environment: insideEnvironment(failing))
        let status = await offPool { collected(relay.pid, by: MacTime.real.awake() + 60) }
        #expect(status.map { ($0 >> 8) & 0xff } == 3, "\(failing.rig.log)")
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no door"))
    func aHookThroughTheDoorAnswersWithinItsThreeSeconds() async throws {
        let world = try world()
        let through = try await runHook(Self.prompt, environment: insideEnvironment(world))
        // The same hook run plain, on the outside's folders, for the time the door adds.
        var plainEnvironment = scratchEnvironment(world.inside)
        plainEnvironment["VIBESWITCHER_HOME"] = world.outside.path
        let plain = try await runHook(Self.prompt, environment: plainEnvironment)
        #expect(through.status == 0 && plain.status == 0)
        #expect(through.took < Self.hookBudget, "through the door: \(through.took) s")
        print("door timing: a hook through the door took \(through.took) s, plain \(plain.took) s, added \(through.took - plain.took) s")
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no door"))
    func aSteerMessageIsDeliveredThroughTheDoor() async throws {
        let world = try world()
        var posted: (id: String, tty: String)?
        let run = try await runHook(Self.prompt, environment: insideEnvironment(world)) { pid, tty in
            let message = SteerMessage(text: "steered in", from: .lead("lead"), agentPid: pid)
            try SteerInbox.post(message, tty: tty, root: world.outside, sealer: SteerSeal(seal: { _ in "sealed" }, verify: { _ in nil }))
            posted = (message.id, tty)
        }
        let (id, tty) = try #require(posted)
        #expect(run.output.contains("steered in"))
        #expect(SteerInbox.delivered(tty: tty, root: world.outside).contains(id), "\(world.rig.log)")
        // Its seal was checked by the host, through the session's connector.
        #expect(world.host.requests.contains { if case .vault(.verify) = $0 { return true } else { return false } })
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no door"))
    func theHelpersReachTheHostOnlyThroughTheSessionsConnector() async throws {
        let world = try world()
        // A decoy at the host socket's path: a helper that connected by the path would be counted here.
        let decoy = try UnixSocket.listen(path: world.outside.appendingPathComponent("host.sock").path)
        defer { Sys.close(decoy) }
        _ = try await runHook(Self.prompt, environment: insideEnvironment(world)) { pid, tty in
            try SteerInbox.post(SteerMessage(text: "x", from: .lead("lead"), agentPid: pid), tty: tty, root: world.outside,
                                sealer: SteerSeal(seal: { _ in "sealed" }, verify: { _ in nil }))
        }
        #expect(world.host.count > 0)
        #expect(Platform.Sockets.accept(decoy) < 0 && errno == EAGAIN, "a helper connected by the host socket's path")
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no door"))
    func theStatusLineAndThePermissionHookWorkThroughTheDoor() async throws {
        let world = try world()
        // The user's own status line, in the outside's home: run outside, its output back inside.
        let home = world.rig.folder.appendingPathComponent("home/.claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"statusLine": {"type": "command", "command": "echo outside-status"}}"#.write(to: home.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        // A project's own status line, in a folder a box writes: never run outside.
        let project = scratch.url("project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try #"{"statusLine": {"type": "command", "command": "echo project-status"}}"#.write(to: project.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        let status = try startToolServer([UsageStatusLine.argument], environment: insideEnvironment(world))
        status.pipes.write(#"{"cwd": "\#(project.path)", "workspace": {"current_dir": "\#(project.path)", "project_dir": "\#(project.path)"}}"#)
        status.pipes.closeInput()
        let shown = status.pipes.line(containing: "status")
        #expect(shown == "outside-status", "\(String(describing: shown)) \(world.rig.log)")
        #expect(await offPool { collected(status.pid, by: MacTime.real.awake() + 60) } == 0)

        // The permission hook: a read in the worker's worktree is allowed, judged outside by the host's root.
        let root = scratch.url("root")
        let worktree = Worktrees.path(root: root.path, slug: "t1")
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let judged = try self.world(SessionHelper(role: "worker", root: root.path, task: "t1"))
        let permission = try startToolServer([ReadOnlyCommand.hookArgument, "--root", "/"], environment: insideEnvironment(judged))
        let event: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "cwd": worktree,
                                    "tool_input": ["command": "git status"]]
        permission.pipes.write(String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self))
        permission.pipes.closeInput()
        let answer = permission.pipes.line(containing: "allow", within: 30) ?? ""
        #expect(answer.contains("allow"), "\(answer) \(judged.rig.log)")
        #expect(await offPool { collected(permission.pid, by: MacTime.real.awake() + 60) } == 0)
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no door"))
    func withNoDoorTheToolServerAndTheHookRunAsBefore() async throws {
        let folder = try scratch.shortFolder("plain")
        let environment = scratchEnvironment(folder, testBuildEnvironment("plain"))
        let server = try startToolServer([MCPKeeper.flag, "--role", "worker", "--root", "/r/main"], environment: environment)
        server.pipes.write(buildToolCall)
        let helper = try #require(answeringPid(server.pipes.line(containing: "plain "), build: "plain"))
        // Itself, or the server its keeper runs: never a porter's.
        #expect(helper == server.pid || Platform.Processes.brief(helper).isChild(of: server.pid))
        server.pipes.closeInput()
        _ = await offPool { collected(server.pid, by: MacTime.real.awake() + 60) }

        var hookEnvironment = scratchEnvironment(folder)
        hookEnvironment["VIBESWITCHER_HOME"] = folder.appendingPathComponent("vs").path
        let run = try await runHook(Self.prompt, environment: hookEnvironment)
        #expect(run.status == 0)
        #expect(HookState.load(from: folder.appendingPathComponent("vs/state/\(run.tty).json"))?.agentPid == run.agent)
    }

    @Test func theMacsToolServerNeverRelays() {
        let environment = [DoorProtocol.variable: DoorProtocol.path]
        if Platform.CodeIdentity.isAvailable {
            #expect(DoorRelay.door(environment: environment) == nil)
            // Returns: on the Mac this process goes on.
            DoorRelay.runIfConfined(DoorRelay.toolServerMode, arguments: ["vibeswitcher-mcp"], environment: environment)
        } else {
            #expect(DoorRelay.door(environment: environment) == DoorProtocol.path)
        }
        #expect(DoorRelay.door(environment: [:]) == nil)
        #expect(DoorRelay.door(environment: [DoorProtocol.variable: "relative/door"]) == nil)
    }
}

private extension Platform.Processes.BriefRead {
    func isChild(of parent: pid_t) -> Bool {
        if case .brief(let brief) = self { return brief.ppid == parent }
        return false
    }
}
