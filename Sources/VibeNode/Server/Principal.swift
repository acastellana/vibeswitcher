import Foundation
import VibeCore

/// What the peer of a connection is, resolved once when it connects (the architecture review's row 1), and the one
/// decision of where each of its requests goes (`route`), made from the kinds' table (`KindSpec`): the Unix socket's
/// server (`NodeServer`), its requests (`Requests.handle`), a page's screen (`WebRequestScreen`, `WebAccess.refusal`) and
/// the hub's hand-off of a page's requests (`NodeLive`) ask it, instead of each judging a kind's voice its own way.
///
/// A process's user's voice isn't resolved here: the rule judges the sender as it is when it asks (its ancestry, its
/// terminal, read again; Touch ID for a state change on the Mac), so `route` says only that a kind needs it
/// (`usersVoice`), and `Requests` judges it then.
public enum Principal: Sendable, Equatable {
    /// A process on the node's Unix socket, as read at its accept: its `anyone` reads are taken as that process (every
    /// read's sender is checked against it, `NodeServer`).
    case process(PeerFacts)
    /// A web page, with its token's rights; `terminals`: this server opens a page's terminals (LW-D12).
    case page(LiveRights, terminals: Bool)

    /// Where a request of a kind goes, or why it goes nowhere.
    public enum Route: Sendable, Equatable {
        /// A kind this server doesn't take from this peer: answered as an unknown kind.
        case unknown
        /// Refused, with its code and why.
        case refused(NodeWire.Code, String)
        /// The live hub's.
        case hub
        /// A page's terminal (the hub's relay).
        case terminal
        /// A read anyone may ask: `Requests.act`, no voice.
        case read
        /// The user's voice, judged when it is asked (`Voice.judge`, or the Mac's dialog), then `Requests.voiced`.
        case usersVoice
        /// The lead's tool server's post, its host's seal checked (`questionPost`).
        case toolPost
        /// A page's draft (`Requests.draft`).
        case draft
        /// A page's read of a private record (`Requests.webRead`).
        case privateRead
        /// A user's kind from an acting page (`LiveRights.act`): `PageVoice` confirms it, then `Requests.voiced`, recorded
        /// as the user's, marked as the page's.
        case pageVoice
    }

    /// Where `kind` from this peer goes.
    public func route(_ kind: String) -> Route {
        let shown = ConfigSeal.inert(kind, limit: 80)
        guard let spec = KindSpec.spec(kind) else { return .unknown }
        switch self {
        case .process:
            switch spec.sender {
            case .anyone: return spec.servedBy == .hub ? .hub : .read
            // A private record's read on the socket is the user's alone, as a user's-voice read (no typed word).
            case .user, .webRead: return .usersVoice
            case .leadToolServer: return .toolPost
            case .webDraft:
                return .refused(.voice, "a draft comes from a web page; in a terminal, `vibeswitcher answer CARD TEXT` answers and `vibeswitcher send SESSION TEXT` sends")
            // A page's alone: the socket doesn't take it.
            case .webTerminal: return .unknown
            }
        case .page(let rights, let terminals):
            let noRead = Route.refused(.voice, "this page's token doesn't read")
            // An agent's vs-ask files through its tool server, stamped by the host: a page files nothing.
            if kind == "plugin.file" { return .refused(.voice, "a page files nothing") }
            switch spec.sender {
            case .anyone: return !rights.contains(.read) ? noRead : spec.servedBy == .hub ? .hub : .read
            case .webRead: return rights.contains(.read) ? .privateRead : noRead
            case .webDraft: return rights.contains(.draft) ? .draft : .refused(.voice, "this page's token doesn't draft")
            case .user:
                guard rights.contains(.act) else {
                    return .refused(.voice, "\(shown) is the user's voice: a web page is never that; run it with `vibeswitcher` in a terminal")
                }
                switch spec.page {
                case .acts: return .pageVoice
                case .terminalOnly(let why): return .refused(.voice, "\(shown) is the terminal's alone: \(why); run it with `vibeswitcher` in a terminal")
                case .bySender: return .refused(.voice, "\(shown) is the user's voice")
                }
            case .leadToolServer: return .refused(.voice, "\(shown) is the lead's tool server's alone")
            case .webTerminal:
                guard terminals else { return .unknown }
                // Watching needs a pairing the user confirmed in a terminal (the acting review's fix C).
                return rights.contains(.watch) ? .terminal : .refused(.voice, "watching a terminal needs this page's pairing confirmed in a terminal (`vibeswitcher web`)")
            }
        }
    }

    /// Whether it is an acting page (`LiveRights.act`).
    public var acts: Bool { if case .page(let rights, _) = self { return rights.contains(.act) } else { return false } }

    /// A page's refusal of `request`, or nil when it goes on (`WebAccess.refusal`).
    public func refusal(_ request: NodeWire.Request) -> NodeWire.Reply? {
        switch route(request.kind) {
        case .unknown:
            return .init(re: request.id, error: .init(.unknownKind, "this server doesn't take \(ConfigSeal.inert(request.kind, limit: 80))"))
        case .refused(let code, let why): return .init(re: request.id, error: .init(code, why))
        case .hub, .terminal, .read, .usersVoice, .toolPost, .draft, .privateRead, .pageVoice: return nil
        }
    }

    /// The kinds this peer may send, in the table's order: a page's `hello.kinds`.
    public var kinds: [String] {
        KindSpec.all.map(\.name).filter { refusal(NodeWire.Request(id: "", kind: $0)) == nil }
    }
}
