import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A card too large for a snapshot's part, read in parts (the no-terminal inventory's C7): `questions` with `card` and
/// `part` gives the bytes `questions` with `card` alone gives whole, cut into parts of at most `Requests.cardPartBytes`,
/// at most `Requests.mostCardParts` of them; each part names the card and the version (the SHA-256 of all its bytes) it
/// is of, and a part asked with a version that is no longer the card's is `changed`. Nothing a part carries is more
/// than the whole card's read. Not `linuxOnly`: the Mac runs it.
struct CardPartsTests {
    static let id = "local:card:5b1f0c3e-8a2d-4e6f-b7c9-1d0a2f3e4b5c"

    /// A question card's value with `size` bytes of question (a lead's long question, with characters that take more than
    /// one byte and some the wire escapes).
    static func card(question size: Int, draft: String? = nil) -> NodeWire.Value {
        let unit = "Ünïcode “quotes” and \\ slashes\n"
        let text = String(repeating: unit, count: size / unit.utf8.count + 1)
        var fields: [String: NodeWire.Value] = ["id": .string(id), "kind": .string("question"), "project": .string("local:project:x"),
                                                "root": .string("/home/dev/projects/example"), "open": .bool(true),
                                                "question": .object(["text": .string(text), "version": .int(1)])]
        if let draft { fields["draft"] = .object(["text": .string(draft)]) }
        return .object(fields)
    }

    private func part(_ value: NodeWire.Value?, _ index: Int, version: String? = nil, id: String = CardPartsTests.id) -> Result<WireKinds.Questions.CardPart, Requests.ReadRefusal> {
        Requests.cardPart(value, id: id, part: index, version: version)
    }

    /// Every part read in turn and joined is the card whole, as `questions` with `card` alone writes it in its reply:
    /// byte for byte, nothing more. Each part's bytes are at most `cardPartBytes`, its reply under a snapshot's part.
    @Test func thePartsJoinedAreTheWholeCardsBytesEachBounded() throws {
        let value = Self.card(question: 700_000)
        let whole = Data(NodeWire.line(value).dropLast())
        let first = try part(value, 0).get()
        #expect(first.card == Self.id && first.bytes == whole.count && first.version == BuildInfo.sha256(of: whole))
        #expect(first.parts == (whole.count + Requests.cardPartBytes - 1) / Requests.cardPartBytes && (first.parts ?? 0) > 1)
        var joined = Data()
        for index in 0..<(first.parts ?? 0) {
            let piece = try part(value, index, version: first.version).get()
            #expect(piece.card == Self.id && piece.version == first.version && piece.part == index && piece.parts == first.parts)
            let bytes = try #require(Data(base64Encoded: piece.data ?? ""))
            #expect(bytes.count <= Requests.cardPartBytes && (index == first.parts! - 1 || bytes.count == Requests.cardPartBytes))
            let reply = NodeWire.replyLine(NodeWire.Reply(re: "1", typed: WireKinds.Questions.Result(part: piece)))
            #expect(reply.count < NodeWire.partBytes, "part \(index): \(reply.count) bytes")
            joined += bytes
        }
        #expect(joined == whole)
        // The whole card's read writes those very bytes as its card.
        let read = String(decoding: NodeWire.line(WireKinds.Questions.Result(cards: [value], more: 0)), as: UTF8.self)
        #expect(read.contains(String(decoding: joined, as: UTF8.self)))
        #expect(try JSONDecoder().decode(NodeWire.Value.self, from: joined) == value)
    }

    /// A small card is one part; the part count is bounded: past `mostCardParts` parts it is refused, nothing given.
    @Test func thePartCountIsBounded() throws {
        let small = try part(Self.card(question: 100), 0).get()
        #expect(small.parts == 1 && small.part == 0)
        let limit = Requests.cardPartBytes * Requests.mostCardParts
        guard case .failure(let past) = part(Self.card(question: limit), 0) else { Issue.record("given"); return }
        #expect(past.code == NodeWire.Code.refused.rawValue && past.message.contains("more than \(Requests.mostCardParts) parts"), "\(past)")
        let value = Self.card(question: 300_000)
        let first = try part(value, 0).get()
        for (index, version) in [(first.parts ?? 0, first.version), (-1, first.version)] {
            guard case .failure(let failure) = part(value, index, version: version) else { Issue.record("part \(index) given"); continue }
            #expect(failure.code == NodeWire.Code.badArgs.rawValue, "\(index): \(failure)")
        }
    }

    /// Parts aren't mixed: a part after the first needs the version the first gave; a card that changed meanwhile (a
    /// draft left, a question revised) is `changed`, nothing of the new version given against the old; another card's id,
    /// or one the node doesn't hold, is `gone`.
    @Test func aCardThatChangedWhileBeingReadIsChanged() throws {
        let before = Self.card(question: 300_000)
        let first = try part(before, 0).get()
        guard case .failure(let unversioned) = part(before, 1) else { Issue.record("given"); return }
        #expect(unversioned.code == NodeWire.Code.badArgs.rawValue && unversioned.message.contains("needs the version"), "\(unversioned)")
        let after = Self.card(question: 300_000, draft: "Use the staging database")
        guard case .failure(let changed) = part(after, 1, version: first.version) else { Issue.record("given"); return }
        #expect(changed.code == NodeWire.Code.changed.rawValue && changed.message.contains("changed while it was being read"), "\(changed)")
        // Read again from its first part: the new version, whole.
        let again = try part(after, 0).get()
        #expect(again.version != first.version && again.bytes == Data(NodeWire.line(after).dropLast()).count)
        guard case .failure(let gone) = part(nil, 0, id: "local:card:00000000") else { Issue.record("given"); return }
        #expect(gone.code == NodeWire.Code.gone.rawValue, "\(gone)")
    }

    /// On the wire: `part` and `version` are typed arguments (a wrong form is `bad-args`); a part's result is `part`
    /// alone, and a list's result is as it was (the captured replies keep their bytes: `WireKindsTests`).
    @Test func theWireAddsPartAndVersion() throws {
        let wrong = NodeWire.Request(id: "1", kind: "questions", args: ["card": .string(Self.id), "part": .string("first")])
        guard case .failure(let failure) = wrong.typedArgs(WireKinds.Questions.Args.self) else { Issue.record("taken"); return }
        #expect(failure.code == "bad-args" && failure.message.contains("part"), "\(failure)")
        let asked = NodeWire.Request(id: "2", kind: "questions", args: ["card": .string(Self.id), "part": .int(1), "version": .string("abc")])
        #expect(asked.typedArgs(WireKinds.Questions.Args.self).taken == .init(card: Self.id, part: 1, version: "abc"))
        let piece = WireKinds.Questions.CardPart(card: Self.id, version: "v", part: 0, parts: 2, bytes: 5, data: "aGVsbG8=")
        let text = String(decoding: NodeWire.line(WireKinds.Questions.Result(part: piece)), as: UTF8.self)
        #expect(text == #"{"part":{"bytes":5,"card":"\#(Self.id)","data":"aGVsbG8=","part":0,"parts":2,"version":"v"}}"# + "\n", "\(text)")
        // The same sender rule as every card read: `questions` is anyone's read, a page's with its read right.
        #expect(KindSpec.spec("questions")?.sender == .anyone && KindSpec.spec("questions")?.effect == .read)
        #expect(WebAccess.refusal(for: asked, rights: [.read]) == nil)
        #expect(WebAccess.refusal(for: asked, rights: [])?.error?.code == NodeWire.Code.voice.rawValue)
    }
}
