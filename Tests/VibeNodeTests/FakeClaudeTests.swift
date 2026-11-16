import Foundation
import Testing
import VibeCore

/// The fake Claude Code the engine's tests run (`FakeClaude`, copied from the app's tests) on a scratch host's session
/// (`NodeTestHost`), through the harness (`NodeHarness`): the process table sees it as Claude, it takes Claude's own
/// arguments, it calls a tool through the tool server it was given, and the hook's step hands it a steered message.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct FakeClaudeTests {
    private let scratch = Scratch()

    @Test func theProcessTableSeesTheFakeAsClaude() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let h = try await NodeHarness.start(on: host)
        let pid = try #require(h.agentPid)
        let info = try #require(ProcessTable.info(pid: pid), "pid \(pid) isn't in the process table")
        #expect(info.agent == .claude, "comm \(info.comm), tty \(String(describing: info.tty))")
        #expect(info.comm == "claude")
        // On the session's own terminal, the one its files are named by.
        #expect(info.tty == h.session.tty, "\(String(describing: info.tty)) on \(h.session.tty)")
        #expect(h.agent["terminal"] as? String == h.session.tty)
        #expect(h.files.state.path.hasPrefix(h.fake.folder.path + "/" + h.session.tty + "/"))
    }

    @Test func theFakeTakesClaudesArguments() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let settings = #"{"permissions":{"deny":["Bash(rm:*)"]},"hooks":{}}"#
        let mcp = #"{"mcpServers":{"vibeswitcher":{"command":"/bin/false","args":[]}}}"#
        let h = try await NodeHarness.start(on: host, arguments: ["--settings", settings, "--mcp-config", mcp, "--model", "sonnet",
                                                                  "--permission-mode", "default", "--append-system-prompt", "be brief",
                                                                  "a goal"])
        // It drew its prompt box (`start` waited for it), with the prompt it was started with submitted.
        #expect(h.screen.contains("❯ ") && h.screen.contains("? for shortcuts"), "\(h.screen)")
        #expect(h.agent["prompt"] as? String == "a goal")
        try await h.waitFor { h.transcript.contains { ($0["message"] as? [String: Any])?["content"] as? String == "a goal" } }
        // None of Claude's own arguments was taken for a file or a prompt.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: h.fake.folder.path)) ?? []
        #expect(files == [h.session.tty], "\(files)")
        // A second fake on the same host has files of its own.
        let other = try await NodeHarness.start(on: host, fake: h.fake)
        #expect(other.session.tty != h.session.tty && other.files.state != h.files.state)
        #expect(other.agent["prompt"] is NSNull || other.agent["prompt"] == nil)
    }

    @Test func theFakeCallsAToolThroughTheServerItWasGiven() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let record = host.folder.appendingPathComponent("tool-calls.jsonl")
        let server = host.folder.appendingPathComponent("tool_server.py")
        try Self.standInToolServer.write(to: server, atomically: true, encoding: .utf8)
        let config: [String: Any] = ["mcpServers": ["vibeswitcher": ["command": "/usr/bin/python3", "args": ["-I", "-u", server.path, record.path]]]]
        let inline = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        let h = try await NodeHarness.start(on: host, arguments: ["--mcp-config", inline, "a goal"])

        h.tell(["op": "mcp", "tool": "status", "arguments": ["verbose": true]])
        try await h.waitFor { (h.agent["mcp"] as? [Any])?.isEmpty == false }
        let call = try #require((h.agent["mcp"] as? [[String: Any]])?.first)
        #expect(call["error"] == nil, "\(call)")
        let result = (call["reply"] as? [String: Any])?["result"] as? [String: Any]
        #expect(((result?["content"] as? [[String: Any]])?.first?["text"] as? String) == "called status", "\(call)")
        // The stand-in recorded the call it was made, as the fake made it.
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
        let recorded = try lines.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(recorded.map { $0["method"] as? String } == ["initialize", "notifications/initialized", "tools/call"], "\(recorded)")
        let params = recorded.last?["params"] as? [String: Any]
        #expect(params?["name"] as? String == "status" && (params?["arguments"] as? [String: Any])?["verbose"] as? Bool == true)

        // The same through a config file, as a path.
        let file = host.folder.appendingPathComponent("mcp.json")
        try Data(inline.utf8).write(to: file)
        let second = try await NodeHarness.start(on: host, fake: h.fake, arguments: ["--mcp-config", file.path])
        second.tell(["op": "mcp", "tool": "board", "arguments": [:] as [String: Any]])
        try await second.waitFor { (second.agent["mcp"] as? [Any])?.isEmpty == false }
        let reply = (second.agent["mcp"] as? [[String: Any]])?.first
        #expect((((reply?["reply"] as? [String: Any])?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
                == "called board", "\(String(describing: reply))")
    }

    @Test func theHarnessHookTakesASteeredMessage() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let h = try await NodeHarness.start(on: host)
        let pid = try #require(h.agentPid)
        // Posted to the fake's inbox in the host's root (never this process's own), as the engine will.
        let message = SteerMessage(text: "Look at the failing test first.", from: .user, agentPid: pid)
        try SteerInbox.post(message, tty: h.session.tty, root: host.root)
        #expect(FileManager.default.fileExists(atPath: host.root.appendingPathComponent("steer/\(h.session.tty).jsonl").path))
        #expect(h.hookTakes())
        let context = h.transcript.compactMap { line -> String? in
            guard let attachment = line["attachment"] as? [String: Any], attachment["type"] as? String == "hook_additional_context" else { return nil }
            return (attachment["content"] as? [String])?.joined(separator: "\n")
        }
        #expect(context.count == 1 && context[0].contains("> Look at the failing test first."), "\(context)")
        #expect(context.first?.contains("The user sent this") == true, "\(context)")
        // Taken: the next step has nothing.
        #expect(!h.hookTakes())
    }

    /// A fake started on a terminal an ended fake used (Linux hands a pty's number out again) starts fresh: it doesn't
    /// run the control lines the ended one was sent, nor keep its transcript or state.
    @Test func aFakeOnAnEndedFakesTerminalStartsFresh() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let fake = try FakeClaude.install(in: host.folder)
        // The session waits on a FIFO before it starts the fake, so its terminal's files can be laid down first, as an
        // ended fake leaves them.
        let gate = host.folder.appendingPathComponent("gate")
        try #require(mkfifo(gate.path, 0o600) == 0, "mkfifo: errno \(errno)")
        let session = try await host.spawn("read line < \(FakeClaude.quoted(gate.path)); exec \(FakeClaude.quoted(fake.launcher.path))",
                                           agent: "claude")
        let h = NodeHarness(found: session, on: host, fake: fake)
        try FileManager.default.createDirectory(at: h.files.state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"pid": 999999, "mode": "working", "turns": false}"#.write(to: h.files.state, atomically: true, encoding: .utf8)
        try (#"{"type": "user", "message": {"role": "user", "content": "the ended fake's prompt"}}"# + "\n")
            .write(to: h.files.transcript, atomically: true, encoding: .utf8)
        try (#"{"op": "work"}"# + "\n").write(to: h.files.control, atomically: true, encoding: .utf8)
        let opened = await offPool { () -> Bool in
            let fd = open(gate.path, O_WRONLY | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return write(fd, "go\n", 3) == 3
        }
        #expect(opened, "the gate didn't open")

        try await h.screenShows { $0.contains("? for shortcuts") }
        // A line told now is taken after any it would replay.
        h.tell(["op": "turns"])
        try await h.waitFor { h.agent["turns"] as? Bool == true }
        #expect(h.agentPid != 999_999 && h.agentPid != nil, "\(h.agent)")
        #expect(h.agent["mode"] as? String == "idle", "it ran the ended fake's control line: \(h.agent)")
        #expect(h.transcript.isEmpty, "\(h.transcript)")
        // The ended fake's folder was moved aside, whole.
        let aside = ((try? FileManager.default.contentsOfDirectory(atPath: fake.folder.path)) ?? []).filter { $0.hasPrefix(session.tty + ".ended-") }
        #expect(aside.count == 1, "\(aside)")
        let kept = aside.first.flatMap { try? String(contentsOf: fake.folder.appendingPathComponent("\($0)/transcript.jsonl"), encoding: .utf8) }
        #expect(kept?.contains("the ended fake's prompt") == true, "\(String(describing: kept))")
    }

    /// A launcher `install` has just written runs at once, while the process starts children meanwhile: none of them
    /// holds it open for writing (Linux won't exec a file that is, ETXTBSY). The children keep every descriptor they
    /// inherit, for 50 ms each, as a session's program or a git started by another test in this process can.
    @Test func aLauncherJustInstalledRunsWhileTheProcessStartsChildren() async throws {
        let children = Children()
        let spawning = Thread { children.spawnUntilStopped() }
        spawning.start()
        let scratch = scratch
        let refused = await offPool { () -> [String] in
            defer { children.stopAndWait() }
            var refused: [String] = []
            for index in 0..<60 {
                do {
                    let fake = try FakeClaude.install(in: scratch.url("fake-\(index)"))
                    // Exec'd at once; it starts and ends at once (no terminal): what matters is that it started.
                    try runToEnd(fake.launcher.path, [], environment: ["PATH": "/usr/bin:/bin"],
                                 output: .path("/dev/null", flags: O_WRONLY))
                } catch {
                    refused.append("\(index): \(error)")
                }
            }
            return refused
        }
        #expect(refused.isEmpty, "\(refused.count) of 60 launchers didn't start, the first: \(refused.first ?? "")")
        #expect(children.started > 0)
    }

    /// Children started with `posix_spawn` and nothing closed: each keeps every descriptor of this process that isn't
    /// close-on-exec, for its 50 ms. At most 64 at once.
    private final class Children: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var live: [pid_t] = []
        private var count = 0
        private let done = DispatchSemaphore(value: 0)
        var started: Int { lock.withLock { count } }

        func spawnUntilStopped() {
            let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("0.05"), nil]
            let environment: [UnsafeMutablePointer<CChar>?] = [nil]
            defer { arguments.forEach { free($0) } }
            while !lock.withLock({ stopped }) {
                reap(blocking: false)
                guard lock.withLock({ live.count }) < 64 else { sched_yield(); continue }
                var pid = pid_t()
                if posix_spawn(&pid, "/bin/sleep", nil, nil, arguments, environment) == 0 {
                    lock.withLock {
                        live.append(pid)
                        count += 1
                    }
                }
            }
            reap(blocking: true)
            done.signal()
        }

        /// Stops the spawning, and returns once every child has ended and been waited for.
        func stopAndWait() {
            lock.withLock { stopped = true }
            done.wait()
        }

        private func reap(blocking: Bool) {
            for pid in lock.withLock({ live }) {
                var status: Int32 = 0
                let got = waitpid(pid, &status, blocking ? 0 : WNOHANG)
                if got == pid || (got < 0 && errno == ECHILD) { lock.withLock { live.removeAll { $0 == pid } } }
            }
        }
    }

    /// A tool server standing in for `vibeswitcher-mcp`: MCP over stdio, a JSON message a line; it records each message
    /// it is sent in the file its argument names and answers a tool call with "called NAME".
    static let standInToolServer = #"""
    import json
    import sys

    record = sys.argv[1]
    for line in sys.stdin:
        if not line.strip():
            continue
        message = json.loads(line)
        with open(record, "a") as f:
            f.write(json.dumps(message) + "\n")
        if message.get("method") == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "stand-in", "version": "1"}}
        elif message.get("method") == "tools/call":
            result = {"content": [{"type": "text", "text": "called " + message["params"]["name"]}]}
        else:
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
    """#
}
