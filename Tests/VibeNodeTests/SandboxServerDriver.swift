import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `scripts/sandbox-server.sh`'s node (the live plan's G1): a `ScratchNode` with the server's web on, two fake sessions
/// and a fake lead with a question open and a made-up board, for a person to look at in a browser. **Not a test:** it runs only when the
/// script names its folder (`VIBESWITCHER_SANDBOX_SERVER`), and it lives until it is told to quit, or until the 24 h
/// limit. Everything is the tests' own: the scratch host and server built from this worktree, `FakeClaude` as the
/// lead, stage 1's fake agent as the sessions; nothing reaches the user's `~/.vibeswitcher`, `~/.claude` or node.
///
/// The script talks to it through `<folder>/control`: it writes `req-<id>` (one word: `url`, `flip`, `quit`) and reads
/// `rep-<id>` (`ok` or `error` on the first line, then the answer). It writes `started` once the node is up.
///
/// - `shell`: the shell session's id on the page (its address is `#/s/<id>`).
/// - `url`: a fresh pairing code (`web.open` in a scratch server's form, `--test-web-pair`), the page's address.
/// - `flip`: the first session's turn ends, or starts again (`done` and `working` by turns), as its hook would say.
/// - `chat`: the first session's agent takes its next step in its transcript (a command and its output, or a reply),
///   which its chat on the page shows as it lands. Its transcript starts with a short conversation.
/// - `answer`: `vibeswitcher answer CARD` with no text on the lead's open card, on a terminal of its own with the
///   card's code typed, as the user confirms what the page drafted (the live plan's slice 3); its output.
/// - Its server opens terminals to its pages (`--test-web-terminal`, typed: a scratch server's alone, LW-D12), and a third
///   session is a shell in a scratch folder (`example-shell`), whose screen the page's Terminal pane shows and types
///   into: the only session typed into from a page, and a scratch one (AGENTS.md's first hard rule).
/// - Unless `VIBESWITCHER_SANDBOX_STILL` is set, the second session's status changes by itself every 20 s too, and the
///   first session's agent takes a step every 8 s, so an open page shows the list and the chat living.
@Suite(NodeTraits.linuxOnly)
struct SandboxServerDriver {
    static let folderKey = "VIBESWITCHER_SANDBOX_SERVER"
    static var folder: URL? { ProcessInfo.processInfo.environment[folderKey].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    @Test(.enabled(if: SandboxServerDriver.folder != nil, "only scripts/sandbox-server.sh runs it"), .timeLimit(.minutes(24 * 60)))
    func sandbox() async throws {
        let folder = try #require(Self.folder)
        let control = folder.appendingPathComponent("control", isDirectory: true)
        let environment = ProcessInfo.processInfo.environment
        let port = environment["VIBESWITCHER_SANDBOX_PORT"].flatMap(UInt16.init) ?? 0
        // `--watch`: the terminals watched, as on the user's node; by default typed, a scratch server's spike.
        let terminal = environment["VIBESWITCHER_SANDBOX_WATCH"] != nil ? ServerArguments.testWebTerminalWatchFlag : ServerArguments.testWebTerminalFlag
        var arguments = ["--server-arg", ServerArguments.testWebPortFlag + String(port), "--server-arg", ServerArguments.testWebPairFlag,
                         "--server-arg", terminal]
        if let root = environment["VIBESWITCHER_SANDBOX_WEB_ROOT"] { arguments += ["--server-arg", ServerArguments.testWebRootFlag + root] }
        let scratch = Scratch()
        let node = try await ScratchNode(scratch, holdFirstLook: true, hostArguments: arguments)
        defer { node.stop() }

        // Two sessions of the host: one working on the site, with a conversation in its transcript, one asking for a
        // permission in the API.
        let site = try await HookedAgent.start(node, project: "example-site")
        let transcript = node.home.appendingPathComponent(".claude/projects/-example-site/5c1e7a20-3b4d-4e8f-9a6b-1c2d3e4f5a6b.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let story = SandboxChat(folder: site.folder.path)
        try Data(story.opening.map { $0 + "\n" }.joined().utf8).write(to: transcript)
        try site.hook(node, "UserPromptSubmit", transcript: transcript)
        let api = try await HookedAgent.start(node, project: "example-api")
        try api.hook(node, "PermissionRequest")

        // A shell for the Terminal pane, in a scratch folder with a few files, its prompt short.
        let shellFolder = node.home.appendingPathComponent("example-shell")
        for name in ["src", "tests"] {
            try FileManager.default.createDirectory(at: shellFolder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["README.md", "package.json", "src/index.js"] {
            try Data("// \(name)\n".utf8).write(to: shellFolder.appendingPathComponent(name))
        }
        // The node lists agents' sessions, as the host started them (`HostedAgents`): the shell is started as Claude, a copy
        // of bash named `claude` (as the fake agents run as a copy of sleep), with a hook state saying its turn is done.
        let shellBin = node.root.appendingPathComponent("shell-bin")
        try FileManager.default.createDirectory(at: shellBin, withIntermediateDirectories: true)
        let bash = shellBin.appendingPathComponent("claude")
        try copyClosedOnExec(URL(fileURLWithPath: "/bin/bash").resolvingSymlinksInPath().path, to: bash.path)
        let says = environment["VIBESWITCHER_SANDBOX_WATCH"] != nil ? "watched from the page" : "typed into from the page"
        let shell = try await node.spawn("printf '\\033[1mexample-shell\\033[0m: a scratch session, \(says).\\n\\n'; "
            + "PS1='\\[\\033[32m\\]example-shell\\[\\033[0m\\] $ ' exec '\(bash.path)' --noprofile --norc -i", cwd: shellFolder.path, label: "Shell",
                                     agent: "claude")
        try HookedAgent(session: shell, pid: shell.childPID, folder: shellFolder).hook(node, "Stop")

        // A lead on a scratch repository, started as the user starts one (the accepts, then `lead`, each code typed),
        // asking the user one question through its tool server.
        let repo = node.root.appendingPathComponent("example-app")
        try await scratchRepository(repo)
        try EngineEndToEndTests.workflow(repo)
        let head = Git.run(["rev-parse", "main"], in: repo.path).output
        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: head)
        let started = try await node.runOnTerminal(["lead", repo.path, "--goal", "Ship the onboarding page"])
        try #require(started.status == 0, "the lead didn't start: \(started.output)\n\(node.said)")
        let lead = try #require(try node.sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") }, "\(node.said)")
        let tools = node.fake.files(terminal: lead.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(tools)["pid"] != nil }, "\(node.said)")
        let leadPID = try #require((EngineEndToEndTests.state(tools)["pid"] as? Int).map(Int32.init))
        try hook(node, ["hook_event_name": "Stop"], tty: lead.tty, pid: leadPID)
        try tools.call("ask_user", ["question": "Launch the onboarding page to the testers on Thursday, or wait for the copy review?",
                                    "options": ["Thursday", "Wait for the review"]])
        try #require(await eventually(timeout: 120) { tools.calls().count == 1 }, "\(node.said)")
        // A made-up board for the lead (the board view's): its running task worked by example-site, so its row opens
        // that session's chat; example-api checks the one in review.
        let made = WireVectors.sampleBoard(now: Date().timeIntervalSince1970, worker: site.session.id, verifier: api.session.id)
        try BoardStore(root: repo.path).update { $0.tasks = made.tasks }
        // A new task's `since` is stamped its creation: the times it has been in its state, set again (no status changes).
        try BoardStore(root: repo.path).update { board in
            for index in board.tasks.indices { board.tasks[index].since = made.tasks.first { $0.id == board.tasks[index].id }?.since }
        }

        try Data("\(getpid())\n\(node.root.path)\n".utf8).write(to: control.appendingPathComponent("started"))

        var siteWorking = true, apiAsking = true
        var lastLife = Date(), lastStep = Date()
        var step = 0
        func takeStep() throws -> String {
            let lines = story.step(step)
            step += 1
            let handle = try FileHandle(forWritingTo: transcript)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
            return "example-site took step \(step)"
        }
        let still = environment["VIBESWITCHER_SANDBOX_STILL"] != nil
        while true {
            let requests = ((try? FileManager.default.contentsOfDirectory(atPath: control.path)) ?? []).filter { $0.hasPrefix("req-") }.sorted()
            for name in requests {
                let request = control.appendingPathComponent(name)
                let word = ((try? String(contentsOf: request, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: request)
                var reply = "ok\n"
                switch word {
                case "shell":
                    reply += NodeIds.session(host: shell.id)
                case "url":
                    do { reply += try LiveScratch.open(node).url } catch { reply = "error\n\(error)" }
                case "flip":
                    siteWorking.toggle()
                    try site.hook(node, siteWorking ? "UserPromptSubmit" : "Stop", transcript: transcript)
                    reply += "example-site is \(siteWorking ? "working" : "done")"
                case "chat":
                    reply += try takeStep()
                case "answer":
                    do {
                        let listed = WireClient.reply(try WireClient(node).request("questions", action: nil))
                        let card = listed?.result?["cards"]?.array?.first { $0["open"]?.bool == true }?["id"]?.string
                        guard let card else { throw CancellationError() }
                        let ran = try await node.runOnTerminal(["answer", card])
                        reply = (ran.status == 0 ? "ok\n" : "error\n") + ran.output
                    } catch {
                        reply = "error\nno open card to answer: \(error)"
                    }
                case "quit":
                    reply += "quitting"
                default:
                    reply = "error\nunknown command \(word): url, shell, flip, chat, answer, quit"
                }
                let answer = control.appendingPathComponent("rep-" + name.dropFirst(4))
                try Data(reply.utf8).write(to: answer.appendingPathExtension("part"))
                try FileManager.default.moveItem(at: answer.appendingPathExtension("part"), to: answer)
                if word == "quit" { return }
            }
            if !still, Date().timeIntervalSince(lastLife) >= 20 {
                lastLife = Date()
                apiAsking.toggle()
                try api.hook(node, apiAsking ? "PermissionRequest" : "UserPromptSubmit")
            }
            if !still, Date().timeIntervalSince(lastStep) >= 8 {
                lastStep = Date()
                _ = try takeStep()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

/// The sandbox's first session's conversation, as Claude Code writes its transcript: an opening, then steps that go round
/// (a command and its output, an edit, a reply), each line's ids its own.
struct SandboxChat {
    let folder: String

    private static func stamp() -> String { NodeWire.dateText(Date()) }

    private static func line(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    private static func user(_ uuid: String, _ content: Any) -> String {
        line(["type": "user", "uuid": uuid, "timestamp": stamp(), "message": ["role": "user", "content": content]])
    }

    private static func assistant(_ uuid: String, _ content: [[String: Any]]) -> String {
        line(["type": "assistant", "uuid": uuid, "timestamp": stamp(), "message": ["id": "msg-\(uuid)", "role": "assistant", "content": content]])
    }

    private static func tool(_ uuid: String, _ id: String, _ name: String, _ input: [String: Any]) -> String {
        assistant(uuid, [["type": "tool_use", "id": id, "name": name, "input": input]])
    }

    private static func result(_ uuid: String, _ id: String, _ output: String, failed: Bool = false) -> String {
        user(uuid, [["type": "tool_result", "tool_use_id": id, "content": output, "is_error": failed]])
    }

    private static func reply(_ uuid: String, _ text: String) -> String { assistant(uuid, [["type": "text", "text": text]]) }

    var opening: [String] {
        [Self.user("open-1", "The hero's headline wraps badly on phones. Fix it, and keep the desktop look."),
         Self.tool("open-2", "open-t1", "Read", ["file_path": "\(folder)/pages/hero.css"]),
         Self.result("open-3", "open-t1", ".hero h1 {\n  font-size: 64px;\n  white-space: nowrap;\n}"),
         Self.reply("open-4", "The headline never wraps (`white-space: nowrap`) and has a fixed size, so on a phone it runs off the screen. I'll let it wrap and size it to the viewport:\n\n- `clamp()` for the size, so the desktop keeps its 64 px\n- `text-wrap: balance`, so two lines read evenly"),
         Self.tool("open-5", "open-t2", "Edit", ["file_path": "\(folder)/pages/hero.css",
                                                  "old_string": ".hero h1 {\n  font-size: 64px;\n  white-space: nowrap;\n}",
                                                  "new_string": ".hero h1 {\n  font-size: clamp(34px, 7vw, 64px);\n  text-wrap: balance;\n}"]),
         Self.result("open-6", "open-t2", "The file has been updated."),
         Self.tool("open-7", "open-t3", "Bash", ["command": "npm test -- hero", "description": "Run the hero's tests"]),
         Self.result("open-8", "open-t3", "PASS  tests/hero.test.js\n  ✓ wraps on a 375 px screen (38 ms)\n  ✓ keeps 64 px on a desktop (11 ms)"),
         Self.reply("open-9", "Fixed: the headline wraps into two even lines on a phone and keeps its size on a desktop. Both tests pass.")]
    }

    /// Step `index`'s lines.
    func step(_ index: Int) -> [String] {
        let id = "s\(index)"
        switch index % 3 {
        case 0:
            return [Self.user("\(id)-p", "Now check the pricing page the same way."),
                    Self.tool("\(id)-a", "\(id)-t", "Bash", ["command": "npm test -- pricing", "description": "Run the pricing page's tests"]),
                    Self.result("\(id)-r", "\(id)-t", "PASS  tests/pricing.test.js\n  ✓ wraps on a 375 px screen (41 ms)")]
        case 1:
            return [Self.tool("\(id)-a", "\(id)-t", "Read", ["file_path": "\(folder)/pages/pricing.css"]),
                    Self.result("\(id)-r", "\(id)-t", ".pricing h2 { font-size: 40px; }")]
        default:
            return [Self.reply("\(id)-m", "The pricing page wraps well already: its heading is sized in `clamp()` too. Step \(index / 3 + 1) done.")]
        }
    }
}
