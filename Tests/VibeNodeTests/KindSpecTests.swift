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

    /// Who may send a kind and what it does are two fields, so a row could join them badly: one anyone or a page may
    /// read that changes state, a page's draft or terminal that doesn't, a user's read that slips in unasked. Each
    /// sender holds its effect here, and the user's reads are a frozen list (`start` the one recorded: the user's
    /// recorded start of a node, which changes nothing on a running one).
    @Test func eachSendersEffectIsItsOwn() {
        for spec in KindSpec.all {
            switch spec.sender {
            case .anyone, .webRead: #expect(spec.effect == .read, "\(spec.name): \(spec.sender) may send it, so it changes nothing")
            case .webDraft, .webTerminal: #expect(spec.effect == .change, "\(spec.name)")
            case .leadToolServer: #expect(spec.effect == .toolPost, "\(spec.name)")
            case .user: break
            }
        }
        let usersReads = KindSpec.all.filter { $0.sender == .user && $0.effect != .change }
        #expect(usersReads.map(\.name).sorted() == ["approve.list", "base.show", "config.held", "plugin.inspect", "shells", "start", "update.check"],
                "a user's-voice read added or gone: \(usersReads.map(\.name).sorted())")
        for spec in usersReads { #expect(spec.effect == .read && (spec.recorded == nil) == (spec.name != "start"), "\(spec.name)") }
        for spec in KindSpec.all where spec.effect == .toolPost { #expect(spec.sender == .leadToolServer, "\(spec.name)") }
    }

    /// The typed kinds the command line asks and sends are the table's.
    @Test func theTypedListsAreTheTables() {
        #expect(Set(WireKinds.typed) == Set(KindSpec.all.compactMap { spec in spec.typed.flatMap { $0 is any WireChangeKind.Type ? nil : spec.name } }))
        for spec in KindSpec.all { if let type = spec.typed { #expect(type.kind == spec.name, "\(spec.name) is typed as \(type.kind)") } }
        #expect(WireKinds.leftOut == ["plugin.inspect", "plugin.add", "plugin.remove", "plugin.file"])
    }
}

/// One decision of where a request goes, for both transports (`Principal.route`), resolved from the peer once: a page's
/// refusals and `hello.kinds` are as before (KindSpecTests' frozen lists), and every kind routes as the per-transport
/// checks it replaced did.
struct PrincipalTests {
    static let anyFacts = PeerFacts(pid: 1, uid: nil, cgroup: nil, ancestry: nil, terminal: .none, sessionMarker: nil, underRunner: nil)

    /// On the socket: an `anyone` kind is read (or the hub's), a user's-voice kind and a private record's read are
    /// the user's voice, the tool server's post its own, a draft refused, a terminal's not taken, and nothing else taken.
    @Test func aProcessRoutesEachKindByItsSender() {
        let process = Principal.process(Self.anyFacts)
        for spec in KindSpec.all {
            let route = process.route(spec.name)
            switch spec.sender {
            case .anyone: #expect(route == (LiveHub.kinds.contains(spec.name) ? .hub : .read), "\(spec.name)")
            case .user, .webRead: #expect(route == .usersVoice, "\(spec.name)")
            case .leadToolServer: #expect(route == .toolPost, "\(spec.name)")
            case .webDraft: if case .refused(.voice, _) = route {} else { Issue.record("\(spec.name): \(route)") }
            case .webTerminal: #expect(route == .unknown, "\(spec.name)")
            }
            #expect((route != .unknown) == NodeWire.taken.contains(spec.name), "\(spec.name): \(route)")
        }
        #expect(process.route("no.such.kind") == .unknown)
    }

    /// A page: never the user's voice or the tool server's, each right what it admits, a terminal's only on a server
    /// that opens them and with `read`, `plugin.file` never.
    @Test func aPageRoutesEachKindByItsRights() {
        for rights: LiveRights in [[], .read, .draft, [.read, .draft]] {
            for terminals in [false, true] {
                let page = Principal.page(rights, terminals: terminals)
                for spec in KindSpec.all {
                    let route = page.route(spec.name)
                    #expect(route != .usersVoice && route != .toolPost, "\(spec.name)")
                    switch route {
                    case .read, .hub, .privateRead: #expect(rights.contains(.read) && spec.name != "plugin.file", "\(spec.name)")
                    case .draft: #expect(rights.contains(.draft) && spec.sender == .webDraft, "\(spec.name)")
                    case .terminal: #expect(terminals && rights.contains(.read) && spec.sender == .webTerminal, "\(spec.name)")
                    case .unknown: #expect(spec.sender == .webTerminal && !terminals, "\(spec.name)")
                    case .refused, .usersVoice, .toolPost: break
                    }
                }
                let terminal = terminals && rights.contains(.read) ? NodeLive.terminalKinds : []
                #expect(page.kinds == WebAccess.kinds(for: rights) + terminal)
            }
        }
    }
}
