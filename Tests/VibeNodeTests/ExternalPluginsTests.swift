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
    private func added(_ world: CardWorld, folder: String = ExternalPluginsTests.probe, on: Bool = true, id: String = "probe") async throws -> NodeWire.Reply {
        let inspected = try #require(await world.ask("plugin.inspect", ["folder": .string(folder)], action: nil))
        try #require(inspected.ok, "\(inspected)")
        let added = try #require(await world.ask("plugin.add", ["folder": .string(folder), "manifest": inspected.result?["manifestSHA"] ?? .null,
                                                               "program": inspected.result?["programSHA"] ?? .null]))
        try #require(added.ok, "\(added)")
        if on {
            let turned = try #require(await world.ask("plugin.on", ["plugin": .string(id)]))
            try #require(turned.ok, "\(turned)")
        }
        return inspected
    }

    /// `vs-ask probe -- WORDS` from a scratch session: the filer as the tool server runs it, the host stamping it.
    private func ask(_ world: CardWorld, _ words: [String], id: String = "probe") async throws -> (asker: HostSession, output: (status: Int32, output: String, error: String)) {
        let asker = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Asker")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.engine.link.sessions.contains { $0.id == asker.id && $0.isLive } } })
        let session = asker.id.uuidString.lowercased()
        let vault = world.host.book.vault(folder: scratch.url("asker-\(UUID().uuidString.prefix(6))"), as: { .session(session) }, userOpened: true)
        let facts = CardWorld.toolServer(of: asker)
        let ran = await offPool {
            PluginAsk.run([id, "--"] + words, cwd: world.repo, vault: vault, root: world.host.root) { args in
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
        // Its wrapper beside the node's commands while it is on (the host puts the folder last on sessions' PATH).
        let wrapper = world.host.root.appendingPathComponent("plugins/bin/vs-probe")
        #expect(await eventually(timeout: 30) { (try? String(contentsOf: wrapper, encoding: .utf8))?.contains("exec vs-ask probe -- \"$@\"") == true })

        let filed = try await ask(world, ["normal", "deep"])
        #expect(filed.output.status == 0 && filed.output.output.contains("Filed Probe request"), "\(filed.output)")
        await look(world)
        let card = try #require(cards(world).first)
        #expect(WireSchema.check(card.value, as: "card", strict: true) == nil, "\(card.value)")
        let lines = CardText.lines(card.value)
        #expect(lines.contains("  the probe plugin says, depth: 1") && lines.contains("  the asking session's folder: \(world.repo)"), "\(lines)")
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
        #expect(await eventually(timeout: 30) { !FileManager.default.fileExists(atPath: wrapper.path) }, "its wrapper gone with it")
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
        let cookie = try #require(PluginsTests.cookie(page.head), "\(page.head)")
        let answer = try WebTestClient(port: port)
        try #require(answer.upgrade(path: path + "answer", host: place, origin: "http://" + place, extra: [cookie])?.hasPrefix("HTTP/1.1 101") == true)
        _ = answer.send(WebTestClient.text(#"{"ok":true}"#))
        #expect(answer.message()?.text == "ok")
        #expect(await eventually(timeout: 30) { world.card(card.id)?.plugin?.state == "answered" })
    }

    /// The page's answer is taken only while its request waits on the page, marked before the plugin hears it: a second
    /// answer in the same turn, or one after the card closed, never reaches the program (automated review 2).
    @Test func aPagesAnswerReachesThePluginOnce() async throws {
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        _ = try await added(world)
        _ = try await ask(world, ["page"])
        await look(world)
        let card = try #require(cards(world).first)
        let plugin = try #require(probe(world))
        let take = Locked<((Data, @escaping (Bool) -> Void) -> Void)?>(nil)
        let act = PluginAct(start: { _, _ in }, page: { _, given, _, opened in
            take.value = given
            opened(.success(()))
        })
        let performed = Locked<Result<NodeWire.Value, LeadEngine.CardFailure>?>(nil)
        world.queue.async {
            var marked = card
            marked.plugin?.state = "answering"
            world.engine.cards.put(marked)
            plugin.perform("run", on: marked, desk: world.engine.desk(plugin), act: act) { performed.value = $0 }
        }
        #expect(await eventually(timeout: 30) { performed.value != nil && take.value != nil })
        #expect(world.card(card.id)?.plugin?.state == "page")
        let answered = Locked<[Bool]>([])
        let given = try #require(take.value)
        world.queue.async {
            given(Data(#"{"ok":true}"#.utf8)) { taken in answered.mutate { $0.append(taken) } }
            given(Data(#"{"ok":true}"#.utf8)) { taken in answered.mutate { $0.append(taken) } }
        }
        #expect(await eventually(timeout: 30) { answered.value.count == 2 })
        #expect(answered.value.filter { $0 }.count == 1 && answered.value.count == 2, "\(answered.value)")
        #expect(world.card(card.id)?.plugin?.state == "answered")
        let late = Locked<Bool?>(nil)
        world.queue.async { given(Data(#"{"ok":true}"#.utf8)) { late.value = $0 } }
        #expect(await eventually(timeout: 30) { late.value != nil })
        #expect(late.value == false, "a card answered: no answer taken after it")
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
            // A look that began as it was turned on may have read the folder before: look until its card is up.
            for _ in 0..<5 where !cards(world).contains(where: \.isOpen) { await look(world) }
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

    /// A program that broke the protocol stays ended across further requests (nothing starts it again, nothing is filed,
    /// `plugin list` says why) until the user's `plugin off` and `on`; its cards are withdrawn as ended, not turned off
    /// (automated review 2).
    @Test func aBreachStaysEndedUntilOffAndOn() async throws {
        let notes = Locked<[String]>([])
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()], note: { line in notes.mutate { $0.append(line) } })
        defer { world.stop() }
        _ = try await added(world)
        _ = try await ask(world, ["normal"])
        for _ in 0..<5 where !cards(world).contains(where: \.isOpen) { await look(world) }
        let open = try #require(cards(world).first { $0.isOpen }, "\(notes.value.suffix(8))")
        _ = try await ask(world, ["wrong-id"])
        await look(world)
        #expect(await eventually(timeout: 30) { self.probe(world)?.ended != nil })
        let withdrawn = try #require(world.card(open.id))
        #expect(withdrawn.closed?.contains("program ended") == true, "\(String(describing: withdrawn.closed))")
        for _ in 0..<2 {
            let refused = try await ask(world, ["normal"])
            #expect(refused.output.status != 0, "nothing filed while it is ended: \(refused.output)")
            await look(world)
            #expect(probe(world)?.ended != nil, "still ended")
        }
        // Asked to start directly (a look whose read was in flight at the breach, an answer): refused while ended.
        let plugin = try #require(probe(world))
        let restarted = Locked<Bool?>(nil)
        world.queue.async { plugin.startedProcess(world.engine.desk(plugin)) { restarted.value = (try? $0.get()) != nil } }
        #expect(await eventually(timeout: 30) { restarted.value != nil })
        #expect(restarted.value == false, "not started again while ended")
        let listed = try #require(await world.ask("plugin.list", action: nil))
        #expect(PluginListText.lines(listed.result?["plugins"]?.array ?? []).contains { $0.contains("its program ended") })
        _ = await world.ask("plugin.off", ["plugin": .string("probe")])
        _ = await world.ask("plugin.on", ["plugin": .string("probe")])
        #expect(probe(world)?.ended == nil)
        let filed = try await ask(world, ["normal"])
        #expect(filed.output.status == 0, "\(filed.output)")
        for _ in 0..<5 where !cards(world).contains(where: \.isOpen) { await look(world) }
        #expect(cards(world).contains { $0.isOpen }, "on again: it starts afresh")
    }

    /// A copy of the probe plugin in `name`, its program with `extra` appended (other bytes), under `id`.
    private func copy(_ name: String, extra: String = "", id: String = "probe") throws -> URL {
        let folder = scratch.url(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: Self.probe)
        let manifest = try String(contentsOf: source.appendingPathComponent(PluginManifest.fileName), encoding: .utf8)
        try writeClosedOnExec(manifest.replacingOccurrences(of: #""id": "probe""#, with: #""id": "\#(id)""#),
                              to: folder.appendingPathComponent(PluginManifest.fileName), mode: 0o644)
        let program = try String(contentsOf: source.appendingPathComponent("plugin.py"), encoding: .utf8)
        try writeClosedOnExec(program.replacingOccurrences(of: #""plugin": "probe""#, with: #""plugin": "\#(id)""#) + extra,
                              to: folder.appendingPathComponent("plugin.py"))
        return folder
    }

    /// A plugin's program that breached while a child of its (in a session of its own) holds its pipes open, the
    /// process still held: no reader is left in `read` on a descriptor closed under it, so a pipe that takes its number
    /// afterwards is never read (automated review 1: each reader owns its descriptor and ends at the cancel pipe).
    @Test func aBreachedProgramsReadersNeverReadAReusedDescriptor() async throws {
        let work = scratch.url("linger-work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let copy = try Platform.ProcessSelf.sealedCopy(of: Self.probe + "/plugin.py", name: "plugin-linger").get()
        let process = PluginProcess(id: "linger", note: { _ in })
        let started = process.start(copy: copy, data: work)
        Sys.close(copy.fd)
        try started.get()
        var strangers: [[Int32]] = []
        defer {
            try? Data().write(to: work.appendingPathComponent("stop"))
            for pair in strangers { pair.forEach { Sys.close($0) } }
            process.stop()
        }
        let ends = process.readEnds
        try #require(ends.count == 2)
        // Each read end's file ("pipe:[inode]"): closed, or its number another file's now (another test may take it first).
        let file = { (fd: Int32) in try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(fd)") }
        let pipes = ends.map(file)
        try #require(pipes.allSatisfy { $0?.hasPrefix("pipe:") == true }, "\(pipes)")
        let ended = Locked<String?>(nil)
        process.onEnd = { ended.value = $0 }
        let payload = Data(#"{"words":["linger"]}"#.utf8).base64EncodedString()
        process.call("card", ["request": "r1", "payload": payload, "settings": [String: String]()]) { _ in }
        #expect(await eventually(timeout: 30) { ended.value != nil }, "the wrong id ended it")
        // Its read ends' numbers let go: pipes made now take the lowest free numbers, theirs among them.
        #expect(await eventually(timeout: 30) { zip(ends, pipes).allSatisfy { file($0) != $1 } }, "its descriptors closed")
        for _ in 0..<16 {
            var pair: [Int32] = [-1, -1]
            guard Sys.pipeClosedOnExec(&pair) == 0 else { break }
            _ = fcntl(pair[0], F_SETFL, fcntl(pair[0], F_GETFL) | O_NONBLOCK)
            _ = pair[1].withMarker { write(pair[1], $0, 6) }
            strangers.append(pair)
        }
        try Data().write(to: work.appendingPathComponent("go"))
        #expect(await eventually(timeout: 30) { FileManager.default.fileExists(atPath: work.appendingPathComponent("wrote").path) })
        let stolen = {
            strangers.contains { pair in
                var buffer = [UInt8](repeating: 0, count: 6)
                let count = read(pair[0], &buffer, 6)
                if count > 0 { _ = pair[1].withMarker { write(pair[1], $0, count) } }
                return count != 6
            }
        }
        #expect(await eventually(timeout: 3) { stolen() } == false, "a reader read a pipe that took its descriptor's number")
        withExtendedLifetime(process) {}
    }

    /// Removed, then another program added under the same id: off, its settings at their defaults, nothing of the
    /// old one inherited (automated review 1). (An id already listed is refused at `plugin add`: removing comes first.)
    @Test func aPluginAddedBackUnderItsIdInheritsNothing() async throws {
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        let first = try copy("probe-first")
        _ = try await added(world, folder: first.path)
        _ = try await ask(world, ["normal"])
        for _ in 0..<5 where !cards(world).contains(where: \.isOpen) { await look(world) }
        let set = try #require(await world.ask("set", ["key": .string("probe_depth"), "value": .string("3")]))
        try #require(set.ok, "\(set)")
        let vault = world.world.link.vaultV2
        #expect(try vault.pluginSettings()["probe.depth"] == "3")

        let removed = try #require(await world.ask("plugin.remove", ["plugin": .string("probe")]))
        try #require(removed.ok, "\(removed)")
        #expect(try vault.pluginSettings()["probe.depth"] == nil && vault.plugins()["probe"] == nil, "removed: none of its keys left")

        let second = try copy("probe-second", extra: "\n# another program\n")
        _ = try await added(world, folder: second.path, on: false)
        #expect(try vault.plugins()["probe"] == nil && vault.pluginSettings().isEmpty, "added back: off, at its defaults")
        let listed = try #require(await world.ask("plugin.list", action: nil))
        #expect(listed.result?["plugins"]?.array?.contains { $0["id"]?.string == "probe" && $0["on"]?.bool == false } == true, "\(listed)")

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
        // A look that began as it was turned on may have read the folder before: look until its card is up (its program runs).
        for _ in 0..<5 where !cards(world).contains(where: \.isOpen) { await look(world) }
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

// MARK: The independent review of step C (3cbffc3a)

extension ExternalPluginsTests {
    /// A card of the probe's for `mode`, its program running: filed, then looked at until it is up.
    private func probeCard(_ world: CardWorld, _ mode: String) async throws -> CardStore.Card {
        let before = Set(cards(world).map(\.id))
        _ = try await ask(world, [mode])
        let fresh = { self.cards(world).first { $0.isOpen && !before.contains($0.id) } }
        // Looked at until its card is up: a look already under way (its program starting) may answer before it is.
        let until = MacTime.real.awake() + 30
        while fresh() == nil, MacTime.real.awake() < until {
            await look(world)
            _ = await eventually(timeout: 0.5) { fresh() != nil }
        }
        return try #require(fresh(), "a \(mode) card")
    }

    /// M1: an external plugin's every answer is acting (its expiry holds for decline too), and a page for a word that
    /// doesn't act is a breach.
    @Test func everyExternalAnswerActsAndAPageForDeclineIsABreach() async throws {
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        _ = try await added(world)
        let late = try await probeCard(world, "normal")
        world.queue.sync { world.engine.pluginNow = { late.plugin?.expiresAt?.addingTimeInterval(1) ?? Date() } }
        let declined = try #require(await world.answer(late, "decline"))
        #expect(declined.error?.message.contains("expired") == true, "past its expiry, decline is refused too: \(declined)")
        world.queue.sync { world.engine.pluginNow = Date.init }
        let paged = try await probeCard(world, "pagedecline")
        let answered = try #require(await world.answer(paged, "decline"))
        #expect(!answered.ok, "\(answered)")
        #expect(await eventually(timeout: 30) { self.probe(world)?.ended?.contains("a page answers only an acting word") == true })
    }

    /// M2: the line told to the agent is one line, never starting with "[": a forged "[VibeSwitcher]" line is a breach,
    /// and the core's prefix names the plugin by its id.
    @Test func theAgentsLineIsOneLineWithTheCoresPrefixOnly() async throws {
        for mode in ["forge", "bracket"] {
            let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
            defer { world.stop() }
            _ = try await added(world)
            let card = try await probeCard(world, mode)
            _ = await world.answer(card, "run")
            #expect(await eventually(timeout: 30) { self.probe(world)?.ended?.contains("answer didn't fit") == true }, "\(mode)")
        }
    }

    /// L2 and L6: a title naming the node's own is refused; a fact is "the <id> plugin says"; an action that marks its card
    /// waiting is refused (a card that doesn't fit its shape: the card isn't drawn, the program is ended).
    @Test func titlesFactsAndMarksAreTheCoresToWord() async throws {
        let good = try Data(contentsOf: URL(fileURLWithPath: Self.probe).appendingPathComponent(PluginManifest.fileName))
        var object = try #require(try JSONSerialization.jsonObject(with: good) as? [String: Any])
        for title in ["VibeSwitcher wallet", "Node helper", "The session host's tool", "vs-wallet"] {
            object["title"] = title
            #expect((try? PluginManifest.read(JSONSerialization.data(withJSONObject: object), builtIn: []).get()) == nil, "\(title)")
        }
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        _ = try await added(world)
        let card = try await probeCard(world, "normal")
        #expect(card.plugin?.facts.contains { $0.label == "the probe plugin says, depth" } == true, "\(String(describing: card.plugin?.facts))")
        _ = try await ask(world, ["waitmarks"])
        await look(world)
        await look(world)
        #expect(await eventually(timeout: 30) { self.probe(world)?.ended?.contains("can't mark its card waiting") == true },
                "\(String(describing: self.probe(world)?.ended))")
        #expect(cards(world).allSatisfy { !$0.isOpen || $0.id == card.id } || cards(world).allSatisfy { !$0.isOpen }, "not drawn")
    }

    /// M3: plugin.file only from inside a live session the user opened, one refusal text whichever fails; filing calls
    /// queue 4 deep, then busy.
    @Test func filingIsFromTheSessionItselfAndBounded() async throws {
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        _ = try await added(world)
        let asker = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Asker")
        let other = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Other")
        try #require(await eventually(timeout: 60) {
            world.queue.sync { [asker.id, other.id].allSatisfy { id in world.engine.link.sessions.contains { $0.id == id && $0.isLive } } }
        })
        let args = { (session: UUID, words: [String]) -> [String: NodeWire.Value] in
            ["plugin": .string("probe"), "session": .string(session.uuidString.lowercased()), "words": .array(words.map(NodeWire.Value.string)),
             "cwd": .string(world.repo)]
        }
        let stranger = PeerFacts(pid: 77_002, uid: getuid(), cgroup: nil, ancestry: [.init(pid: 77_002, startTicks: 1)], terminal: .none,
                                 sessionMarker: false, underRunner: false)
        let outside = self.blocking(world, "plugin.file", args(asker.id, ["normal"]), from: stranger)
        let elsewhere = self.blocking(world, "plugin.file", args(asker.id, ["normal"]), from: CardWorld.toolServer(of: other))
        let gone = self.blocking(world, "plugin.file", args(UUID(), ["normal"]), from: CardWorld.toolServer(of: asker))
        let texts = [outside, elsewhere, gone].map { $0?.error?.message }
        #expect(texts.allSatisfy { $0 == texts[0] } && texts[0]?.contains("only a live session the user opened") == true, "\(texts)")
        // Filing calls the program doesn't answer: 4 wait, the fifth is busy.
        let replies = Locked<[NodeWire.Reply]>([])
        for _ in 0..<6 {
            world.queue.async {
                world.requests.handle(NodeWire.Request(id: UUID().uuidString, kind: "plugin.file", args: args(asker.id, ["filehang"]), action: nil),
                                      from: CardWorld.toolServer(of: asker)) { reply in replies.mutate { $0.append(reply) } }
            }
        }
        #expect(await eventually(timeout: 8) { replies.value.contains { $0.error?.message.contains("busy") == true } }, "\(replies.value)")
    }

    /// L1: add takes only the folder as inspect resolved it, not a path that resolves there.
    @Test func addTakesTheResolvedFolderOnly() async throws {
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        let link = scratch.url("probe-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: Self.probe)
        let inspected = try #require(await world.ask("plugin.inspect", ["folder": .string(link.path)], action: nil))
        try #require(inspected.ok, "\(inspected)")
        #expect(inspected.result?["folder"]?.string != link.path)
        let added = try #require(await world.ask("plugin.add", ["folder": .string(link.path), "manifest": inspected.result?["manifestSHA"] ?? .null,
                                                               "program": inspected.result?["programSHA"] ?? .null]))
        #expect(added.error?.message.contains("isn't the one shown") == true, "\(added)")
    }

    /// L5: a setting is checked by the program even when it isn't running yet (it is started for it).
    @Test func aSettingStartsTheProgramToCheckIt() async throws {
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        _ = try await added(world)
        let set = try #require(await world.ask("set", ["key": .string("probe_depth"), "value": .string("4")]))
        #expect(set.ok, "\(set)")
        let refused = try #require(await world.ask("set", ["key": .string("probe_depth"), "value": .string("99")]))
        #expect(refused.error?.message.contains("1 to 9") == true, "\(refused)")
    }

    /// L4 and L7: a link where the node keeps its plugins' folders is never followed (no wrapper written through it,
    /// nothing removed behind it); remove empties the plugin's requests folder, so a program added back sees none.
    @Test func pluginFoldersAreTheNodesOwnAndRemoveEmptiesTheRequests() async throws {
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        let elsewhere = scratch.url("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: elsewhere.appendingPathComponent("vs-theirs"))
        let plugins = world.host.root.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: plugins.appendingPathComponent("bin"))
        try FileManager.default.createSymbolicLink(at: plugins.appendingPathComponent("bin"), withDestinationURL: elsewhere)
        let notes = Locked<[String]>([])
        LeadEngine.writeWrappers(["vs-probe": "probe"], in: plugins.appendingPathComponent("bin"), note: { line in notes.mutate { $0.append(line) } })
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("vs-theirs").path), "nothing removed behind the link")
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("vs-probe").path), "nothing written through it")
        #expect(notes.value.contains { $0.contains("is a link") }, "\(notes.value)")
        #expect(PluginFolders.empty(plugins.appendingPathComponent("bin"), andItself: true)?.contains("is a link") == true)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("vs-theirs").path))
        try FileManager.default.removeItem(at: plugins.appendingPathComponent("bin"))

        _ = try await added(world)
        _ = try await ask(world, ["normal"])
        let requests = world.host.root.appendingPathComponent("plugin-requests/probe")
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? []).isEmpty, "a request filed")
        let removed = try #require(await world.ask("plugin.remove", ["plugin": .string("probe")]))
        try #require(removed.ok, "\(removed)")
        #expect(await eventually(timeout: 30) { !FileManager.default.fileExists(atPath: requests.path) }, "its requests gone with it")
    }

    /// L3: no plugin command is one the node ships; the Linux install leaves the Mac's vs-wallet filer out.
    @Test func aPluginCommandIsNeverTheNodesOwn() throws {
        let bin = URL(fileURLWithPath: Self.probe).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shipped = Set(try FileManager.default.contentsOfDirectory(atPath: bin.appendingPathComponent("Resources/bin").path).filter { $0.hasPrefix("vs-") })
        #expect(shipped == PluginManifest.nodeCommands.union(PluginManifest.macOnlyCommands), "\(shipped)")
        let install = try String(contentsOf: bin.appendingPathComponent("scripts/install-node.sh"), encoding: .utf8)
        for name in PluginManifest.macOnlyCommands { #expect(install.contains("[[ ${file##*/} == \(name) ]] && continue"), "\(name) shipped on Linux") }
        let good = try Data(contentsOf: URL(fileURLWithPath: Self.probe).appendingPathComponent(PluginManifest.fileName))
        var object = try #require(try JSONSerialization.jsonObject(with: good) as? [String: Any])
        for name in PluginManifest.nodeCommands {
            object["commands"] = [["name": name, "about": "x"]]
            #expect((try? PluginManifest.read(JSONSerialization.data(withJSONObject: object), builtIn: []).get()) == nil, "\(name)")
        }
        object["commands"] = [["name": "vs-wallet", "about": "asks for a signature"]]
        #expect((try? PluginManifest.read(JSONSerialization.data(withJSONObject: object), builtIn: []).get()) != nil, "the wallet plugin's own")
    }

    /// H1: the program has no writable place it reads at start (HOME names nothing, it works in /, Python reads no user
    /// site): a .pth planted where its HOME used to be never runs; its data folder only when asked for.
    @Test func theProgramReadsNoWritablePlaceAtStart() async throws {
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        let version = try #require(try? Self.output("/usr/bin/python3", ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"]))
        let marker = scratch.url("pth-ran")
        let oldHome = world.host.root.appendingPathComponent("plugins/probe/work")
        let site = oldHome.appendingPathComponent(".local/lib/python\(version)/site-packages")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("import os; open(\"\(marker.path)\", \"w\").close()\n".utf8).write(to: site.appendingPathComponent("x.pth"))
        _ = try await added(world)
        let card = try await probeCard(world, "env")
        let body = card.plugin?.body.text ?? ""
        #expect(body.contains("HOME=/nonexistent") && body.contains("PYTHONNOUSERSITE=1") && body.contains("PYTHONSAFEPATH=1")
                && body.contains("PYTHONDONTWRITEBYTECODE=1") && body.contains("VIBESWITCHER_PLUGIN_DATA=-") && body.contains("cwd=/"), "\(body)")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the planted .pth didn't run")
    }

    /// H1: what a program loads before its own code is root's: `env`, an interpreter of the user's, an ELF's RUNPATH or
    /// $ORIGIN into a writable place are refused; a system program passes.
    @Test func whatAProgramLoadsIsRootsAllTheWay() throws {
        #expect(PluginProgram.refusal(Data("#!/usr/bin/python3\nprint(1)\n".utf8)) == nil)
        #expect(PluginProgram.refusal(Data("#!/usr/bin/env python3\n".utf8))?.contains("env") == true)
        let mine = scratch.url("python3")
        try writeClosedOnExec("#!/bin/sh\n", to: mine)
        #expect(PluginProgram.refusal(Data("#!\(mine.path)\n".utf8))?.contains("isn't root's alone") == true)
        #expect(PluginProgram.refusal(Data("echo hi\n".utf8)) != nil, "neither ELF nor #!")
        #expect(PluginProgram.refusal(try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))) == nil, "a system program")
        let writable = scratch.url("libs")
        try FileManager.default.createDirectory(at: writable, withIntermediateDirectories: true)
        #expect(PluginProgram.refusal(Self.elf(interpreter: "/lib64/ld-linux-x86-64.so.2", runpath: writable.path))?.contains("search path") == true)
        #expect(PluginProgram.refusal(Self.elf(interpreter: "/lib64/ld-linux-x86-64.so.2", runpath: "$ORIGIN/lib"))?.contains("$ORIGIN") == true)
        #expect(PluginProgram.refusal(Self.elf(interpreter: "/lib64/ld-linux-x86-64.so.2", runpath: "/usr/lib")) == nil)
        #expect(PluginProgram.refusal(Self.elf(interpreter: mine.path, runpath: nil))?.contains("interpreter") == true)
        // At add: a folder whose program finds its interpreter on PATH is refused, the reason shown.
        let folder = try copy("probe-env")
        let program = try String(contentsOf: folder.appendingPathComponent("plugin.py"), encoding: .utf8)
        try writeClosedOnExec(program.replacingOccurrences(of: "#!/usr/bin/python3", with: "#!/usr/bin/env python3"), to: folder.appendingPathComponent("plugin.py"))
        guard case .failure(let why) = PluginFolder.inspect(folder.path, builtIn: []) else { Issue.record("added"); return }
        #expect(why.description.contains("env"), "\(why)")
    }

    /// A minimal 64-bit ELF: a PT_LOAD over the file, a PT_INTERP, and a PT_DYNAMIC with a string table and RUNPATH.
    static func elf(interpreter: String, runpath: String?) -> Data {
        var strings: [UInt8] = [0]
        let runpathAt = strings.count
        if let runpath { strings += Array(runpath.utf8) + [0] }
        let interp = Array(interpreter.utf8) + [0]
        let headers = 64, phCount = 3, phSize = 56
        let interpAt = headers + phCount * phSize
        let stringsAt = interpAt + interp.count
        let dynamicAt = stringsAt + strings.count
        var dynamic: [(UInt64, UInt64)] = [(5, UInt64(stringsAt))]
        if runpath != nil { dynamic.append((29, UInt64(runpathAt))) }
        dynamic.append((0, 0))
        let total = dynamicAt + dynamic.count * 16
        var bytes = [UInt8](repeating: 0, count: total)
        func put(_ value: UInt64, _ at: Int, _ width: Int) { for i in 0..<width { bytes[at + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) } }
        bytes[0...3] = [0x7F, 0x45, 0x4C, 0x46]
        bytes[4] = 2; bytes[5] = 1; bytes[6] = 1
        put(2, 16, 2); put(62, 18, 2); put(1, 20, 4)
        put(UInt64(headers), 0x20, 8); put(64, 0x34, 2); put(UInt64(phSize), 0x36, 2); put(UInt64(phCount), 0x38, 2)
        let program: [(UInt64, Int, Int)] = [(1, 0, total), (3, interpAt, interp.count), (2, dynamicAt, dynamic.count * 16)]
        for (index, (type, offset, size)) in program.enumerated() {
            let at = headers + index * phSize
            put(type, at, 4); put(UInt64(offset), at + 8, 8); put(UInt64(offset), at + 16, 8); put(UInt64(size), at + 32, 8); put(UInt64(size), at + 40, 8)
        }
        bytes[interpAt..<interpAt + interp.count] = interp[...]
        bytes[stringsAt..<stringsAt + strings.count] = strings[...]
        for (index, (tag, value)) in dynamic.enumerated() { put(tag, dynamicAt + index * 16, 8); put(value, dynamicAt + index * 16 + 8, 8) }
        return Data(bytes)
    }

    static func output(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A line nested deeper than the protocol's bound is a breach found before it is parsed.
    @Test func aDeeplyNestedLineIsABreachBeforeItIsParsed() async throws {
        #expect(PluginProcess.nesting(Data(#"{"a":[1,{"b":"[[[["}]}"#.utf8)) == 3, "brackets in a string don't count")
        let world = try await CardWorld.make(scratch, plugins: [ShellPlugin()])
        defer { world.stop() }
        _ = try await added(world)
        _ = try await ask(world, ["deep"])
        await look(world)
        #expect(await eventually(timeout: 30) { self.probe(world)?.ended?.contains("nested over") == true },
                "\(String(describing: self.probe(world)?.ended))")
    }

    /// The program gets the parent-death signal through setpriv, tied to the spawner's thread: when that thread ends (as
    /// the server's end does), a program that ignores TERM and its input's end is killed.
    @Test func aProgramDiesWithItsSpawner() async throws {
        try #require(PluginSpawner.setpriv != nil, "this system has no setpriv")
        let script = scratch.url("deaf.py")
        try writeClosedOnExec("#!/usr/bin/python3\nimport signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nwhile True:\n    time.sleep(1)\n",
                              to: script)
        let copy = try Platform.ProcessSelf.sealedCopy(of: script.path, name: "plugin-deaf").get()
        let spawner = PluginSpawner()
        let process = PluginProcess(id: "deaf", note: { _ in }, spawner: spawner)
        let started = process.start(copy: copy, data: nil)
        Sys.close(copy.fd)
        try started.get()
        defer { process.stop() }
        let pid = process.pid
        let alive = { () -> Bool in
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let close = stat.lastIndex(of: ")") else { return false }
            return !stat[close...].hasPrefix(") Z")
        }
        #expect(alive() && process.confinement.contains("parent-death signal"), "\(process.confinement)")
        // Past setpriv (which sets the signal, then execs the program): a thread ending before that sends nothing.
        let name = { (try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(await eventually(timeout: 30) { name().map { $0 != "setpriv" } == true }, "\(String(describing: name()))")
        spawner.end()
        #expect(await eventually(timeout: 30) { !alive() }, "killed when its spawner's thread ended")
    }

    /// The cgroup a program gets only where the server's cgroup is writable; the launch moves itself in before exec.
    @Test func aProgramsCgroupIsMadeOnlyWhereItCanBe() {
        #expect(PluginCgroup.make(id: "probe", own: "0::/\n") == nil, "the root cgroup")
        #expect(PluginCgroup.make(id: "probe", own: "0::/non-writable-\(UUID().uuidString)\n") == nil)
        #expect(PluginCgroup.make(id: "probe", own: nil) == nil)
        let (executable, words, confinement) = PluginProcess.launch(copy: "/proc/self/fd/9", cgroup: PluginCgroup(folder: "/sys/fs/cgroup/x/vs-plugin-p"),
                                                                    setpriv: "/usr/bin/setpriv")
        #expect(executable == "/bin/sh" && words.contains("/sys/fs/cgroup/x/vs-plugin-p/cgroup.procs") && confinement == "a cgroup of its own")
        #expect(Array(words.suffix(5)) == ["/usr/bin/setpriv", "--pdeathsig", "KILL", "--", "/proc/self/fd/9"], "\(words)")
    }
}

private extension Int32 {
    /// Calls `body` with the marker a test puts in a pipe ("marker", 6 bytes).
    func withMarker<T>(_ body: (UnsafeRawPointer) -> T) -> T { Array("marker".utf8).withUnsafeBytes { body($0.baseAddress!) } }
}
