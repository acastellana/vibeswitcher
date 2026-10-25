import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// E-14: the steer inbox's lock is held by others for seconds (a hook's delivery checks seals through the host with a
/// 5 s timeout), and the composer's send and the strip's withdraw took it on the main thread: the window froze for as
/// long. Here another process holds the lock until the test lets it go, and the main-thread call returns while it
/// still holds it; the message lands (or comes back) once the lock is free, shown as sending meanwhile.
@MainActor
@Suite(.serialized)
struct SteerOffMainTests {
    let temp = Scratch()
    let tty = "ttys900"
    let agentPid: Int32 = 4242
    /// The composer's key: its own per test (drafts are saved under the scratch home).
    let key = "host:\(UUID().uuidString)"

    /// A chat on a scratch inbox, and the file its inbox lock is on.
    func chat() throws -> (ChatModel, ChatSync, URL) {
        let home = temp.url("steer-off-main")
        let root = home.appendingPathComponent("vibeswitcher")
        let folder = root.appendingPathComponent("steer")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let chat = ChatModel(outbox: ComposerOutbox(url: home.appendingPathComponent("outbox.json")), home: home.path, steerRoot: root)
        let sync = ChatSync(chat: chat, host: HostClient(socketPath: home.appendingPathComponent("no-host.sock").path, appKey: { nil }))
        return (chat, sync, folder.appendingPathComponent("\(tty).jsonl"))
    }

    /// Another process holding a file's lock.
    struct Holder {
        let process: Process
        let input: Pipe

        /// Lets the lock go now: the holder exits.
        func release() { try? input.fileHandleForWriting.close() }
    }

    /// Another process holding `file`'s lock until `release`, or for `seconds` from when it took it, whichever comes
    /// first; returns once it has it.
    func holdLock(_ file: URL, for seconds: Double) throws -> Holder {
        let script = """
        import fcntl, os, select, sys
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        sys.stdout.write("locked\\n"); sys.stdout.flush()
        select.select([sys.stdin], [], [], float(sys.argv[2]))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", script, file.path, String(seconds)]
        let out = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardInput = input
        try process.run()
        var line = Data()
        while let byte = try out.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) { line += byte }
        let said = String(decoding: line, as: UTF8.self)
        try #require(said == "locked", "the holder said \(said)")
        return Holder(process: process, input: input)
    }

    /// Whether another process holds `file`'s lock now: one asked for here without waiting is refused. What a call
    /// that must not wait for the lock is checked by, rather than how long it took (a loaded Mac can take 0.3 s to run
    /// any call on the main thread).
    func heldElsewhere(_ file: URL) -> Bool {
        let fd = open(file.path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) != 0 else {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    @Test func aSendWhileAnotherProcessHoldsTheInboxReturnsAtOnceAndLandsWhenItsFree() async throws {
        let (chat, sync, file) = try chat()
        // Held until the test lets it go (a minute at most, should the send wait for it).
        let holder = try holdLock(file, for: 60)
        defer { holder.process.terminate() }
        let accepted = sync.steer("use port 8080", key: key, tty: tty, agentPid: agentPid)
        // It returned without waiting for the lock: the holder has it still.
        #expect(heldElsewhere(file), "the main-thread send waited for the lock")
        #expect(accepted)
        // Meanwhile: in the chat as sending, not in the inbox yet; a heartbeat doesn't drop it.
        let id = try #require(chat.steering.first?.id)
        #expect(chat.steering.map(\.text) == ["use port 8080"])
        #expect(chat.steerSending == [id])
        #expect(SteerInbox.pending(tty: tty, root: chat.steerRoot).isEmpty)
        chat.watchSteering(tty: tty, agentPid: agentPid, idle: false)
        chat.refreshSteering()
        #expect(chat.steering.map(\.text) == ["use port 8080"])
        // Not in while the lock is held.
        #expect(heldElsewhere(file))
        #expect(chat.steerSending == [id])
        #expect(SteerInbox.pending(tty: tty, root: chat.steerRoot).isEmpty)
        // Lands once the lock is free: steering (no longer sending), in the inbox, sealed as the user's. The wait ends
        // when the post is in (the hang guard only bounds it). The lock goes with the holder's exit, which Process
        // learns of a moment later, so that's waited for too.
        holder.release()
        #expect(await until { chat.steerSending.isEmpty })
        #expect(await until { !holder.process.isRunning })
        let waiting = SteerInbox.pending(tty: tty, root: chat.steerRoot)
        #expect(waiting.map(\.id) == [id])
        #expect(SteerInbox.verified(waiting, sealer: .for(chat.steerRoot)).map(\.from) == [.user])
        chat.watchSteering(tty: tty, agentPid: agentPid, idle: false)
        #expect(chat.steering.map(\.id) == [id])
        #expect(chat.sendNotice == nil)
    }

    @Test func aWithdrawWhileAnotherProcessHoldsTheInboxReturnsAtOnceAndTakesItWhenItsFree() async throws {
        let (chat, _, file) = try chat()
        let message = SteerMessage(text: "never mind", from: .user, agentPid: agentPid)
        try SteerInbox.post(message, tty: tty, root: chat.steerRoot)
        chat.watchSteering(tty: tty, agentPid: agentPid, idle: true)
        #expect(chat.steering.map(\.id) == [message.id])
        let holder = try holdLock(file, for: 60)
        defer { holder.process.terminate() }
        var taken: SteerMessage?
        chat.withdrawSteered(message) { taken = $0 }
        #expect(heldElsewhere(file), "the main-thread withdraw waited for the lock")
        #expect(taken == nil)
        #expect(chat.steering.map(\.id) == [message.id])
        #expect(SteerInbox.pending(tty: tty, root: chat.steerRoot).map(\.id) == [message.id])
        holder.release()
        #expect(await until { taken != nil })
        #expect(await until { !holder.process.isRunning })
        #expect(taken?.id == message.id)
        #expect(chat.steering.isEmpty)
        #expect(!chat.steeringStranded)
        #expect(SteerInbox.pending(tty: tty, root: chat.steerRoot).isEmpty)
    }

    /// A withdraw sent while its post is still waiting on the lock comes after it (one queue, in order).
    @Test func aWithdrawRightAfterASendWaitsForItsPost() async throws {
        let (chat, sync, file) = try chat()
        let holder = try holdLock(file, for: 60)
        defer { holder.process.terminate() }
        #expect(sync.steer("stop after this", key: key, tty: tty, agentPid: agentPid))
        let message = try #require(chat.steering.first)
        var taken: SteerMessage?
        chat.withdrawSteered(message) { taken = $0 }
        #expect(heldElsewhere(file))
        holder.release()
        #expect(await until { taken != nil })
        #expect(taken?.text == "stop after this")
        #expect(chat.steering.isEmpty)
        #expect(chat.steerSending.isEmpty)
        #expect(SteerInbox.pending(tty: tty, root: chat.steerRoot).isEmpty)
    }

    /// The composer's ↩ while the agent works: the message in the outbox, then steered (`ChatModel.deliver`).
    @discardableResult
    func send(_ text: String, attachments: [String] = [], chat: ChatModel, sync: ChatSync, tty: String? = nil) -> OutboxEntry {
        let entry = OutboxEntry(key: key, message: text, text: text, attachments: attachments)
        chat.outbox.add(entry)
        let actions = ComposerActions(send: { _ in Issue.record("typed, not steered"); return false },
                                      steer: { [tty = tty ?? self.tty, agentPid, key] in sync.steer($0, key: key, tty: tty, agentPid: agentPid) },
                                      stop: {}, cycleMode: {})
        #expect(chat.deliver(entry, steering: true, working: true, actions: actions))
        return entry
    }

    /// The composer's outbox keeps a steer until it's in the inbox (never in the list of messages typed in), and
    /// lets it go then.
    @Test func theOutboxKeepsASteerUntilItsInTheInbox() async throws {
        let (chat, sync, file) = try chat()
        let holder = try holdLock(file, for: 60)
        defer { holder.process.terminate() }
        let entry = send("use port 8080", chat: chat, sync: sync)
        #expect(chat.outbox.entry(entry.id)?.state == .sending)
        #expect(chat.pending.isEmpty)
        #expect(chat.steering.map(\.text) == ["use port 8080"])
        holder.release()
        #expect(await until { chat.steerSending.isEmpty })
        #expect(chat.outbox.entry(entry.id) == nil)
        #expect(chat.pending.isEmpty)
        #expect(SteerInbox.pending(tty: tty, root: chat.steerRoot).map(\.text) == ["use port 8080"])
    }

    /// A crash while the post waits on the lock: the message is in the outbox on disk, and the next launch offers it
    /// to send again or discard.
    @Test func aCrashWhileTheLockHoldsTheSteerLeavesItInTheOutbox() async throws {
        let home = temp.url("steer-crash")
        let root = home.appendingPathComponent("vibeswitcher")
        let folder = root.appendingPathComponent("steer")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let outboxFile = home.appendingPathComponent("outbox.json")
        // Held through the test (ended with it): the next launch comes before the post got through.
        let holder = try holdLock(folder.appendingPathComponent("\(tty).jsonl"), for: 60)
        defer { holder.process.terminate() }
        weak var gone: ChatModel?
        let entry: OutboxEntry
        do {
            let chat = ChatModel(outbox: ComposerOutbox(url: outboxFile), home: home.path, steerRoot: root)
            let sync = ChatSync(chat: chat, host: HostClient(socketPath: home.appendingPathComponent("no-host.sock").path, appKey: { nil }))
            entry = send("deploy to staging", chat: chat, sync: sync)
            #expect(chat.steerSending.count == 1)
            gone = chat
        }
        #expect(gone == nil, "the first launch's model is still alive")
        // The next launch, before the post got through.
        #expect(SteerInbox.pending(tty: tty, root: root).isEmpty)
        let relaunched = ChatModel(outbox: ComposerOutbox(url: outboxFile), home: home.path, steerRoot: root)
        let restored = relaunched.outbox.outbox.needsYou(key: key)
        #expect(restored.map(\.id) == [entry.id])
        #expect(restored.map(\.message) == ["deploy to staging"])
        #expect(restored.map(\.state) == [.sending])
    }

    /// One that can't get into the inbox leaves the strip and goes back into the composer's box, said under it.
    @Test func aSendThatCantBePostedGoesBackInTheBox() async throws {
        let (chat, sync, _) = try chat()
        defer { chat.composer.drafts[key] = nil; chat.composer.attachments[key] = nil; chat.composer.save() }
        #expect(sync.steer("use the staging database", key: key, tty: "not/a/tty", agentPid: agentPid))
        #expect(await until { chat.steering.isEmpty })
        #expect(chat.steerSending.isEmpty)
        #expect(chat.composer.drafts[key] == "use the staging database")
        #expect(chat.sendNotice != nil)
    }
}

extension SteerOffMainTests {
    /// From the composer: its outbox entry goes back into the box whole (images too), and leaves the outbox.
    @Test func aComposerSendThatCantBePostedGoesBackInTheBoxWithItsImages() async throws {
        let (chat, sync, _) = try chat()
        defer { chat.composer.drafts[key] = nil; chat.composer.attachments[key] = nil; chat.composer.save() }
        let entry = send("look at this /tmp/shot.png", attachments: ["/tmp/shot.png"], chat: chat, sync: sync, tty: "not/a/tty")
        #expect(chat.outbox.entry(entry.id) != nil)
        #expect(await until { chat.steering.isEmpty })
        #expect(chat.outbox.entry(entry.id) == nil)
        #expect(chat.pending.isEmpty)
        #expect(chat.composer.drafts[key] == "look at this /tmp/shot.png")
        #expect(chat.composer.attachments[key] == ["/tmp/shot.png"])
        #expect(chat.sendNotice != nil)
    }
}
