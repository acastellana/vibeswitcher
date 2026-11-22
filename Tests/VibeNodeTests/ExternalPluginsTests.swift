import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// External plugins (docs/superpowers/specs/2026-11-22-v2-feature-plugins.md, "External plugins"), driven by the test
/// plugin in Tests/Fixtures/plugin-probe (a script speaking protocol v1): added as the user's voice with the SHA-256s
/// shown, run from a sealed copy checked against the vault's record, a request filed with vs-ask (the host stamping it),
/// a card of the plugin's data under the core's checks, an answer, its page served by the core, its settings, and its
/// hostile answers (a wrong id, an answer out of order, a line too long, a hang, a card with an escape): each ends its
/// program or refuses its card, never reaching the node as more than data.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ExternalPluginsTests {
    private let scratch = Scratch()

    static let probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/plugin-probe").path

    /// `kind` with `args` from `facts`, answered (bridged for code that blocks).
    private func blocking(_ world: CardWorld, _ kind: String, _ args: [String: NodeWire.Value], from facts: PeerFacts) -> NodeWire.Reply? {
        let done = DispatchSemaphore(value: 0)
        let reply = Locked<NodeWire.Reply?>(nil)
        world.queue.async {
            world.requests.handle(NodeWire.Request(id: UUID().uuidString, kind: kind, args: args, action: nil), from: facts) { answer in
                reply.value = answer
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 60)
        return reply.value
    }

    /// The probe added (inspected, then added with what was shown) and, when `on`, turned on.
    private func added(_ world: CardWorld, folder: String = ExternalPluginsTests.probe, on: Bool = true) async throws -> NodeWire.Reply {
        let inspected = try #require(await world.ask("plugin.inspect", ["folder": .string(folder)], action: nil))
        try #require(inspected.ok, "\(inspected)")
        let added = try #require(await world.ask("plugin.add", ["folder": .string(folder), "manifest": inspected.result?["manifestSHA"] ?? .null,
                                                               "program": inspected.result?["programSHA"] ?? .null]))
        try #require(added.ok, "\(added)")
        if on {
            let turned = try #require(await world.ask("plugin.on", ["plugin": .string("probe")]))
            try #require(turned.ok, "\(turned)")
        }
        return inspected
    }

    /// `vs-ask probe -- WORDS` from a scratch session: the filer as the tool server runs it, the host stamping it.
    private func ask(_ world: CardWorld, _ words: [String]) async throws -> (asker: HostSession, output: (status: Int32, output: String, error: String)) {
        let asker = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Asker")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.engine.link.sessions.contains { $0.id == asker.id && $0.isLive } } })
        let session = asker.id.uuidString.lowercased()
        let vault = world.host.book.vault(folder: scratch.url("asker-\(UUID().uuidString.prefix(6))"), as: { .session(session) }, userOpened: true)
        let facts = CardWorld.toolServer(of: asker)
        let ran = await offPool {
            PluginAsk.run(["probe", "--"] + words, cwd: world.repo, vault: vault, root: world.host.root) { args in
                let wire = NodeWire.Value.object(args.mapValues { value -> NodeWire.Value in
                    if let text = value as? String { return .string(text) }
                    return .array((value as? [String] ?? []).map(NodeWire.Value.string))
                })
                guard let reply = self.blocking(world, "plugin.file", wire.object ?? [:], from: facts) else { return .failure(.init("no reply")) }
                guard reply.ok, case .object(let result)? = reply.result else { return .failure(.init(reply.error?.message ?? "refused")) }
                return .success(result.compactMapValues(\.string))
            }
        }
        return (asker, ran)
    }

    private func look(_ world: CardWorld) async {
        let done = Locked(false)
        world.queue.async { world.engine.lookAtPlugins { done.value = true } }
        _ = await eventually(timeout: 60) { done.value }
    }

    private func cards(_ world: CardWorld) -> [CardStore.Card] {
        world.queue.sync { world.engine.cards.cards.values.filter { $0.plugin?.plugin == "probe" }.sorted { $0.at < $1.at } }
    }

    private func probe(_ world: CardWorld) -> ExternalPlugin? { world.queue.sync { world.engine.plugins.plugin("probe") as? ExternalPlugin } }

    // MARK: The manifest

    @Test func theManifestIsReadStrictly() throws {
        let good = try Data(contentsOf: URL(fileURLWithPath: Self.probe).appendingPathComponent(PluginManifest.fileName))
        #expect((try? PluginManifest.read(good, builtIn: ["shell"]).get())?.id == "probe")
        #expect((try? PluginManifest.read(good, builtIn: ["probe"]).get()) == nil, "a built-in's id")
        var object = try #require(try JSONSerialization.jsonObject(with: good) as? [String: Any])
        object["extra"] = true
        #expect((try? PluginManifest.read(JSONSerialization.data(withJSONObject: object), builtIn: []).get()) == nil, "a field it doesn't read")
        object["extra"] = nil
        object["program"] = "../escape"
        #expect((try? PluginManifest.read(JSONSerialization.data(withJSONObject: object), builtIn: []).get()) == nil)
        object["program"] = "plugin.py"
        object["life"] = 7 * 86_400
        #expect((try? PluginManifest.read(JSONSerialization.data(withJSONObject: object), builtIn: []).get()) == nil, "past 24 hours")
        object["life"] = 3600
        #expect((try? PluginManifest.read(JSONSerialization.data(withJSONObject: object), builtIn: []).get()) == nil, "past 30 minutes with no reason")
    }

    // MARK: Add, on, a request, an answer, remove

    @Test func addedOnAskedAnsweredRemoved() async throws {
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        let inspected = try await added(world, on: false)
        #expect(inspected.result?["programSHA"]?.string?.count == 64)
        #expect(try world.world.link.vaultV2.externalPlugins()["probe"]?.contains(inspected.result?["programSHA"]?.string ?? "-") == true)
        let listed = try #require(await world.ask("plugin.list", action: nil))
        #expect(listed.result?["plugins"]?.array?.contains { $0["id"]?.string == "probe" && $0["on"]?.bool == false } == true, "added off")
        // Off: vs-ask files nothing.
        let off = try await ask(world, ["normal"])
        #expect(off.output.status == 1, "\(off.output)")
        _ = try #require(await world.ask("plugin.on", ["plugin": .string("probe")]))

        let filed = try await ask(world, ["normal", "deep"])
        #expect(filed.output.status == 0 && filed.output.output.contains("Filed Probe request"), "\(filed.output)")
        await look(world)
        let card = try #require(cards(world).first)
        #expect(WireSchema.check(card.value, as: "card", strict: true) == nil, "\(card.value)")
        let lines = CardText.lines(card.value)
        #expect(lines.contains("  Probe says, depth: 1") && lines.contains("  the asking session's folder: \(world.repo)"), "\(lines)")
        #expect(lines.contains("    | normal deep") && lines.contains("  why (the agent's words): \u{201C}a test\u{201D}"), "\(lines)")
        #expect(card.plugin?.session == NodeIds.session(host: filed.asker.id) && card.plugin?.asker == "Asker", "the host's, not the plugin's")
        let ran = try #require(await world.answer(card, "run"))
        #expect(ran.ok && ran.result?["outcome"]?.string == "ran" && ran.result?["say"]?.array?.first?.string == "Ran the probe", "\(ran)")
        let closed = try #require(world.card(card.id))
        #expect(!closed.isOpen && closed.plugin?.state == "ran")

        let removed = try #require(await world.ask("plugin.remove", ["plugin": .string("probe")]))
        #expect(removed.ok, "\(removed)")
        #expect(try world.world.link.vaultV2.externalPlugins()["probe"] == nil)
        #expect(probe(world) == nil)
    }

    /// The plugin's page is served by the core: the address only in the answer's reply, the answer handed to the plugin.
    @Test func aPluginsPageIsServedByTheCore() async throws {
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        _ = try await added(world)
        _ = try await ask(world, ["page"])
        await look(world)
        let card = try #require(cards(world).first)
        let opened = try #require(await world.answer(card, "run"))
        let address = try #require(opened.result?["say"]?.array?.last?.string?.trimmingCharacters(in: .whitespaces), "\(opened)")
        let url = try #require(URL(string: address))
        let port = try #require(url.port.map(UInt16.init))
        let place = "127.0.0.1:\(port)", path = String(address.dropFirst("http://\(place)".count))
        let client = try WebTestClient(port: port)
        _ = client.send("GET \(path) HTTP/1.1\r\nHost: \(place)\r\n\r\n")
        let page = try #require(client.response())
        #expect(page.head.contains("script-src 'sha256-") && page.body.contains("document.title"), "\(page.head)")
        let answer = try WebTestClient(port: port)
        try #require(answer.upgrade(path: path + "answer", host: place, origin: "http://" + place)?.hasPrefix("HTTP/1.1 101") == true)
        _ = answer.send(WebTestClient.text(#"{"ok":true}"#))
        #expect(answer.message()?.text == "ok")
        #expect(await eventually(timeout: 30) { world.card(card.id)?.plugin?.state == "answered" })
    }

    /// Hostile answers: a card with an escape is refused (the program runs on); a wrong id, an answer out of order, a line
    /// too long, a hang: each ends the program, its open cards withdrawn, `plugin list` says why.
    @Test func hostileAnswersEndTheProgramOrRefuseTheCard() async throws {
        let notes = Locked<[String]>([])
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()], note: { line in notes.mutate { $0.append(line) } })
        defer { world.stop() }
        _ = try await added(world)
        _ = try await ask(world, ["controls"])
        await look(world)
        #expect(cards(world).isEmpty, "a card with an escape isn't drawn")
        #expect(probe(world)?.ended == nil, "a card refused, not a breach")

        for mode in ["wrong-id", "out-of-order", "oversize"] {
            _ = try await ask(world, ["normal"])
            await look(world)
            #expect(cards(world).contains { $0.isOpen }, "\(mode): a card open before: \(notes.value.suffix(8))")
            _ = try await ask(world, [mode])
            await look(world)
            #expect(await eventually(timeout: 30) { self.probe(world)?.ended != nil }, "\(mode): its program ended: \(notes.value.suffix(12))")
            #expect(cards(world).allSatisfy { !$0.isOpen }, "\(mode): its open cards withdrawn")
            let listed = try #require(await world.ask("plugin.list", action: nil))
            #expect(PluginListText.lines(listed.result?["plugins"]?.array ?? []).contains { $0.contains("its program ended") }, "\(mode)")
            _ = await world.ask("plugin.off", ["plugin": .string("probe")])
            _ = await world.ask("plugin.on", ["plugin": .string("probe")])
            #expect(probe(world)?.ended == nil)
        }
        _ = try await ask(world, ["hang"])
        await look(world)
        #expect(await eventually(timeout: 60) { self.probe(world)?.ended?.contains("didn't answer") == true }, "a hang ends it after 10 s")
    }

    /// Its settings are checked by its program and kept in the vault; a program changed since it was added is held.
    @Test func settingsAreCheckedAndAChangedProgramIsHeld() async throws {
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        let folder = scratch.url("probe-copy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: Self.probe)
        try writeClosedOnExec(String(contentsOf: source.appendingPathComponent(PluginManifest.fileName), encoding: .utf8),
                              to: folder.appendingPathComponent(PluginManifest.fileName), mode: 0o644)
        let program = try String(contentsOf: source.appendingPathComponent("plugin.py"), encoding: .utf8)
        try writeClosedOnExec(program, to: folder.appendingPathComponent("plugin.py"))
        _ = try await added(world, folder: folder.path)
        _ = try await ask(world, ["normal"])
        await look(world)
        let set = try #require(await world.ask("set", ["key": .string("probe_depth"), "value": .string("3")]))
        #expect(set.ok, "\(set)")
        let refused = try #require(await world.ask("set", ["key": .string("probe_depth"), "value": .string("99")]))
        #expect(refused.error?.code == NodeWire.Code.badArgs.rawValue && refused.error?.message.contains("1 to 9") == true, "\(refused)")

        // Changed on disk: off and on again, it isn't run.
        try writeClosedOnExec(program + "\n# changed\n", to: folder.appendingPathComponent("plugin.py"))
        _ = await world.ask("plugin.off", ["plugin": .string("probe")])
        _ = await world.ask("plugin.on", ["plugin": .string("probe")])
        _ = try await ask(world, ["normal"])
        await look(world)
        #expect(await eventually(timeout: 30) { self.probe(world)?.held?.contains("changed since you added it") == true })
    }
}
