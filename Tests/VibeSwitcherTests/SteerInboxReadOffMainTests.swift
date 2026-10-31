import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The window's each-second heartbeat (`followChat` → `readScreen`) had the chat read the selected Claude session's
/// steer inbox on the main thread: `watchSteering` read `steer/<tty>.jsonl`, and `refreshSteering` that and
/// `.delivered` while a steered message waited. On a memory-starved Mac a read there can hold the window. They're
/// read on the chat's inbox queue now, and shown on main once read.
@MainActor
@Suite(.serialized)
struct SteerInboxReadOffMainTests {
    let temp = Scratch()
    let tty = "ttys901"
    let agentPid: Int32 = 4343

    /// A chat on a scratch inbox.
    func chat() throws -> ChatModel {
        let home = temp.url("steer-read-off-main")
        let root = home.appendingPathComponent("vibeswitcher")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("steer"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return ChatModel(outbox: ComposerOutbox(url: home.appendingPathComponent("outbox.json")), home: home.path, steerRoot: root)
    }

    /// Where each of the chat's inbox reads ran, and whether it read `.delivered` too.
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [(onMain: Bool, delivered: Bool)] = []
        func add(onMain: Bool, delivered: Bool) { lock.withLock { all.append((onMain, delivered)) } }
        var list: [(onMain: Bool, delivered: Bool)] { lock.withLock { all } }
    }

    @Test func theHeartbeatsInboxReadsRunOffTheMainThread() async throws {
        let chat = try chat()
        let reads = Reads()
        let load = chat.loadSteering
        chat.loadSteering = { tty, root, delivered in
            reads.add(onMain: Thread.isMainThread, delivered: delivered)
            return load(tty, root, delivered)
        }
        let message = SteerMessage(text: "use port 8080", from: .user, agentPid: agentPid)
        try SteerInbox.post(message, tty: tty, root: chat.steerRoot)
        // One heartbeat with nothing shown yet (followChat's refresh, then readScreen's watch), then one with it shown.
        chat.refreshSteering()
        chat.watchSteering(tty: tty, agentPid: agentPid, idle: false)
        #expect(await until { chat.steering.map(\.id) == [message.id] })
        #expect(await until { !chat.steerReading })
        chat.refreshSteering()
        chat.watchSteering(tty: tty, agentPid: agentPid, idle: false)
        #expect(await until { !chat.steerReading })
        let all = reads.list
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { !$0.onMain }, "an inbox read ran on the main thread: \(all)")
        // With a message shown, the read takes in what agents took too.
        #expect(all.last?.delivered == true)
        #expect(chat.steering.map(\.id) == [message.id])
    }

    /// A message waiting (the agent idle: stranded), then taken by its agent's hook: it leaves the strip, by the
    /// `.delivered` record alone (refresh) and by the heartbeat as a whole.
    @Test func aMessageWaitingThenDeliveredLeavesTheStrip() async throws {
        let chat = try chat()
        let message = SteerMessage(text: "stop after this", from: .user, agentPid: agentPid)
        try SteerInbox.post(message, tty: tty, root: chat.steerRoot)
        chat.watchSteering(tty: tty, agentPid: agentPid, idle: true)
        #expect(await until { chat.steering.map(\.id) == [message.id] })
        #expect(chat.steeringStranded)
        // Another agent's message on that terminal isn't this one's to show.
        try SteerInbox.post(SteerMessage(text: "not for this agent", from: .user, agentPid: agentPid + 1), tty: tty, root: chat.steerRoot)
        chat.watchSteering(tty: tty, agentPid: agentPid, idle: true)
        #expect(await until { !chat.steerReading })
        #expect(chat.steering.map(\.id) == [message.id])
        // The hook takes it.
        #expect(SteerInbox.take(tty: tty, agentPid: agentPid, root: chat.steerRoot).map(\.id) == [message.id])
        #expect(SteerInbox.delivered(tty: tty, root: chat.steerRoot).contains(message.id))
        chat.refreshSteering()
        #expect(await until { chat.steering.isEmpty })
        #expect(!chat.steeringStranded)
        chat.watchSteering(tty: tty, agentPid: agentPid, idle: true)
        #expect(await until { !chat.steerReading })
        #expect(chat.steering.isEmpty)
        #expect(!chat.steeringStranded)
    }

    /// A read still on its way when another session is selected shows nothing: the strip reads the new one's inbox
    /// after it (one read at a time) and shows that.
    @Test func aReadForATerminalNoLongerFollowedShowsNothing() throws {
        let chat = try chat()
        var queued: [() -> Void] = []
        chat.inbox = { queued.append($0) }
        chat.onMain = { $0() }
        let other = "ttys902"
        try SteerInbox.post(SteerMessage(text: "for the first", from: .user, agentPid: agentPid), tty: tty, root: chat.steerRoot)
        let second = SteerMessage(text: "for the second", from: .user, agentPid: agentPid + 1)
        try SteerInbox.post(second, tty: other, root: chat.steerRoot)
        chat.watchSteering(tty: tty, agentPid: agentPid, idle: true)
        chat.watchSteering(tty: other, agentPid: agentPid + 1, idle: false)
        #expect(queued.count == 1)
        #expect(chat.steerReading)
        queued.removeFirst()()
        // The first terminal's read: not shown. The second's is asked for now.
        #expect(chat.steering.isEmpty)
        #expect(!chat.steeringStranded)
        #expect(queued.count == 1)
        queued.removeFirst()()
        #expect(chat.steering.map(\.id) == [second.id])
        #expect(!chat.steeringStranded)
        #expect(!chat.steerReading)
        #expect(queued.isEmpty)
    }
}
