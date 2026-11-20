import Foundation
import Testing
import VibeCore
import VibeNode

/// The Mac's voice rule behind its seam (`ApprovalVoice`, the node on the Mac's design; the user's decision of
/// 2026-11-20), with a fake authenticator on both systems: no dialog is ever shown (`ApprovalLintTests`). A peer's
/// token and its code are a table here (`runs`); facts and live sessions are made up.
struct ApprovalVoiceTests {
    /// The person at the Mac, faked: each reason asked is kept, and `answer` given back.
    final class Person: ApprovalVoice.Authenticator, @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [String] = []
        let answer: Platform.Approval.Outcome

        init(_ answer: Platform.Approval.Outcome) { self.answer = answer }

        func ask(_ reason: String) -> Platform.Approval.Outcome {
            lock.withLock { reasons.append(reason) }
            return answer
        }

        var asked: [String] { lock.withLock { reasons } }
    }

    static let uid: uid_t = 501
    static let commandLine = Data(repeating: 0xc1, count: 20)
    static let card = "Which database? → Postgres (project shop, lead in /Users/u/shop)"

    /// A token for `pid` (the Mac's audit token, Linux's pid and start ticks).
    static func token(_ pid: pid_t) -> Platform.PeerToken {
        #if canImport(Darwin)
        var token = audit_token_t()
        token.val.5 = UInt32(bitPattern: pid)
        return token
        #else
        return Platform.PeerToken(pid: pid, uid: uid, startTicks: 1)
        #endif
    }

    /// Facts of a peer from a user's terminal: the server's uid, an ancestry of a shell, a terminal no session holds.
    static func facts(pid: pid_t = 900, uid: uid_t = uid, ancestry: [pid_t]? = [900, 800], terminal: PeerFacts.Terminal = .named("/dev/ttys004"),
                      underRunner: Bool? = false) -> PeerFacts {
        PeerFacts(pid: pid, uid: uid, cgroup: nil, ancestry: ancestry.map { $0.map { PeerFacts.Ancestor(pid: $0, startTicks: 1) } }, terminal: terminal,
                  sessionMarker: nil, underRunner: underRunner)
    }

    static let live = LiveSessions(programs: [700], terminals: ["/dev/ttys009"], host: 600, server: 650)

    /// The voice with `person`, the peers running the command line's code being `commandLinePeers`.
    static func voice(_ person: Person, commandLinePeers: Set<pid_t> = [900], commandLine: Data? = commandLine) -> ApprovalVoice {
        ApprovalVoice(authenticator: person, commandLine: commandLine) { token, code in
            code == Self.commandLine && commandLinePeers.contains(token.pid)
        }
    }

    @Test func aStateChangeIsTheUsersOnlyOnceThePersonAgreesToItsCard() {
        let person = Person(.approved)
        let voice = Self.voice(person)
        #expect(voice.judge(kind: "answer", card: Self.card, peer: Self.token(900), facts: Self.facts(), live: Self.live, uid: Self.uid) == .user)
        #expect(person.asked == ["answer a lead's question for you: \(Self.card)"])

        let declined = Person(.declined("cancelled at the Mac"))
        #expect(Self.voice(declined).judge(kind: "config.accept", card: "settings.json changed", peer: Self.token(900), facts: Self.facts(),
                                           live: Self.live, uid: Self.uid)
                == .notUser("declined at the Mac (cancelled at the Mac)"))
        #expect(declined.asked == ["accept a change to a watched file: settings.json changed"])

        let nobody = Person(.unavailable("no session to show the dialog in"))
        #expect(Self.voice(nobody).judge(kind: "stop", card: "stop the node", peer: Self.token(900), facts: Self.facts(), live: Self.live, uid: Self.uid)
                == .notUser("Touch ID or the login password can't be asked here (no session to show the dialog in)"))
    }

    /// A read changes nothing: the user's voice on the uid, the command line's code and the guard rails, as on Linux,
    /// and nobody is asked.
    @Test func aReadIsTheUsersWithoutAsking() {
        let person = Person(.declined("would refuse"))
        for kind in ["status", "questions", "board", "config.held", "base.show", "start"] {
            #expect(Self.voice(person).judge(kind: kind, card: nil, peer: Self.token(900), facts: Self.facts(), live: Self.live, uid: Self.uid) == .user, "\(kind)")
        }
        #expect(person.asked.isEmpty)
    }

    /// Every silent check comes before the dialog: a session's request, or anything but the installed command line,
    /// never puts one on the screen.
    @Test func whatIsntTheCommandLineFromAUsersTerminalIsNeverAsked() {
        let person = Person(.approved)
        let voice = Self.voice(person)
        func judged(_ facts: PeerFacts, peer: Platform.PeerToken? = Self.token(900)) -> Voice {
            voice.judge(kind: "answer", card: Self.card, peer: peer, facts: facts, live: Self.live, uid: Self.uid)
        }
        #expect(judged(Self.facts(uid: 502)) == .notUser("it is another user's (uid 502)"))
        #expect(judged(PeerFacts(pid: 900, uid: nil, cgroup: nil, ancestry: nil, terminal: .none, sessionMarker: nil, underRunner: false))
                == .notUser("its user can't be read"))
        #expect(judged(Self.facts(), peer: nil) == .notUser("its process can't be named (no audit token)"))
        #expect(judged(Self.facts(pid: 901, ancestry: [901, 800]), peer: Self.token(901))
                == .notUser("it isn't the installed command line (its code isn't the build's)"))
        #expect(judged(Self.facts(ancestry: nil)) == .notUser("its ancestry can't be read"))
        #expect(judged(Self.facts(ancestry: [900, 700])) == .notUser("it runs under a live session's program (pid 700)"))
        #expect(judged(Self.facts(ancestry: [900, 600])) == .notUser("it runs under the session host (pid 600)"))
        #expect(judged(Self.facts(ancestry: [900, 650])) == .notUser("it runs under the server (pid 650)"))
        #expect(judged(Self.facts(terminal: .named("/dev/ttys009"))) == .notUser("its terminal /dev/ttys009 is a live session's"))
        #expect(judged(Self.facts(terminal: .unreadable)) == .notUser("its controlling terminal can't be read"))
        #expect(judged(Self.facts(underRunner: true)) == .notUser("it runs under a branch code runner"))
        #expect(judged(Self.facts(underRunner: nil)) == .notUser("whether it runs under branch code can't be read"))
        #expect(person.asked.isEmpty, "\(person.asked)")
        // No code read at the server's start: no peer is the user's, nobody asked.
        #expect(Self.voice(person, commandLine: nil).judge(kind: "status", card: nil, peer: Self.token(900), facts: Self.facts(), live: Self.live, uid: Self.uid)
                == .notUser("the installed command line's code couldn't be read at the server's start"))
        // A state change with no card: refused, nobody asked.
        for card in [nil, "", "  \n"] {
            #expect(voice.judge(kind: "answer", card: card, peer: Self.token(900), facts: Self.facts(), live: Self.live, uid: Self.uid)
                    == .notUser("answer changes state and has no card to ask the person at the Mac about"))
        }
        #expect(person.asked.isEmpty)
    }

    /// The dialog's reason: what the request does, then the card the engine built, on one line, inert and cut.
    @Test func theReasonIsTheCardsTextInert() {
        #expect(ApprovalVoice.reason(kind: "hooks.install", card: "  into ~/.claude/settings.json\n") == "install VibeSwitcher's hooks: into ~/.claude/settings.json")
        let tricky = ApprovalVoice.reason(kind: "answer", card: "yes\u{1b}[2J\u{202e}drowssap\nsecond line")
        #expect(!tricky.contains("\u{1b}") && !tricky.contains("\u{202e}") && !tricky.contains("\n"), "\(tricky)")
        let long = ApprovalVoice.reason(kind: "tell", card: String(repeating: "x", count: 500))
        #expect(long.hasPrefix("tell a lead something for you: ") && long.hasSuffix("…") && long.count < 300, "\(long.count)")
        #expect(ApprovalVoice.action("some.new.kind") == "do some.new.kind for you")
        // Every state-changing kind the server takes has its own words.
        for kind in NodeWire.taken where NodeWire.changesState(kind) && NodeWire.kinds[kind] == .user {
            #expect(!ApprovalVoice.action(kind).hasPrefix("do "), "\(kind)")
        }
    }
}
