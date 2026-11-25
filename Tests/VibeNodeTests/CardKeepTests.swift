import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The open cards across a server restart or a switch (`CardKeep`, 2026-11-24): every kind written whole and read back
/// the same, taken back only while the vault keeps the digest of the very bytes (the file, or the partial one a crash
/// left between the vault and the rename), and nothing of a file the vault doesn't vouch for.
@Suite(.timeLimit(.minutes(5)))
struct CardKeepTests {
    private let scratch = Scratch()

    /// One open card of each kind but a plugin's, as the engine draws them: a question with a revision and a page's
    /// draft, an approval with its facts, held config, a base move.
    static func cards(root: String) -> [CardStore.Card] {
        var question = CardStore.Card(root: root, kind: .question, at: Date(timeIntervalSince1970: 1_790_000_000.25))
        var asked = LeadQuestion(text: "Name the parser?", options: ["Parser", "Reader"], priority: .blocking)
        asked.revisions = [.init(text: "Name it?", options: ["A"], note: "clearer", at: 1_790_000_001)]
        question.question = asked
        question.draft = .init(text: "Parser, and keep the old name as an alias", version: asked.version, at: Date(timeIntervalSince1970: 1_790_000_002.5),
                               action: UUID().uuidString.lowercased())
        var approval = CardStore.Card(root: root, kind: .approval)
        approval.question = LeadQuestion(text: "Merge it?", options: ["Approve " + String(repeating: "c", count: 40), "Not yet"])
        approval.approval = .init(commit: String(repeating: "c", count: 40), tasks: ["write-the-parser"], base: "main", files: ["Parser.swift"],
                                  diffstat: "1 file changed", subject: "Parser")
        var config = CardStore.Card(root: root, kind: .configHeld)
        config.config = ConfigHoldStore.Shown(items: [.init(name: ".claude/settings.json", changedAt: Date(timeIntervalSince1970: 1_790_000_003), size: 20,
                                                            hash: "0123456789ab", change: "env.A added", outside: true)],
                                              hashes: ["settings:.claude/settings.json": String(repeating: "d", count: 64)], baseBranch: "main",
                                              guarded: [.init(key: "test_command", value: "swift test", sinceAccept: "changed")])
        var base = CardStore.Card(root: root, kind: .baseMove)
        base.base = BaseMoveStore.Shown(branch: "main", from: String(repeating: "e", count: 40), fromIs: .recorded, to: String(repeating: "f", count: 40),
                                        commits: [.init(sha: String(repeating: "f", count: 40), subject: "moved")], reason: "not from a team session")
        return [question, approval, config, base]
    }

    @Test func everyKindReadsBackTheSame() throws {
        let file = CardKeep.File(cards: Self.cards(root: "/repo"))
        let bytes = CardKeep.encoded(file)
        let read = try JSONDecoder().decode(CardKeep.File.self, from: bytes)
        #expect(read == file)
        #expect(read.cards.map(\.code) == file.cards.map(\.code) && read.cards[0].question?.version == 2 && read.cards[0].draft != nil)
        #expect(CardKeep.encoded(read) == bytes, "the same bytes again: a look that changed nothing writes nothing")
    }

    /// A card's code isn't kept: it is its id's (a digest of it, which anyone who lists the cards can work out), made
    /// again as the file is read; a code written into the file is never taken.
    @Test func theFileKeepsNoCodeAndACodeInItIsNeverTaken() throws {
        let cards = Self.cards(root: "/repo")
        let bytes = CardKeep.encoded(.init(cards: cards))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("\"code\""), "\(String(decoding: bytes, as: UTF8.self).prefix(300))")
        var object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var listed = try #require(object["cards"] as? [[String: Any]])
        listed[0]["code"] = "ZZZZ"
        object["cards"] = listed
        let read = try JSONDecoder().decode(CardKeep.File.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(read.cards[0].code == NodeIds.code(card: cards[0].id) && read.cards[0].code != "ZZZZ")
    }

    /// A restored card's right code from any sender but the user's terminal (here the lead's tool server, a session's
    /// process) is refused by the voice rule before the code is looked at: nothing answered.
    @Test(NodeTraits.linuxOnly) func aRestoredCardsCodeFromAnotherSenderAnswersNothing() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let card = try await world.asked("Approve the merge?", options: ["Yes", "No"], lead: lead).card
        let reply = try #require(await world.answer(card, "Yes", code: card.code, from: CardWorld.toolServer(of: lead)))
        #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
        #expect(world.card(card.id)?.isOpen == true)
    }

    @Test func onlyTheBytesTheVaultVouchesForAreTaken() throws {
        let cards = Self.cards(root: "/repo")
        let good = CardKeep.encoded(.init(cards: cards))
        let other = CardKeep.encoded(.init(cards: Array(cards.prefix(1))))
        let digest = BuildInfo.sha256(of: good)
        #expect(try CardKeep.taken(file: good, partial: nil, vouched: digest).get() == cards)
        // A crash between the vault and the rename: the partial file is the vouched one.
        #expect(try CardKeep.taken(file: other, partial: good, vouched: digest).get() == cards)
        #expect(CardKeep.taken(file: other, partial: nil, vouched: digest).failure?.description.contains("aren't the ones the vault keeps") == true)
        #expect(CardKeep.taken(file: good, partial: nil, vouched: nil).failure?.description.contains("keeps no digest") == true)
        #expect(try CardKeep.taken(file: nil, partial: nil, vouched: digest).get().isEmpty)
        // Vouched bytes of another format aren't read.
        let unknown = Data(#"{"format":2,"cards":[]}"#.utf8)
        #expect(CardKeep.taken(file: unknown, partial: nil, vouched: BuildInfo.sha256(of: unknown)).failure?.description.contains("format 1") == true)
    }

    @Test func theVaultKeepsOneDigestAndOnlyAHexOne() {
        var book: LeadVaultV2.Book? = nil
        let digest = String(repeating: "a", count: 64)
        #expect(LeadVaultV2.answer(.keptCards, from: .app, book: &book, on: true) == .cards(nil))
        #expect(LeadVaultV2.answer(.keepCards(digest: digest), from: .app, book: &book, on: true) == .ok)
        #expect(LeadVaultV2.answer(.keptCards, from: .app, book: &book, on: true) == .cards(digest))
        #expect(LeadVaultV2.answer(.keepCards(digest: "../" + String(repeating: "a", count: 61)), from: .app, book: &book, on: true)
            == .refused("A cards digest is 64 lower-case hex digits."))
        #expect(LeadVaultV2.answer(.keepCards(digest: String(repeating: "A", count: 64)), from: .app, book: &book, on: true) != .ok)
        #expect(LeadVaultV2.answer(.keptCards, from: .app, book: &book, on: true) == .cards(digest))
        // Only the server (the app's caller) sets it: a session can't vouch for a file it wrote.
        if case .refused = LeadVaultV2.answer(.keepCards(digest: String(repeating: "b", count: 64)), from: .session("x"), book: &book, on: true) {} else {
            Issue.record("a session set the cards digest")
        }
        #expect(LeadVaultV2.answer(.keepCards(digest: nil), from: .app, book: &book, on: true) == .ok)
        #expect(LeadVaultV2.answer(.keptCards, from: .app, book: &book, on: true) == .cards(nil))
    }

    /// Against an engine on a scratch host: the open cards written as they change (the vault keeping the file's digest),
    /// then, as a server after a restart finds them, taken back whole with the same ids, codes and draft; the approval's
    /// facts built again. A file rewritten after its digest was kept is taken back not at all.
    @Test(NodeTraits.linuxOnly) func theOpenCardsComeBackWholeFromAVouchedFile() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let engine = world.engine
        try #require(await eventually(timeout: 60) { world.queue.sync { engine.cardKeep.saving } })
        let cards = Self.cards(root: world.repo)
        world.queue.sync { for card in cards { engine.cards.put(card) } }
        let url = CardKeep.url(root: engine.root)
        let written = { (try? JSONDecoder().decode(CardKeep.File.self, from: Data(contentsOf: url)))?.cards.map(\.id) ?? [] }
        try #require(await eventually(timeout: 60) { Set(written()) == Set(cards.map(\.id)) }, "\(written())")
        let kept = try #require(try world.world.link.vaultV2.keptCards())
        #expect(kept == BuildInfo.sha256(of: try Data(contentsOf: url)))
        var info = stat()
        #expect(stat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)

        // As the next server: an empty store, the file taken back.
        await restore(engine, world, removing: cards)
        for card in cards {
            let back = try #require(world.card(card.id), "\(card.kind) not taken back")
            #expect(back.code == card.code && back.question == card.question && back.draft == card.draft && back.config == card.config
                    && back.base == card.base, "\(back)")
        }
        // The approval's facts are built again from git (this commit isn't in the repository: said on the card).
        #expect(await eventually(timeout: 60) { world.card(cards[1].id)?.approval?.problems.isEmpty == false }, "\(String(describing: world.card(cards[1].id)))")

        // A file rewritten under the kept digest (after every write the engine queued): nothing taken back.
        await restore(engine, world, removing: cards) {
            guard let bytes = try? Data(contentsOf: url) else { return }
            try? Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Name the parser?", with: "Approve it?").utf8).write(to: url)
        }
        #expect(world.queue.sync { engine.cards.list() }.isEmpty)
    }

    /// The engine as a fresh server finds it: writes off, `removing` gone from memory, then (after every write already
    /// queued) `file`, then `restoreCards`, waited for.
    private func restore(_ engine: LeadEngine, _ world: CardWorld, removing: [CardStore.Card], file: (() -> Void)? = nil) async {
        let done = Locked(false)
        world.queue.async {
            engine.cardKeep.saving = false
            engine.cardKeepWatch = nil
            for card in removing { engine.cards.remove(card.id) }
            engine.cardKeep.writes.async {
                file?()
                world.queue.async { engine.restoreCards { done.value = true } }
            }
        }
        _ = await eventually(timeout: 60) { done.value }
    }
}
