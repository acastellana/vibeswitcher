import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The node's status as a stream, and a session's whole value (the live plan's B2, the live wire contract's §5): the
/// `node` collection's one entry is `status`'s result without its sessions and leads (their own collections) and with
/// the web's state, sent when a look finds it changed; a session's value is `status`'s eight fields, unchanged, and the
/// contract's twelve more.
struct NodeStatusStoreTests {
    private let scratch = Scratch()

    // MARK: a session's value

    private static func session() -> Session {
        var session = Session(tty: "pts/4", agent: .claude, pid: 4242, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                              cwd: "/home/u/acme-site/sub", project: "acme-site", task: "Login fix", status: .working,
                              statusSince: Date(timeIntervalSince1970: 1_800_000_100), detail: "Thinking", hasHooks: true,
                              inTerminalApp: false)
        session.hostID = UUID(uuidString: "3F6C2C1E-8A5B-4C1D-9E0F-2B7A6D5C4E3F")
        session.teamRole = .lead
        session.activity = "Run unit tests"
        session.activitySince = Date(timeIntervalSince1970: 1_800_000_200)
        session.startFolder = "/home/u/acme-site"
        session.transcriptPath = "/home/u/.claude/projects/x/abc.jsonl"
        session.backgroundJobs = [BackgroundJob(pid: 1, command: "sleep 1", startedAt: Date()), BackgroundJob(pid: 2, command: "sleep 2", startedAt: Date())]
        return session
    }

    @Test func aSessionsLiveValueHasStatussEightFieldsUnchanged() throws {
        let session = Self.session()
        let status = try #require(Requests.value(session).object)
        let live = try #require(session.liveValue.object)
        #expect(status.count == 8)
        for (name, value) in status { #expect(live[name] == value, "\(name)") }
        #expect(Set(live.keys).subtracting(status.keys) == ["shownStatus", "project", "task", "detail", "activity", "activitySince",
                                                            "startedAt", "hasHooks", "leadAsks", "startFolder", "backgroundJobs",
                                                            "hasTranscript", "name", "pausedUntil", "agentSession"])
        #expect(live["id"] == .string("local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f"))
        #expect(live["project"] == .string("acme-site") && live["task"] == .string("Login fix") && live["detail"] == .string("Thinking"))
        #expect(live["activity"] == .string("Run unit tests"))
        #expect(live["activitySince"] == .date(Date(timeIntervalSince1970: 1_800_000_200)))
        #expect(live["startedAt"] == .date(Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(live["hasHooks"] == .bool(true) && live["leadAsks"] == .bool(false))
        #expect(live["startFolder"] == .string("/home/u/acme-site"))
        #expect(live["backgroundJobs"] == .int(2) && live["hasTranscript"] == .bool(true))
        #expect(live["shownStatus"] == .string("working"))
    }

    @Test func shownStatusIsTheLeadsAsk() {
        var lead = Self.session()
        lead.status = .done
        lead.leadAsks = true
        #expect(lead.liveValue["status"] == .string("done"))
        #expect(lead.liveValue["shownStatus"] == .string("needs-you"))
        #expect(lead.liveValue["leadAsks"] == .bool(true))
        // A worker waiting on its lead shows as working.
        var worker = Self.session()
        worker.teamRole = .worker
        worker.status = .needsInput
        #expect(worker.liveValue["status"] == .string("needs-you") && worker.liveValue["shownStatus"] == .string("working"))
    }

    @Test func aSessionWithNoTranscriptSaysSo() {
        var session = Self.session()
        session.transcriptPath = nil
        session.hostID = nil
        session.startFolder = nil
        session.activity = nil
        session.activitySince = nil
        session.task = nil
        session.detail = nil
        session.backgroundJobs = []
        let live = session.liveValue
        #expect(live["hasTranscript"] == .bool(false))
        #expect(live["id"] == .string("local:pts/4") && live["hosted"] == .bool(false))
        // Every field is there, null when it holds nothing (the contract: present unless marked optional).
        for name in ["startFolder", "activity", "activitySince", "task", "detail"] { #expect(live[name] == .null, "\(name)") }
        #expect(live["backgroundJobs"] == .int(0))
    }

    // MARK: the node

    private struct NoHost: HostDialer {
        func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw HostLink.Failure("no host in this test") }
    }

    @Test func theNodesValueIsStatusWithoutSessionsAndLeads() async throws {
        let queue = DispatchQueue(label: "engine")
        let link = HostLink(dialer: NoHost(), root: scratch.url("link-root"), queue: queue)
        let requests = Requests(link: link, sessions: nil, rule: VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's"),
                                root: scratch.url("node-root"), hostSocket: "/nonexistent/host.sock", commit: "abc123", hostPID: 1)
        let web: NodeWire.Value = .object(["state": .string("listening"), "port": .int(47830), "tokens": .int(1), "connections": .int(2)])
        let store = NodeStatusStore(requests: requests, web: { web })
        queue.sync { store.look() }

        var expected = try #require(queue.sync { requests.statusValue() }.object)
        #expect(expected["sessions"] != nil && expected["leads"] != nil)
        expected["sessions"] = nil
        expected["leads"] = nil
        expected["web"] = web
        #expect(store.changes.values == [NodeIds.node: .object(expected)])
        #expect(NodeStatusStore.webOff == .object(["state": .string("off"), "port": .null, "tokens": .int(0), "connections": .int(0)]))
    }

    /// A store on a status that says what `said` holds, watching `watched`, and what it sent.
    private final class Node: @unchecked Sendable {
        let queue = DispatchQueue(label: "engine")
        let said = Locked<[String: NodeWire.Value]>(["node": .string("local"), "notices": .array([]), "accepted": .array([]),
                                                      "sessions": .array([]), "leads": .array([])])
        let watched = Changes<Int>()
        let store: NodeStatusStore
        let got = Got<NodeWire.Value>()
        private var subscription: Subscription?

        init(clock: NodeClock? = nil) {
            store = NodeStatusStore(queue: queue, status: { [said] in .object(said.value) })
            subscription = store.changes.subscribe { [got] in got.add($0) }
            queue.sync { [self] in
                store.watch(watched)
                store.start(clock: clock)
            }
        }
    }

    @Test func aNewNoticeIsADelta() async throws {
        // The start's look is the first delta.
        let node = Node()
        #expect(await eventually { node.got.deltas.count == 1 })
        #expect(node.got.deltas[0].id == NodeIds.node)
        #expect(node.got.deltas[0].value?["sessions"] == nil && node.got.deltas[0].value?["web"] == NodeStatusStore.webOff)

        // A notice comes while a store the node watches changes: that change is the look, no call from anyone.
        node.said.mutate { $0["notices"] = .array([.string("the host restarted")]) }
        node.watched.send("card", 1)
        #expect(await eventually { node.got.deltas.count == 2 })
        #expect(node.got.deltas[1].value?["notices"] == .array([.string("the host restarted")]))
    }

    @Test func aLookThatFindsNothingNewSendsNothing() async throws {
        let node = Node()
        // The start's look, taken before the next (the store folds what its subscriber hasn't taken yet).
        #expect(await eventually { node.got.deltas.count == 1 })
        node.queue.sync {
            node.store.look()
            node.store.look()
        }
        node.watched.send("a", 1)
        node.watched.send("a", 2)
        node.queue.sync { node.store.look() }
        // A marker: once its delta is in, any before it would have been.
        node.said.mutate { $0["notices"] = .array([.string("marker")]) }
        node.queue.sync { node.store.look() }
        #expect(await eventually { node.got.deltas.count >= 2 })
        node.queue.sync {}
        #expect(node.got.deltas.count == 2, "\(node.got.deltas)")
        #expect(node.got.deltas[1].value?["notices"] == .array([.string("marker")]))
    }

    @Test func anAcceptedRequestIsADelta() async throws {
        let node = Node()
        node.queue.sync { node.store.look() }
        #expect(await eventually { node.got.deltas.count == 1 })
        let accepted: NodeWire.Value = .object(["kind": .string("answer"), "action": .string("6f1d2a34-9b8c-4e7d-a1f0-3c5b7d9e2f46"),
                                                "subject": .string("local:card:x"), "at": .date(Date(timeIntervalSince1970: 1_800_000_000)),
                                                "pid": .int(41822), "cgroup": .null, "commandLine": .array([.string("vibeswitcher")])])
        node.said.mutate { $0["accepted"] = .array([accepted]) }
        // `Requests` keeps an accepted request and acts on it (`acting`), where the integration looks.
        node.queue.sync { node.store.look() }
        #expect(await eventually { node.got.deltas.count == 2 })
        #expect(node.got.deltas[1].value?["accepted"] == .array([accepted]))
    }

    @Test func eachRefreshLooks() async throws {
        let time = DrivenTime()
        let clock = time.clock()
        let node = Node(clock: clock)
        // The start's look, taken before the next (the store folds what its subscriber hasn't taken yet).
        #expect(await eventually { node.got.deltas.count == 1 })
        node.said.mutate { $0["notices"] = .array([.string("seen at a refresh")]) }
        // The start's look found none; the first refresh finds it.
        time.run(until: Double(NodeStatusStore.refreshEvery) + 0.5)
        #expect(await eventually { node.got.deltas.count == 2 })
        #expect(node.got.deltas[1].value?["notices"] == .array([.string("seen at a refresh")]))
        node.queue.sync { node.store.stop() }
        node.said.mutate { $0["notices"] = .array([]) }
        time.run(until: Double(NodeStatusStore.refreshEvery) * 3 + 0.5)
        node.queue.sync {}
        #expect(node.got.deltas.count == 2, "a stopped store looks no more")
        withExtendedLifetime(clock) {}
    }
}
