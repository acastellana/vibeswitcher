import Foundation
import Testing
import VibeCore
import VibeNode

/// The Mac rule's two lines settled from the user's measurements (the node on the Mac's design, "The rule's lines,
/// settled from the measurements", row 3): the coalition line (a peer in the server's own launchd coalition is refused)
/// and the peer's environment line (a peer carrying `VIBESWITCHER_SESSION` is refused early). Both run in
/// `ApprovalVoice.callerRefusal`, before the kind is looked at, so they refuse reads as well as state changes. A fake
/// person throughout: no dialog is ever shown (`ApprovalLintTests`), and the peer's code is a table (`runs`).
struct ApprovalLinesTests {
    typealias V = ApprovalVoiceTests

    static let reads = ["status", "board", "questions"]
    static let stateChanges = ["answer", "set"]

    /// `facts` judged for each read and each state change, by a voice whose person approves: the voices, and what the
    /// person was asked.
    static func judged(_ facts: PeerFacts, coalition: UInt64? = V.nodeCoalition) -> (voices: [String: Voice], asked: [String]) {
        let person = V.Person(.approved)
        let voice = V.voice(person, coalition: coalition)
        var voices: [String: Voice] = [:]
        for kind in reads + stateChanges {
            voices[kind] = voice.judge(kind: kind, card: V.card, peer: V.token(900), facts: facts, live: V.live, uid: V.uid)
        }
        return (voices, person.asked)
    }

    // MARK: The coalition line

    @Test func aPeerInTheServersOwnCoalitionIsRefusedForReadsAndStateChangesAlike() {
        let (voices, asked) = Self.judged(V.facts(coalition: V.nodeCoalition))
        for kind in Self.reads + Self.stateChanges {
            #expect(voices[kind] == .notUser(ApprovalVoice.inNodeCoalition(V.nodeCoalition)), "\(kind): \(String(describing: voices[kind]))")
        }
        #expect(asked.isEmpty, "\(asked)")
    }

    @Test func aPeerOutsideTheServersCoalitionPassesTheLine() {
        let (voices, asked) = Self.judged(V.facts(coalition: V.terminalCoalition))
        for kind in Self.reads + Self.stateChanges { #expect(voices[kind] == .user, "\(kind): \(String(describing: voices[kind]))") }
        // Each state change was put to the person: the dialog, not the line, decides it.
        #expect(asked.count == Self.stateChanges.count, "\(asked)")
    }

    /// The peer's coalition unread, or the server's own unread at its start: refused, never open (a later macOS that
    /// changes the private flavour makes every request refused, loudly).
    @Test func aCoalitionThatCantBeReadIsRefused() {
        let unreadPeer = Self.judged(V.facts(coalition: nil))
        let unreadOwn = Self.judged(V.facts(coalition: V.terminalCoalition), coalition: nil)
        for kind in Self.reads + Self.stateChanges {
            #expect(unreadPeer.voices[kind] == .notUser(ApprovalVoice.coalitionUnread), "\(kind)")
            #expect(unreadOwn.voices[kind] == .notUser(ApprovalVoice.ownCoalitionUnread), "\(kind)")
        }
        #expect(unreadPeer.asked.isEmpty && unreadOwn.asked.isEmpty)
    }

    // MARK: The peer's environment line

    @Test func aPeerCarryingTheSessionVariableIsRefusedForReadsTooSayingToUseTerminalOrThePage() {
        let (voices, asked) = Self.judged(V.facts(marker: true))
        for kind in Self.reads + Self.stateChanges {
            #expect(voices[kind] == .notUser(ApprovalVoice.carriesSession), "\(kind): \(String(describing: voices[kind]))")
        }
        #expect(asked.isEmpty, "\(asked)")
        #expect(ApprovalVoice.carriesSession.contains(PeerFacts.sessionMarkerName))
        #expect(ApprovalVoice.carriesSession.contains("from Terminal") && ApprovalVoice.carriesSession.contains("the page"))
    }

    @Test func aPeerWithoutTheSessionVariablePassesTheLine() {
        let (voices, _) = Self.judged(V.facts(marker: false))
        for kind in Self.reads + Self.stateChanges { #expect(voices[kind] == .user, "\(kind)") }
    }

    @Test func anEnvironmentThatCantBeReadIsRefused() {
        let (voices, asked) = Self.judged(V.facts(marker: nil))
        for kind in Self.reads + Self.stateChanges { #expect(voices[kind] == .notUser(ApprovalVoice.environmentUnread), "\(kind)") }
        #expect(asked.isEmpty)
        #expect(ApprovalVoice.environmentUnread.contains("from Terminal") && ApprovalVoice.environmentUnread.contains("the page"))
    }

    /// The environment line is NOT a security boundary: a session drops the variable at will (`env -u`, a re-exec,
    /// a job of its own, an escape into Terminal: K-ESC-1 to 3), and then passes it. It keeps honest app sessions and
    /// accidents away from the dialog; the guarantee for a state change rests on the dialog alone, which still asks,
    /// and a declined dialog is still no.
    @Test func theEnvironmentLineIsNotABoundaryASessionThatDroppedTheVariablePassesItAndOnlyTheDialogGuardsAStateChange() {
        let dropped = V.facts(marker: false)
        let declined = V.Person(.declined("cancelled at the Mac"))
        let voice = V.voice(declined)
        #expect(voice.callerRefusal(peer: V.token(900), facts: dropped, live: V.live, uid: V.uid) == nil)
        #expect(voice.judge(kind: "answer", card: V.card, peer: V.token(900), facts: dropped, live: V.live, uid: V.uid)
                == .notUser("declined at the Mac (cancelled at the Mac)"))
        #expect(declined.asked.count == 1, "\(declined.asked)")
    }

    /// The lines run after every line before them, so a refusal those gave keeps its words.
    @Test func theTwoLinesComeAfterTheGuardRailsBeforeThem() {
        let both = V.facts(ancestry: [900, 700], marker: true, coalition: V.nodeCoalition)
        #expect(Self.judged(both).voices["status"] == .notUser("it runs under a live session's program (pid 700)"))
        let inCoalitionCarrying = V.facts(marker: true, coalition: V.nodeCoalition)
        #expect(Self.judged(inCoalitionCarrying).voices["status"] == .notUser(ApprovalVoice.inNodeCoalition(V.nodeCoalition)))
    }

    // MARK: Off: nothing changes while approvalMeasured is false

    /// With `NodeSystem.approvalMeasured` false (as it is), the user's server on the Mac is on the closed rule, as at
    /// 657bb3d4, byte for byte: `ServerStart` builds an `ApprovalVoice` only under `.approval`, so neither line runs,
    /// and the facts the lines read (a coalition, the variable) change no other rule's answer. The literals are the
    /// tip's own, copied, not the constants.
    @Test func withApprovalUnmeasuredTheRulesResultIsWhatItWas() {
        #expect(NodeSystem.approvalMeasured == false)
        let unbuilt = "closed: no rule tells the user's voice on this system yet (no cgroups; the Mac's rule isn't built), so no request is taken as the user's voice"
        let closed = VoiceRule(mode: .closed, scopes: [], uid: 501, says: unbuilt, refusal: unbuilt)
        #expect(VoiceRule.at(start: nil, testScopes: nil, uid: 501, cgroups: false, usersNode: true) == closed)
        #expect(VoiceRule.at(start: nil, testScopes: nil, uid: 501, cgroups: false, usersNode: true, approvalMeasured: false) == closed)
        let weaker = VoiceRule(mode: .weaker, scopes: [], uid: 501,
                               says: "the weaker rule: no systemd unit to tell by (the server's cgroup is unknown), so a peer's cgroup isn't checked and a state change needs a controlling terminal")
        #expect(VoiceRule.at(start: nil, testScopes: nil, uid: 501, cgroups: false, usersNode: false) == weaker)
        let peer = { (marker: Bool?, coalition: UInt64?) in
            PeerFacts(pid: 900, uid: 501, cgroup: nil, ancestry: [.init(pid: 900, startTicks: 1)], terminal: .named("/dev/ttys004"),
                      sessionMarker: marker, underRunner: false, coalition: coalition)
        }
        for coalition: UInt64? in [nil, V.nodeCoalition, V.terminalCoalition] {
            #expect(Voice.judge(peer(false, coalition), live: V.live, rule: closed) == .notUser(unbuilt))
            #expect(Voice.judge(peer(true, coalition), live: V.live, rule: closed) == .notUser(unbuilt))
            #expect(Voice.judge(peer(false, coalition), live: V.live, rule: weaker) == .user)
            #expect(Voice.judge(peer(true, coalition), live: V.live, rule: weaker) == .notUser("its environment carries VIBESWITCHER_SESSION"))
            #expect(Voice.judge(peer(nil, coalition), live: V.live, rule: weaker) == .notUser("its environment can't be read"))
        }
    }
}

/// The two lines on real processes, read as the server reads a peer (`PeerFacts.read`: `proc_pidinfo`'s coalition and
/// `KERN_PROCARGS2`'s environment, as the measurements' probe read them, M2 and M4), then judged by `callerRefusal`.
/// The peer's code (`runs`, `hardened`) is a table, and the lines before these two are set to pass (an ancestry of
/// itself, no terminal, no runner) so these two decide. Only processes this test starts, and pid 1's records (as M4
/// read them); no dialog, no job.
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "launchd coalitions and the Mac's KERN_PROCARGS2"))
struct ApprovalLinesProcessTests {
    typealias V = ApprovalVoiceTests
    private let scratch = Scratch()

    /// A voice whose server's own coalition is `own`, any peer running the command line's code.
    static func voice(own: UInt64?) -> ApprovalVoice {
        ApprovalVoice(authenticator: V.Person(.approved), commandLine: V.commandLine, coalition: own,
                      runs: { _, code in code == V.commandLine }, hardened: { _ in true })
    }

    /// `pid` read as the server reads a peer, then judged: the uid, coalition and environment as read; the other
    /// guard rails passing.
    static func refusal(of pid: pid_t, own: UInt64?) -> (facts: PeerFacts, refusal: String?) {
        var facts = PeerFacts.read(pid: pid)
        facts.ancestry = [.init(pid: pid, startTicks: 1)]
        facts.terminal = .none
        facts.underRunner = false
        return (facts, voice(own: own).callerRefusal(peer: V.token(pid), facts: facts, live: LiveSessions(), uid: getuid()))
    }

    /// The built tool server waiting on its input (the user's program, not Apple's, so its environment can be read,
    /// M2), started through `/usr/bin/env` with `envArguments` in `environment` and nothing else; ended after `body`.
    private func withBuilt<T>(environment: [String: String], envArguments: [String] = [],
                              _ body: (pid_t) async throws -> T) async throws -> T {
        let built = builtProducts.appendingPathComponent("vibeswitcher-mcp").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = envArguments + [built]
        process.environment = environment.merging(["PATH": "/usr/bin:/bin", "HOME": scratch.url("home").path]) { mine, _ in mine }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.terminate()
        }
        let pid = process.processIdentifier
        // Once `env` has exec'd the built program (Apple's `env` reads empty until then, M2).
        try #require(await eventually(timeout: 60) { Platform.Processes.arguments(pid).first == built })
        return try await body(pid)
    }

    @Test func aChildAndADetachedChildOfTheServersCoalitionAreRefused() async throws {
        let own = try #require(Platform.Processes.coalition(getpid()), "this process's coalition can't be read")
        try await withBuilt(environment: [:]) { pid in
            let (facts, refusal) = Self.refusal(of: pid, own: own)
            #expect(facts.coalition == own && facts.sessionMarker == false, "\(facts)")
            #expect(refusal == ApprovalVoice.inNodeCoalition(own))
        }
        // Detached as M3/M4 did it: a session of its own (setsid), its parent gone, reparented to launchd.
        let pidFile = scratch.url("detached.pid")
        var spawn = Platform.Spawn(executable: "/bin/sh", arguments: ["sh", "-c", "/bin/sleep 600 </dev/null >/dev/null 2>&1 & echo $! > \"$0\"", pidFile.path])
        spawn.group = .ownSession
        let shell = try spawn.start().get()
        var status: Int32 = 0
        _ = await offPool { waitpid(shell, &status, 0) }
        let detached = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(detached, SIGKILL) }
        try #require(await eventually(timeout: 60) { Platform.Processes.link(detached)?.parent == 1 })
        let (facts, refusal) = Self.refusal(of: detached, own: own)
        #expect(facts.coalition == own, "\(facts)")
        #expect(refusal == ApprovalVoice.inNodeCoalition(own))
    }

    /// launchd's own coalition (pid 1's, M4: another than this process's) as the server's: this process's child is
    /// outside it and passes the line.
    @Test func aPeerOutsideTheServersCoalitionPassesTheLine() async throws {
        let launchd = try #require(Platform.Processes.coalition(1), "pid 1's coalition can't be read")
        try await withBuilt(environment: [:]) { pid in
            let (facts, refusal) = Self.refusal(of: pid, own: launchd)
            #expect(facts.coalition != nil && facts.coalition != launchd, "\(facts)")
            #expect(refusal == nil, "\(String(describing: refusal))")
        }
    }

    @Test func aPeerCarryingTheSessionVariableIsRefusedSayingToUseTerminalOrThePage() async throws {
        let launchd = try #require(Platform.Processes.coalition(1))
        try await withBuilt(environment: [PeerFacts.sessionMarkerName: UUID().uuidString]) { pid in
            let (facts, refusal) = Self.refusal(of: pid, own: launchd)
            #expect(facts.sessionMarker == true, "\(facts)")
            #expect(refusal == ApprovalVoice.carriesSession)
        }
    }

    @Test func aPeerWithoutTheSessionVariablePassesTheLine() async throws {
        let launchd = try #require(Platform.Processes.coalition(1))
        try await withBuilt(environment: ["OTHER": "1"]) { pid in
            let (facts, refusal) = Self.refusal(of: pid, own: launchd)
            #expect(facts.sessionMarker == false, "\(facts)")
            #expect(refusal == nil, "\(String(describing: refusal))")
        }
    }

    /// Not a boundary: started carrying the variable and re-exec'd without it (`env -u`), the peer passes the line.
    @Test func theEnvironmentLineIsNotABoundaryAPeerThatDroppedTheVariablePassesIt() async throws {
        let launchd = try #require(Platform.Processes.coalition(1))
        try await withBuilt(environment: [PeerFacts.sessionMarkerName: UUID().uuidString], envArguments: ["-u", PeerFacts.sessionMarkerName]) { pid in
            let (facts, refusal) = Self.refusal(of: pid, own: launchd)
            #expect(facts.sessionMarker == false, "\(facts)")
            #expect(refusal == nil, "\(String(describing: refusal))")
        }
    }

    /// Another user's process (pid 1, root's: `KERN_PROCARGS2` refused, M8) reads no environment: refused.
    @Test func anEnvironmentThatCantBeReadIsRefused() throws {
        let environment = PeerFacts.read(pid: 1).sessionMarker
        #expect(environment == nil)
        let facts = V.facts(marker: environment)
        #expect(Self.voice(own: V.nodeCoalition).callerRefusal(peer: V.token(900), facts: facts, live: V.live, uid: V.uid)
                == ApprovalVoice.environmentUnread)
    }
}
