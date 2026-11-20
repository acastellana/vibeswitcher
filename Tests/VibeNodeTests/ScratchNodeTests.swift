import Foundation
import Testing
import VibeCore
import VibeNode

/// The scratch node's own clean-up (the engine sweep's test findings): what it leaves running, and where its short
/// folders go.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ScratchNodeTests {
    private let scratch = Scratch()

    /// A runner killed outright (or crashed) leaves no node running: its host ends with its owner (`--exit-with`), its
    /// session's program too, though the session is live and the host's idle exit never comes.
    @Test func theHostEndsWithItsOwner() async throws {
        var stand = Platform.Spawn(executable: "/bin/sleep", arguments: ["/bin/sleep", "600"])
        stand.stdin = .path("/dev/null", flags: O_RDONLY)
        let owner = SpawnedHost(pid: try await startRetrying(stand))
        defer { if owner.isRunning { kill(owner.processIdentifier, SIGKILL); _ = owner.isRunning } }
        let node = try await ScratchNode(scratch, owner: owner.processIdentifier)
        let session = try await node.spawn("exec sleep 600")
        try #require(session.isLive && session.childPID > 0, "\(session)")
        let program = try #require(Platform.Processes.link(session.childPID))

        kill(owner.processIdentifier, SIGKILL)
        #expect(await exited(owner, within: 30))
        #expect(await exited(node.process, within: 60), "the host outlived its owner: \(node.said)")
        #expect(await eventually(timeout: 30) { !ScratchNode.runs(program) }, "its session's program outlived its owner")
    }

    /// `stop()` ends what left the host's tree (here a program its session started in a session of its own, whose
    /// parent ended: init's now, as a tool server whose keeper was killed is) before the root is removed.
    @Test func aStopEndsWhatLeftTheHostsTree() async throws {
        let node = try await ScratchNode(scratch)
        let mark = node.root.appendingPathComponent("stray.pid")
        let line = "/usr/bin/setsid -f /bin/sh -c 'echo $$ > \(mark.path).part && mv \(mark.path).part \(mark.path) && exec sleep 600'; exec sleep 600"
        _ = try await node.spawn(line)
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: mark.path) }, "\(node.said)")
        let written = try String(contentsOf: mark, encoding: .utf8)
        let pid = try #require(pid_t(written.trimmingCharacters(in: .whitespacesAndNewlines)), "\(written)")
        let stray = try #require(Platform.Processes.link(pid))
        defer { if ScratchNode.runs(stray) { kill(stray.pid, SIGKILL) } }
        // Out of the host's tree before the stop lists it.
        try #require(await eventually(timeout: 30) { !ScratchNode.descendants(of: node.hostPID).contains { $0.pid == pid } })

        await offPool { node.stop() }
        #expect(!ScratchNode.runs(stray), "pid \(pid), out of the host's tree, outlived the stop")
    }

    /// The host says its pid, its build (the `build-info` its start checked) and `SWIFT_BACKTRACE` on its stderr at its
    /// start (the start plan's S5), the line the command line reads from the journal as the start's detail (ST-D24).
    @Test func theHostSaysItsBuildAndBacktraceAtItsStart() async throws {
        let node = try await ScratchNode(scratch)
        let line = "vibeswitcher-host: started pid \(node.hostPID) build \(ScratchNode.commit) SWIFT_BACKTRACE=enable=no"
        #expect(await eventually(timeout: 30) { node.said.contains(line + "\n") }, "\(node.said)")
        // As journald would record it from the unit's main process: the start's detail.
        let entries = NodeJournal.entries(json: [
            #"{"__REALTIME_TIMESTAMP":"1800000000000000","USER_UNIT":"vibeswitcher-node.service","JOB_TYPE":"start","JOB_RESULT":"done"}"#,
            String(decoding: try JSONSerialization.data(withJSONObject: ["__REALTIME_TIMESTAMP": "1800000001000000", "MESSAGE": line,
                                                                          "_PID": String(node.hostPID), "_TRANSPORT": "stdout", "_UID": String(getuid()),
                                                                          "_SYSTEMD_USER_UNIT": "vibeswitcher-node.service"]), as: UTF8.self),
        ].joined(separator: "\n"))
        let start = try #require(NodeJournal.events(entries, mainPID: node.hostPID, uid: getuid()).first)
        #expect(start.detail == "pid \(node.hostPID) build \(ScratchNode.commit) SWIFT_BACKTRACE=enable=no")
    }

    /// A scratch root too long for sockets gives a short folder of the run's own, linked from it, not the shared /tmp:
    /// removed with its link when empty, both kept (the link for the run's leftover check to find) when not.
    @Test func aLongScratchRootGivesAShortFolderOfTheRunsOwn() throws {
        let long = scratch.url("long-" + String(repeating: "x", count: 60))
        let empty = try #require(ShortScratch.make(linkedFrom: long))
        #expect(empty.folder.hasPrefix(ShortScratch.shared + "/vst-") && empty.folder.utf8.count <= 40, "\(empty.folder)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: empty.link)) == empty.folder)
        #expect(URL(fileURLWithPath: empty.link).deletingLastPathComponent().standardizedFileURL.path == long.standardizedFileURL.path)
        #expect(ShortScratch.removeIfEmpty(empty))
        #expect(!FileManager.default.fileExists(atPath: empty.folder) && (try? FileManager.default.destinationOfSymbolicLink(atPath: empty.link)) == nil)

        let used = try #require(ShortScratch.make(linkedFrom: long))
        defer { try? FileManager.default.removeItem(atPath: used.folder) }
        try FileManager.default.createDirectory(atPath: used.folder + "/vsn-left", withIntermediateDirectories: false)
        #expect(!ShortScratch.removeIfEmpty(used))
        #expect(FileManager.default.fileExists(atPath: used.folder + "/vsn-left"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: used.link)) == used.folder)
    }

    // MARK: The live page (the live plan's I1)

    /// A page's whole first connection on a scratch node: `web.open` in the scratch form; the page's file served with
    /// the policy and one `nosniff`, and 304 for an `ETag` it holds; the WebSocket, `auth` with the pairing code,
    /// `hello` with a token, the read kinds and the build; the four subscriptions and their snapshots; then a fake
    /// session's status change arriving as a delta whose `prev` is the snapshot's `seq`. Every frame passes the schema.
    @Test func aPageSessionFromPairToDelta() async throws {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let agent = try await HookedAgent.start(node)
        try agent.hook(node, "UserPromptSubmit")
        let opened = try LiveScratch.open(node)
        #expect(opened.url == "http://127.0.0.1:\(opened.port)/#pair=\(opened.code)")

        let page = try RawClient.ask(port: opened.port, "GET / HTTP/1.1", ["Host: 127.0.0.1:\(opened.port)"])
        #expect(page.status == 200 && String(decoding: page.body, as: UTF8.self).contains("<html"), "\(page.head)")
        #expect(page.head.components(separatedBy: "X-Content-Type-Options: nosniff").count == 2, "one nosniff: \(page.head)")
        #expect(page.head.contains("Content-Security-Policy: default-src 'none'"), "\(page.head)")
        let etag = try #require(page.head.split(separator: "\r\n").first { $0.hasPrefix("ETag: ") }?.dropFirst(6))
        let again = try RawClient.ask(port: opened.port, "GET / HTTP/1.1", ["Host: 127.0.0.1:\(opened.port)", "If-None-Match: \(etag)"])
        #expect(again.status == 304 && again.body.isEmpty, "\(again.head)")

        let socket = try LivePage(port: opened.port)
        _ = try socket.send("auth", ["pair": .string(opened.code), "client": .string("test")])
        let hello = try #require(try socket.next())
        #expect(hello["kind"]?.string == "hello" && hello["auth"]?["token"]?.string != nil, "\(hello)")
        #expect(hello["peer"]?["voice"]?.string == "other" && hello["assets"]?.string?.count == 8, "\(hello)")
        let kinds = Set(hello["kinds"]?.array?.compactMap(\.string) ?? [])
        #expect(kinds == ["status", "questions", "subscribe", "unsubscribe", "chat.page", "draft", "draft.clear", "board", "seen",
                          "session.draft", "session.draft.clear", "session.presets", "session.complete", "session.attach"], "\(kinds)")
        var seq: [String: Int] = [:]
        for (sub, collection) in [("s0", "node"), ("s1", "sessions"), ("s2", "leads"), ("s3", "cards")] {
            let id = try socket.send("subscribe", ["sub": .string(sub), "collection": .string(collection)])
            let reply = try #require(try socket.next())
            #expect(reply["re"]?.string == id && reply["result"]?["mode"]?.string == "snapshot", "\(reply)")
            let snapshot = try #require(try socket.next())
            #expect(snapshot["kind"]?.string == "snapshot" && snapshot["sub"]?.string == sub && snapshot["epoch"]?.string == hello["epoch"]?.string,
                    "\(snapshot)")
            seq[sub] = snapshot["seq"]?.int
            if collection == "node" {
                let web = snapshot["entries"]?.array?.first?["value"]?["web"]
                #expect(web?["state"]?.string == "listening" && web?["port"]?.int == Int(opened.port), "\(String(describing: web))")
            }
        }
        try agent.hook(node, "Stop")
        let frames = try #require(try socket.until { frame in
            frame["sub"]?.string == "s1" && frame["changes"]?.array?.contains {
                $0["id"]?.string == agent.id && $0["value"]?["shownStatus"]?.string == "done"
            } == true
        }, "the status change never came: \(node.said)")
        for delta in frames where delta["kind"]?.string == "delta" {
            let sub = try #require(delta["sub"]?.string)
            #expect(delta["prev"]?.int == seq[sub], "\(delta)")
            seq[sub] = delta["seq"]?.int
        }
        #expect(socket.unsound.isEmpty, "\(socket.unsound)")
    }

    /// Slice 2 (I2): a page follows a session's chat. The fake agent's hook names a transcript in the node's
    /// `~/.claude/projects`; the page subscribes to its chat, gets its items, then each line the agent writes as an op,
    /// and pages back with `chat.page`.
    @Test func aPageFollowsASessionsChat() async throws {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let agent = try await HookedAgent.start(node)
        let transcript = node.home.appendingPathComponent(".claude/projects/-project/1d2e3f40-0000-4000-8000-000000000001.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<3).map { ChatWorld.reply("a\($0)", "Reply \($0)") + "\n" }.joined().utf8).write(to: transcript)
        try agent.hook(node, "UserPromptSubmit", transcript: transcript)
        let opened = try LiveScratch.open(node)
        let socket = try LivePage(port: opened.port)
        _ = try socket.send("auth", ["pair": .string(opened.code), "client": .string("test")])
        _ = try #require(try socket.next())
        // The session says it has a transcript once the sessions store has read the hook.
        _ = try socket.send("subscribe", ["sub": .string("s1"), "collection": .string("sessions")])
        _ = try #require(try socket.until { frame in
            (frame["entries"]?.array ?? frame["changes"]?.array ?? []).contains {
                $0["id"]?.string == agent.id && $0["value"]?["hasTranscript"]?.bool == true
            }
        }, "the session never had its transcript: \(node.said)")

        let id = try socket.send("subscribe", ["sub": .string("c1"), "collection": .string("chat"), "key": .string(agent.id), "limit": .int(2)])
        let replied = try #require(try socket.until { $0["re"]?.string == id }, "no reply to the chat's subscribe")
        #expect(replied.last?["result"]?["mode"]?.string == "snapshot", "\(replied)")
        let snapshot = try #require(try socket.until { $0["sub"]?.string == "c1" }?.last)
        #expect(snapshot["kind"]?.string == "snapshot" && snapshot["more"]?.bool == true, "\(snapshot)")
        #expect(snapshot["items"]?.array?.compactMap { $0["id"]?.string } == ["a1.0", "a2.0"], "\(snapshot)")

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((ChatWorld.reply("a3", "Reply 3") + "\n").utf8))
        try handle.close()
        let added = try #require(try socket.until { $0["sub"]?.string == "c1" && $0["kind"]?.string == "delta" }?.last, "no op for the new line")
        #expect(added["prev"]?.int == snapshot["seq"]?.int, "\(added)")
        #expect(added["ops"]?.array?.first?["item"]?["id"]?.string == "a3.0", "\(added)")

        let page = try socket.send("chat.page", ["session": .string(agent.id), "before": .string("a1.0")])
        let paged = try #require(try socket.until { $0["re"]?.string == page }?.last)
        #expect(paged["result"]?["items"]?.array?.compactMap { $0["id"]?.string } == ["a0.0"] && paged["result"]?["more"]?.bool == false,
                "\(paged)")
        #expect(socket.unsound.isEmpty, "\(socket.unsound)")
    }

    /// No TCP listener until `web.open`: `status` says the web is off, with no port; once opened it listens on the port
    /// the address names, and `status` says so.
    @Test func theWebIsOffUntilAsked() async throws {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let client = try WireClient(node)
        let before = try #require(WireClient.reply(client.request("status", action: nil))?.result)
        #expect(before["web"]?["state"]?.string == "off" && before["web"]?["port"] == .null && before["web"]?["tokens"]?.int == 0, "\(before)")
        let opened = try LiveScratch.open(node)
        #expect(try RawClient.connects(address: "127.0.0.1", port: opened.port))
        let after = try #require(WireClient.reply(client.request("status", action: nil))?.result)
        #expect(after["web"]?["state"]?.string == "listening" && after["web"]?["port"]?.int == Int(opened.port), "\(after)")
    }

    /// The web's test flags are a scratch server's: the user's server (`--node`) refuses each and listens on
    /// `NodeWeb.port` alone, serves the embedded files, and asks the user's voice for `web.open`.
    @Test func aTestWebFlagIsRefusedOnTheUsersServer() throws {
        let base = ["vibeswitcher-server", "--host-connector", "3", "--host-socket", "/x/host.sock"]
        let flags = [ServerArguments.testWebPortFlag + "0", ServerArguments.testWebRootFlag + "/x/web", ServerArguments.testWebPairFlag]
        let user = try ServerArguments.parse(base + ["--node", "--node-root", "/x/b"] + flags).get()
        #expect(user.refused == flags)
        #expect(user.testWebPort == nil && user.testWebRoot == nil && !user.testWebPair)
        let scratch = try ServerArguments.parse(base + ["--root", "/x", "--node-root", "/x/b"] + flags).get()
        #expect(scratch.refused.isEmpty && scratch.testWebPort == 0 && scratch.testWebRoot == "/x/web" && scratch.testWebPair)
        #expect(throws: (any Error).self) { try ServerArguments.parse(base + ["--root", "/x", ServerArguments.testWebRootFlag + "web"]).get() }
    }

    /// `status` says the web's state: off, then the page's address with its tokens and pages once a page is paired.
    @Test func statusSaysTheWebsState() async throws {
        let node = try await ScratchNode(scratch, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let off = try await node.run(["status"])
        #expect(off.output.contains("web: off"), "\(off.output)")
        let opened = try LiveScratch.open(node)
        let socket = try LivePage(port: opened.port)
        _ = try socket.send("auth", ["pair": .string(opened.code), "client": .string("test")])
        #expect(try socket.next()?["kind"]?.string == "hello")
        // The connection is counted as the hub takes it, a moment after `hello`.
        var said = ""
        let deadline = Date().addingTimeInterval(30)
        while !said.contains("web: http://127.0.0.1:\(opened.port)/, 1 tokens alive, 1 pages open"), Date() < deadline {
            said = try await node.run(["status"]).output
        }
        #expect(said.contains("web: http://127.0.0.1:\(opened.port)/, 1 tokens alive, 1 pages open"), "\(said)")
    }

}
