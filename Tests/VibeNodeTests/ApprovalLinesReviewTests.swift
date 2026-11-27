import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode
#if canImport(Darwin)
import Darwin
#endif

/// The independent review of row 3 (the coalition line and the peer's environment line, branch
/// `v2-mac-approval-lines`; REVIEW-row3.md): what the lines reach on the wire, and what stays as it was while
/// `NodeSystem.approvalMeasured` is false. A fake person throughout (no dialog), no host (`NoHost`), the peer's code a
/// table. Runs on both systems.
struct ApprovalLinesReviewTests {
    private let scratch = Scratch()

    private struct NoHost: HostDialer {
        func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw HostLink.Failure("no host in this test") }
    }

    static let pid: pid_t = 9_000_902
    /// A peer that fails both new lines and passes every line before them: the installed command line's code (the
    /// table), the server's uid, an ancestry of itself, a terminal no session holds, in the node's coalition and
    /// carrying the session's variable (a Mac app shell card's process, or a node session's detached descendant).
    static let sessionLike = PeerFacts(pid: pid, uid: getuid(), cgroup: nil, ancestry: [.init(pid: pid, startTicks: 5)],
                                       terminal: .named("ttytest-review"), sessionMarker: true, underRunner: false,
                                       coalition: ApprovalVoiceTests.nodeCoalition)
    /// The same peer from a user's Terminal: another coalition, no variable.
    static let terminalLike: PeerFacts = {
        var facts = sessionLike
        facts.sessionMarker = false
        facts.coalition = ApprovalVoiceTests.terminalCoalition
        return facts
    }()

    /// A `Requests` on `rule` (the Mac's by default) with an `ApprovalVoice` whose person approves when `approval`.
    private func requests(rule: VoiceRule = VoiceRule(mode: .approval, scopes: [], uid: getuid(), says: VoiceRule.approvalSays),
                          approval: Bool = true) -> (Requests, ApprovalVoiceTests.Person) {
        let person = ApprovalVoiceTests.Person(.approved)
        let queue = DispatchQueue(label: "approval-lines-review")
        let root = scratch.url("root-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = HostLink(dialer: NoHost(), root: root, queue: queue)
        let requests = Requests(link: link, sessions: nil, rule: rule, root: root, hostSocket: scratch.url("h.sock").path, commit: "test", hostPID: 1)
        requests.engine = LeadEngine(root: root, nodeRoot: nil, link: link, clock: nil)
        if approval {
            requests.approval = ApprovalVoice(authenticator: person, commandLine: ApprovalVoiceTests.commandLine,
                                              coalition: ApprovalVoiceTests.nodeCoalition,
                                              runs: { token, code in code == ApprovalVoiceTests.commandLine && token.pid == Self.pid },
                                              hardened: { _ in true })
            requests.approvalLinkWelcomed = { true }
        }
        return (requests, person)
    }

    /// `kind` handled as `NodeServer` hands a request over (`Requests.handle` on its queue), from `facts`.
    private func handled(_ requests: Requests, _ kind: String, _ args: [String: NodeWire.Value] = [:], from facts: PeerFacts) async -> NodeWire.Reply? {
        let reply = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: UUID().uuidString, kind: kind, args: args, action: nil)
        let token = ApprovalVoiceTests.token(Self.pid)
        requests.queue.async { requests.handle(request, from: facts, token: token) { reply.value = $0 } }
        _ = await eventually(timeout: 60) { reply.value != nil }
        return reply.value
    }

    /// Attack 5. `status`, `board` and `questions` are `anyone`'s kinds (`KindSpec`): on the socket they route `.read`
    /// and never reach `ApprovalVoice`, so the lines don't refuse them, whatever the spec's row says ("so `status`,
    /// `board` and the other reads are refused there too"); `ApprovalLinesTests`' "reads" judge `status` directly, a
    /// path only the hello takes. The user's own reads (`shells`, `config.held`, `base.show`, `mail`, `recent`, `brief`)
    /// route `.usersVoice` and are refused by the lines with no dialog. Safe in its direction: a shell card keeps
    /// `status`, `board` and `questions`, and loses the user's own reads and every state change.
    @Test func onTheWireTheLinesRefuseTheUsersReadsButNotAnyonesReads() async throws {
        for kind in ["status", "board", "questions"] {
            #expect(Principal.process(Self.sessionLike).route(kind) == .read, "\(kind)")
        }
        let usersReads = ["shells", "config.held", "base.show", "mail", "recent", "brief"]
        for kind in usersReads {
            #expect(Principal.process(Self.sessionLike).route(kind) == .usersVoice, "\(kind)")
            #expect(NodeWire.changesState(kind) == false, "\(kind) asks no dialog under the Mac's rule")
        }
        let (requests, person) = requests()
        // `questions` answered to the shell card's process (the engine's open cards: none).
        let questions = try #require(await handled(requests, "questions", from: Self.sessionLike))
        #expect(questions.error == nil, "\(questions)")
        // The user's own reads: refused by the environment line's or the coalition line's words, nothing asked.
        for kind in ["shells", "config.held"] {
            let reply = try #require(await handled(requests, kind, from: Self.sessionLike))
            #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(kind): \(reply)")
            #expect(reply.error?.message == "not the user's voice: \(ApprovalVoice.inNodeCoalition(ApprovalVoiceTests.nodeCoalition))", "\(kind): \(reply)")
            var carrying = Self.terminalLike
            carrying.sessionMarker = true
            let carried = try #require(await handled(requests, kind, from: carrying))
            #expect(carried.error?.message == "not the user's voice: \(ApprovalVoice.carriesSession)", "\(kind): \(carried)")
            let fromTerminal = try #require(await handled(requests, kind, from: Self.terminalLike))
            #expect(fromTerminal.error?.code != NodeWire.Code.voice.rawValue, "\(kind) from a Terminal's peer: \(fromTerminal)")
        }
        #expect(person.asked.isEmpty, "\(person.asked)")
        // The hello judges `status` through the voice: it says `other`, with the line's words; the command line acts on
        // nothing of it (`NodeClient` reads only `rule`).
        let hello = requests.queue.sync { requests.hello(peer: Self.sessionLike, token: ApprovalVoiceTests.token(Self.pid)) }
        #expect(hello.peer.voice == "other" && hello.peer.why == ApprovalVoice.inNodeCoalition(ApprovalVoiceTests.nodeCoalition), "\(String(describing: hello.peer))")
        let fromTerminal = requests.queue.sync { requests.hello(peer: Self.terminalLike, token: ApprovalVoiceTests.token(Self.pid)) }
        #expect(fromTerminal.peer.voice == "user", "\(String(describing: fromTerminal.peer))")
    }

    /// Attack 7. The connection's slots (`Requests.mayBeUsersVoice`, `NodeServer.reservedForUser`) don't read the two
    /// lines: a node session's detached descendant in the node's coalition, carrying the variable, still takes a slot
    /// kept for the user, as on 657bb3d4. Nothing new leans on the lines there; the request itself is judged again.
    @Test func theUsersSlotsDontLeanOnTheLines() {
        let (requests, _) = requests()
        #expect(requests.queue.sync { requests.mayBeUsersVoice(Self.sessionLike) } == true)
        #expect(requests.queue.sync { requests.mayBeUsersVoice(Self.terminalLike) } == true)
    }

    /// Gates. With `NodeSystem.approvalMeasured` false the user's node on the Mac is on the closed rule (no
    /// `ApprovalVoice` built, `ServerStart`), and every caller, whatever its coalition and variable, gets the closed
    /// rule's refusal for a user's read and a hello of `other`, as on 657bb3d4; `anyone`'s reads are answered.
    @Test func withApprovalUnmeasuredEveryCallerIsAnsweredAsOnTheBase() async throws {
        #expect(NodeSystem.approvalMeasured == false)
        let rule = VoiceRule.at(start: nil, testScopes: nil, uid: getuid(), cgroups: false, usersNode: true)
        #expect(rule.mode == .closed)
        let (requests, person) = requests(rule: rule, approval: false)
        var unread = Self.sessionLike
        unread.sessionMarker = nil
        unread.coalition = nil
        for facts in [Self.sessionLike, Self.terminalLike, unread] {
            let shells = try #require(await handled(requests, "shells", from: facts))
            #expect(shells.error?.message == "not the user's voice: \(NodeSystem.voiceUnbuilt)", "\(shells)")
            let questions = try #require(await handled(requests, "questions", from: facts))
            #expect(questions.error == nil, "\(questions)")
            let hello = requests.queue.sync { requests.hello(peer: facts, token: ApprovalVoiceTests.token(Self.pid)) }
            #expect(hello.peer.voice == "other" && hello.peer.why == NodeSystem.voiceUnbuilt, "\(String(describing: hello.peer))")
        }
        #expect(person.asked.isEmpty)
    }
}

/// The review's attacks on real processes (attacks 1 to 3): only processes this test starts, this process's own token
/// (a socket pair's), and pid 1's coalition as M4 read it; no dialog, no job, no other process inspected.
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "launchd coalitions, audit tokens and the Mac's KERN_PROCARGS2"))
struct ApprovalLinesReviewProcessTests {
    typealias V = ApprovalVoiceTests
    private let scratch = Scratch()

    #if canImport(Darwin)
    /// This process's own audit token, as a socket names its peer (a pair's two ends are both this process's).
    static func ownToken() throws -> Platform.PeerToken {
        let (one, other) = try #require(Platform.Sockets.pair(type: Platform.Sockets.stream))
        defer { close(one); close(other) }
        return try #require(Platform.Sockets.peerToken(one))
    }
    #endif

    /// A voice whose server's coalition is `own`, every peer running the command line's code (the table).
    static func voice(own: UInt64?) -> ApprovalVoice {
        ApprovalVoice(authenticator: V.Person(.approved), commandLine: V.commandLine, coalition: own,
                      runs: { _, code in code == V.commandLine }, hardened: { _ in true })
    }

    /// `executable` started with exactly `environment` (no inherited one), its input a pipe it waits on; ended after
    /// `body`. Ready once its record names `ready` (an exec through `/usr/bin/env` done).
    private func with<T>(_ executable: String, _ arguments: [String], environment: [String], ready: String,
                         _ body: (pid_t) async throws -> T) async throws -> T {
        var spawn = Platform.Spawn(executable: executable, arguments: [executable] + arguments)
        spawn.environment = environment
        var input: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&input) == 0)
        spawn.stdin = .descriptor(input[0])
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        spawn.stderr = .path("/dev/null", flags: O_WRONLY)
        spawn.keep = []
        let started = spawn.start()
        close(input[0])
        let child: pid_t
        do { child = try started.get() } catch { close(input[1]); throw error }
        defer {
            close(input[1])
            kill(child, SIGKILL)
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0, errno == EINTR {}
        }
        try #require(await eventually(timeout: 60) { Platform.Processes.arguments(child).first == ready })
        return try await body(child)
    }

    /// Attack 1. The coalition is bound to the token's process: read before the token's check of the first link
    /// (`PeerFacts.read`), and dropped when that check fails, as the ancestry is. A token whose pidversion isn't the
    /// running process's (what a pid given again, or an exec since the connect, leaves: M7; the link's own binding is
    /// `ProcessesTests.aTokenFromBeforeAnExecOrAnEndNamesNoLink`) gives no coalition and no ancestry, so the voice
    /// refuses. The environment's marker is NOT dropped with them (read before the check too, but not gated on it): it
    /// is the process's that has the pid now, harmless only because the ancestry line runs before the environment line
    /// in `callerRefusal`; pinned here, so a reorder of the lines shows.
    @Test func theCoalitionIsBoundToTheTokensProcessAndTheMarkerOnlyByTheLinesOrder() throws {
        #if canImport(Darwin)
        let token = try Self.ownToken()
        let own = try #require(Platform.Processes.coalition(getpid()))
        let bound = PeerFacts.read(pid: getpid(), token: token)
        #expect(bound.coalition == own && bound.ancestry != nil, "\(bound)")
        var stale = token
        stale.val.7 &+= 1
        let unbound = PeerFacts.read(pid: getpid(), token: stale)
        #expect(unbound.coalition == nil, "\(unbound)")
        #expect(unbound.ancestry == nil && unbound.terminal == .unreadable && unbound.underRunner == nil, "\(unbound)")
        // Not gated: the process with the pid now (this one) read as it is.
        #expect(unbound.sessionMarker == bound.sessionMarker && unbound.sessionMarker != nil, "\(unbound)")
        let launchd = try #require(Platform.Processes.coalition(1))
        #expect(Self.voice(own: launchd).callerRefusal(peer: stale, facts: unbound, live: LiveSessions(), uid: getuid())
                == "its ancestry can't be read")
        #endif
    }

    /// Attack 2. `PROC_PIDCOALITIONINFO` (flavour 20) as this macOS answers it: exactly five 64-bit words, a smaller
    /// buffer refused (so a later macOS that grows the struct makes `coalition` nil: `read == size` fails), the resource
    /// id first and non-zero, a child's the same as this process's; pid 0, -1, a zombie and a reaped child read none.
    /// The code's other guard, a 0 id, has no seam to reach here (the kernel never gives one for a live process).
    @Test func flavourTwentyIsFiveWordsAndEverythingElseReadsNone() async throws {
        #if canImport(Darwin)
        var words = [UInt64](repeating: 0, count: 6)
        let full = words.withUnsafeMutableBytes { proc_pidinfo(getpid(), 20, 0, $0.baseAddress, 40) }
        #expect(full == 40)
        let own = words[0]
        #expect(own != 0 && Platform.Processes.coalition(getpid()) == own)
        let larger = words.withUnsafeMutableBytes { proc_pidinfo(getpid(), 20, 0, $0.baseAddress, 48) }
        #expect(larger == 40, "the kernel copies its own size, whatever the room")
        let smaller = words.withUnsafeMutableBytes { proc_pidinfo(getpid(), 20, 0, $0.baseAddress, 32) }
        #expect(smaller <= 0, "a buffer short of the struct is refused (\(smaller))")
        #expect(Platform.Processes.coalition(0) == nil && Platform.Processes.coalition(-1) == nil)

        var spawn = Platform.Spawn(executable: "/bin/sh", arguments: ["sh", "-c", "read line"])
        var input: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&input) == 0)
        spawn.stdin = .descriptor(input[0])
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        spawn.keep = []
        let started = spawn.start()
        close(input[0])
        let child: pid_t
        do { child = try started.get() } catch { close(input[1]); throw error }
        var reaped = false
        var writing = true
        defer {
            if writing { close(input[1]) }
            if !reaped {
                kill(child, SIGKILL)
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0, errno == EINTR {}
            }
        }
        #expect(Platform.Processes.coalition(child) == own)
        close(input[1])  // its read ends: it exits, a zombie until reaped
        writing = false
        try #require(await eventually(timeout: 60) { Platform.Processes.kernelRecord(child)?.state == .zombie })
        #expect(Platform.Processes.coalition(child) == nil, "a zombie reads none")
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        reaped = true
        #expect(Platform.Processes.coalition(child) == nil, "a reaped child reads none")
        #endif
    }

    /// Attack 3. An Apple platform binary started carrying the session's variable reads an EMPTY environment, not an
    /// unreadable one (M2): `sessionMarker` false, and the environment line passes it. So does the user's own build
    /// started with no environment at all (`env -i`). What stands in front for a platform binary is the code check
    /// (the installed command line's cdhash, before every guard rail); here the table says yes to every peer, so
    /// `callerRefusal` lets both through: the environment line tells nothing of a process whose environment reads empty.
    @Test func anEmptyEnvironmentPassesTheLineOnlyTheCodeCheckStandsInFront() async throws {
        #if canImport(Darwin)
        let launchd = try #require(Platform.Processes.coalition(1))
        func judged(_ pid: pid_t) -> (PeerFacts, String?) {
            var facts = PeerFacts.read(pid: pid)
            facts.ancestry = [.init(pid: pid, startTicks: 1)]
            facts.terminal = .none
            facts.underRunner = false
            return (facts, Self.voice(own: launchd).callerRefusal(peer: V.token(pid), facts: facts, live: LiveSessions(), uid: getuid()))
        }
        let marker = "\(PeerFacts.sessionMarkerName)=\(UUID().uuidString)"
        try await with("/bin/sleep", ["600"], environment: [marker, "PATH=/usr/bin:/bin"], ready: "/bin/sleep") { pid in
            let (facts, refusal) = judged(pid)
            #expect(facts.sessionMarker == false, "Apple's binary carrying the variable reads empty: \(facts)")
            #expect(refusal == nil, "\(String(describing: refusal))")
        }
        let built = builtProducts.appendingPathComponent("vibeswitcher-mcp").path
        try await with("/usr/bin/env", ["-i", built], environment: [marker], ready: built) { pid in
            let (facts, refusal) = judged(pid)
            #expect(facts.sessionMarker == false, "the user's build with no environment: \(facts)")
            #expect(Platform.Processes.environment(pid)?.isEmpty == true)
            #expect(refusal == nil, "\(String(describing: refusal))")
        }
        #endif
    }
}
