import Foundation
import Testing
import VibeCore
import VibeNode

/// `vibeswitcher-server` as the session host's server child, against a process-started scratch node (`ScratchNode`;
/// the engine plan's E1, the security architecture document's S2, S3 and S6).
@Suite(NodeTraits.linuxOnly)
struct ServerTests {
    private let scratch = Scratch()

    @Test func theServerIsNotDumpable() async throws {
        let node = try await ScratchNode(scratch)
        let server = try #require(node.serverPID, "\(node.said)")
        let fd = open("/proc/\(server)/mem", O_RDONLY | O_CLOEXEC)
        let code = errno
        if fd >= 0 { close(fd) }
        #expect(fd < 0 && code == EACCES, "opened /proc/\(server)/mem: fd \(fd), errno \(code)")
        #expect(Platform.Processes.isDumpable(server) == false)
    }

    @Test func anUnknownRequestIsAnsweredNotFatal() async throws {
        let node = try await ScratchNode(scratch)
        let client = try WireClient(node)
        let unknown = try #require(WireClient.reply(client.request("no.such.kind")))
        #expect(unknown.ok == false && unknown.error?.code == "unknown-kind", "\(unknown)")
        // The connection stays open: status on it is answered.
        let status = try #require(WireClient.reply(client.request("status", action: nil)))
        #expect(status.ok, "\(status)")
        #expect(status.result?["node"]?.string == "local")
    }

    @Test func aMustUnderstandRequestNobodyKnowsClosesTheConnection() async throws {
        let node = try await ScratchNode(scratch)
        let client = try WireClient(node)
        let messages = client.request("no.such.kind", must: true)
        let reply = try #require(WireClient.reply(messages), "\(messages)")
        #expect(reply.error?.code == "unknown-kind")
        // The answer, then bye and the close.
        let rest = messages + client.next()
        #expect(WireClient.bye(rest) != nil, "\(rest.map { String(decoding: $0, as: UTF8.self) })")
        #expect(client.closed())
    }

    @Test func aNewerVersionIsAnsweredAndClosed() async throws {
        let node = try await ScratchNode(scratch)
        let client = try WireClient(node)
        let messages = client.request("status", action: nil, v: NodeWire.version + 1)
        let reply = try #require(WireClient.reply(messages))
        #expect(reply.ok == false && reply.error?.code == "version", "\(reply)")
        #expect(WireClient.bye(messages + client.next()) != nil)
        #expect(client.closed())
    }

    @Test func statusThroughTheServerListsWhatTheProbeLists() async throws {
        let node = try await ScratchNode(scratch)
        // Stage 1's fake agent, on a session of the node's host: a copy of `sleep` named `claude`, with its state file.
        let project = node.home.appendingPathComponent("project")
        let bin = node.root.appendingPathComponent("fake-bin")
        for folder in [project, bin] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let claude = bin.appendingPathComponent("claude")
        // Copied through a close-on-exec descriptor: a child another test forks meanwhile can't hold it open for
        // writing, which refuses the exec below ("Text file busy") and ended the session before the agent ran.
        try copyClosedOnExec(URL(fileURLWithPath: "/bin/sleep").resolvingSymlinksInPath().path, to: claude.path)
        let session = try await node.spawn("exec '\(claude.path)' 600", cwd: project.path)
        var found: pid_t = 0
        let started = await eventually(timeout: 60) {
            found = Platform.Processes.children(session.childPID).first ?? session.childPID
            return ProcessTable.info(pid: found)?.comm == "claude" || ProcessTable.info(pid: session.childPID)?.comm == "claude"
        }
        try #require(started, "the fake agent never ran")
        let agent = ProcessTable.info(pid: session.childPID)?.comm == "claude" ? session.childPID : found
        var state = HookState(agent: .claude, tty: session.tty, lastEvent: "PermissionRequest", lastEventAt: Date().timeIntervalSince1970)
        state.agentPid = agent
        state.cwd = project.path
        let states = node.root.appendingPathComponent("state")
        try VibePaths.ensurePrivate(states)
        try state.save(to: states.appendingPathComponent("\(session.tty).json"))

        func listed(_ arguments: [String]) async throws -> [String: Any]? {
            let ran = try await node.run(arguments)
            guard ran.status == 0, let report = try JSONSerialization.jsonObject(with: Data(ran.output.utf8)) as? [String: Any],
                  let sessions = report["sessions"] as? [[String: Any]] else { return nil }
            return sessions.first { $0["terminal"] as? String == session.tty }
        }
        // The server scans every 2 s: wait until it lists the session as the hook says.
        var served: [String: Any]?
        var seen = false
        let deadline = MacTime.real.awake() + 60
        while !seen, MacTime.real.awake() < deadline {
            served = try await listed(["status", "--json"])
            seen = served?["status"] as? String == "needs-you"
            if !seen { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        #expect(seen, "\(node.said)")
        let probed = try #require(try await listed(["status", "--probe", "--json"]))
        // Compared by terminal, agent and status (their ids differ by EN-D4: the server's names the host session).
        for key in ["terminal", "agent", "status"] {
            #expect(served?[key] as? String == probed[key] as? String, "\(key): \(String(describing: served)) vs \(probed)")
        }
        #expect(served?["id"] as? String == NodeIds.session(host: session.id))
        // The plain form shows the standing plain-mode line, and names the scratch node on stderr.
        let plain = try await node.run(["status"])
        #expect(plain.status == 0, "\(plain.errors)")
        #expect(plain.output.contains("plain mode: no sandbox"), "\(plain.output)")
        #expect(plain.output.contains(session.tty), "\(plain.output)")
        #expect(plain.errors.contains("scratch node at \(node.root.standardizedFileURL.path)"), "\(plain.errors)")
    }

    @Test func anUnlistedRequestIsRefused() async throws {
        let node = try await ScratchNode(scratch)
        let client = try WireClient(node)
        // Kinds the protocol names that this server doesn't take yet, and kinds no list names (`lead` is taken from E4,
        // the cards and the lead's questions from E6).
        for kind in ["hooks.install", "hooks.remove", "build.switch", "shell", "exec", ""] {
            let reply = try #require(WireClient.reply(client.request(kind, args: ["folder": .string("/")])), "\(kind)")
            #expect(reply.ok == false && reply.error?.code == "unknown-kind", "\(kind): \(reply)")
        }
        #expect(client.hello.kinds == NodeWire.taken)
        #expect(Set(NodeWire.taken) == Set(NodeWire.kinds.keys).subtracting(["hooks.install", "hooks.remove", "build.switch"]))
        let status = try #require(WireClient.reply(client.request("status", action: nil))?.result)
        #expect(status["accepted"]?.array?.isEmpty == true, "\(status)")
    }

    @Test func aRequestFromAnotherSenderOnTheServersSocketIsRefused() async throws {
        let node = try await ScratchNode(scratch)
        let client = try WireClient(node)
        // A helper writes a request on this test's connection.
        var line = NodeWire.line(NodeWire.Request(id: "forged", kind: "status"))
        line.removeLast()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "printf '%s\\n' \"$0\"", String(decoding: line, as: UTF8.self)]
        helper.standardOutput = FileHandle(fileDescriptor: client.fd, closeOnDealloc: false)
        helper.standardInput = FileHandle.nullDevice
        try helper.run()
        #expect(await exited(helper, within: 30))
        let messages = client.next(timeout: 30)
        #expect(WireClient.reply(messages) == nil, "\(messages.map { String(decoding: $0, as: UTF8.self) })")
        #expect(WireClient.bye(messages)?.reason.contains("another process") == true)
        #expect(client.closed())
        #expect(await eventually(timeout: 30) { node.said.contains("bytes on it came from another process") }, "\(node.said)")
    }

    @Test func theServersSocketIsTheUsersAlone() async throws {
        let node = try await ScratchNode(scratch)
        var info = stat()
        try #require(lstat(node.serverSocket, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600, "\(String(info.st_mode & 0o777, radix: 8))")
        try #require(stat(node.root.appendingPathComponent("v2").path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700, "\(String(info.st_mode & 0o777, radix: 8))")
        // The uid check at accept, as a pure function: another user, or one that can't be read, is refused.
        #expect(NodeServer.admits(peerUID: getuid(), ownUID: getuid()))
        #expect(!NodeServer.admits(peerUID: getuid() + 1, ownUID: getuid()))
        #expect(!NodeServer.admits(peerUID: nil, ownUID: getuid()))
    }

    @Test func theServersSocketIsBoundAgainWhenReplaced() async throws {
        let node = try await ScratchNode(scratch, housekeeping: 1)
        let epoch = try WireClient(node).hello.epoch
        let impostor = node.root.appendingPathComponent("v2/impostor").path
        try #require(FileManager.default.createFile(atPath: impostor, contents: Data("not a socket".utf8)))
        try #require(rename(impostor, node.serverSocket) == 0)
        let back = await eventually(timeout: 60) {
            var info = stat()
            guard lstat(node.serverSocket, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return false }
            return (try? WireClient(node))?.hello.epoch == epoch
        }
        #expect(back, "\(node.said)")
        #expect(node.said.contains("named another file: bound again"), "\(node.said)")
    }

    @Test func theServersSocketIsBoundAgainWhenItsFolderIsMoved() async throws {
        let node = try await ScratchNode(scratch, housekeeping: 1)
        let epoch = try WireClient(node).hello.epoch
        let folder = node.root.appendingPathComponent("v2")
        try FileManager.default.moveItem(at: folder, to: node.root.appendingPathComponent("v2-aside"))
        // The folder made again (0700) and the socket bound in it, by the same server.
        let back = await eventually(timeout: 60) { (try? WireClient(node))?.hello.epoch == epoch }
        #expect(back, "\(node.said)")
        var info = stat()
        #expect(lstat(folder.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        // And the new folder is the one watched: a file renamed over the path there is replaced too.
        let impostor = folder.appendingPathComponent("impostor").path
        try #require(FileManager.default.createFile(atPath: impostor, contents: Data("not a socket".utf8)))
        try #require(rename(impostor, node.serverSocket) == 0)
        let again = await eventually(timeout: 60) {
            var info = stat()
            guard lstat(node.serverSocket, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return false }
            return (try? WireClient(node))?.hello.epoch == epoch
        }
        #expect(again, "\(node.said)")
    }

    @Test func aSessionsProcessCannotStopTheNode() async throws {
        let node = try await ScratchNode(scratch)
        let out = node.root.appendingPathComponent("stop.out").path
        let command = "VIBESWITCHER_HOME='\(node.root.path)' '\(commandLine.path)' stop >'\(out)' 2>&1; echo \"exit $?\" >>'\(out)'"
        let session = try await node.spawn(command)
        // The command line asks its typed word on the session's terminal: the code is typed there, so the server
        // judges the request.
        var code = ""
        let asked = await eventually(timeout: 60) {
            guard let screen = HostCall.styledScreen(session.id, socket: node.socket, appKey: nil)?.text,
                  let range = screen.range(of: #"Type ([A-Z]{4}) and Enter"#, options: .regularExpression) else { return false }
            code = String(screen[range].dropFirst(5).prefix(4))
            return true
        }
        try #require(asked, "the command line never asked: \(String(describing: HostCall.styledScreen(session.id, socket: node.socket, appKey: nil)?.text))")
        try HostCall.send(.input(id: session.id, bytes: Data((code + "\r").utf8), reply: false), socket: node.socket, appKey: nil)
        let ended = await eventually(timeout: 60) { ((try? String(contentsOfFile: out, encoding: .utf8)) ?? "").contains("exit ") }
        let said = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        #expect(ended, "\(said)")
        #expect(said.contains("exit 77"), "\(said)")
        #expect(said.contains("voice: not the user's voice"), "\(said)")
        // The node runs on, and accepted nothing.
        let client = try WireClient(node)
        let status = try #require(WireClient.reply(client.request("status", action: nil))?.result)
        #expect(status["accepted"]?.array?.isEmpty == true)
        #expect(status["notices"]?.array?.isEmpty == true)
        #expect(node.process.isRunning)
    }

    @Test func aStopFromTheUserEndsEverySessionThenTheHost() async throws {
        let node = try await ScratchNode(scratch)
        let lead = try await node.spawn("sleep 600", label: "Lead · project")
        let other = try await node.spawn("sleep 600")
        let server = try #require(node.serverPID)
        let ran = try await node.runOnTerminal(["stop"])
        #expect(ran.status == 0, "\(ran.output)")
        // The confirmation counts what the stop ends: the host's live sessions (two plain programs, no agent on any
        // terminal the scan lists), not the scan's agents (the review of S3).
        #expect(ran.output.contains("This ends 2 sessions in all projects"), "\(ran.output)")
        #expect(ran.output.contains("2 sessions ended"), "\(ran.output)")
        // Every session ended, then the host, and with it the server.
        #expect(await exited(node.process, within: 60), "\(node.said)")
        for pid in [lead.childPID, other.childPID, server] {
            #expect(await eventually(timeout: 30) { kill(pid, 0) != 0 && errno == ESRCH }, "pid \(pid) still runs")
        }
        #expect(node.said.contains("stop: ending 1 leads and 1 other sessions"), "\(node.said)")
        #expect(node.said.contains("shutdown accepted") || (try? String(contentsOfFile: node.root.appendingPathComponent("host.log").path, encoding: .utf8))?.contains("shutdown accepted") == true)
    }

    @Test func anAcceptedRequestIsShownByStatus() async throws {
        let node = try await ScratchNode(scratch)
        let ran = try await node.runOnTerminal(["start"])
        #expect(ran.status == 0, "\(ran.output)")
        let shown = try await node.run(["status", "--json"])
        #expect(shown.status == 0, "\(shown.errors)")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(shown.output.utf8)) as? [String: Any])
        let accepted = try #require(report["accepted"] as? [[String: Any]])
        #expect(accepted.count == 1, "\(accepted)")
        let first = try #require(accepted.first)
        #expect(first["kind"] as? String == "start")
        #expect((first["pid"] as? Int ?? 0) > 0)
        #expect(first["cgroup"] as? String == ScratchNode.ownScope)
        #expect((first["commandLine"] as? [String])?.last == "start", "\(first)")
        // The command line wrote it to the journal: no mark for it.
        let journal = report["journal"] as? [String] ?? []
        #expect(!journal.contains { $0.contains("no entry") }, "\(journal)")
        #expect(node.recorder?.entries.contains { $0.event == "request" && $0.kind == "start" && $0.action == first["action"] as? String } == true)
        let plain = try await node.run(["status"])
        #expect(plain.output.contains("accepted: start"), "\(plain.output)")

        // E6: an answer, recorded in the vault before it acts, is shown too (after the lead's start).
        let lead = try await node.askingLead("Name the parser?", options: ["Parser", "Reader"])
        let answered = try await node.runOnTerminal(["answer", lead.card, "Reader"])
        #expect(answered.status == 0, "\(answered.output)\n\(node.said)")
        let after = try await node.run(["status", "--json"])
        let again = try #require(try JSONSerialization.jsonObject(with: Data(after.output.utf8)) as? [String: Any])
        let kinds = (again["accepted"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        #expect(kinds == ["start", "lead", "answer"], "\(kinds)")
        let answer = try #require((again["accepted"] as? [[String: Any]])?.last)
        #expect(answer["subject"] as? String == lead.card)
        #expect(node.recorder?.entries.contains { $0.event == "request" && $0.kind == "answer" && $0.action == answer["action"] as? String } == true)
    }

    @Test func everyHostCallInTheServerGoesThroughTheConnector() async throws {
        let node = try await ScratchNode(scratch, housekeeping: 1)
        _ = try WireClient(node)
        // E6: a card to answer once the path is taken (its lead's tool server reaches the host by the path, as sessions do).
        let lead = try await node.askingLead("Name the parser?", options: ["Parser", "Reader"])
        // The host's socket moved aside, a recording listener put at its path.
        try #require(rename(node.socket, node.socket + ".aside") == 0)
        let listener = try UnixSocket.listen(path: node.socket)
        defer { Sys.close(listener) }
        let moved = Date()
        let notesAfter: () -> Date? = {
            guard let client = try? WireClient(node), let reply = WireClient.reply(client.request("status", action: nil)),
                  let at = reply.result?["host"]?["notes"]?["at"]?.string else { return nil }
            return NodeWire.date(at)
        }
        var at: Date?
        let fresh = await eventually(timeout: 60) {
            at = notesAfter()
            return at.map { $0 > moved.addingTimeInterval(1) } == true
        }
        #expect(fresh, "notes at \(String(describing: at)), moved at \(moved): \(node.said)")
        // E6: the answer is recorded in the vault and its `.user` message sealed by the host, through the connector.
        let answered = try await node.runOnTerminal(["answer", lead.card, "Parser"])
        #expect(answered.status == 0, "\(answered.output)\n\(node.said)")
        let inbox = node.root.appendingPathComponent("steer/\(lead.session.tty).jsonl")
        let message = Locked<SteerMessage?>(nil)
        #expect(await eventually(timeout: 60) {
            let lines = ((try? Data(contentsOf: inbox)) ?? Data()).split(separator: 0x0A)
            message.value = lines.compactMap { try? JSONDecoder().decode(SteerMessage.self, from: Data($0)) }.first { $0.from == .user }
            return message.value != nil
        }, "\(node.said)")
        if let message = message.value {
            let verified = try? HostCall.vault(.verify([message]), socket: node.socket + ".aside")
            #expect(verified == .verified([true]), "\(String(describing: verified))")
        }
        // Nothing came to the path.
        var connections = 0
        while Platform.Sockets.accept(listener) >= 0 { connections += 1 }
        #expect(connections == 0)
    }

    /// S7 on a fresh vault (its first look held): `config held`, `config accept CARD`, `base show REPO --from COMMIT`,
    /// `base accept CARD`, then `lead`, each through the built command line on a pty.
    @Test func theFreshVaultOrderAcceptsThenStartsTheLead() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        let repo = node.root.appendingPathComponent("repo")
        try await scratchRepository(repo)
        let first = Git.run(["rev-parse", "main"], in: repo.path).output
        func card(_ output: String, _ command: String) -> String? {
            output.components(separatedBy: "\n").first { $0.hasPrefix("accept it with: vibeswitcher \(command) ") }
                .map { String($0.dropFirst("accept it with: vibeswitcher \(command) ".count)) }
        }
        let refused = try await node.runOnTerminal(["lead", repo.path])
        #expect(refused.status == 77 && refused.output.contains("config"), "\(refused.output)")

        let held = try await node.run(["config", "held", repo.path])
        #expect(held.status == 0, "\(held.output)\(held.errors)")
        let configCard = try #require(card(held.output, "config accept"), "\(held.output)")
        let accepted = try await node.runOnTerminal(["config", "accept", configCard])
        #expect(accepted.status == 0 && accepted.output.contains("accepted"), "\(accepted.output)\n\(node.said)")

        let shown = try await node.run(["base", "show", repo.path, "--from", first])
        #expect(shown.status == 0, "\(shown.output)\(shown.errors)")
        let baseCard = try #require(card(shown.output, "base accept"), "\(shown.output)")
        let recorded = try await node.runOnTerminal(["base", "accept", baseCard])
        #expect(recorded.status == 0 && recorded.output.contains("recorded: main at \(first)"), "\(recorded.output)\n\(node.said)")

        let started = try await node.runOnTerminal(["lead", repo.path, "--goal", "plan the work"])
        #expect(started.status == 0 && started.output.contains("the lead started"), "\(started.output)\n\(node.said)")
    }

    @Test func aServerRestartIsCountedInStatus() async throws {
        let node = try await ScratchNode(scratch)
        let first = try WireClient(node).hello
        kill(first.server.pid, SIGKILL)
        var restarted: NodeWire.Hello?
        let back = await eventually(timeout: 120) {
            restarted = try? WireClient(node).hello
            return restarted.map { $0.epoch != first.epoch } == true
        }
        try #require(back, "\(node.said)")
        #expect(restarted?.server.pid != first.server.pid)
        var restarts: Int?
        let counted = await eventually(timeout: 60) {
            restarts = (try? WireClient(node)).flatMap { WireClient.reply($0.request("status", action: nil)) }?.result?["host"]?["notes"]?["serverRestarts"]?.int
            return restarts == 1
        }
        #expect(counted, "restarts \(String(describing: restarts))")
    }

    /// EN-D6 with a lead (the engine plan's E4): a lead started from the command line whose fake keeps asking its tool
    /// server for workers (`start_worker`, through the fake's `mcp` op) while `stop` runs: `stop` still ends with every
    /// session and the host gone. On the way: the command line printed the program the lead runs before its code
    /// (EN-D13), the lead's tool server holds the lead's role in its session, and a worker it starts runs the lead's
    /// resolved `claude`, not what a presets file under the node's root names.
    @Test func aStopWhileALeadSpawnsStillEndsTheHost() async throws {
        let node = try await ScratchNode(scratch)
        // Its workers start whatever the machine's load (the case's is stop's, not the room's).
        try node.noLoadHold()
        let repo = node.root.appendingPathComponent("repo")
        try await scratchRepository(repo)
        // A presets file a worker could write, naming another Claude command: never read on Linux.
        try Data(#"{"presets":[{"agent":"claude","place":"window","command":"/bin/false planted"}]}"#.utf8)
            .write(to: node.root.appendingPathComponent("presets.json"))
        let program = node.fake.launcher.resolvingSymlinksInPath().path
        let started = try await node.runOnTerminal(["lead", repo.path, "--goal", "plan the work"])
        #expect(started.status == 0, "\(started.output)\n\(node.said)")
        let shown = started.output.range(of: "The lead runs \(program)")
        let asked = started.output.range(of: "Type ")
        #expect(shown != nil && asked != nil && shown!.lowerBound < asked!.lowerBound, "\(started.output)")
        #expect(started.output.contains("the lead started"), "\(started.output)")
        let lead = try #require(try node.sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") }, "\(node.said)")
        #expect(lead.command?.hasPrefix(RecentProjects.shellQuote(program) + " ") == true, "\(String(describing: lead.command?.prefix(200)))")

        let files = node.fake.files(terminal: lead.tty)
        func tell(_ command: [String: Any]) throws {
            let line = try JSONSerialization.data(withJSONObject: command) + Data("\n".utf8)
            let handle = try FileHandle(forWritingTo: files.control)
            handle.seekToEndOfFile()
            handle.write(line)
            try handle.close()
        }
        func calls() -> [[String: Any]] {
            let state = (try? JSONSerialization.jsonObject(with: Data(contentsOf: files.state))) as? [String: Any]
            return state?["mcp"] as? [[String: Any]] ?? []
        }
        #expect(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: files.control.path) })
        // Its tool server holds the lead's role in its session: status is one of its tools, and answers.
        try tell(["op": "mcp", "tool": "status", "arguments": [:] as [String: Any]])
        #expect(await eventually(timeout: 120) { calls().count == 1 }, "\(node.said)")
        let status = try #require(calls().first)
        let statusReply = status["reply"] as? [String: Any]
        #expect(statusReply?["result"] != nil && (statusReply?["result"] as? [String: Any])?["isError"] as? Bool != true, "\(status)")

        // A task, its worker asked for (its session starts at once; the call then waits for its tools, which the fake
        // never starts), then workers asked for again and again while stop runs.
        try tell(["op": "mcp", "tool": "add_task", "arguments": ["title": "Write the parser", "goal": "A parser.",
                                                                 "acceptance": ["swift test passes"]] as [String: Any]])
        #expect(await eventually(timeout: 120) { calls().count == 2 }, "\(calls())")
        try tell(["op": "mcp", "tool": "start_worker", "arguments": ["task": "write-the-parser"] as [String: Any]])
        let worker = Locked<HostSession?>(nil)
        let appeared = await eventually(timeout: 120) {
            worker.value = (try? node.sessions())?.first { $0.isLive && $0.label.hasPrefix("Worker") }
            return worker.value != nil
        }
        #expect(appeared, "\(calls())\n\(node.said)")
        if let worker = worker.value {
            #expect(worker.command?.hasPrefix(RecentProjects.shellQuote(program) + " ") == true, "\(String(describing: worker.command?.prefix(200)))")
        }
        for _ in 0..<5 { try tell(["op": "mcp", "tool": "start_worker", "arguments": ["task": "write-the-parser"] as [String: Any]]) }
        let pids = try node.sessions().filter(\.isLive).map(\.childPID) + [try #require(node.serverPID)]

        let stopped = try await node.runOnTerminal(["stop"])
        #expect(stopped.status == 0, "\(stopped.output)\n\(node.said)")
        #expect(await exited(node.process, within: 120), "\(node.said)")
        for pid in pids {
            #expect(await eventually(timeout: 30) { kill(pid, 0) != 0 && errno == ESRCH }, "pid \(pid) still runs")
        }
        #expect(node.said.contains("stop: ending 1 leads"), "\(node.said)")
    }

    @Test func theServerExitsWhenTheHostIsGone() async throws {
        let node = try await ScratchNode(scratch)
        let server = try #require(node.serverPID)
        kill(node.hostPID, SIGKILL)
        #expect(await eventually(timeout: 60) { kill(server, 0) != 0 && errno == ESRCH }, "\(node.said)")
        #expect(await eventually(timeout: 30) { node.said.contains("the session host is gone") }, "\(node.said)")
    }

    @Test func theServersChildrenInheritNoConnector() async throws {
        let folder = try scratch.shortFolder("vsc")
        let listing = folder.appendingPathComponent("fds").path
        let child = folder.appendingPathComponent("child.sh")
        try ScratchNode.script("#!/bin/sh\nls -l /proc/$$/fd >'\(listing).part' 2>&1\nmv '\(listing).part' '\(listing)'\n", at: child)
        let node = try await ScratchNode(scratch, testChild: child.path)
        let listed = await eventually(timeout: 60) { FileManager.default.fileExists(atPath: listing) }
        try #require(listed, "\(node.said)")
        let text = try String(contentsOfFile: listing, encoding: .utf8)
        #expect(!text.contains("socket:"), "\(text)")
        #expect(text.contains(" 0 -> /dev/null"), "\(text)")
    }

    @Test func theServerRefusesToStartWithoutRootsGit() async throws {
        // A scratch host refuses to start without a git only root can change (stage 2's Task 10c, `HostImages.mayStart`),
        // and its server gets its PATH: so the server is started here as the host would, with a connector and its root,
        // on a PATH with no such git.
        let root = try scratch.shortFolder("vsg")
        let ran = try await Self.runServer(root: root, hostSocket: root.appendingPathComponent("host.sock").path, path: "/nonexistent")
        #expect(ran.status == 69, "\(ran.errors)")
        #expect(ran.errors.contains("no git on PATH in a folder owned by root"), "\(ran.errors)")
    }

    @Test func theServerRefusesAHostSocketOtherThanItsRoots() async throws {
        let node = try await ScratchNode(scratch, socketName: "other.sock", waitForServer: false)
        #expect(await eventually(timeout: 60) { node.said.contains("isn't this root's host socket") }, "\(node.said)")
        #expect(!FileManager.default.fileExists(atPath: node.serverSocket))
        // As started on its own, the same: exit 78.
        let root = try scratch.shortFolder("vsh")
        let elsewhere = try scratch.shortFolder("vse").appendingPathComponent("h.sock").path
        let ran = try await Self.runServer(root: root, hostSocket: elsewhere, path: "/usr/bin:/bin")
        #expect(ran.status == 78, "\(ran.errors)")
    }

    @Test func twoScratchNodesInOneRunUseTheirOwnSockets() async throws {
        async let one = ScratchNode(scratch)
        async let two = ScratchNode(scratch)
        let nodes = try await [one, two]
        let hellos = try nodes.map { try WireClient($0).hello }
        #expect(hellos[0].epoch != hellos[1].epoch && hellos[0].server.pid != hellos[1].server.pid)
        for (node, hello) in zip(nodes, hellos) {
            #expect(hello.server.pid == node.serverPID)
            let status = try #require(WireClient.reply(try WireClient(node).request("status", action: nil))?.result)
            #expect(status["root"]?.string == node.root.path)
            #expect(status["epoch"]?.string == hello.epoch)
        }
        #expect(nodes[0].serverSocket != nodes[1].serverSocket)
    }

    /// The built server started on its own as the host would start it (a connector on its stdin, `--root`), with
    /// `path` as its PATH; its status and stderr. Its connector's other end is held, so it doesn't see its host gone.
    static func runServer(root: URL, hostSocket: String, path: String) async throws -> CommandRun {
        guard let (serverEnd, testEnd) = Platform.Sockets.pair(type: Platform.Sockets.seqpacket) else { throw CancellationError() }
        defer { Sys.close(testEnd) }
        let process = Process()
        process.executableURL = builtProducts.appendingPathComponent("vibeswitcher-server")
        process.arguments = ["--host-connector", "0", "--host-socket", hostSocket, "--root", root.path, "--node-root", root.path]
        process.environment = ["PATH": path, "HOME": root.path]
        let errors = Pipe()
        process.standardInput = FileHandle(fileDescriptor: serverEnd, closeOnDealloc: false)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        Sys.close(serverEnd)
        let said = await offPool { errors.fileHandleForReading.readDataToEndOfFile() }
        #expect(await exited(process, within: 60))
        return CommandRun(status: process.terminationStatus, output: "", errors: String(decoding: said, as: UTF8.self))
    }
}
