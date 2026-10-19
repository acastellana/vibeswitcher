import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// E-14: the steer inbox's lock is held by others for seconds (a hook's delivery checks seals through the host with a
/// 5 s timeout), and the composer's send and the strip's withdraw took it on the main thread: the window froze for as
/// long. Here another process holds the lock for 3 s, and the main-thread call still returns at once; the message
/// lands (or comes back) once the lock is free, shown as sending meanwhile.
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

    /// Another process holding a file's lock, and when it took it (by its own clock, so a slow start or a late read of
    /// its line under load doesn't count as time held).
    struct Holder {
        let process: Process
        let lockedAt: Date
    }

    /// Another process holding `file`'s lock for `seconds` from when it took it; returns once it has it.
    func holdLock(_ file: URL, for seconds: Double) throws -> Holder {
        let script = """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        sys.stdout.write("locked %r\\n" % time.time()); sys.stdout.flush()
        time.sleep(float(sys.argv[2]))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", script, file.path, String(seconds)]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        var line = Data()
        while let byte = try out.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) { line += byte }
        let words = String(decoding: line, as: UTF8.self).split(separator: " ")
        let lockedAt = try #require(words.count == 2 && words[0] == "locked" ? Double(words[1]) : nil, "the holder said \(words)")
        return Holder(process: process, lockedAt: Date(timeIntervalSince1970: lockedAt))
    }

    @Test func aSendWhileAnotherProcessHoldsTheInboxReturnsAtOnceAndLandsWhenItsFree() async throws {
        let (chat, sync, file) = try chat()
        let holder = try holdLock(file, for: 3)
        defer { holder.process.terminate() }
        let started = Date()
        let accepted = sync.steer("use port 8080", key: key, tty: tty, agentPid: agentPid)
        let returnedIn = Date().timeIntervalSince(started)
        #expect(accepted)
        #expect(returnedIn < 0.1, "the main-thread send took \(returnedIn) s")
        // Meanwhile: in the chat as sending, not in the inbox yet; a heartbeat doesn't drop it.
        let id = try #require(chat.steering.first?.id)
        #expect(chat.steering.map(\.text) == ["use port 8080"])
        #expect(chat.steerSending == [id])
        #expect(SteerInbox.pending(tty: tty, root: chat.steerRoot).isEmpty)
        chat.watchSteering(tty: tty, agentPid: agentPid, idle: false)
        chat.refreshSteering()
        #expect(chat.steering.map(\.text) == ["use port 8080"])
        // Lands once the lock is free: steering (no longer sending), in the inbox, sealed as the user's. The wait ends
        // when the post is in (the hang guard only bounds it); one that landed while the holder slept its 3 s, counted
        // from when it took the lock, would come in under 2.5 s. The lock goes with the holder's exit, which Process
        // learns of a moment later, so that's waited for too.
        #expect(await until { chat.steerSending.isEmpty })
        #expect(Date().timeIntervalSince(holder.lockedAt) > 2.5, "it landed while the lock was held")
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
        let holder = try holdLock(file, for: 3)
        defer { holder.process.terminate() }
        var taken: SteerMessage?
        let started = Date()
        chat.withdrawSteered(message) { taken = $0 }
        let returnedIn = Date().timeIntervalSince(started)
        #expect(returnedIn < 0.1, "the main-thread withdraw took \(returnedIn) s")
        #expect(taken == nil)
        #expect(chat.steering.map(\.id) == [message.id])
        #expect(await until { taken != nil })
        #expect(Date().timeIntervalSince(holder.lockedAt) > 2.5, "it was taken while the lock was held")
        #expect(await until { !holder.process.isRunning })
        #expect(taken?.id == message.id)
        #expect(chat.steering.isEmpty)
        #expect(!chat.steeringStranded)
        #expect(SteerInbox.pending(tty: tty, root: chat.steerRoot).isEmpty)
    }

    /// A withdraw sent while its post is still waiting on the lock comes after it (one queue, in order).
    @Test func aWithdrawRightAfterASendWaitsForItsPost() async throws {
        let (chat, sync, file) = try chat()
        let holder = try holdLock(file, for: 1)
        defer { holder.process.terminate() }
        #expect(sync.steer("stop after this", key: key, tty: tty, agentPid: agentPid))
        let message = try #require(chat.steering.first)
        var taken: SteerMessage?
        chat.withdrawSteered(message) { taken = $0 }
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
        let holder = try holdLock(file, for: 1)
        defer { holder.process.terminate() }
        let entry = send("use port 8080", chat: chat, sync: sync)
        #expect(chat.outbox.entry(entry.id)?.state == .sending)
        #expect(chat.pending.isEmpty)
        #expect(chat.steering.map(\.text) == ["use port 8080"])
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
        let holder = try holdLock(folder.appendingPathComponent("\(tty).jsonl"), for: 3)
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
