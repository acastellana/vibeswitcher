import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// One table of request kinds (`KindSpec`, the architecture review's row 1), the server's lists its views: every view
/// is what the server ran on before the table (Tests/Fixtures/kind-tables.json, frozen from the lists it replaced:
/// who may send each kind, which change state, which this server takes, the hub's and the terminal's, which are
/// recorded and carded, their retry rules, their arguments, the approval dialog's arguments and phrases, a page's
/// `hello.kinds` for each right), so nothing about who may send what changed.
struct KindSpecTests {
    static let frozen: [String: Any] = {
        let url = ServerLintTests.repo.appendingPathComponent("Tests/Fixtures/kind-tables.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
    }()

    static func strings(_ key: String) -> [String] { frozen[key] as? [String] ?? [] }
    static func map<T>(_ key: String) -> [String: T] { frozen[key] as? [String: T] ?? [:] }

    @Test func theTableIsOneEntryAKind() {
        #expect(KindSpec.all.count == KindSpec.byName.count, "a kind twice")
        #expect(!Self.frozen.isEmpty)
    }

    @Test func whoMaySendEachKindIsAsBefore() {
        let voices: [String: String] = Self.map("voices")
        #expect(NodeWire.kinds.mapValues { "\($0)" } == voices, "\(NodeWire.kinds.mapValues { "\($0)" }.filter { voices[$0.key] != $0.value })")
        #expect(NodeWire.taken == Self.strings("taken"))
        #expect(LiveHub.kinds.sorted() == Self.strings("hub"))
        #expect(NodeLive.terminalKinds == Self.strings("terminal"))
    }

    @Test func whichKindsChangeStateIsAsBefore() {
        let changes: [String: Bool] = Self.map("changesState")
        for (kind, expected) in changes { #expect(NodeWire.changesState(kind) == expected, "\(kind)") }
        #expect(NodeWire.changesNothing.sorted() == Self.strings("changesNothing"))
    }

    @Test func aPagesKindsForEachRightAreAsBefore() {
        #expect(WebAccess.kinds(for: .read) == Self.strings("webKindsRead"))
        #expect(WebAccess.kinds(for: .draft) == Self.strings("webKindsDraft"))
        #expect(WebAccess.kinds(for: [.read, .draft]) == Self.strings("webKindsBoth"))
        #expect(WebAccess.kinds(for: []) == Self.strings("webKindsNone"))
    }

    @Test func recordedCardedRetriedAndArgumentsAreAsBefore() {
        #expect(Requests.recorded.sorted() == Self.strings("recorded"))
        #expect(Requests.carded.sorted() == Self.strings("carded"))
        let rules: [String: [String: Bool]] = Self.map("retryRules")
        #expect(Requests.retryRules.mapValues { ["keepsResult": $0.keepsResult, "rerun": $0.rerun] } == rules)
        let arguments: [String: [String]] = Self.map("arguments")
        #expect(RequestArguments.taken.mapValues { $0.sorted() } == arguments)
    }

    @Test func theApprovalDialogsAreAsBefore() {
        let arguments: [String: [String]] = Self.map("approvalArguments")
        #expect(Requests.approvalArguments.mapValues { $0.sorted() } == arguments)
        let phrases: [String: String] = Self.map("approvalPhrases")
        for (kind, phrase) in phrases { #expect(ApprovalVoice.action(kind) == phrase, "\(kind)") }
    }

    /// The typed kinds the command line asks and sends are the table's.
    @Test func theTypedListsAreTheTables() {
        #expect(Set(WireKinds.typed) == Set(KindSpec.all.compactMap { spec in spec.typed.flatMap { $0 is any WireChangeKind.Type ? nil : spec.name } }))
        for spec in KindSpec.all { if let type = spec.typed { #expect(type.kind == spec.name, "\(spec.name) is typed as \(type.kind)") } }
        #expect(WireKinds.leftOut == ["plugin.inspect", "plugin.add", "plugin.remove", "plugin.file"])
    }
}
