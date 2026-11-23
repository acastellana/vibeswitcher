import Foundation
import Testing
@testable import VibeNode

/// One path for authority (the architecture review's row 1): every kind is one entry of `KindSpec`, whose views (who may
/// send it, whether it changes state, which server takes it, what serves it, whether it is recorded and carded, its
/// retry, its arguments, its dialog) can't disagree, and KindSpecTests holds them to what the server ran on before. What
/// a type can't guarantee is checked here: that the right kinds are recorded and carded, the retry rules' policy, a
/// recorded kind typed by a type that takes keys, and that each kind's handler exists (the `act` switch, the hub's) and
/// nothing else is handled.
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
        // Those whose result carries a secret (web.open's pairing link, a plugin page's address with its token) keep none.
        for kind in ["web.open", "answer", "approve", "set"] { #expect(Requests.retryRules[kind]?.keepsResult == false, "\(kind) keeps its result") }
        // Never done again: stopping the node, a card's act (its card is gone after a restart), anything that types or starts.
        for kind in ["stop", "answer", "hold", "config.accept", "base.accept", "base.keep", "send", "tell", "session.reply", "session.new", "lead", "approve"] {
            #expect(Requests.retryRules[kind]?.rerun == false, "\(kind) is done again")
        }
    }

    /// A recorded kind's keys come from its type when it is typed: one whose type isn't a state change's (its keys would
    /// be none) can't be so declared.
    @Test func aRecordedKindTypedByItsArgumentsHasAStateChangesType() {
        for spec in KindSpec.all {
            guard case .ofType = spec.recorded?.arguments else { continue }
            #expect(spec.typed is any WireChangeKind.Type, "\(spec.name) takes its type's keys but has no state change's type")
        }
    }

    /// A kind on a card (its code checked) is the user's voice, and an item of `approve`'s batch is a carded accept or
    /// the hooks' install: nothing a batch's one code shouldn't cover.
    @Test func cardedAndBatchKindsAreTheUsers() {
        #expect(Requests.carded.isSubset(of: Self.kinds(.user)))
        let batch = Set(KindSpec.all.filter { $0.recorded?.batch == true }.map(\.name))
        #expect(batch == ["config.accept", "base.accept", "hooks.install"], "\(batch.sorted())")
    }

    /// Every kind the server takes has its handler, and every handler's kind is taken: the `act` switch's, the hub's,
    /// the lead's tool server's (`questionPost`) and a page's drafts (`draft`, never `act`).
    @Test func everyTakenKindHasAHandlerAndTheReverse() throws {
        let act = try Self.cases(of: "private func act(_ request: NodeWire.Request", in: "Sources/VibeNode/Server/Requests.swift")
        #expect(act.count > 40, "the act switch wasn't found: \(act.sorted())")
        let handled = act.union(LiveHub.kinds).union(Self.kinds(.leadToolServer)).union(Self.kinds(.webDraft))
        let taken = Set(NodeWire.taken)
        #expect(taken == handled, "taken with no handler: \(taken.subtracting(handled).sorted()); handled, not taken: \(handled.subtracting(taken).sorted())")
        #expect(act.isDisjoint(with: LiveHub.kinds), "\(act.intersection(LiveHub.kinds).sorted()) is both the hub's and act's")
        #expect(act.isDisjoint(with: Self.kinds(.webDraft)), "a draft reaches act: \(act.intersection(Self.kinds(.webDraft)).sorted())")
        #expect(act.isDisjoint(with: Self.kinds(.leadToolServer)))
        // A page's private reads (`webRead`) have a switch of their own; on the socket they reach `act`.
        let webRead = try Self.cases(of: "func webRead(_ request: NodeWire.Request", in: "Sources/VibeNode/Server/MailRequest.swift")
        #expect(webRead == Self.kinds(.webRead), "\(webRead.symmetricDifference(Self.kinds(.webRead)).sorted())")
        #expect(webRead.isSubset(of: act))
        // The terminal's kinds are the terminal relay's (a page's terminal), and only theirs.
        #expect(Set(NodeLive.terminalKinds) == Self.kinds(.webTerminal))
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
