import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// What the server does with a request (`Requests`, the engine plan's E1 and EN-D6), on a link to a stand-in host
/// (`StubHost`): what a scratch host can't be made to do on cue (a host that hasn't welcomed yet, one that refuses its
/// shutdown, sessions that appear while `stop` waits). What a case calls on `Requests` it calls on the link's queue,
/// where `NodeServer` calls it.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct RequestsTests {
    private let scratch = Scratch()

    /// A peer that is the user's voice under the weaker rule (no cgroup read), on no real process's terminal
    /// (`CardWorld.user`).
    private static let user = CardWorld.user
    private static let rule = VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's")

    /// A link on `stub`, started, and the server's requests on it, whose host shutdown is `shutdown`.
    private func requests(_ stub: StubHost, welcomed: Bool = true, rule: VoiceRule = RequestsTests.rule,
                          shutdown: @escaping () -> HostEvent? = { .ok }) async throws -> Requests {
        var timing = HostLink.Timing()
        timing.reconnectDelays = [0.05, 0.1, 0.2, 0.5, 1, 2]
        let link = HostLink(dialer: stub.dialer, root: scratch.url("link-root"), queue: DispatchQueue(label: "engine"), timing: timing,
                            sweep: { _ in })
        link.start()
        if welcomed { try #require(await eventually { link.queue.sync { link.state == .connected } }, "the link was never welcomed") }
        let requests = Requests(link: link, sessions: nil, rule: rule, root: scratch.url("node-root"),
                                hostSocket: stub.path, commit: "test", hostPID: 1)
        requests.shutdown = shutdown
        return requests
    }

    /// `kind` from `peer` (the user, by default), answered.
    private func ask(_ requests: Requests, _ kind: String, from peer: PeerFacts = RequestsTests.user, timeout: TimeInterval = 60) async -> NodeWire.Reply? {
        let reply = Locked<NodeWire.Reply?>(nil)
        requests.queue.async {
            requests.handle(NodeWire.Request(id: "r1", kind: kind, action: UUID().uuidString.lowercased()), from: peer) { answer in
                reply.mutate { $0 = answer }
            }
        }
        _ = await eventually(timeout: timeout) { reply.value != nil }
        return reply.value
    }

    /// A live session labelled `label`.
    private static func session(_ label: String, tty: String) -> HostSession {
        HostSession(id: UUID(), tty: tty, childPID: 1, cwd: "/nonexistent/stub", command: "sleep 600", label: label, agent: nil,
                    title: "", startedAt: Date(), cols: 80, rows: 24, exit: nil)
    }

    private static func ended(_ session: HostSession) -> HostSession {
        var ended = session
        ended.exit = HostSession.Exit(status: 143, at: Date())
        return ended
    }

    /// The sessions the stub was asked to kill, in order.
    private static func killed(_ stub: StubHost) -> [UUID] {
        stub.requests.compactMap { if case .kill(let id) = $0 { id } else { nil } }
    }

    @Test func aStateChangeBeforeTheWelcomeIsAnsweredNotYet() async throws {
        let stub = try StubHost(scratch)
        defer { stub.quit() }
        stub.welcomes = false
        let asked = Locked(0)
        let requests = try await requests(stub, welcomed: false) {
            asked.mutate { $0 += 1 }
            return .ok
        }
        // Before the first welcome the link lists no session: a stop now would find nothing live and say the host
        // shut down while every session runs.
        let reply = try #require(await ask(requests, "stop"))
        #expect(reply.ok == false && reply.error?.code == NodeWire.Code.notYet.rawValue, "\(reply)")
        #expect(asked.value == 0)
        #expect(requests.queue.sync { requests.stopping } == false)
        #expect(requests.queue.sync { requests.accepted }.isEmpty)
        // Status is still answered.
        let status = try #require(await ask(requests, "status"))
        #expect(status.ok, "\(status)")
    }

    @Test func aStopTheHostRefusesIsRefusedAndRequestsAreTakenAgain() async throws {
        let stub = try StubHost(scratch)
        defer { stub.quit() }
        let requests = try await requests(stub) { .error("Sessions are running.") }
        let reply = try #require(await ask(requests, "stop"))
        #expect(reply.ok == false && reply.error?.code == NodeWire.Code.refused.rawValue, "\(reply)")
        #expect(reply.error?.message.contains("Sessions are running.") == true, "\(reply)")
        #expect(requests.queue.sync { requests.stopping } == false)
        // A host that doesn't answer is no shutdown either.
        requests.shutdown = { nil }
        let silent = try #require(await ask(requests, "stop"))
        #expect(silent.ok == false && silent.error?.code == NodeWire.Code.refused.rawValue, "\(silent)")
    }

    /// A user's-voice request while `stop` goes on is refused before it is recorded, with its own code (`stopping`),
    /// never `refused`, which says the server took the request first (the command line journals those).
    @Test func aRequestWhileTheNodeStopsIsRefusedBeforeItIsRecorded() async throws {
        let stub = try StubHost(scratch)
        defer { stub.quit() }
        let answer = DispatchSemaphore(value: 0)
        let requests = try await requests(stub) {
            _ = answer.wait(timeout: .now() + 120)
            return .error("Sessions are running.")
        }
        defer { answer.signal() }
        let stop = Locked<NodeWire.Reply?>(nil)
        requests.queue.async {
            requests.handle(NodeWire.Request(id: "stop", kind: "stop", action: UUID().uuidString.lowercased()), from: Self.user) { stop.value = $0 }
        }
        try #require(await eventually(timeout: 60) { requests.queue.sync { requests.stopping } })
        let lead = try #require(await ask(requests, "lead"))
        #expect(lead.ok == false && lead.error?.code == NodeWire.Code.stopping.rawValue, "\(lead)")
        let accepted = requests.queue.sync { requests.statusValue()["accepted"]?.array ?? [] }
        #expect(accepted.count == 1, "\(accepted)")
        #expect(accepted.first?["kind"]?.string == "stop", "\(accepted)")
        answer.signal()
        #expect(await eventually(timeout: 60) { stop.value != nil })
    }

    @Test func aStopEndsTheLeadsFirstThenEveryOtherAndAnyThatAppears() async throws {
        let lead = Self.session("Lead · project", tty: "ttypts1")
        let worker = Self.session("Worker: one", tty: "ttypts2")
        let stub = try StubHost(scratch, sessions: [lead, worker])
        defer { stub.quit() }
        let asked = Locked(0)
        let requests = try await requests(stub) {
            asked.mutate { $0 += 1 }
            return .ok
        }
        let reply = Locked<NodeWire.Reply?>(nil)
        requests.queue.async {
            requests.handle(NodeWire.Request(id: "r1", kind: "stop", action: UUID().uuidString.lowercased()), from: Self.user) { answer in
                reply.mutate { $0 = answer }
            }
        }
        // The lead first, and only the lead while it lives.
        #expect(await eventually { Self.killed(stub) == [lead.id] }, "\(Self.killed(stub))")
        // A worker its tool server started before it died.
        let late = Self.session("Worker: two", tty: "ttypts3")
        stub.push(.spawned(late))
        _ = requests.queue.sync { requests.link.sessions.count }
        #expect(!Self.killed(stub).contains(worker.id) && !Self.killed(stub).contains(late.id), "\(Self.killed(stub))")
        // The lead gone: every other session, the one that came meanwhile too.
        stub.push(.sessionChanged(Self.ended(lead)))
        #expect(await eventually { Set(Self.killed(stub)) == [lead.id, worker.id, late.id] }, "\(Self.killed(stub))")
        // One more appears while the rest end: it is ended too, and the host is asked only once nothing is live.
        let later = Self.session("Verifier: x", tty: "ttypts4")
        stub.push(.spawned(later))
        stub.push(.sessionChanged(Self.ended(worker)))
        stub.push(.sessionChanged(Self.ended(late)))
        #expect(await eventually { Self.killed(stub).contains(later.id) }, "\(Self.killed(stub))")
        #expect(asked.value == 0 && reply.value == nil)
        stub.push(.sessionChanged(Self.ended(later)))
        #expect(await eventually { reply.value != nil })
        #expect(reply.value?.ok == true, "\(String(describing: reply.value))")
        #expect(reply.value?.result?["sessionsEnded"]?.int == 4)
        #expect(asked.value == 1)
        // Each was asked to end once.
        #expect(Self.killed(stub).count == 4, "\(Self.killed(stub))")
    }

    @Test func underTheWeakerRuleAStateChangeFromAPeerWithNoTerminalIsRefused() async throws {
        // The weaker rule has no cgroup to tell by: a session's process that double-forked out of the host's tree,
        // dropped its terminal (`setsid`) and its marker passes the other four lines. A state change then needs the
        // controlling terminal its typed code is asked on.
        let stub = try StubHost(scratch)
        defer { stub.quit() }
        let asked = Locked(0)
        let requests = try await requests(stub) {
            asked.mutate { $0 += 1 }
            return .ok
        }
        var escaped = Self.user
        escaped.terminal = .none
        let reply = try #require(await ask(requests, "stop", from: escaped))
        #expect(reply.ok == false && reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
        #expect(reply.error?.message.contains("controlling terminal") == true, "\(reply)")
        #expect(asked.value == 0)
        #expect(requests.queue.sync { requests.stopping } == false)
        #expect(requests.queue.sync { requests.accepted }.isEmpty)
        // A request that changes nothing is taken from it, as the reads are.
        let start = try #require(await ask(requests, "start", from: escaped))
        #expect(start.ok, "\(start)")
        let status = try #require(await ask(requests, "status", from: escaped))
        #expect(status.ok, "\(status)")
        // With a terminal of its own (no session's), the stop goes.
        let stop = try #require(await ask(requests, "stop"))
        #expect(stop.ok, "\(stop)")
        #expect(asked.value == 1)
    }

    @Test func everyKindIsClassifiedAsAReadOrAStateChange() {
        // The weaker rule's terminal check (`Voice.handsRefusal`) reads `changesState`: each kind the protocol names is
        // one or the other, every kind recorded in the vault but `start` (a running node's start says when it started)
        // changes state, and a kind no table lists is a state change. The live protocol's kinds too: its reads, a web
        // client's draft and terminal, and opening the web.
        let reads: Set<String> = ["status", "questions", "start", "config.held", "base.show", "question.post", "question.revise", "question.withdraw",
                                  "subscribe", "unsubscribe", "chat.page", "board",
                                  // It changes nothing but a session's seen mark (done or idle), so it needs no voice.
                                  "seen",
                                  // The node's settings, read (2026-11-20).
                                  "settings"]
        let changes: Set<String> = ["stop", "lead", "answer", "hold", "tell", "config.accept", "base.accept", "base.keep", "hooks.install", "hooks.remove", "build.switch",
                                    "draft", "draft.clear", "web.open", "web.revoke", "term.open", "term.close",
                                    // Driving an ordinary session (2026-11-20).
                                    "send", "session.new", "session.end", "session.reply", "session.draft", "session.draft.clear",
                                    // A setting changed (2026-11-20).
                                    "set"]
        #expect(Set(NodeWire.kinds.keys) == reads.union(changes), "a kind added to NodeWire.kinds is classified here")
        for kind in reads { #expect(!NodeWire.changesState(kind), "\(kind)") }
        for kind in changes { #expect(NodeWire.changesState(kind), "\(kind)") }
        for kind in Requests.recorded where kind != "start" { #expect(NodeWire.changesState(kind), "\(kind)") }
        for kind in Requests.carded { #expect(NodeWire.changesState(kind), "\(kind)") }
        #expect(NodeWire.changesState("a.kind.added.later"))
    }

    @Test func underTheClosedRuleNoStateChangeIsTakenAndStatusSaysWhy() async throws {
        // The server's own cgroup unread at its start (a session can make it so): no peer is the user's, not even one
        // with a terminal of its own; the reads are still answered and say why.
        let stub = try StubHost(scratch)
        defer { stub.quit() }
        let asked = Locked(0)
        let closed = VoiceRule.at(start: nil, testScopes: nil, cgroups: true)
        let requests = try await requests(stub, rule: closed) {
            asked.mutate { $0 += 1 }
            return .ok
        }
        for kind in ["stop", "start"] {
            let reply = try #require(await ask(requests, kind))
            #expect(reply.ok == false && reply.error?.code == NodeWire.Code.voice.rawValue, "\(kind): \(reply)")
            #expect(reply.error?.message.contains(VoiceRule.closedRefusal) == true, "\(kind): \(reply)")
        }
        #expect(asked.value == 0)
        #expect(requests.queue.sync { requests.stopping } == false)
        #expect(requests.queue.sync { requests.accepted }.isEmpty)
        let status = try #require(await ask(requests, "status"))
        #expect(status.ok, "\(status)")
        #expect(status.result?["rule"]?["mode"]?.string == "closed", "\(status)")
        #expect(status.result?["rule"]?["says"]?.string?.contains("couldn't be read") == true, "\(status)")
    }

    /// `seen` (the parity gaps of 2026-11-19), as a web page's with the session open sends it (no voice, nor a
    /// terminal): the session counts as seen, so its finished turn reads idle; a session the node doesn't list is
    /// `gone`, one not named `bad-args`.
    @Test func aSessionSeenFromAPageMarksItsFinishedTurnSeen() async throws {
        let stub = try StubHost(scratch)
        defer { stub.quit() }
        let link = HostLink(dialer: stub.dialer, root: scratch.url("link-root"), queue: DispatchQueue(label: "engine"), sweep: { _ in })
        let root = scratch.url("node-root")
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        var hook = HookState(agent: .claude, tty: "ttypts975", lastEvent: "Stop", lastEventAt: Date().timeIntervalSince1970 + 60)
        hook.agentPid = 975
        try hook.save(to: state.appendingPathComponent("ttypts975.json"))
        let table = [Int32(975): ProcInfo(pid: 975, ppid: 1, tty: "ttypts975", comm: "claude", startTime: Date().addingTimeInterval(-600), agent: .claude)]
        let clock = Locked(Date())
        let nodes = NodeSessions(root: root, home: scratch.url("home").path, queue: link.queue,
                                 scanner: SessionScanner(processes: { table }, stateDir: { state }, cwd: { _ in "/r/x" }, arguments: { _ in [] }),
                                 now: { clock.value })
        nodes.start()
        defer { nodes.stop() }
        let requests = Requests(link: link, sessions: nodes, rule: Self.rule, root: root, hostSocket: stub.path, commit: "test", hostPID: 1)
        try #require(await eventually { nodes.queue.sync { nodes.sessions.first?.status == .done } })
        let id = try #require(nodes.queue.sync { nodes.sessions.first.map(NodeSessions.id(of:)) })
        clock.value = clock.value.addingTimeInterval(120)
        func seen(_ args: [String: NodeWire.Value]) async -> NodeWire.Reply? {
            let reply = Locked<NodeWire.Reply?>(nil)
            requests.queue.async {
                requests.handle(NodeWire.Request(id: "s1", kind: "seen", args: args), from: NodeLive.webPeer) { reply.value = $0 }
            }
            _ = await eventually { reply.value != nil }
            return reply.value
        }
        let reply = try #require(await seen(["session": .string(id)]))
        #expect(reply.ok, "\(reply)")
        #expect(nodes.queue.sync { nodes.sessions.first?.status } == .idle)
        let gone = try #require(await seen(["session": .string("t-nobody")]))
        #expect(gone.error?.code == NodeWire.Code.gone.rawValue, "\(gone)")
        let bad = try #require(await seen([:]))
        #expect(bad.error?.code == NodeWire.Code.badArgs.rawValue, "\(bad)")
        // A web page's token that reads may send it; one that doesn't, not.
        let request = NodeWire.Request(id: "s2", kind: "seen", args: ["session": .string(id)])
        #expect(WebAccess.refusal(for: request, rights: [.read]) == nil)
        #expect(WebAccess.refusal(for: request, rights: [])?.error?.code == NodeWire.Code.voice.rawValue)
    }
}
