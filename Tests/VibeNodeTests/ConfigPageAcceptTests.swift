import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A held-config card accepted from an acting page leaves what the terminal's accept of the same card leaves (the real
/// node, 2026-11-25: after a page's accept the guard rails read "not known to be the same", a card with nothing held was
/// drawn and shown as blocking, and the page was sent to the terminal a minute later).
@Suite(.timeLimit(.minutes(5)))
struct ConfigPageAcceptTests {
    private let scratch = Scratch()

    @Test(NodeTraits.linuxOnly) func aPageAcceptLeavesWhatATerminalAcceptLeaves() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.sleepingLead()
        let workflow = ConfigHoldStore.workflowPath(root: world.repo)
        try FileManager.default.createDirectory(atPath: (workflow as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "---\ntest_command: make check\nmax_workers: 2\n---\n".write(toFile: workflow, atomically: true, encoding: .utf8)
        let skill = world.host.home.path + "/.claude/skills/mine/SKILL.md"
        try FileManager.default.createDirectory(atPath: (skill as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        /// The card `config held` draws now (nil: none drawn), and what it shows.
        func held() async throws -> (id: String?, card: NodeWire.Value?) {
            let reply = try #require(await world.ask("config.held", ["folder": .string(world.repo)]))
            #expect(reply.ok, "\(reply)")
            return (reply.result?["card"]?["id"]?.string, reply.result?["card"])
        }
        func change(_ text: String) async throws {
            try "name: mine\n\(text)\n".write(toFile: skill, atomically: true, encoding: .utf8)
            let vault = world.host.vault, repo = world.repo
            _ = try await offPool { try vault.checkConfig(root: repo, shown: [:]) }
        }
        func rails(_ card: NodeWire.Value?) -> [String] {
            (card?["config"]?["guarded"]?.array ?? []).compactMap { $0["sinceAccept"]?.string }
        }

        // The terminal's accept: the first.
        try await change("one")
        let first = try #require(try await held().id)
        let terminal = try #require(await world.ask("config.accept", ["card": .string(first), "code": .string(NodeIds.code(card: first))]))
        #expect(terminal.ok, "\(terminal)")

        // An acting page at trust.
        let acting = ActingPages(vault: MemoryVaultV2().client)
        _ = try acting.set(level: "trust")
        let page = PageCredentials(token: "a-page", act: acting.confirmed(token: "a-page", tokenEnds: Date().addingTimeInterval(3_600)), origin: "127.0.0.1:8765")
        acting.settled()
        world.queue.sync { world.requests.actingPages = acting }
        func pageAccept(_ id: String) async throws -> NodeWire.Reply {
            let card = try #require(world.card(id))
            let got = Locked<NodeWire.Reply?>(nil)
            let request = NodeWire.Request(id: UUID().uuidString, kind: "config.accept", args: ["card": .string(id), "seen": .string(card.seen)],
                                           action: UUID().uuidString.lowercased())
            world.queue.async { world.requests.pageVoiced(request, credentials: page, origin: "http://127.0.0.1:8765") { got.value = $0 } }
            _ = await eventually(timeout: 120) { got.value != nil }
            return try #require(got.value)
        }

        // A held path appears; the page accepts its card.
        try await change("two")
        let second = try await held()
        let secondID = try #require(second.id)
        #expect(rails(second.card).allSatisfy { $0.hasPrefix("the same as at your last accept") }, "\(rails(second.card))")
        let accepted = try await pageAccept(secondID)
        #expect(accepted.ok, "\(accepted)")

        // The server's own write of a watched thing (a hooks update after a build switch), sealed by the vault as the
        // app's: the record moves on with nothing held and no accept.
        let (vault, home) = (world.host.vault, world.host.home.path)
        try await offPool {
            vault.appWrite([skill], home: home) { try? "name: mine\nthe app's\n".write(toFile: skill, atomically: true, encoding: .utf8) }
            vault.sealAppWrites()
        }

        // Then: no card with nothing held, the rails the same, nothing open.
        let after = try await held()
        #expect(rails(after.card).allSatisfy { $0.hasPrefix("the same as at your last accept") }, "\(rails(after.card))")
        // Shown (its rails), never kept: not open, not blocking, not among the cards.
        #expect(after.card?["open"]?.bool == false && after.card?["blocking"]?.bool == false && after.card?["closed"]?.string == "nothing to accept",
                "a card kept with nothing held: \(String(describing: after.card))")
        #expect(after.id.flatMap { world.card($0) } == nil)
        let open = world.queue.sync { world.engine.cards.list(project: world.project).filter { $0.kind == .configHeld } }
        #expect(open.isEmpty, "\(open.map(\.id))")

        // A second held path: the page may accept it too.
        try await change("three")
        let third = try await held()
        #expect(rails(third.card).allSatisfy { $0.hasPrefix("the same as at your last accept") }, "\(rails(third.card))")
        let again = try await pageAccept(try #require(third.id))
        #expect(again.ok, "\(again)")
    }

    /// A card with nothing held is never a hold: not blocking; and when the vault's first look is owed (a host restart,
    /// no sealed last accept), it says so in one line.
    @Test func aCardWithNothingHeldHoldsNothingUp() {
        var card = CardStore.Card(root: scratch.url("repo").path, kind: .configHeld)
        card.config = .init()
        #expect(!card.isBlocking)
        card.config?.firstLook = true
        #expect(!card.isBlocking)
        let lines = CardText.lines(card.value, long: false)
        #expect(lines.contains { $0.contains("the node restarted") } && !lines.contains { $0.contains("held (no worker") }, "\(lines)")
        card.config?.items = [.init(name: "~/.claude/skills", changedAt: nil, size: nil, hash: "abc", change: nil, outside: false, files: [], sinceAccept: nil)]
        #expect(card.isBlocking)
    }
}
