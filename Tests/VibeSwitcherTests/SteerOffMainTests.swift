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

    /// Another process holding `file`'s lock for `seconds`; returns once it has it.
    func holdLock(_ file: URL, for seconds: Double) throws -> Process {
        let script = """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        sys.stdout.write("locked\\n"); sys.stdout.flush()
        time.sleep(float(sys.argv[2]))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", script, file.path, String(seconds)]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let line = String(decoding: out.fileHandleForReading.readData(ofLength: 7), as: UTF8.self)
        #expect(line == "locked\n")
        return process
    }

    @Test func aSendWhileAnotherProcessHoldsTheInboxReturnsAtOnceAndLandsWhenItsFree() async throws {
        let (chat, sync, file) = try chat()
        let holder = try holdLock(file, for: 3)
        defer { holder.terminate() }
        let started = Date()
        let accepted = sync.steer("use port 8080", key: "host:k", tty: tty, agentPid: agentPid)
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
        // Lands once the lock is free: steering (no longer sending), in the inbox, sealed as the user's.
        #expect(await until(timeout: 10) { chat.steerSending.isEmpty })
        #expect(Date().timeIntervalSince(started) > 2.5, "the lock wasn't held")
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
        defer { holder.terminate() }
        var taken: SteerMessage?
        let started = Date()
        chat.withdrawSteered(message) { taken = $0 }
        let returnedIn = Date().timeIntervalSince(started)
        #expect(returnedIn < 0.1, "the main-thread withdraw took \(returnedIn) s")
        #expect(taken == nil)
        #expect(chat.steering.map(\.id) == [message.id])
        #expect(await until(timeout: 10) { taken != nil })
        #expect(Date().timeIntervalSince(started) > 2.5, "the lock wasn't held")
        #expect(taken?.id == message.id)
        #expect(chat.steering.isEmpty)
        #expect(!chat.steeringStranded)
        #expect(SteerInbox.pending(tty: tty, root: chat.steerRoot).isEmpty)
    }

    /// A withdraw sent while its post is still waiting on the lock comes after it (one queue, in order).
    @Test func aWithdrawRightAfterASendWaitsForItsPost() async throws {
        let (chat, sync, file) = try chat()
        let holder = try holdLock(file, for: 1)
        defer { holder.terminate() }
        #expect(sync.steer("stop after this", key: "host:k", tty: tty, agentPid: agentPid))
        let message = try #require(chat.steering.first)
        var taken: SteerMessage?
        chat.withdrawSteered(message) { taken = $0 }
        #expect(await until(timeout: 10) { taken != nil })
        #expect(taken?.text == "stop after this")
        #expect(chat.steering.isEmpty)
        #expect(chat.steerSending.isEmpty)
        #expect(SteerInbox.pending(tty: tty, root: chat.steerRoot).isEmpty)
    }

    /// One that can't get into the inbox leaves the strip and goes back into the composer's box, said under it.
    @Test func aSendThatCantBePostedGoesBackInTheBox() async throws {
        let (chat, sync, _) = try chat()
        #expect(sync.steer("use the staging database", key: "host:k", tty: "not/a/tty", agentPid: agentPid))
        #expect(await until(timeout: 10) { chat.steering.isEmpty })
        #expect(chat.steerSending.isEmpty)
        #expect(chat.composer.drafts["host:k"] == "use the staging database")
        #expect(chat.sendNotice != nil)
    }
}
