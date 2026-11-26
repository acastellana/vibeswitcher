import Foundation
import VibeCore

/// The user's voice on the Mac, built behind a seam and not yet the server's rule (the node on the Mac's design, "The
/// user's voice"; the user's decision of 2026-11-20: Touch ID or the login password for each state change, with the
/// caller check). Until the design's step 4 has measured it on a real Mac (LocalAuthentication from a LaunchAgent in
/// `gui/<uid>`, the lid closed, over ssh, no Touch ID; the environment line under SIP), the user's server there stays on
/// the closed rule (`VoiceRule.at`'s `usersNode`) and the user's node isn't started (`NodeSystem`); nothing calls
/// `judge` but the tests.
///
/// A request is the user's voice when, in this order (the cheap and silent checks first, so a session's request never
/// puts a dialog on the screen):
/// 1. its peer is the server's uid;
/// 2. its peer runs the installed command line's code (`commandLine`, its cdhash read at the server's start; the peer's
///    audit token checked by Security, `Platform.CodeIdentity.runs`) with the Hardened Runtime (`hardened`: no injected
///    library, no task port for another process): the request came through the command line;
/// 3. the guard rails: its ancestry holds no live session's program, the host or the server; its controlling terminal
///    is no live session's; no branch code runner is above it. (Linux's environment line is left out: with SIP on, the
///    Mac doesn't show another process's environment, and it would fail every peer.)
/// 4. a request that changes nothing (`NodeWire.changesState` false) is the user's voice then, as on Linux;
/// 5. a state change is put to the person at the Mac (`authenticator`, LocalAuthentication's dialog), its reason the
///    card's text the engine built (`reason(kind:card:)`, never the board's): approved, it is the user's voice; declined,
///    or nothing can be asked here (no Touch ID and no password, no GUI session), it isn't. A state change with no card
///    text is refused without asking.
///
/// What it proves beyond Linux's cgroup rule: a person agreed to *this* card; a session's process can make the dialog
/// appear but can't answer it. What it doesn't: a person who approves an unexpected dialog (prompt fatigue).
public struct ApprovalVoice: Sendable {
    /// What asks the person: the system's dialog (`System`), or a test's fake.
    public protocol Authenticator: Sendable {
        /// Asks the person to agree to `reason`, blocking until they answer or it times out.
        func ask(_ reason: String) -> Platform.Approval.Outcome
    }

    /// LocalAuthentication's dialog (`Platform.Approval.ask`), waiting at most `timeout` seconds. Never in a test: it
    /// would put a dialog on the screen of the person at the Mac (`ApprovalLintTests`).
    public struct System: Authenticator {
        public var timeout: TimeInterval
        public init(timeout: TimeInterval = 120) { self.timeout = timeout }
        public func ask(_ reason: String) -> Platform.Approval.Outcome { Platform.Approval.ask(reason, timeout: timeout) }
    }

    public var authenticator: any Authenticator
    /// The installed command line's cdhash, read once at the server's start from the node's record (`commandLineAnchor`:
    /// the row whose server is this server's own running code, never a file under the node's root); nil when it
    /// couldn't be taken, and then no peer is the user's.
    public var commandLine: Data?
    /// Whether a peer's token runs code of a cdhash (`Platform.CodeIdentity.runs(_:cdhash:)`; a test's table).
    public var runs: @Sendable (Platform.PeerToken, Data) -> Bool
    /// Whether a peer runs with the Hardened Runtime (`Platform.CodeIdentity.isHardened`; unreadable is no; a test's own).
    public var hardened: @Sendable (Platform.PeerToken) -> Bool

    /// The installed command line's cdhash the server holds for this rule, read once at its start (item 3's owed half,
    /// the node on the Mac's design, "The anchor", check 3): the command line of the build whose server is this
    /// server's own running code (`own`, `Platform.CodeIdentity.ownCdhash`) in the node's record (`pins`, root's to
    /// write). Never read from `<nodeRoot>/bin/vibeswitcher` (`nodeRoot` chooses nothing), so a command line swapped
    /// there after the host's start isn't the installed one. nil when the record can't be taken or names no build for
    /// this server: then no peer is the user's.
    public static func commandLineAnchor(nodeRoot: String?, own: Data?, pins: Result<NodePins, NodePins.Refused>) -> Data? {
        guard case .success(let record) = pins, let own else { return nil }
        return record.build(server: own)?.cli
    }

    public init(authenticator: any Authenticator, commandLine: Data?,
                runs: @escaping @Sendable (Platform.PeerToken, Data) -> Bool = { Platform.CodeIdentity.runs($0, cdhash: $1) },
                hardened: @escaping @Sendable (Platform.PeerToken) -> Bool = { Platform.CodeIdentity.isHardened($0) == true }) {
        self.authenticator = authenticator
        self.commandLine = commandLine
        self.runs = runs
        self.hardened = hardened
    }

    /// Whose voice the request of `kind` from `peer` (its token, read from the socket: `Platform.Sockets.peerToken`) is,
    /// `facts` read of it, `live` the live sessions, `uid` the server's, `card` the text of the card it acts on as the
    /// engine built it (nil for none). Asks the person only at step 5 above.
    public func judge(kind: String, card: String?, peer: Platform.PeerToken?, facts: PeerFacts, live: LiveSessions, uid: uid_t) -> Voice {
        if let why = callerRefusal(peer: peer, facts: facts, live: live, uid: uid) { return .notUser(why) }
        guard NodeWire.changesState(kind) else { return .user }
        guard let card, !card.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notUser("\(kind) changes state and has no card to ask the person at the Mac about")
        }
        switch authenticator.ask(Self.reason(kind: kind, card: card)) {
        case .approved: return .user
        case .declined(let why): return .notUser("declined at the Mac (\(why))")
        case .unavailable(let why): return .notUser("Touch ID or the login password can't be asked here (\(why))")
        }
    }

    /// Why the caller fails steps 1 to 3 (its uid, the installed command line's code, a hardened process, the guard
    /// rails), or nil when it passes: silent, never asks. The server runs it before it takes the one dialog's place.
    public func callerRefusal(peer: Platform.PeerToken?, facts: PeerFacts, live: LiveSessions, uid: uid_t) -> String? {
        guard let peerUID = facts.uid else { return "its user can't be read" }
        guard peerUID == uid else { return "it is another user's (uid \(peerUID))" }
        guard let commandLine else { return "the installed command line's code couldn't be read at the server's start" }
        guard let peer else { return "its process can't be named (no audit token)" }
        guard runs(peer, commandLine) else { return "it isn't the installed command line (its code isn't the build's)" }
        // The Hardened Runtime refuses an injected library (DYLD_INSERT_LIBRARIES) and another process's task port: a
        // command line without it could be made to send anything under its own code.
        guard hardened(peer) else { return "the command line doesn't run with the Hardened Runtime, so another process could steer it" }
        guard let ancestry = facts.ancestry else { return "its ancestry can't be read" }
        for ancestor in ancestry {
            if ancestor.pid == live.host { return "it runs under the session host (pid \(ancestor.pid))" }
            if ancestor.pid == live.server { return "it runs under the server (pid \(ancestor.pid))" }
            if live.programs.contains(ancestor.pid) { return "it runs under a live session's program (pid \(ancestor.pid))" }
        }
        switch facts.terminal {
        case .unreadable: return "its controlling terminal can't be read"
        case .named(let name) where live.terminals.contains(name): return "its terminal \(name) is a live session's"
        case .named, .none: break
        }
        guard let runner = facts.underRunner else { return "whether it runs under branch code can't be read" }
        guard !runner else { return "it runs under a branch code runner" }
        return nil
    }

    /// The longest card text a reason carries: the dialog is small, and the rest is on the command line's screen.
    public static let cardLimit = 200

    /// The dialog's reason for a state change of `kind` on `card` (the text the engine built for it), which the system
    /// shows after "<program> is trying to ": what the request does, then the card, on one line, inert
    /// (`ConfigSeal.inert`: no control or invisible character acts) and cut at `cardLimit`.
    public static func reason(kind: String, card: String) -> String {
        "\(action(kind)): \(ConfigSeal.inert(card.trimmingCharacters(in: .whitespacesAndNewlines), limit: cardLimit))"
    }

    /// What a state change of `kind` does, as a phrase that follows "is trying to " (`KindSpec.phrase`).
    public static func action(_ kind: String) -> String {
        KindSpec.spec(kind)?.phrase ?? "do \(ConfigSeal.inert(kind, limit: 40)) for you"
    }
}
