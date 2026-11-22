import Foundation
import Testing
@testable import VibeNode

/// One path for authority (the architecture review's row 1, 2026-11-22): a request kind is still declared in several
/// lists (`NodeWire.kinds`, `changesNothing`, `taken`, `Requests.recorded`, `carded`, the `act` switch, the hub's), and
/// `recorded` and `carded` are opt-in, so a state-changing kind left out of `recorded` would act without the vault's
/// record. These checks hold the lists to one another until one table replaces them.
@Suite struct RequestKindsLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func kinds(_ voice: NodeWire.Voice) -> Set<String> { Set(NodeWire.kinds.filter { $0.value == voice }.keys) }

    /// Every user's-voice kind that changes state is recorded in the vault before it acts, and nothing else is, but
    /// `start` (it changes nothing on a running node, and is the user's recorded start of one).
    @Test func recordedIsEveryStateChangingUsersVoiceKind() {
        let expected = Self.kinds(.user).subtracting(NodeWire.changesNothing).union(["start"])
        #expect(Requests.recorded == expected,
                "missing from recorded: \(expected.subtracting(Requests.recorded).sorted()); not the user's state change: \(Requests.recorded.subtracting(expected).sorted())")
        for kind in Requests.recorded { #expect(NodeWire.taken.contains(kind), "\(kind) is recorded but not taken") }
    }

    /// A kind on a card (its code checked) is recorded too: a card's answer never acts unrecorded.
    @Test func everyCardedKindIsRecorded() {
        #expect(Requests.carded.isSubset(of: Requests.recorded), "\(Requests.carded.subtracting(Requests.recorded).sorted())")
        #expect(Requests.carded.isSubset(of: Self.kinds(.user)))
    }

    /// `changesNothing` names user's-voice kinds only (one of another voice there would mean nothing).
    @Test func changesNothingIsUsersVoiceKindsOnly() {
        #expect(NodeWire.changesNothing.isSubset(of: Self.kinds(.user)), "\(NodeWire.changesNothing.subtracting(Self.kinds(.user)).sorted())")
    }

    /// Every kind the server takes has its handler, and every handler's kind is taken: the `act` switch's, the hub's,
    /// the lead's tool server's (`questionPost`) and a page's drafts (`draft`, never `act`).
    @Test func everyTakenKindHasAHandlerAndTheReverse() throws {
        let act = try Self.cases(of: "private func act(_ request: NodeWire.Request", in: "Sources/VibeNode/Server/Requests.swift")
        #expect(act.count > 40, "the act switch wasn't found: \(act.sorted())")
        let handled = act.union(LiveHub.kinds).union(Self.kinds(.leadToolServer)).union(Self.kinds(.webDraft))
        let taken = Set(NodeWire.taken)
        #expect(taken.count == NodeWire.taken.count, "taken names a kind twice")
        #expect(taken == handled, "taken with no handler: \(taken.subtracting(handled).sorted()); handled, not taken: \(handled.subtracting(taken).sorted())")
        #expect(act.isDisjoint(with: LiveHub.kinds), "\(act.intersection(LiveHub.kinds).sorted()) is both the hub's and act's")
        #expect(act.isDisjoint(with: Self.kinds(.webDraft)), "a draft reaches act: \(act.intersection(Self.kinds(.webDraft)).sorted())")
        #expect(act.isDisjoint(with: Self.kinds(.leadToolServer)))
        // A page's private reads (`webRead`) have a switch of their own; on the socket they reach `act`.
        let webRead = try Self.cases(of: "func webRead(_ request: NodeWire.Request", in: "Sources/VibeNode/Server/MailRequest.swift")
        #expect(webRead == Self.kinds(.webRead), "\(webRead.symmetricDifference(Self.kinds(.webRead)).sorted())")
        #expect(webRead.isSubset(of: act))
        // The terminal's kinds: a page's on a server with terminals, never the socket's (`taken`).
        #expect(Set(NodeLive.terminalKinds) == Self.kinds(.webTerminal) && taken.isDisjoint(with: NodeLive.terminalKinds))
    }

    /// The hub takes exactly `LiveHub.kinds` (the list the Unix socket hands it), and on a server with no terminals
    /// nothing else.
    @Test func theHubTakesExactlyItsKinds() {
        let world = LiveWorld()
        for kind in Set(NodeWire.kinds.keys).union(["no.such.kind"]).sorted() {
            let took = world.queue.sync { world.hub.handle(NodeWire.Request(id: "1", kind: kind), on: Recorder(), rights: .read) }
            #expect(took == LiveHub.kinds.contains(kind), "\(kind)")
        }
    }

    /// The reader of a switch's labels finds each form the `act` switch uses, and stops at its `default:`.
    @Test func theSwitchReaderFindsEveryLabel() throws {
        let fixture = """
        func other() { switch x { case "not.this": break } }
        private func act(_ request: Request) {
            switch request.kind {
            case "status": status()
            case "push", "push.decline": push()
            case "term.open" where terminals != nil: open()
                if request.kind == "inside" { }
            default: reply("this server doesn't take it")
            case "after.default": never()
            }
        }
        """
        #expect(try Self.cases(of: "private func act(", text: fixture) == ["status", "push", "push.decline", "term.open"])
    }

    /// The labels of the first `switch` after `function` (from its `case "…"` lines to its `default:`).
    static func cases(of function: String, in path: String) throws -> Set<String> {
        try cases(of: function, text: String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8))
    }

    static func cases(of function: String, text: String) throws -> Set<String> {
        guard let start = text.range(of: function) else { throw Missing(function: function) }
        let label = try Regex(#"^\s*case ((?:"[^"]+"(?:,\s*)?)+)(?:\s+where [^:]+)?:"#)
        let quoted = try Regex(#""([^"]+)""#)
        var found: Set<String> = []
        for line in text[start.upperBound...].split(separator: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("default:") { break }
            guard let match = try label.firstMatch(in: String(line)), let labels = match.output[1].substring else { continue }
            for name in labels.matches(of: quoted) { if let name = name.output[1].substring { found.insert(String(name)) } }
        }
        return found
    }

    struct Missing: Error { var function: String }
}
