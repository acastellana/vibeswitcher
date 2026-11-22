import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// `vibeswitcher approve` (`ApproveRequest.swift`): one typed code for a batch the user sees whole, of what a plain accept
/// settles, each item recorded in the vault as its own action under the one voiced request; what needs the user's own
/// decision listed only. On a scratch host in the test process (`CardWorld`), its vault sealing at a first look, then a
/// change to the home's Claude settings held.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ApproveTests {
    private let scratch = Scratch()

    /// A world whose home's settings changed after the first look: held, for the repo's card (a project of the node's,
    /// recorded in the accepted snapshot) and the home's.
    private func world() async throws -> CardWorld {
        let world = try await CardWorld.make(scratch)
        world.queue.sync { world.requests.home = world.host.home.path }
        // The repository a project of this node's: in the accepted snapshot, as an accept leaves it.
        try AcceptedSnapshot.update(root: world.host.root, project: world.repo) { _ in }
        let settings = world.host.home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"env":{"A":"1"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        for folder in [world.repo, world.host.home.path] { _ = await world.ask("config.held", ["folder": .string(folder)], action: nil) }
        try #"{"env":{"A":"2"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        return world
    }

    private func list(_ world: CardWorld, only: [String] = ["config"]) async throws -> NodeWire.Value {
        let reply = try #require(await world.ask("approve.list", ["only": .array(only.map(NodeWire.Value.string))], action: nil))
        return try #require(reply.result, "\(reply)")
    }

    @Test func oneCodeDoesTheListedBatchEachItemItsOwnAction() async throws {
        let world = try await world()
        defer { world.stop() }
        let listed = try await list(world)
        let items = listed["items"]?.array ?? []
        #expect(items.compactMap { $0["kind"]?.string }.allSatisfy { $0 == "config.accept" } && !items.isEmpty, "\(listed)")
        let subjects = items.compactMap { $0["subject"]?.string }
        #expect(subjects.contains(world.repo), "\(listed)")
        // Each item with its card, as `config held` shows it.
        let shown = items.map { item in CardText.lines(item["card"] ?? .null).joined(separator: "\n") }
        #expect(shown.allSatisfy { $0.contains("~/.claude/settings.json") }, "\(shown)")
        let batch = try #require(listed["batch"]?.string)
        let code = try #require(listed["code"]?.string)
        #expect(code == NodeIds.code(card: batch))

        // Another code: refused by voice; the batch still stands.
        let wrong = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string("ZZZZ")]))
        #expect(wrong.error?.code == NodeWire.Code.voice.rawValue, "\(wrong)")

        let action = UUID().uuidString.lowercased()
        let done = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)], action: action))
        let result = try #require(done.result, "\(done)")
        let doneItems = result["done"]?.array ?? []
        #expect(doneItems.count == items.count && result["refused"] == .null, "\(result)")
        #expect(doneItems.enumerated().allSatisfy { $0.element["action"]?.string == Requests.itemAction(action, $0.offset) }, "\(result)")
        // Recorded: the batch's action and each item's, each its own.
        let accepted = world.queue.sync { world.requests.accepted }
        #expect(accepted.contains { $0.kind == "approve" && $0.action == action }, "\(accepted)")
        for index in items.indices {
            #expect(accepted.contains { $0.kind == "config.accept" && $0.action == Requests.itemAction(action, index) }, "\(accepted)")
        }
        // Taken once: a new action finds no batch; the same action is answered as before, nothing done twice.
        let again = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)]))
        #expect(again.error?.code == NodeWire.Code.gone.rawValue, "\(again)")
        let replayed = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)], action: action))
        #expect(replayed.ok && replayed.result?["done"]?.array?.count == items.count, "\(replayed)")
        #expect(world.queue.sync { world.requests.accepted }.filter { $0.kind == "config.accept" }.count == items.count)
        // Nothing held any more: nothing to list.
        let after = try await list(world)
        #expect(after["items"]?.array?.isEmpty == true && after["batch"] == nil, "\(after)")
    }

    @Test func aCardSettledSinceStopsTheBatchSayingWhatsLeft() async throws {
        let world = try await world()
        defer { world.stop() }
        let listed = try await list(world)
        let items = listed["items"]?.array ?? []
        try #require(items.count >= 2, "the repo's card and the home's: \(listed)")
        // The first item's card accepted on its own meanwhile.
        let first = try #require(items[0]["card"]?["id"]?.string)
        let alone = try #require(await world.ask("config.accept", ["card": .string(first), "code": .string(NodeIds.code(card: first))]))
        #expect(alone.ok, "\(alone)")
        let batch = try #require(listed["batch"]?.string)
        let code = try #require(listed["code"]?.string)
        let done = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)]))
        let result = try #require(done.result, "\(done)")
        #expect(result["done"]?.array?.isEmpty == true, "\(result)")
        #expect(result["refused"]?["kind"]?.string == "config.accept" && result["refused"]?["subject"]?.string == items[0]["subject"]?.string, "\(result)")
        #expect(result["left"]?.array?.count == items.count - 1, "\(result)")
    }

    @Test func onlyTheUserListsOrApprovesAndOnlyNamesNarrowIt() async throws {
        let world = try await world()
        defer { world.stop() }
        var session = CardWorld.user
        session.sessionMarker = true
        for kind in ["approve.list", "approve"] {
            let refused = try #require(await world.ask(kind, ["batch": .string("x"), "code": .string("x")], from: session))
            #expect(refused.error?.code == NodeWire.Code.voice.rawValue, "\(kind): \(refused)")
        }
        #expect(NodeWire.kinds["approve"] == .user && NodeWire.changesState("approve") && !NodeWire.changesState("approve.list"))
        let bad = try #require(await world.ask("approve.list", ["only": .array([.string("questions")])], action: nil))
        #expect(bad.error?.code == NodeWire.Code.badArgs.rawValue, "\(bad)")
        let bases = try await list(world, only: ["base"])
        #expect(bases["items"]?.array?.allSatisfy { $0["kind"]?.string == "base.accept" } == true, "\(bases)")
        #expect(Requests.itemAction("a", 0) != Requests.itemAction("a", 1) && Requests.itemAction("a", 0) == Requests.itemAction("A", 0))
        #expect(UUID(uuidString: Requests.itemAction(UUID().uuidString, 3)) != nil)
    }
}

/// The hooks out of date, as `approve` lists them (`HooksRequest.outOfDate`).
struct HooksOutOfDateTests {
    private let scratch = Scratch()

    @Test func aMissingProgramAndAConfigWithoutTheHooksAreSaid() throws {
        let home = scratch.url("home").path
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try "{}".write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        let request = HooksRequest(nodeRoot: "/nonexistent", home: home, binaries: ["vibeswitcher-hook": "aa", "vibeswitcher-mcp": "bb"],
                                   vault: LeadVault(folder: scratch.url("vault")) { _ in .ok })
        let said = request.outOfDate(agents: [.claude])
        #expect(said.contains { $0.contains("vibeswitcher-hook isn't installed") } && said.contains { $0.contains("vibeswitcher-mcp isn't installed") }, "\(said)")
        #expect(said.contains { $0.contains("lacks VibeSwitcher's hooks for claude") }, "\(said)")
        // A program that isn't the build's.
        try FileManager.default.createDirectory(atPath: home + "/.vibeswitcher/bin", withIntermediateDirectories: true)
        try Data("other".utf8).write(to: URL(fileURLWithPath: home + "/.vibeswitcher/bin/vibeswitcher-hook"))
        #expect(request.outOfDate(agents: []).contains { $0.contains("isn't this build's vibeswitcher-hook") })
    }
}
