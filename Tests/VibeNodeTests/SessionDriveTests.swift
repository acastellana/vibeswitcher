import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// Driving an ordinary session (the parity table's gaps 1, 3 and 6, 2026-11-20): `session.new`, `session.end` and
/// `session.reply`, each the user's voice and recorded in the host's vault first; the question open on a session's
/// screen as its `prompt`; a page's `session.draft`, which `send` types. Only fake and scratch sessions are started,
/// ended or typed into (AGENTS.md).
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct SessionDriveTests {
    private let scratch = Scratch()

    /// The node's `claude` (`NodePreflight.claudeLink` on a scratch root) linked to the world's fake.
    private func linkClaude(_ world: CardWorld) throws {
        let link = world.host.root.appendingPathComponent("v2/test/claude")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: world.world.fake.launcher.path)
    }

    private func hosted(_ world: CardWorld, _ reply: NodeWire.Reply) -> HostSession? {
        guard let id = reply.result?["session"]?.string.flatMap({ UUID(uuidString: String($0.dropFirst(NodeIds.node.count + 1))) }) else { return nil }
        return world.queue.sync { world.world.link.sessions.first { $0.id == id } }
    }

    private func live(_ world: CardWorld, _ id: UUID) -> Bool {
        world.queue.sync { world.world.link.sessions.contains { $0.id == id && $0.isLive } }
    }

    /// A fake Claude between turns in an ordinary session, once the link lists it.
    private func claude(_ world: CardWorld) async throws -> NodeHarness {
        let harness = try await NodeHarness.start(on: world.host, fake: world.world.fake, cwd: world.repo, label: "Claude")
        try #require(await eventually(timeout: 60) { live(world, harness.session.id) })
        return harness
    }

    // MARK: new

    @Test func aShellAndAClaudeStartAsTheUsers() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let action = UUID().uuidString.lowercased()
        let shell = try #require(await world.ask("session.new", ["folder": .string(world.repo), "agent": .string("shell")], action: action))
        #expect(shell.ok, "\(shell)")
        let started = try #require(hosted(world, shell))
        #expect(started.label == "Shell" && started.agent == nil && started.cwd == world.repo, "\(started)")
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["session.new"])

        try linkClaude(world)
        let reply = try #require(await world.ask("session.new", ["folder": .string(world.repo), "model": .string("opus")]))
        #expect(reply.ok && reply.result?["agent"]?.string == "claude" && reply.result?["model"]?.string == "opus", "\(reply)")
        let session = try #require(hosted(world, reply))
        #expect(session.label == "Claude" && session.agent == "claude", "\(session)")
        #expect(session.command?.hasSuffix("--model 'opus'") == true, "\(String(describing: session.command))")
        let harness = NodeHarness(found: session, on: world.host, fake: world.world.fake)
        try await harness.screenShows { $0.contains("? for shortcuts") }
    }

    @Test func aFolderModelOrAgentThatIsntOneIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let cases: [([String: NodeWire.Value], NodeWire.Code, String)] = [
            (["folder": .string("repo")], .badArgs, "absolute path"),
            (["folder": .string(world.repo + "/missing")], .refused, "isn't a folder"),
            (["folder": .string(world.repo), "model": .string("opus; rm -rf ~")], .badArgs, "isn't a model name"),
            (["folder": .string(world.repo), "agent": .string("codex")], .badArgs, "claude or shell"),
            (["folder": .string(world.repo), "agent": .string("shell"), "model": .string("opus")], .badArgs, "a shell takes no model"),
            // No `claude` link on this node yet: the link it read is named.
            (["folder": .string(world.repo)], .refused, "v2/test/claude"),
        ]
        for (args, code, says) in cases {
            let reply = try #require(await world.ask("session.new", args))
            #expect(reply.error?.code == code.rawValue && reply.error?.message.contains(says) == true, "\(args): \(reply)")
        }
        #expect(world.queue.sync { world.world.link.sessions.filter(\.isLive).isEmpty })
    }

    // MARK: end

    @Test func anOrdinarySessionEndsALeadAndATeamMemberDont() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let shell = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Shell")
        let lead = try await world.sleepingLead()
        let worker = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Worker: login-fix")
        try #require(await eventually(timeout: 60) { [shell, lead, worker].allSatisfy { live(world, $0.id) } })

        let refusedLead = try #require(await world.ask("session.end", ["session": .string(lead.id.uuidString)]))
        #expect(refusedLead.error?.code == NodeWire.Code.refused.rawValue && refusedLead.error?.message.contains("--replace") == true, "\(refusedLead)")
        let refusedWorker = try #require(await world.ask("session.end", ["session": .string(worker.id.uuidString)]))
        #expect(refusedWorker.error?.code == NodeWire.Code.refused.rawValue && refusedWorker.error?.message.contains("tell") == true, "\(refusedWorker)")

        let action = UUID().uuidString.lowercased()
        let ended = try #require(await world.ask("session.end", ["session": .string(String(shell.id.uuidString.prefix(8)))], action: action))
        #expect(ended.ok && ended.result?["ended"]?.bool == true, "\(ended)")
        #expect(!live(world, shell.id))
        #expect(live(world, lead.id) && live(world, worker.id))
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["session.end"])
        let again = try #require(await world.ask("session.end", ["session": .string(shell.id.uuidString)]))
        #expect(again.error?.code == NodeWire.Code.gone.rawValue, "\(again)")
    }

    // MARK: reply

    /// A permission prompt answered as the app's card answers it; an answer for another question, an option it hasn't,
    /// words for an option that takes none, and a question already answered are refused, nothing typed.
    @Test func theSessionsQuestionIsAnsweredAsTheAppAnswersIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        let id = harness.session.id.uuidString
        let nothing = try #require(await world.ask("session.reply", ["session": .string(id), "choice": .int(1)]))
        #expect(nothing.error?.message.contains("no question is open") == true, "\(nothing)")

        harness.tell(["op": "permission", "command": "rm -rf build"])
        try await harness.screenShows { $0.contains("Do you want to proceed?") }
        // It draws before it writes its state.
        try await harness.waitFor { harness.agent["mode"] as? String == "permission" }
        let question = try #require(SessionPrompt.menu(on: harness.screen)).question
        #expect(question.contains("rm -rf build") && question.contains("Do you want to proceed?"), "\(question)")
        for (args, says) in [(["choice": NodeWire.Value.int(4)], "3 options"), (["choice": .int(1), "question": .string("Delete it?")], "isn't the one"),
                             (["choice": .int(2), "text": .string("sure")], "takes no words"),
                             (["choice": .int(1), "options": .array([.string("Yes"), .string("No")])], "options aren't the ones")] {
            let reply = try #require(await world.ask("session.reply", args.merging(["session": .string(id)]) { $1 }))
            #expect(reply.error?.code == NodeWire.Code.refused.rawValue && reply.error?.message.contains(says) == true, "\(args): \(reply)")
        }
        #expect(harness.agent["mode"] as? String == "permission", "\(harness.agent)")

        let action = UUID().uuidString.lowercased()
        let reply = try #require(await world.ask("session.reply", ["session": .string(id), "choice": .int(1), "question": .string(question)], action: action))
        #expect(reply.ok && reply.result?["option"]?.string == "Yes", "\(reply)")
        try await harness.waitFor { harness.agent["reply"] as? String == "Allowed." }
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["session.reply"])
    }

    /// The keys go to the option asked even when the cursor sits elsewhere: arrows from it, then Enter.
    @Test func theAnswerMovesFromWhereTheCursorIs() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        harness.tell(["op": "permission", "command": "make clean"])
        try await harness.screenShows { $0.contains("Do you want to proceed?") }
        world.queue.sync { world.world.link.type([HostInput.Write(bytes: [27, 91, 66], delay: 0)], into: harness.session.id) }
        try await harness.screenShows { $0.contains("❯ 2.") }
        let reply = try #require(await world.ask("session.reply", ["session": .string(harness.session.id.uuidString), "choice": .int(1)]))
        #expect(reply.ok, "\(reply)")
        try await harness.waitFor { harness.agent["reply"] as? String == "Allowed." }
    }

    /// Claude's folder-trust question at the start of a session in a new folder, its rows unnumbered (acceptance run,
    /// 2026-11-20: needs-you with no `prompt`, and `reply S 2` refused "asks nothing now"): read as a question, its
    /// options in screen order, and `reply 2` trusts the folder.
    @Test func claudesFolderTrustQuestionIsAnswered() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        harness.tell(["op": "trust"])
        try await harness.screenShows { $0.contains("Yes, I trust this folder") }
        try await harness.waitFor { harness.agent["mode"] as? String == "trust" }
        let menu = try #require(SessionPrompt.menu(on: harness.screen))
        #expect(menu.options == ["No, exit", "Yes, I trust this folder"] && menu.question.contains("Quick safety check"), "\(menu)")
        let reply = try #require(await world.ask("session.reply", ["session": .string(harness.session.id.uuidString), "choice": .int(2),
                                                                    "options": .array(menu.options.map(NodeWire.Value.string))]))
        #expect(reply.ok && reply.result?["option"]?.string == "Yes, I trust this folder", "\(reply)")
        try await harness.waitFor { harness.agent["trusted"] as? Bool == true }
        #expect(live(world, harness.session.id))
    }

    /// An arrow lost on a menu not yet taking keys: Enter isn't pressed on the row the cursor stayed on ("No, exit"
    /// would end the session); the answer is refused, and the next one goes in.
    @Test func enterWaitsForTheCursorOnTheOptionChosen() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        harness.tell(["op": "trust", "lose": 1])
        try await harness.waitFor { harness.agent["mode"] as? String == "trust" }
        try await harness.screenShows { $0.contains("Yes, I trust this folder") }
        let id = harness.session.id.uuidString
        let lost = try #require(await world.ask("session.reply", ["session": .string(id), "choice": .int(2)]))
        #expect(lost.error?.code == NodeWire.Code.refused.rawValue && lost.error?.message.contains("didn't reach option 2") == true, "\(lost)")
        #expect(live(world, harness.session.id) && harness.agent["mode"] as? String == "trust", "\(harness.agent)")
        let again = try #require(await world.ask("session.reply", ["session": .string(id), "choice": .int(2)]))
        #expect(again.ok, "\(again)")
        try await harness.waitFor { harness.agent["trusted"] as? Bool == true }
    }

    // MARK: voice

    @Test func aSessionsProcessAToolServerAndAWebPageCannotDrive() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        let lead = try await world.sleepingLead()
        let asks: [(String, [String: NodeWire.Value])] = [
            ("session.new", ["folder": .string(world.repo), "agent": .string("shell")]),
            ("session.end", ["session": .string(harness.session.id.uuidString)]),
            ("session.reply", ["session": .string(harness.session.id.uuidString), "choice": .int(1)]),
        ]
        for (kind, args) in asks {
            for facts in [PeerFacts.read(pid: harness.session.childPID), CardWorld.toolServer(of: lead)] {
                let action = UUID().uuidString.lowercased()
                let reply = try #require(await world.ask(kind, args, action: action, from: facts))
                #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(kind): \(reply)")
                #expect(await world.actions().filter { $0.action == action }.isEmpty)
            }
            #expect(NodeWire.kinds[kind] == .user && Requests.recorded.contains(kind) && NodeWire.taken.contains(kind))
            let web = WebAccess.refusal(for: NodeWire.Request(id: "1", kind: kind, args: args), rights: [.read, .draft])
            #expect(web?.error?.code == NodeWire.Code.voice.rawValue, "\(kind): \(String(describing: web))")
        }
        #expect(live(world, harness.session.id))
        // A draft is a page's: a token that drafts may leave one, and from the Unix socket nobody can.
        for kind in ["session.draft", "session.draft.clear"] {
            #expect(NodeWire.kinds[kind] == .webDraft && WebAccess.kinds(for: [.read, .draft]).contains(kind))
            #expect(!WebAccess.kinds(for: [.read]).contains(kind))
            let reply = try #require(await world.ask(kind, ["session": .string(NodeIds.session(host: harness.session.id)), "text": .string("hi")]))
            #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
        }
    }

    // MARK: prompt and draft (with the node's session scan)

    /// A world whose requests have the node's session scan, its screens read often (a test's timing).
    private func scanned() async throws -> (world: DeliveryWorld, sessions: NodeSessions, requests: Requests) {
        let world = try await DeliveryWorld.make(scratch)
        var timing = NodeSessions.Timing()
        timing.screenEvery = 0.2
        timing.promptEvery = 0.2
        let sessions = NodeSessions(root: world.host.root, home: world.host.home.path, queue: world.queue, link: world.link, timing: timing,
                                    onlyHosted: true)
        world.queue.sync { sessions.start() }
        let requests = Requests(link: world.link, sessions: sessions, rule: CardWorld.rule, root: world.host.root, hostSocket: world.host.socket,
                                commit: "test", hostPID: 1)
        requests.engine = world.engine
        return (world, sessions, requests)
    }

    private func status(_ world: DeliveryWorld, _ requests: Requests, _ id: String) -> NodeWire.Value? {
        world.queue.sync { requests.statusValue()["sessions"]?.array?.first { $0["id"]?.string == id } }
    }

    @Test func theQuestionOnItsScreenIsItsPromptUntilAnswered() async throws {
        let (world, sessions, requests) = try await scanned()
        defer { world.stop(); sessions.stop() }
        let harness = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: world.repo, label: "Claude")
        let id = NodeIds.session(host: harness.session.id)
        try #require(await eventually(timeout: 60) { sessions.refresh(); return status(world, requests, id) != nil })
        #expect(status(world, requests, id)?["prompt"] == .null)

        harness.tell(["op": "permission", "command": "rm -rf build"])
        try #require(await eventually(timeout: 60) { sessions.refresh(); return world.queue.sync { sessions.prompts.values[id] } != nil })
        let prompt = try #require(status(world, requests, id)?["prompt"])
        #expect(prompt["question"]?.string?.contains("Do you want to proceed?") == true, "\(prompt)")
        #expect(prompt["options"]?.array?.first?.string == "Yes" && prompt["options"]?.array?.count == 3, "\(prompt)")
        #expect(prompt["text"]?.array == [] && prompt["multiSelect"]?.bool == false, "\(prompt)")

        let reply = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: "1", kind: "session.reply", args: ["session": .string(id), "choice": .int(3), "question": prompt["question"]!],
                                       action: UUID().uuidString.lowercased())
        world.queue.async { requests.handle(request, from: CardWorld.user) { reply.value = $0 } }
        try #require(await eventually(timeout: 60) { reply.value != nil })
        #expect(reply.value?.ok == true, "\(String(describing: reply.value))")
        try await harness.waitFor { harness.agent["reply"] as? String == "Denied." }
        #expect(await eventually(timeout: 60) { sessions.refresh(); return world.queue.sync { sessions.prompts.values[id] } == nil })
    }

    @Test func aPagesDraftIsKeptBesideItsSessionAndSendTypesIt() async throws {
        let (world, sessions, requests) = try await scanned()
        defer { world.stop(); sessions.stop() }
        let harness = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: world.repo, label: "Claude")
        let id = NodeIds.session(host: harness.session.id)
        try #require(await eventually(timeout: 60) { sessions.refresh(); return status(world, requests, id) != nil })
        func page(_ kind: String, _ args: [String: NodeWire.Value]) async -> NodeWire.Reply? {
            let reply = Locked<NodeWire.Reply?>(nil)
            let request = NodeWire.Request(id: "1", kind: kind, args: args, action: UUID().uuidString.lowercased())
            world.queue.async { requests.draft(request) { reply.value = $0 } }
            _ = await eventually(timeout: 60) { reply.value != nil }
            return reply.value
        }
        let left = try #require(await page("session.draft", ["session": .string(id), "text": .string("Run the tests\nthen push")]))
        #expect(left.ok && left.result?["session"]?.string == id && left.result?["applied"]?["sessions"] != nil, "\(left)")
        #expect(status(world, requests, id)?["draft"]?["text"]?.string == "Run the tests\nthen push")
        #expect(harness.transcript.isEmpty, "a draft is typed into nothing")
        let cleared = try #require(await page("session.draft.clear", ["session": .string(id)]))
        #expect(cleared.ok && status(world, requests, id)?["draft"] == .null, "\(cleared)")
        let gone = try #require(await page("session.draft", ["session": .string(NodeIds.session(host: UUID())), "text": .string("x")]))
        #expect(gone.error?.code == NodeWire.Code.gone.rawValue, "\(gone)")
        let empty = try #require(await page("session.draft", ["session": .string(id), "text": .string(" ")]))
        #expect(empty.error?.code == NodeWire.Code.badArgs.rawValue, "\(empty)")

        // Sent as drafted (what `vibeswitcher send SESSION` sends): typed once, and the draft goes.
        _ = try #require(await page("session.draft", ["session": .string(id), "text": .string("Ship it")]))
        let sent = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: "2", kind: "send", args: ["session": .string(id), "text": .string("Ship it")], action: UUID().uuidString.lowercased())
        world.queue.async { requests.handle(request, from: CardWorld.user) { sent.value = $0 } }
        try #require(await eventually(timeout: 60) { sent.value != nil })
        #expect(sent.value?.ok == true, "\(String(describing: sent.value))")
        _ = try await EngineEndToEndTests.prompt(harness.files) { $0 == "Ship it" }
        #expect(status(world, requests, id)?["draft"] == .null)
    }

    /// A page's send-now draft (its composer while the agent works) is kept saying so, for `vibeswitcher send SESSION` to
    /// steer it (`SteerNowTests`); a plain one after it says nothing of now.
    @Test func aPagesSendNowDraftIsKeptSayingSo() async throws {
        let (world, sessions, requests) = try await scanned()
        defer { world.stop(); sessions.stop() }
        let harness = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: world.repo, label: "Claude")
        let id = NodeIds.session(host: harness.session.id)
        try #require(await eventually(timeout: 60) { sessions.refresh(); return status(world, requests, id) != nil })
        func page(_ args: [String: NodeWire.Value]) async -> NodeWire.Reply? {
            let reply = Locked<NodeWire.Reply?>(nil)
            let request = NodeWire.Request(id: "1", kind: "session.draft", args: args, action: UUID().uuidString.lowercased())
            world.queue.async { requests.draft(request) { reply.value = $0 } }
            _ = await eventually(timeout: 60) { reply.value != nil }
            return reply.value
        }
        let now = try #require(await page(["session": .string(id), "text": .string("Read the logs first"), "now": .bool(true)]))
        #expect(now.ok, "\(now)")
        #expect(status(world, requests, id)?["draft"]?["now"]?.bool == true)
        #expect(harness.transcript.isEmpty, "a draft is typed into nothing")
        _ = try #require(await page(["session": .string(id), "text": .string("Later")]))
        #expect(status(world, requests, id)?["draft"]?["text"]?.string == "Later" && status(world, requests, id)?["draft"]?["now"] == nil)
    }

    /// An image a page pastes comes in parts, is written to the node's attachments folder as the app saves a pasted
    /// one, and the page's draft names it; `send` with the draft's words and image types both, and the draft goes. A
    /// draft names no file but an attached image.
    @Test func aPastedImageIsKeptAndTheDraftThatNamesItIsSent() async throws {
        let (world, sessions, requests) = try await scanned()
        defer { world.stop(); sessions.stop() }
        let harness = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: world.repo, label: "Claude")
        let id = NodeIds.session(host: harness.session.id)
        try #require(await eventually(timeout: 60) { sessions.refresh(); return status(world, requests, id) != nil })
        func page(_ kind: String, _ args: [String: NodeWire.Value]) async -> NodeWire.Reply? {
            let reply = Locked<NodeWire.Reply?>(nil)
            let request = NodeWire.Request(id: "1", kind: kind, args: args, action: UUID().uuidString.lowercased())
            world.queue.async { requests.draft(request) { reply.value = $0 } }
            _ = await eventually(timeout: 60) { reply.value != nil }
            return reply.value
        }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 7, count: 100))
        let upload = UUID().uuidString
        var path: String?
        for (index, part) in [png.prefix(40), png.dropFirst(40).prefix(40), png.dropFirst(80)].enumerated() {
            let reply = try #require(await page("session.attach", ["session": .string(id), "upload": .string(upload), "type": .string("image/png"),
                                                                    "part": .int(index), "parts": .int(3), "data": .string(Data(part).base64EncodedString())]))
            #expect(reply.ok && reply.result?["received"]?.int == index + 1, "\(reply)")
            path = reply.result?["path"]?.string
        }
        let saved = try #require(path)
        #expect(saved.hasPrefix(world.host.root.appendingPathComponent("attachments").path + "/pasted-") && saved.hasSuffix(".png"), "\(saved)")
        #expect(FileManager.default.contents(atPath: saved) == png)
        let mode = try FileManager.default.attributesOfItem(atPath: saved)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let elsewhere = try #require(await page("session.draft", ["session": .string(id), "text": .string("Look"), "images": .array([.string("/etc/hostname.png")])]))
        #expect(elsewhere.error?.code == NodeWire.Code.badArgs.rawValue && elsewhere.error?.message.contains("isn't an image attached") == true, "\(elsewhere)")
        let left = try #require(await page("session.draft", ["session": .string(id), "text": .string("What's this?"), "images": .array([.string(saved)])]))
        #expect(left.ok, "\(left)")
        #expect(status(world, requests, id)?["draft"]?["images"] == .array([.string(saved)]))

        let sent = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: "2", kind: "send", args: ["session": .string(id), "text": .string("What's this?"), "images": .array([.string(saved)])],
                                       action: UUID().uuidString.lowercased())
        world.queue.async { requests.handle(request, from: CardWorld.user) { sent.value = $0 } }
        try #require(await eventually(timeout: 60) { sent.value != nil })
        #expect(sent.value?.ok == true, "\(String(describing: sent.value))")
        try await harness.waitFor { harness.transcript.contains { line in
            ((line["message"] as? [String: Any])?["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image" } == true
        } }
        #expect(status(world, requests, id)?["draft"] == .null)
    }

    @Test func anImagesPartsAreCheckedAsTheyCome() {
        let attachments = SessionAttachments()
        let id = UUID().uuidString.lowercased()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2])
        // Out of order, and a part again (a page's retry): taken once.
        if case .partial(1) = attachments.take(id: id, session: "s", type: "image/png", part: 1, parts: 2, data: png.dropFirst(5)) {} else { Issue.record("part 1") }
        if case .partial(1) = attachments.take(id: id, session: "s", type: "image/png", part: 1, parts: 2, data: png.dropFirst(5)) {} else { Issue.record("again") }
        if case .refused = attachments.take(id: id, session: "other", type: "image/png", part: 0, parts: 2, data: png.prefix(5)) {} else { Issue.record("another's") }
        guard case .whole(let whole, "image/png") = attachments.take(id: id, session: "s", type: "image/png", part: 0, parts: 2, data: png.prefix(5)) else {
            Issue.record("whole")
            return
        }
        #expect(whole == png)
        // Not what its type says; too large; not a type; four at once.
        if case .refused(_, let why) = attachments.take(id: UUID().uuidString, session: "s", type: "image/gif", part: 0, parts: 1, data: png) {
            #expect(why.contains("isn't a image/gif"))
        } else { Issue.record("gif") }
        let big = Data(count: SessionAttachments.maxBytes / 2 + 1)
        let large = UUID().uuidString
        _ = attachments.take(id: large, session: "s", type: "image/png", part: 0, parts: 3, data: big)
        if case .refused(_, let why) = attachments.take(id: large, session: "s", type: "image/png", part: 1, parts: 3, data: big) {
            #expect(why.contains("at most"))
        } else { Issue.record("large") }
        if case .refused = attachments.take(id: UUID().uuidString, session: "s", type: "image/svg+xml", part: 0, parts: 1, data: png) {} else { Issue.record("svg") }
        for _ in 0..<SessionAttachments.maxUploads { _ = attachments.take(id: UUID().uuidString, session: "s", type: "image/png", part: 0, parts: 2, data: png) }
        if case .refused(_, let why) = attachments.take(id: UUID().uuidString, session: "s", type: "image/png", part: 0, parts: 2, data: png) {
            #expect(why.contains("coming in already"))
        } else { Issue.record("many") }
        // Waiting parts go after a while.
        if case .partial = attachments.take(id: UUID().uuidString, session: "s", type: "image/png", part: 0, parts: 2, data: png,
                                            now: Date().addingTimeInterval(SessionAttachments.uploadLife + 1)) {} else { Issue.record("expired") }
        #expect(SessionAttachments.looks(Data("RIFF\0\0\0\0WEBPVP8 ".utf8), like: "image/webp"))
        #expect(SessionAttachments.looks(Data([0xFF, 0xD8, 0xFF, 0xE0]), like: "image/jpeg"))
    }

    // MARK: the command line

    /// Asks `condition` (a command run, say) until it holds or `timeout` passes, a fifth of a second between asks.
    private func polled(timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return await condition()
    }

    /// On a scratch node, each code typed on its terminal: `new` starts the fake, `reply` answers its question (shown
    /// first), `send` with no text finds no draft, `end` ends it; wrong forms are the usage.
    @Test func theCommandLineStartsAnswersAndEndsASession() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let repo = scratch.url("work")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let started = try await node.runOnTerminal(["new", repo.path])
        #expect(started.status == 0 && started.output.contains("started: session"), "\(started.output)\(started.errors)\n\(node.said)")
        let short = try #require(started.output.components(separatedBy: "started: session ").last?.prefix(8)).description
        let session = try #require(try node.sessions().first { $0.id.uuidString.lowercased().hasPrefix(short) && $0.isLive }, "\(node.said)")
        let files = node.fake.files(terminal: session.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["pid"] != nil }, "\(node.said)")
        try EngineEndToEndTests.tell(files, ["op": "permission", "command": "make clean"])
        // The server reads a quiet session's screen every 6 s: `status` lists the question once it has.
        try #require(await polled(timeout: 60) { (try? await node.run(["status", "--json"]))?.output.contains("Do you want to proceed?") == true }, "\(node.said)")
        let answered = try await node.runOnTerminal(["reply", short, "2"])
        #expect(answered.status == 0 && answered.output.contains("answered: option 2"), "\(answered.output)\(answered.errors)")
        #expect(answered.errors.contains("make clean") || answered.output.contains("make clean"), "the question is shown before the code")
        #expect(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["reply"] as? String == "Allowed always." })

        // One word alone is the page's draft for it, and there is none.
        let noDraft = try await node.run(["send", short])
        #expect(noDraft.status == 64 && noDraft.errors.contains("has no draft"), "\(noDraft.output)\(noDraft.errors)")

        // The terminal name `status` prints names it as well as its id (`SessionLookup`), also as pts/N.
        let byTerminal = try await node.run(["send", session.tty])
        #expect(byTerminal.status == 64 && byTerminal.errors.contains("session \(short)") && byTerminal.errors.contains("has no draft"),
                "\(byTerminal.output)\(byTerminal.errors)")
        let ended = try await node.runOnTerminal(["end", session.tty])
        #expect(ended.status == 0 && ended.output.contains("ended: session \(short)"), "\(ended.output)\(ended.errors)")
        for (words, usage) in [(["new"], "usage: vibeswitcher new"), (["new", repo.path, "--agent", "codex"], "usage: vibeswitcher new"),
                               (["end"], "usage: vibeswitcher end"), (["reply", short], "usage: vibeswitcher reply"),
                               (["reply", short, "first"], "usage: vibeswitcher reply")] {
            let run = try await node.run(words)
            #expect(run.status == 64 && run.errors.contains(usage), "\(words): \(run.output)\(run.errors)")
        }
    }
}
