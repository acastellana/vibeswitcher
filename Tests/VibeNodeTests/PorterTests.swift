import Foundation
import Testing
@testable import VibeCore

/// A porter as the host will start one (the session sandbox plan's SB5): from a sealed copy of the built tool server,
/// with sealed copies of the built tool server and hook, a socket pair standing for its door line (the test plays the
/// box's init, handing it each connection) and one for its connector. Its environment is a scratch home's, plus
/// `extra`; its stderr goes to a file of the scratch folder.
final class PorterRig: @unchecked Sendable {
    let folder: URL
    let helper: SessionHelper
    let pid: pid_t
    /// The test's end of the door line (-1 once closed).
    private(set) var doorLine: Int32
    /// The test's end of the connector.
    let connector: Int32
    let errors: URL
    private let copies: [Platform.ProcessSelf.SealedCopy]
    private var collectedStatus: Int32?

    init(_ scratch: Scratch, helper: SessionHelper, hostSocket: String? = nil, environment extra: [String: String] = [:]) throws {
        folder = scratch.url("porter")
        self.helper = helper
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("home"), withIntermediateDirectories: true)
        let mcp = builtProducts.appendingPathComponent("vibeswitcher-mcp").path
        let hook = builtProducts.appendingPathComponent("vibeswitcher-hook").path
        var made: [Platform.ProcessSelf.SealedCopy] = []
        for (path, name) in [(mcp, "porter"), (mcp, "tool-server"), (hook, "hook")] {
            made.append(try Platform.ProcessSelf.sealedCopy(of: path, name: name).get())
        }
        copies = made
        guard let line = Platform.Sockets.pair(type: Platform.Sockets.stream),
              let pair = Platform.Sockets.pair(type: Platform.Sockets.seqpacket) else { throw Platform.Errno(code: errno) }
        doorLine = line.0
        connector = pair.0
        // As the host makes a door line (SB5): its messages name their sender to the porter from the first.
        Platform.Sockets.enableCredentials(line.1)
        errors = folder.appendingPathComponent("porter.log")
        let arguments = Porter.Arguments(session: UUID(), helper: helper, doorLine: line.1, connector: pair.1,
                                         hostSocket: hostSocket ?? folder.appendingPathComponent("host.sock").path,
                                         toolServerImage: made[1].fd, hookImage: made[2].fd)
        var spawn = Platform.Spawn(executable: made[0].path, arguments: ["vibeswitcher-mcp", Porter.flag] + arguments.words)
        spawn.environment = scratchEnvironment(folder, extra.merging([Platform.ProcessSelf.imageVariable: String(made[0].fd)]) { $1 })
            .map { "\($0.key)=\($0.value)" }
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stderr = .path(errors.path, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600)
        spawn.keep = made.map(\.fd) + [line.1, pair.1]
        let started = spawn.start()
        Sys.close(line.1)
        Sys.close(pair.1)
        pid = try started.get()
    }

    /// One door connection, as init hands it over: a socket pair whose one end goes over the door line. The relay's
    /// end, blocking.
    func connect() throws -> Int32 {
        guard let pair = Platform.Sockets.pair(type: Platform.Sockets.stream) else { throw Platform.Errno(code: errno) }
        defer { Sys.close(pair.1) }
        guard Platform.Sockets.sendDescriptor(pair.1, over: doorLine) else {
            Sys.close(pair.0)
            throw Platform.Errno(code: errno)
        }
        return pair.0
    }

    /// The porter's answer on `relay`, without its newline; nil when the connection closed first, or past `within`.
    func answer(_ relay: Int32, within: TimeInterval = 30) -> String? {
        var bytes: [UInt8] = []
        let deadline = Date().addingTimeInterval(within)
        while !bytes.contains(UInt8(ascii: "\n")) {
            var waiting = pollfd(fd: relay, events: Int16(POLLIN), revents: 0)
            let left = deadline.timeIntervalSinceNow
            guard left > 0, poll(&waiting, 1, Int32(left * 1_000)) > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = Sys.read(relay, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            bytes += buffer[0..<count]
        }
        return String(decoding: bytes.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
    }

    /// The door line closed: the box has ended.
    func closeDoorLine() {
        guard doorLine >= 0 else { return }
        Sys.close(doorLine)
        doorLine = -1
    }

    /// The porter's exit status once it ended within `within` (it is killed past it); nil when it never was collected.
    func collect(within: TimeInterval = 30) -> Int32? {
        if let collectedStatus { return collectedStatus }
        guard let raw = collected(pid, by: MacTime.real.awake() + within) else { return nil }
        collectedStatus = raw
        return raw
    }

    var log: String { (try? String(contentsOf: errors, encoding: .utf8)) ?? "" }

    deinit {
        closeDoorLine()
        Sys.close(connector)
        if collectedStatus == nil { kill(pid, SIGKILL); _ = collect(within: 10) }
        copies.forEach { Sys.close($0.fd) }
    }
}

/// A helper's stdio as a relay hands it over: three pipes, the helper's ends (`given`) sent with the line and closed
/// here once sent, the test's ends kept.
final class RelayPipes: @unchecked Sendable {
    /// stdin's write end, stdout's and stderr's read ends: the test's.
    private(set) var input: Int32, output: Int32, errors: Int32
    /// The helper's ends: stdin's read end, stdout's and stderr's write ends.
    private(set) var given: [Int32]

    init() throws {
        var a: [Int32] = [-1, -1], b: [Int32] = [-1, -1], c: [Int32] = [-1, -1]
        guard Sys.pipeClosedOnExec(&a) == 0, Sys.pipeClosedOnExec(&b) == 0, Sys.pipeClosedOnExec(&c) == 0 else {
            throw Platform.Errno(code: errno)
        }
        (input, output, errors) = (a[1], b[0], c[0])
        given = [a[0], b[1], c[1]]
    }

    /// Sends `line` with the helper's three ends (and `more`) over `relay`, then closes the three here.
    @discardableResult
    func send(_ line: [UInt8], over relay: Int32, more: [Int32] = []) -> Int {
        let sent = Platform.Sockets.send(line, with: given + more, over: relay)
        closeGiven()
        return sent
    }

    func closeGiven() {
        given.forEach { Sys.close($0) }
        given = []
    }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        var done = 0
        while done < bytes.count {
            let count = bytes[done...].withUnsafeBytes { Sys.write(input, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            done += count
        }
    }

    /// stdout's lines until one holds `marker`, or `within` passes: that line; nil otherwise.
    func line(containing marker: String, within: TimeInterval = 60) -> String? {
        var pending = ""
        let deadline = Date().addingTimeInterval(within)
        while true {
            if let line = pending.components(separatedBy: "\n").dropLast().first(where: { $0.contains(marker) }) { return line }
            var waiting = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            let left = deadline.timeIntervalSinceNow
            guard left > 0, poll(&waiting, 1, Int32(left * 1_000)) > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = Sys.read(output, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            // At the end, what came last without a newline counts too.
            guard count > 0 else { return pending.components(separatedBy: "\n").last.flatMap { $0.contains(marker) ? $0 : nil } }
            pending += String(decoding: buffer[0..<count], as: UTF8.self)
        }
    }

    func closeInput() {
        guard input >= 0 else { return }
        Sys.close(input)
        input = -1
    }

    deinit {
        closeGiven()
        [input, output, errors].filter { $0 >= 0 }.forEach { Sys.close($0) }
    }
}

/// The tool server in its test build (`VIBESWITCHER_MCP_TEST_BUILD`, no host behind it): its "build" tool answers
/// `<build> <pid>`. What a porter's environment carries so that its tool server answers so.
func testBuildEnvironment(_ build: String = "b1") -> [String: String] {
    ["VIBESWITCHER_MCP_TEST_BUILD": build, "VIBESWITCHER_MCP_TEST_BINARY": builtProducts.appendingPathComponent("vibeswitcher-mcp").path]
}

/// The MCP lines that start a session and call the test build's "build" tool (id 2).
let buildToolCall: String = {
    let lines: [[String: Any]] = [
        ["jsonrpc": "2.0", "id": 0, "method": "initialize",
         "params": ["protocolVersion": "2025-11-25", "capabilities": [:] as [String: Any], "clientInfo": ["name": "claude-code", "version": "2"]]],
        ["jsonrpc": "2.0", "method": "notifications/initialized"],
        ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "build", "arguments": [:] as [String: Any]]],
    ]
    return lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }.joined()
}()

/// The pid in the test build's answer to "build" (`<build> <pid>`) on `line`; nil without one.
func answeringPid(_ line: String?, build: String = "b1") -> pid_t? {
    guard let line, let range = line.range(of: "\(build) ") else { return nil }
    return pid_t(line[range.upperBound...].prefix { $0.isNumber })
}

/// Whether `pid` is no process any more (or one ended and not yet collected).
func isGone(_ pid: pid_t) -> Bool {
    if kill(pid, 0) != 0, errno == ESRCH { return true }
    if case .brief(let brief) = Platform.Processes.brief(pid) { return brief.state == .zombie }
    return false
}

/// The porter (the session sandbox plan's SB4): what it starts for a box, from what, and when it ends it. The rules are
/// pure and run on both systems; the rest runs the built tool server as the porter, on Linux.
@Suite(.timeLimit(.minutes(5)))
struct PorterTests {
    private let scratch = Scratch()
    static let worker = SessionHelper(role: "worker", root: "/r/main", task: "t1")

    // MARK: The rules

    @Test func nothingFromInsideChoosesTheRoleTheRootOrTheTask() async throws {
        let hostile = ["--role", "lead", "--root", "/etc", "--task", "other", "--keeper", "--porter", "--for-pid", "1",
                       "--caller-socket", "0", "--worker", "--user-settings-only", "/"]
        let worker = Self.worker
        #expect(Porter.command(.init(mode: .mcp, args: hostile), helper: worker, caller: 77)
                == ["vibeswitcher-mcp", "--role", "worker", "--root", "/r/main", "--task", "t1"])
        #expect(Porter.command(.init(mode: .hook, args: ["claude"] + hostile), helper: worker, caller: 77)
                == ["vibeswitcher-hook", "claude", "--for-pid", "77"])
        // Codex's hooks find their session among every Codex terminal of the machine, by what the event says: no
        // box's event may choose one.
        #expect(Porter.allowed(.init(mode: .hook, args: ["codex"]), for: worker) != nil)
        #expect(Porter.allowed(.init(mode: .hook, args: hostile), for: worker) != nil, "a hook's first word is its agent's name, or nothing starts")
        // A confined session's status line runs no status line command outside: not a project's, not the user's own.
        #expect(Porter.command(.init(mode: .statusLine, args: hostile), helper: worker, caller: 77)
                == ["vibeswitcher-mcp", "--status-line", "--user-settings-only", "--for-a-box"])
        #expect(Porter.command(.init(mode: .permission, args: hostile), helper: worker, caller: 77)
                == ["vibeswitcher-mcp", "--read-only-permission", "--root", "/r/main/.vibeswitcher/worktrees/t1", "--worker"])
        #expect(Porter.command(.init(mode: .permission, args: hostile), helper: SessionHelper(role: "lead", root: "/r/main"), caller: 77)
                == ["vibeswitcher-mcp", "--read-only-permission", "--root", "/r/main"])
        for mode in DoorProtocol.Mode.allCases {
            let words = Porter.command(.init(mode: mode, args: ["claude"] + hostile), helper: worker, caller: 77)
            #expect(!words.contains("/etc") && !words.contains("other") && !words.contains("lead") && !words.contains("--porter"), "\(mode): \(words)")
        }

        // And as run: the tool server the porter starts is the host's worker, whatever its relay said.
        guard !Platform.CodeIdentity.isAvailable else { return }
        let rig = try PorterRig(scratch, helper: worker, environment: testBuildEnvironment())
        let relay = try rig.connect()
        defer { Sys.close(relay) }
        let pipes = try RelayPipes()
        pipes.send(DoorProtocol.line(.init(mode: .mcp, args: hostile))!, over: relay)
        pipes.write(buildToolCall)
        let helperPid = try #require(answeringPid(pipes.line(containing: "b1 ")), "\(rig.log)")
        #expect(Platform.Processes.arguments(helperPid).dropFirst() == ["--role", "worker", "--root", "/r/main", "--task", "t1"])
    }

    @Test func aModeItsRoleDoesntHaveIsRefused() async throws {
        let verifier = SessionHelper(role: "verifier", root: "/r/main", task: "t1")
        #expect(Porter.allowed(.init(mode: .permission, args: []), for: verifier) != nil)
        #expect(Porter.allowed(.init(mode: .mcp, args: []), for: verifier) == nil)
        for role in ["branchRun", "", "root", "Worker"] {
            for mode in DoorProtocol.Mode.allCases {
                #expect(Porter.allowed(.init(mode: mode, args: ["claude"]), for: SessionHelper(role: role, root: "/r")) != nil, "\(role) \(mode)")
            }
        }
        #expect(Porter.allowed(.init(mode: .mcp, args: []), for: SessionHelper(role: "worker", root: "/r")) != nil, "a worker without its task")
        #expect(Porter.allowed(.init(mode: .mcp, args: []), for: SessionHelper(role: "worker", root: "/r", task: "../x")) != nil)
        #expect(Porter.allowed(.init(mode: .mcp, args: []), for: SessionHelper(role: "lead", root: "r")) != nil)
        #expect(Porter.allowed(.init(v: 2, mode: .mcp, args: []), for: Self.worker) != nil)

        guard !Platform.CodeIdentity.isAvailable else { return }
        let rig = try PorterRig(scratch, helper: verifier, environment: testBuildEnvironment())
        let relay = try rig.connect()
        defer { Sys.close(relay) }
        let pipes = try RelayPipes()
        pipes.send(DoorProtocol.line(.init(mode: .permission, args: ["--root", "/r/main"]))!, over: relay)
        let answer = try #require(rig.answer(relay))
        #expect(answer.hasPrefix("refused "), "\(answer)")
        // Nothing started: no process holds the stdout it was sent.
        #expect(pipes.line(containing: "x", within: 10) == nil)
        #expect(rig.log.contains("refused a permission request"), "\(rig.log)")
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no porter"))
    func onlyThreeDescriptorsAreTakenAndAFourthIsClosed() async throws {
        let rig = try PorterRig(scratch, helper: Self.worker, environment: testBuildEnvironment())
        let line = DoorProtocol.line(.init(mode: .mcp, args: []))!

        // A fourth descriptor: refused, and the porter's copy of it closed.
        var extra: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&extra) == 0)
        let relay = try rig.connect()
        defer { Sys.close(relay) }
        let pipes = try RelayPipes()
        pipes.send(line, over: relay, more: [extra[1]])
        Sys.close(extra[1])
        let answer = try #require(rig.answer(relay))
        #expect(answer.hasPrefix("refused "), "\(answer)")
        let closed: Bool = await offPool {
            var waiting = pollfd(fd: extra[0], events: Int16(POLLIN), revents: 0)
            var byte: UInt8 = 0
            return poll(&waiting, 1, 30_000) > 0 && Sys.read(extra[0], &byte, 1) == 0
        }
        #expect(closed, "the fourth descriptor is still open somewhere")
        Sys.close(extra[0])

        // Two: refused.
        let short = try rig.connect()
        defer { Sys.close(short) }
        let two = try RelayPipes()
        Platform.Sockets.send(line, with: Array(two.given.prefix(2)), over: short)
        two.closeGiven()
        #expect(rig.answer(short)?.hasPrefix("refused ") == true)

        // Three, then one more with the line's last bytes: refused.
        let late = try rig.connect()
        defer { Sys.close(late) }
        let three = try RelayPipes()
        three.send(Array(line.dropLast(4)), over: late)
        var another: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&another) == 0)
        Platform.Sockets.send(Array(line.suffix(4)), with: [another[1]], over: late)
        Sys.close(another[1])
        #expect(rig.answer(late)?.hasPrefix("refused ") == true)
        Sys.close(another[0])

        // And three alone still start the helper.
        let good = try rig.connect()
        defer { Sys.close(good) }
        let pipesGood = try RelayPipes()
        pipesGood.send(line, over: good)
        pipesGood.write(buildToolCall)
        #expect(answeringPid(pipesGood.line(containing: "b1 ")) != nil, "\(rig.log)")
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no porter"))
    func theHelpersAreStartedFromSealedCopiesAndAreNotDumpable() async throws {
        let rig = try PorterRig(scratch, helper: Self.worker, environment: testBuildEnvironment())
        #expect(await eventually(timeout: 30) { Platform.Processes.isDumpable(rig.pid) == false }, "the porter itself")
        let relay = try rig.connect()
        defer { Sys.close(relay) }
        let pipes = try RelayPipes()
        pipes.send(DoorProtocol.line(.init(mode: .mcp, args: []))!, over: relay)
        pipes.write(buildToolCall)
        let helper = try #require(answeringPid(pipes.line(containing: "b1 ")), "\(rig.log)")
        #expect(Platform.Processes.isDumpable(helper) == false)
        guard case .brief(let brief) = Platform.Processes.brief(helper) else { Issue.record("no brief of \(helper)"); return }
        #expect(brief.ppid == rig.pid)
        // Started by a descriptor's path (`/proc/self/fd/N`), never a file on disk: its name is the descriptor's number.
        #expect(Int32(brief.name) != nil, "\(brief.name)")
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no porter"))
    func aHelperThatOutlivesItsRelayIsEnded() async throws {
        let rig = try PorterRig(scratch, helper: Self.worker, environment: testBuildEnvironment())
        let relay = try rig.connect()
        let pipes = try RelayPipes()
        pipes.send(DoorProtocol.line(.init(mode: .mcp, args: []))!, over: relay)
        pipes.write(buildToolCall)
        let helper = try #require(answeringPid(pipes.line(containing: "b1 ")), "\(rig.log)")
        // Its stdin still open: only the relay's going ends it.
        Sys.close(relay)
        #expect(await eventually(timeout: 30) { isGone(helper) }, "\(rig.log)")
        #expect(!isGone(rig.pid), "the porter serves on")
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no porter"))
    func thePorterEndsWhenItsDoorLineCloses() async throws {
        let rig = try PorterRig(scratch, helper: Self.worker, environment: testBuildEnvironment())
        let relay = try rig.connect()
        defer { Sys.close(relay) }
        let pipes = try RelayPipes()
        pipes.send(DoorProtocol.line(.init(mode: .mcp, args: []))!, over: relay)
        pipes.write(buildToolCall)
        let helper = try #require(answeringPid(pipes.line(containing: "b1 ")), "\(rig.log)")
        rig.closeDoorLine()
        let status = await offPool { rig.collect() }
        #expect(status == 0, "\(String(describing: status)) \(rig.log)")
        #expect(isGone(helper))
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no porter"))
    func aHelperThatDiedIsStartedAgainAtTheNextConnection() async throws {
        let rig = try PorterRig(scratch, helper: Self.worker, environment: testBuildEnvironment())
        let first = try rig.connect()
        defer { Sys.close(first) }
        let pipes = try RelayPipes()
        pipes.send(DoorProtocol.line(.init(mode: .mcp, args: []))!, over: first)
        pipes.write(buildToolCall)
        let dead = try #require(answeringPid(pipes.line(containing: "b1 ")), "\(rig.log)")
        kill(dead, SIGKILL)
        #expect(rig.answer(first) == "exit \(128 + SIGKILL)")

        let second = try rig.connect()
        defer { Sys.close(second) }
        let again = try RelayPipes()
        again.send(DoorProtocol.line(.init(mode: .mcp, args: []))!, over: second)
        again.write(buildToolCall)
        let next = try #require(answeringPid(again.line(containing: "b1 ")), "\(rig.log)")
        #expect(next != dead)
        // Its input's end ends it, and its status comes back.
        again.closeInput()
        #expect(rig.answer(second) == "exit 0", "\(rig.log)")
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: the Mac has no porter"))
    func aBoxCantHoldMoreThanItsShareOfRequests() async throws {
        let rig = try PorterRig(scratch, helper: Self.worker, environment: testBuildEnvironment())
        // Silent relays, each holding a connection without a line.
        var held: [Int32] = []
        defer { held.forEach { Sys.close($0) } }
        for _ in 0..<Porter.maxConnections { held.append(try rig.connect()) }
        let over = try rig.connect()
        defer { Sys.close(over) }
        #expect(rig.answer(over, within: Porter.helloPatience - 1)?.hasPrefix("refused ") == true, "\(rig.log)")
        // A silent one is dropped once its patience is gone.
        #expect(rig.answer(held[0])?.hasPrefix("refused ") == true)
    }

    /// A relay as a box holds one, for `HookCaller`: a process connected to a listener of the test's, the child of a
    /// shell on a terminal of its own (under `script`). The shell stands for the box's init: above the relay, and on
    /// the session's terminal.
    final class TerminalRelay: @unchecked Sendable {
        let runner: pid_t
        let relay: pid_t
        /// The shell above the relay, on the terminal.
        let box: pid_t
        let listener: Int32
        /// The relay's connection, as the porter holds it.
        let accepted: Int32

        init(_ scratch: Scratch, _ name: String) async throws {
            let folder = try scratch.shortFolder(name)
            let path = folder.appendingPathComponent("s").path
            let who = folder.appendingPathComponent("who").path
            listener = try UnixSocket.listen(path: path)
            let relaying = "import os,socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); "
                + "open(sys.argv[2]+'.tmp','w').write('%d %d' % (os.getpid(), os.getppid())); os.rename(sys.argv[2]+'.tmp', sys.argv[2]); time.sleep(600)"
            let shell = "/usr/bin/python3 -I -c \(FakeClaude.quoted(relaying)) \(FakeClaude.quoted(path)) \(FakeClaude.quoted(who)) & wait"
            var spawn = Platform.Spawn(executable: "/usr/bin/script", arguments: ["script", "-q", "-e", "-c", "/bin/sh -c \(FakeClaude.quoted(shell))", "/dev/null"])
            spawn.stdin = .path("/dev/null", flags: O_RDONLY)
            spawn.stdout = .path("/dev/null", flags: O_WRONLY)
            spawn.stderr = .path("/dev/null", flags: O_WRONLY)
            runner = try spawn.start().get()
            var taken: Int32 = -1
            let listening = listener
            let connected = await eventually(timeout: 30) {
                if taken < 0 { taken = Platform.Sockets.accept(listening) }
                return taken >= 0 && FileManager.default.fileExists(atPath: who)
            }
            accepted = taken
            let words = ((try? String(contentsOfFile: who, encoding: .utf8)) ?? "").split(separator: " ").compactMap { pid_t($0) }
            (relay, box) = (words.first ?? -1, words.dropFirst().first ?? -1)
            guard connected, relay > 1, box > 1 else {
                end()
                throw Platform.Errno(code: ETIMEDOUT)
            }
        }

        /// Ends `script`, the one process here this test started itself: its terminal hangs up, which ends the shell
        /// and the relay on it. Neither is signalled by the pid it wrote down: a pid read from a file names whatever
        /// holds it by then (a relay whose shell had gone would have written the user's systemd as its parent).
        func end() {
            kill(runner, SIGKILL)
            _ = collected(runner, by: MacTime.real.awake() + 10)
            if accepted >= 0 { Sys.close(accepted) }
            Sys.close(listener)
        }

        /// The hook's arguments as the porter gives them for this relay, with `pid`, `box` and `held` as given.
        func arguments(pid: pid_t? = nil, socket: Int32? = nil, box: pid_t? = nil, held: Int32) -> [String] {
            ["claude", "--for-pid", String(pid ?? relay), "--caller-socket", String(socket ?? accepted), "--caller-held", String(held),
             "--box-init", String(box ?? self.box)]
        }
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: no peer's pid to prove on the Mac"))
    func aHookTakesItsRelaysPidOnlyFromItsConnection() async throws {
        let terminal = try await TerminalRelay(scratch, "caller")
        defer { terminal.end() }
        let held = try #require(Platform.ProcessExit.hold(terminal.relay))
        defer { Sys.close(held) }
        #expect(HookCaller.pid(terminal.arguments(held: held)) == terminal.relay)
        // Any other pid, or no socket, or a socket that isn't the relay's: this process, as without the arguments.
        #expect(HookCaller.pid(terminal.arguments(pid: getppid(), held: held)) == getpid())
        #expect(HookCaller.pid(["claude", "--for-pid", String(terminal.relay)]) == getpid())
        #expect(HookCaller.pid(terminal.arguments(socket: terminal.listener, held: held)) == getpid())
        #expect(HookCaller.pid(["claude"]) == getpid())
    }

    /// A pid names whichever process holds it when it is read. A relay that left while another process of its box kept
    /// its connection open would lend its pid to whoever is given it next, another session's process among them; and a
    /// process that isn't under this box's init is no relay of it, whatever a connection says.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux only: no peer's pid to prove on the Mac"))
    func aHookActsForNoRelayThatLeftNorForAProcessOutsideItsBox() async throws {
        let terminal = try await TerminalRelay(scratch, "left")
        defer { terminal.end() }
        let held = try #require(Platform.ProcessExit.hold(terminal.relay))
        defer { Sys.close(held) }
        #expect(HookCaller.pid(terminal.arguments(held: held)) == terminal.relay)
        // Under another box's init (a process that isn't above the relay), or with no word of one: nobody's.
        var bystander = Platform.Spawn(executable: "/bin/sleep", arguments: ["sleep", "600"])
        bystander.stdin = .path("/dev/null", flags: O_RDONLY)
        let outside = try bystander.start().get()
        defer { kill(outside, SIGKILL); _ = collected(outside, by: MacTime.real.awake() + 10) }
        #expect(HookCaller.pid(terminal.arguments(box: outside, held: held)) == getpid())
        #expect(HookCaller.pid(Array(terminal.arguments(held: held).dropLast(2))) == getpid())
        // Held as another process (the bystander's descriptor): nobody's.
        let wrong = try #require(Platform.ProcessExit.hold(outside))
        defer { Sys.close(wrong) }
        #expect(HookCaller.pid(terminal.arguments(held: wrong)) == getpid())
        // The relay leaves. Its connection still names its pid (the kernel recorded it at the connect), and the pid is
        // free for any process once its shell has collected it: the hook acts for nobody.
        // (Signalled only as the process this test holds, and that connected to its listener.)
        try #require(Platform.ProcessExit.stillRuns(held: held, pid: terminal.relay) && Platform.Sockets.peerPID(terminal.accepted) == terminal.relay)
        kill(terminal.relay, SIGKILL)
        var gone = pollfd(fd: held, events: Int16(POLLIN), revents: 0)
        var ready: Int32
        repeat { ready = poll(&gone, 1, 30_000) } while ready < 0 && errno == EINTR
        try #require(ready == 1)
        #expect(Platform.Sockets.peerPID(terminal.accepted) == terminal.relay)
        #expect(HookCaller.pid(terminal.arguments(held: held)) == getpid())
    }
}
