import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// docs/process/v2-acceptance.md, automated: each row a case named after it, run as a person runs it, on a scratch node
/// (`ScratchNode`: a scratch session host and the built server, its root and home its own, never `~/.vibeswitcher`)
/// with `FakeClaude` for every agent (no real one), through the built command line on a pty of its own with the typed
/// code (`runOnTerminal`), each asserting what the row says must happen. Where an agent would act, the fake is told
/// to (`EngineEndToEndTests.tell`) or calls its tool server as the agent would (`FakeClaude.Files.call`); what Claude
/// Code's hooks would write the case writes (`hook`). A row that truly needs a real Claude is skipped saying why.
///
/// `scripts/e2e/node-acceptance.sh` runs this suite alone; it is gated (`NodeAcceptance.enabled`) behind
/// `VIBESWITCHER_ACCEPTANCE=1`, set by that script and by `scripts/nightly.sh`.
@Suite(NodeTraits.linuxOnly, .enabled(if: NodeAcceptance.enabled, "set VIBESWITCHER_ACCEPTANCE=1 (scripts/e2e/node-acceptance.sh)"),
       .timeLimit(.minutes(10)))
struct NodeAcceptanceTests {
    private let scratch = Scratch()

    // MARK: A1-A2, the node

    @Test("A1: status shows the build, the host, the server, the sessions, the leads and the cards, with no error")
    func a1Status() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let shown = try await node.run(["status"])
        #expect(shown.status == 0 && !shown.errors.lowercased().contains("error"), "\(shown.output)\(shown.errors)")
        let lines = shown.output.components(separatedBy: "\n")
        #expect(lines.contains { $0.hasPrefix("node local, server pid ") && $0.contains("build \(ScratchNode.commit)") }, "\(shown.output)")
        #expect(lines.contains { $0.hasPrefix("host pid \(node.hostPID) ") }, "\(shown.output)")
        #expect(lines.contains("No agent sessions."), "\(shown.output)")
        #expect(!shown.output.lowercased().contains("error"), "\(shown.output)")
        let status = try await node.statusJSON()
        for field in ["node", "server", "host", "sessions", "leads", "cards"] { #expect(status[field] != nil, "\(field): \(status.keys.sorted())") }
    }

    @Test("A2: config held shows a short card, and config accept with the code clears it")
    func a2ConfigHeldAndAccept() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let repo = try await Self.repository(node)
        let held = try await node.run(["config", "held", repo.path])
        #expect(held.status == 0, "\(held.output)\(held.errors)")
        let card = try #require(ScratchNode.card(held.output, "config accept"), "\(held.output)")
        let accepted = try await node.runOnTerminal(["config", "accept", card])
        #expect(accepted.status == 0 && accepted.output.contains("accepted"), "\(accepted.output)\(accepted.errors)")
        let after = try await node.run(["config", "held", repo.path])
        #expect(after.status == 0 && after.output.contains("nothing held"), "\(after.output)\(after.errors)")
    }

    // MARK: A4-A9, a session of the user's

    @Test("A4: new starts a Claude session, listed in status")
    func a4New() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, _) = try await Self.newClaude(node, model: "haiku")
        #expect(session.command?.hasSuffix("--model 'haiku'") == true, "\(String(describing: session.command))")
        let id = NodeIds.session(host: session.id)
        #expect(await node.eventuallyStatus { Self.listed($0, id) != nil }, "\(node.said)")
        let shown = try await node.run(["status"])
        #expect(shown.output.contains(String(session.id.uuidString.lowercased().prefix(8))) || shown.output.contains(session.tty), "\(shown.output)")
    }

    @Test("A5: send types the message into the session, and the agent takes it")
    func a5Send() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, files) = try await Self.newClaude(node)
        let sent = try await node.runOnTerminal(["send", Self.short(session), "say hello in three words"])
        #expect(sent.status == 0 && sent.output.contains("sent: "), "\(sent.output)\(sent.errors)\n\(node.said)")
        _ = try await EngineEndToEndTests.prompt(files) { $0 == "say hello in three words" }
        // The page's chat of a session is ScratchNodeTests.aPageFollowsASessionsChat's (the fake's transcript isn't in
        // Claude's own folders, where the node reads chats from).
    }

    @Test("A6: Claude's folder-trust dialog and a permission prompt each show as the session's prompt, and reply answers them")
    func a6Reply() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, files) = try await Self.newClaude(node)
        let id = NodeIds.session(host: session.id)
        try EngineEndToEndTests.tell(files, ["op": "trust"])
        try #require(await node.eventuallyStatus { Self.prompt($0, id)?.contains("Yes, I trust this folder") == true }, "\(node.said)")
        let trusted = try await node.runOnTerminal(["reply", Self.short(session), "2"])
        #expect(trusted.status == 0 && trusted.output.contains("answered: option 2"), "\(trusted.output)\(trusted.errors)")
        #expect(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["trusted"] as? Bool == true })

        try EngineEndToEndTests.tell(files, ["op": "permission", "command": "make clean"])
        try #require(await node.eventuallyStatus { Self.prompt($0, id)?.contains("Do you want to proceed?") == true }, "\(node.said)")
        let allowed = try await node.runOnTerminal(["reply", Self.short(session), "1"])
        #expect(allowed.status == 0 && allowed.output.contains("answered: option 1"), "\(allowed.output)\(allowed.errors)")
        #expect(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["reply"] as? String == "Allowed." })
        #expect(await node.eventuallyStatus { Self.listed($0, id)?["prompt"] is NSNull })
    }

    @Test("A7: send --now steers a working session mid-turn, nothing lost")
    func a7SendNow() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, files) = try await Self.newClaude(node)
        let pid = try #require((EngineEndToEndTests.state(files)["pid"] as? Int).map(Int32.init))
        try hook(node, ["hook_event_name": "UserPromptSubmit", "prompt": "Fix the parser"], tty: session.tty, pid: pid)
        let sent = try await node.runOnTerminal(["send", Self.short(session), "Use the new tokenizer", "--now"])
        #expect(sent.status == 0 && sent.output.contains("steered: "), "\(sent.output)\(sent.errors)\n\(node.said)")
        // At its next step its hook hands it over as the user's: nothing typed into its box mid-turn, nothing lost.
        let taken = leadsHookTakes(node, event: "PostToolUse", tty: session.tty, pid: pid)
        #expect(taken.messages.map(\.text) == ["Use the new tokenizer"] && taken.messages.map(\.from) == [.user], "\(taken.messages)")
        #expect(EngineEndToEndTests.prompts(files).isEmpty, "\(EngineEndToEndTests.prompts(files))")
    }

    @Test("A8: rename and pause are shown; end removes the session, and resume lists it")
    func a8RenamePauseEnd() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (session, _) = try await Self.newClaude(node)
        let (short, id) = (Self.short(session), NodeIds.session(host: session.id))
        let renamed = try await node.runOnTerminal(["rename", short, "Release notes"])
        #expect(renamed.status == 0, "\(renamed.output)\(renamed.errors)")
        #expect(await node.eventuallyStatus { Self.listed($0, id)?["name"] as? String == "Release notes" })
        let paused = try await node.runOnTerminal(["pause", short, "--hours", "2"])
        #expect(paused.status == 0 && paused.output.contains("paused: session \(short)"), "\(paused.output)\(paused.errors)")
        #expect(await node.eventuallyStatus { Self.listed($0, id)?["pausedUntil"] is String })
        let ended = try await node.runOnTerminal(["end", short])
        #expect(ended.status == 0 && ended.output.contains("ended: session \(short)"), "\(ended.output)\(ended.errors)")
        #expect(await node.eventuallyStatus { Self.listed($0, id) == nil })
        // Past the grace an ended session is kept for (`LeadEngine.openGrace`, 30 s), `resume` lists it.
        #expect(await Self.polled(timeout: 120) { (try? await node.run(["resume"]))?.output.contains(short) == true }, "\(node.said)")
    }

    @Test("A9: resume brings an ended session back in its conversation")
    func a9Resume() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let folder = node.root.appendingPathComponent("work").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (session, files) = try await Self.newClaude(node, folder: folder)
        let pid = try #require((EngineEndToEndTests.state(files)["pid"] as? Int).map(Int32.init))
        // Its conversation, as Claude Code's hooks name it, with its transcript in Claude's folder for the project.
        let conversation = UUID().uuidString.lowercased()
        let transcript = URL(fileURLWithPath: LeadLaunch.claudeProjectFolder(folder.path, home: node.home.path)).appendingPathComponent("\(conversation).jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (#"{"type":"user","cwd":"\#(folder.path)","sessionId":"\#(conversation)"}"# + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        try hook(node, ["hook_event_name": "SessionStart", "session_id": conversation, "transcript_path": transcript.path], tty: session.tty, pid: pid)
        try #require(await node.eventuallyStatus { Self.listed($0, NodeIds.session(host: session.id))?["agentSession"] as? String == conversation },
                     "\(node.said)")
        // The engine's record of the user's sessions (`engine.json`) has it with its conversation before it ends.
        let record = EngineState.url(root: node.root)
        try #require(await eventually(timeout: 60) { ((try? String(contentsOf: record, encoding: .utf8)) ?? "").contains(conversation) }, "\(node.said)")
        let short = Self.short(session)
        let ended = try await node.runOnTerminal(["end", short])
        #expect(ended.status == 0, "\(ended.output)\(ended.errors)")
        try #require(await Self.polled(timeout: 120) { (try? await node.run(["resume"]))?.output.contains(short) == true }, "\(node.said)")
        let resumed = try await node.runOnTerminal(["resume", short])
        #expect(resumed.status == 0, "\(resumed.output)\(resumed.errors)\n\(node.said)")
        let back = try #require(await Self.liveSession(node) { $0.id != session.id && $0.label == "Claude" }, "\(node.said)")
        #expect(back.cwd == folder.path && back.command?.hasSuffix("--resume '\(conversation)'") == true, "\(back)")
        #expect(await eventually(timeout: 60) { EngineEndToEndTests.state(node.fake.files(terminal: back.tty))["resume"] as? String == conversation })
    }
}

/// The suite's gate and helpers.
enum NodeAcceptance {
    /// Whether the acceptance suite runs: `VIBESWITCHER_ACCEPTANCE=1` (its script, the nightly run).
    static let enabled = ProcessInfo.processInfo.environment["VIBESWITCHER_ACCEPTANCE"] == "1"
}

extension NodeAcceptanceTests {
    /// A scratch repository under the node's root with one commit and a workflow.md whose test command passes.
    static func repository(_ node: ScratchNode, name: String = "repo") async throws -> URL {
        let repo = node.root.appendingPathComponent(name)
        try await scratchRepository(repo)
        try EngineEndToEndTests.workflow(repo)
        return repo
    }

    /// `new FOLDER [--model M]` on a terminal, the code typed: the session it started, its fake up.
    static func newClaude(_ node: ScratchNode, folder: URL? = nil, model: String? = nil,
                          sourceLocation: SourceLocation = #_sourceLocation) async throws -> (HostSession, FakeClaude.Files) {
        let folder = folder ?? node.root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = try await node.runOnTerminal(["new", folder.path] + (model.map { ["--model", $0] } ?? []))
        try #require(started.status == 0 && started.output.contains("started: session"), "\(started.output)\(started.errors)\n\(node.said)",
                     sourceLocation: sourceLocation)
        let short = try #require(started.output.components(separatedBy: "started: session ").last?.prefix(8)).description
        let session = try #require(try node.sessions().first { $0.id.uuidString.lowercased().hasPrefix(short) && $0.isLive }, "\(node.said)",
                                   sourceLocation: sourceLocation)
        let files = node.fake.files(terminal: session.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["pid"] != nil }, "\(node.said)", sourceLocation: sourceLocation)
        return (session, files)
    }

    /// Asks `condition` (a command run) until it holds or `timeout` passes, half a second between asks.
    static func polled(timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return await condition()
    }

    static func short(_ session: HostSession) -> String { String(session.id.uuidString.lowercased().prefix(8)) }

    /// `status --json`'s entry for the session `id` (the node's), if listed.
    static func listed(_ status: [String: Any], _ id: String) -> [String: Any]? {
        (status["sessions"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    /// The question of the session `id`'s prompt in `status --json`, with its options.
    static func prompt(_ status: [String: Any], _ id: String) -> String? {
        guard let prompt = listed(status, id)?["prompt"] as? [String: Any] else { return nil }
        return ([prompt["question"] as? String ?? ""] + ((prompt["options"] as? [String]) ?? [])).joined(separator: "\n")
    }

    /// The first live session the host lists that `matches`, once it does.
    static func liveSession(_ node: ScratchNode, timeout: TimeInterval = 60, _ matches: @escaping (HostSession) -> Bool) async -> HostSession? {
        var found: HostSession?
        _ = await eventually(timeout: timeout) {
            found = (try? node.sessions())?.first { $0.isLive && matches($0) }
            return found != nil
        }
        return found
    }
}
