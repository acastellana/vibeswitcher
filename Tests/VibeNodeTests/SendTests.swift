import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `vibeswitcher send SESSION TEXT` (the parity table's gap 1, 2026-11-20), as `tell`'s cases go: the user's words typed
/// once into a fake Claude's session the scratch host runs, recorded in the host's vault first; refused, nothing typed,
/// for a question open on its screen, a shell, a session the host doesn't run, a session's process, the lead's tool
/// server and a web page. Only fake sessions are typed into (AGENTS.md).
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct SendTests {
    private let scratch = Scratch()

    private func send(_ world: CardWorld, _ session: String, _ text: String, action: String = UUID().uuidString.lowercased(),
                      from facts: PeerFacts = CardWorld.user) async -> NodeWire.Reply? {
        await world.ask("send", ["session": .string(session), "text": .string(text)], action: action, from: facts)
    }

    /// A fake Claude between turns in a session labelled as an ordinary one, once the link lists it.
    private func claude(_ world: CardWorld) async throws -> NodeHarness {
        let harness = try await NodeHarness.start(on: world.host, fake: world.world.fake, cwd: world.repo, label: "Claude")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == harness.session.id && $0.isLive } } })
        return harness
    }

    /// The prompts the fake took (its transcript's user lines whose content is text).
    private func prompts(_ harness: NodeHarness) -> [String] {
        harness.transcript.compactMap { line in
            guard line["type"] as? String == "user", let message = line["message"] as? [String: Any] else { return nil }
            return message["content"] as? String
        }
    }

    @Test func aMessageIsTypedOnceAndRecorded() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        let action = UUID().uuidString.lowercased()
        // Named by the first 8 characters of its id, as the page shows it.
        let short = String(harness.session.id.uuidString.lowercased().prefix(8))
        let reply = try #require(await send(world, short, "Run the tests\nthen tell me", action: action))
        #expect(reply.ok, "\(reply)")
        #expect(reply.result?["session"]?.string == NodeIds.session(host: harness.session.id), "\(reply)")
        #expect(reply.result?["terminal"]?.string == harness.session.tty, "\(reply)")
        try await harness.waitFor { prompts(harness).contains("Run the tests\nthen tell me") }
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["send"])

        // The same action again is answered as before, not typed again: a message sent after it comes alone.
        let again = try #require(await send(world, short, "Run the tests\nthen tell me", action: action))
        #expect(again.ok, "\(again)")
        #expect(try #require(await send(world, short, "And the next")).ok)
        try await harness.waitFor { prompts(harness).contains("And the next") }
        #expect(prompts(harness) == ["Run the tests\nthen tell me", "And the next"], "\(prompts(harness))")
    }

    /// What the user typed is the engine's to know: the session's input (a lead's rotation quiet), and a `!` git line
    /// kept for the base move it may make (`BaseMoveStore.typed`); words to the agent aren't a command of the user's.
    @Test func aTypedMessageIsTheSessionsInputAndABangGitLineIsKept() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        let short = String(harness.session.id.uuidString.lowercased().prefix(8))
        #expect(try #require(await send(world, short, "commit it for me")).ok)
        try await harness.waitFor { prompts(harness).contains("commit it for me") }
        #expect(await eventually(timeout: 30) { world.queue.sync { world.engine.userInput[harness.session.id] != nil } })
        #expect(world.queue.sync { world.engine.baseMoves.sent.isEmpty })
        #expect(try #require(await send(world, short, "! git commit -am mine")).ok)
        let kept = await eventually(timeout: 30) { world.queue.sync { world.engine.baseMoves.sent.map(\.line) == ["git commit -am mine"] } }
        #expect(kept, "\(world.queue.sync { world.engine.baseMoves.sent })")
        #expect(world.queue.sync { world.engine.baseMoves.sent.first?.session } == harness.session.id.uuidString)
    }

    /// A question open on its screen that takes typed words (its "Type something." row, the app's free-text row): the
    /// message goes in as that answer, as the app's composer sends it, not held; a `/` command isn't an answer (held), and
    /// a multi-select is ticked in its terminal (held).
    @Test func aMessageAnswersAQuestionThatTakesWords() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        let id = harness.session.id.uuidString
        let question: [String: Any] = ["question": "Which name for the parser?", "header": "Name",
                                       "options": [["label": "Parser"], ["label": "Reader"]], "multiSelect": false]
        harness.tell(["op": "ask", "questions": [question]])
        try await harness.screenShows { $0.contains("Type something.") }
        try await harness.waitFor { harness.agent["mode"] as? String == "question" }
        let command = try #require(await send(world, id, "/model"))
        #expect(command.ok && command.result?["queued"]?.bool == true && command.result?["answered"] == nil, "\(command)")

        let world2 = try await CardWorld.make(scratch)
        defer { world2.stop() }
        let other = try await claude(world2)
        other.tell(["op": "ask", "questions": [question]])
        try await other.screenShows { $0.contains("Type something.") }
        try await other.waitFor { other.agent["mode"] as? String == "question" }
        let reply = try #require(await send(world2, other.session.id.uuidString, "Tokenizer"))
        #expect(reply.ok && reply.result?["answered"]?.string == "Type something." && reply.result?["queued"]?.bool == false, "\(reply)")
        try await other.waitFor { (other.agent["reply"] as? String) == "Thanks." }
        let answered = other.transcript.compactMap { ($0["toolUseResult"] as? [String: Any])?["answers"] as? [String: String] }.last
        #expect(answered?["Which name for the parser?"] == "Tokenizer", "\(other.transcript.suffix(2))")
        #expect(world2.queue.sync { world2.requests.heldSends.values[NodeIds.session(host: other.session.id)] } == nil)

        // A multi-select takes ticks: held.
        let world3 = try await CardWorld.make(scratch)
        defer { world3.stop() }
        let third = try await claude(world3)
        var multi = question
        multi["multiSelect"] = true
        third.tell(["op": "ask", "questions": [multi]])
        try await third.screenShows { $0.contains("Type something") }
        try await third.waitFor { third.agent["mode"] as? String == "question" }
        let held = try #require(await send(world3, third.session.id.uuidString, "Tokenizer"))
        #expect(held.ok && held.result?["queued"]?.bool == true, "\(held)")
    }

    /// A permission prompt on its screen takes keys: typed now, the words would go into it, so the message is held, as
    /// the app's composer holds it, and so is one sent after it (behind it); both go in, in order, once it's answered.
    @Test func aMessageSentWhileAQuestionIsOpenWaitsForItsAnswer() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        let id = NodeIds.session(host: harness.session.id)
        harness.tell(["op": "permission", "command": "rm -rf build"])
        try await harness.screenShows { $0.contains("Do you want to proceed?") }
        // It draws before it writes its state.
        try await harness.waitFor { harness.agent["mode"] as? String == "permission" }
        let first = try #require(await send(world, harness.session.id.uuidString, "Then run the linter"))
        #expect(first.ok && first.result?["queued"]?.bool == true, "\(first)")
        #expect(first.result?["waits"]?.string?.contains("a question is open") == true, "\(first)")
        let second = try #require(await send(world, harness.session.id.uuidString, "And the docs"))
        #expect(second.ok && second.result?["queued"]?.bool == true && second.result?["waits"]?.string?.contains("sent before it") == true, "\(second)")
        #expect(world.queue.sync { world.requests.heldSends.values[id]?.map(\.text) } == ["Then run the linter", "And the docs"])
        #expect(harness.agent["mode"] as? String == "permission", "\(harness.agent)")
        #expect(prompts(harness).isEmpty, "\(prompts(harness))")
        // A session's value lists them (`HeldSend.value`): the words, how many images, the action.
        let value = try #require(world.queue.sync { world.requests.heldSends.values[id]?.first?.value })
        #expect(value["text"]?.string == "Then run the linter" && value["images"]?.int == 0, "\(value)")

        let answered = try #require(await world.ask("session.reply", ["session": .string(harness.session.id.uuidString), "choice": .int(1)]))
        #expect(answered.ok, "\(answered)")
        // It works on after the answer, so it queues them, as Claude Code queues what's typed during a turn.
        try await harness.waitFor { (harness.agent["queued"] as? [String] ?? []) + prompts(harness) == ["Then run the linter", "And the docs"] }
        try #require(await eventually { world.queue.sync { world.requests.heldSends.values[id] == nil } })
    }

    /// The security review of 7ca2061c: a held message's action is spent in the vault before its keys; a spend that fails
    /// types nothing (it stays held, said in the log), and once the vault takes the spend it goes in.
    @Test func aHeldMessageWhoseSpendFailsIsNotTyped() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let failing = Locked(true)
        let tries = Locked(0)
        world.queue.sync {
            let real = world.requests.spendUserActions
            world.requests.spendUserActions = { actions in
                if failing.value {
                    tries.mutate { $0 += 1 }
                    throw HostCall.Failure(description: "the vault refused the spend")
                }
                try real(actions)
            }
        }
        let harness = try await claude(world)
        let id = NodeIds.session(host: harness.session.id)
        harness.tell(["op": "permission", "command": "rm -rf build"])
        try await harness.screenShows { $0.contains("Do you want to proceed?") }
        try await harness.waitFor { harness.agent["mode"] as? String == "permission" }
        let sent = try #require(await send(world, harness.session.id.uuidString, "Then run the linter"))
        #expect(sent.ok && sent.result?["queued"]?.bool == true, "\(sent)")
        let answered = try #require(await world.ask("session.reply", ["session": .string(harness.session.id.uuidString), "choice": .int(1)]))
        #expect(answered.ok, "\(answered)")
        try await harness.waitFor { harness.agent["reply"] as? String == "Allowed." }
        // Its question closed, the pump tries: the spend fails, nothing is typed, it stays held.
        #expect(await eventually(timeout: 30) { tries.value >= 2 }, "the pump tried twice: \(tries.value)")
        #expect((harness.agent["queued"] as? [String] ?? []) + prompts(harness) == [], "\(harness.agent)")
        #expect(world.queue.sync { world.requests.heldSends.values[id]?.map(\.text) } == ["Then run the linter"])
        failing.value = false
        try await harness.waitFor { (harness.agent["queued"] as? [String] ?? []) + prompts(harness) == ["Then run the linter"] }
    }

    /// An image goes as its quoted path on a line of its own after the words, as the app's composer sends it, and the
    /// Enter waits until Claude Code's box shows it taken: the fake drops an Enter that comes while it reads one, as
    /// Claude Code 2.1.310 does.
    @Test func anImageGoesAsItsPathAndTheEnterWaitsForIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        let shots = scratch.url("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let image = shots.appendingPathComponent("screen shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: image)
        let reply = try #require(await world.ask("send", ["session": .string(harness.session.id.uuidString), "text": .string("What's wrong here?"),
                                                          "images": .array([.string(image.path)])]))
        #expect(reply.ok && reply.result?["queued"]?.bool == false, "\(reply)")
        try await harness.waitFor { harness.transcript.contains { line in
            guard line["type"] as? String == "user", let content = (line["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
            return content.contains { $0["type"] as? String == "image" }
        } }
        #expect(harness.agent["droppedEnters"] as? Int == 0, "\(harness.agent)")

        // Refused, nothing typed: not an image Claude Code reads, not a file, not absolute.
        for (path, says) in [(shots.appendingPathComponent("notes.txt").path, "isn't an image"), (shots.appendingPathComponent("gone.png").path, "no image file"), ("shot.png", "absolute")] {
            let refused = try #require(await world.ask("send", ["session": .string(harness.session.id.uuidString), "images": .array([.string(path)])]))
            #expect(refused.error?.message.contains(says) == true, "\(path): \(refused)")
        }
    }

    /// A `/` command goes in as the composer types it; one that opens a picker (`/model`) is said, and a message sent
    /// while the picker is open waits for it to close.
    @Test func aSlashCommandsPickerIsSaidAndAMessageWaitsForIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        let model = try #require(await send(world, harness.session.id.uuidString, "/model"))
        #expect(model.ok && model.result?["opened"]?.string?.contains("open on its screen") == true, "\(model)")
        let held = try #require(await send(world, harness.session.id.uuidString, "Carry on"))
        #expect(held.ok && held.result?["queued"]?.bool == true, "\(held)")
        #expect(harness.agent["mode"] as? String == "picker", "\(harness.agent)")
        // Esc closes it, in the session's terminal; the message goes in then.
        world.queue.sync { world.world.link.type([HostInput.Write(bytes: [27], delay: 0)], into: harness.session.id) }
        try await harness.waitFor { prompts(harness).contains("Carry on") }
    }

    @Test func aMessageIsItsWordsThenEachImagesPathOnALineOfItsOwn() {
        #expect(Requests.message(text: "Look", images: ["/a/b.png", "/c/it's.png"]) == "Look\n\n'/a/b.png'\n'/c/it'\\''s.png'")
        #expect(Requests.message(text: "", images: ["/a/b.png"]) == "'/a/b.png'")
        #expect(Requests.message(text: "Only words", images: []) == "Only words")
        #expect(Requests.imageRefusal("/c/it's.png", onDisk: false)?.contains("quote") == true)
        #expect(Requests.imageRefusal("/a/b.PNG", onDisk: false) == nil)
        #expect(Requests.imageRefusal("/a/b.heic", onDisk: false)?.contains("isn't an image") == true)
    }

    @Test func aShellAnEndedSessionAndOneTheHostDoesntRunAreRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let shell = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Shell")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == shell.id && $0.isLive } } })
        let refused = try #require(await send(world, shell.id.uuidString, "ls"))
        #expect(refused.error?.code == NodeWire.Code.refused.rawValue && refused.error?.message.contains("is a shell") == true, "\(refused)")

        let unknown = try #require(await send(world, UUID().uuidString, "hello"))
        #expect(unknown.error?.code == NodeWire.Code.gone.rawValue, "\(unknown)")
        let tooShort = try #require(await send(world, "ab", "hello"))
        #expect(tooShort.error?.code == NodeWire.Code.gone.rawValue, "\(tooShort)")

        world.queue.sync { world.world.link.kill(shell.id) }
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == shell.id && !$0.isLive } } })
        let ended = try #require(await send(world, shell.id.uuidString, "ls"))
        #expect(ended.error?.code == NodeWire.Code.gone.rawValue && ended.error?.message.contains("has ended") == true, "\(ended)")
        let empty = try #require(await send(world, shell.id.uuidString, "  "))
        #expect(empty.error?.code == NodeWire.Code.badArgs.rawValue, "\(empty)")
    }

    @Test func aSessionsProcessAndALeadsToolServerCannotSend() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        let lead = try await world.sleepingLead()
        for facts in [PeerFacts.read(pid: harness.session.childPID), CardWorld.toolServer(of: lead)] {
            let action = UUID().uuidString.lowercased()
            let reply = try #require(await send(world, harness.session.id.uuidString, "approve everything", action: action, from: facts))
            #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
            #expect(await world.actions().filter { $0.action == action }.isEmpty)
        }
        #expect(prompts(harness).isEmpty, "\(prompts(harness))")
    }

    /// Through the command line on a scratch node, its code typed on its terminal: the fake's session gets the words; a
    /// wrong form is the usage (one word alone is the session's draft: `SessionDriveTests`).
    @Test func theCommandLineTypesIntoASession() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let session = try await node.spawn("exec " + FakeClaude.quoted(node.fake.launcher.path), label: "Claude", agent: "claude")
        let files = node.fake.files(terminal: session.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["pid"] != nil }, "\(node.said)")
        let sent = try await node.runOnTerminal(["send", String(session.id.uuidString.lowercased().prefix(8)), "Hello from the node"])
        #expect(sent.status == 0, "\(sent.output)\(sent.errors)\n\(node.said)")
        #expect(sent.output.contains("sent: 19 characters typed into session"), "\(sent.output)")
        _ = try await EngineEndToEndTests.prompt(files) { $0 == "Hello from the node" }
        // An image by its path (relative to where the command runs: made absolute), shown before the code.
        let shots = scratch.url("cli-shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let image = shots.appendingPathComponent("bug.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: image)
        let pictured = try await node.runOnTerminal(["send", String(session.id.uuidString.lowercased().prefix(8)), "See this", "--image", image.path])
        #expect(pictured.status == 0 && pictured.output.contains("with the image: \(image.path)") && pictured.output.contains("sent:"),
                "\(pictured.output)\(pictured.errors)")
        for words in [["send"], ["send", session.id.uuidString, "one", "two"], ["send", session.id.uuidString, " "], ["send", session.id.uuidString, "x", "--image"]] {
            let usage = try await node.run(words)
            #expect(usage.status == 64 && usage.errors.contains("usage: vibeswitcher send SESSION [TEXT]"), "\(words): \(usage.output)\(usage.errors)")
        }
    }

    /// A web page is never the user's voice, whatever its token's rights.
    @Test func aWebPageCannotSend() {
        #expect(NodeWire.kinds["send"] == .user)
        #expect(NodeWire.changesState("send"))
        #expect(Requests.recorded.contains("send"))
        #expect(NodeWire.taken.contains("send"))
        let refused = WebAccess.refusal(for: NodeWire.Request(id: "1", kind: "send", args: ["session": .string("x"), "text": .string("y")]),
                                        rights: [.read, .draft])
        #expect(refused?.error?.code == NodeWire.Code.voice.rawValue, "\(String(describing: refused))")
        #expect(!WebAccess.kinds(for: [.read, .draft]).contains("send"))
    }

    /// The menus that take keys are told apart from a plain prompt box.
    @Test func whatIsOpenOnAScreenIsTold() {
        let box = "\n─────────────────────────\n❯ \n─────────────────────────\n  ? for shortcuts"
        #expect(Requests.openMenu(box) == nil)
        let question = "Bash command\n  rm -rf build\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n\nEsc to cancel"
        #expect(Requests.openMenu(question)?.contains("a question is open") == true)
    }
}

/// What a session's composer completes (the composer's lane, 2026-11-20): `/` to its agent's commands, the user's and
/// the project's own among them, `@` to its folder's files, as the app's composer offers them; a read.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct SessionCompleteTests {
    private let scratch = Scratch()

    private func write(_ text: String, to path: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func slashAndMentionCompleteAsTheAppsComposerDoes() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let home = scratch.url("home")
        world.queue.sync { world.requests.home = home.path }
        try write("---\ndescription: Ship it to staging\n---\nDeploy.", to: ".claude/commands/deploy.md", in: home)
        try write("---\nname: review-pr\ndescription: Review a pull request\n---\n", to: ".claude/skills/review-pr/SKILL.md", in: home)
        let repo = URL(fileURLWithPath: world.repo)
        try write("# Release\nSteps.", to: ".claude/commands/release.md", in: repo)
        try write("export {}", to: "src/login.ts", in: repo)
        try write("x", to: "node_modules/left-pad/login.js", in: repo)
        let harness = try await NodeHarness.start(on: world.host, fake: world.world.fake, cwd: world.repo, label: "Claude")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == harness.session.id && $0.isLive } } })
        let session = harness.session.id.uuidString

        func complete(_ kind: String, _ query: String) async throws -> [NodeWire.Value] {
            let reply = try #require(await world.ask("session.complete", ["session": .string(session), "kind": .string(kind), "query": .string(query)], action: nil))
            #expect(WireSchema.check(try #require(reply.result, "\(reply)"), as: "session.complete.result", strict: true) == nil)
            return reply.result?["items"]?.array ?? []
        }
        #expect(try await complete("slash", "dep").first == SessionCompletions.value(insert: "/deploy ", title: "/deploy", subtitle: "Ship it to staging"))
        #expect(try await complete("slash", "review").first?["insert"]?.string == "/review ")
        #expect(try await complete("slash", "review-").first?["insert"]?.string == "/review-pr ")
        #expect(try await complete("slash", "rel").first?["subtitle"]?.string == "Release")
        #expect(try await complete("slash", "comp").first?["insert"]?.string == "/compact ")
        let files = try await complete("mention", "login")
        #expect(files.map { $0["insert"]?.string } == ["@src/login.ts "], "\(files)")

        let shell = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Shell")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == shell.id && $0.isLive } } })
        for (args, says) in [(["session": NodeWire.Value.string(shell.id.uuidString), "kind": .string("slash"), "query": .string("")], "no agent"),
                             (["session": .string(session), "kind": .string("other"), "query": .string("")], "slash or mention")] {
            let refused = try #require(await world.ask("session.complete", args, action: nil))
            #expect(refused.error?.message.contains(says) == true, "\(refused)")
        }
    }

    @Test func aListIsReusedAWhileThenMadeAgain() throws {
        let folder = scratch.url("work")
        try write("a", to: "one.txt", in: folder)
        let index = SessionCompletions()
        let now = Date()
        #expect(index.files(in: folder.path, now: now) == ["one.txt"])
        try write("b", to: "two.txt", in: folder)
        #expect(index.files(in: folder.path, now: now.addingTimeInterval(5)) == ["one.txt"])
        #expect(Set(index.files(in: folder.path, now: now.addingTimeInterval(SessionCompletions.kept + 1))) == ["one.txt", "two.txt"])
    }

    @Test func aPageReadsCompletionsAndPresets() {
        for kind in ["session.complete", "session.presets"] {
            #expect(NodeWire.kinds[kind] == .anyone && NodeWire.taken.contains(kind) && !NodeWire.changesState(kind))
            #expect(WebAccess.kinds(for: [.read]).contains(kind))
            #expect(WebAccess.refusal(for: NodeWire.Request(id: "1", kind: kind), rights: [.draft])?.error?.code == NodeWire.Code.voice.rawValue)
        }
    }
}
