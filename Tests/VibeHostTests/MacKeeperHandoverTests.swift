import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The Mac's switch through a proven keeper (the node on the Mac's design, "The checked node start", "A switch"; the
/// review of 2026-11-25, F6; docs/process/v2-mac-tasks.md item 13), end to end on scratch hosts: the old and new builds,
/// and a third image standing in for a file a session swapped in, are copies of the built host signed here ad hoc with
/// the Hardened Runtime, each under an identifier of its own (so each has a cdhash of its own). A scratch host's test
/// flag stands for the record: `--handover-test-keeper HEX`, the host code a switch may go to (a checked node host takes
/// it from the record instead, `HandoverTarget.macPinned`; the record's path isn't a host process's to choose). Mac only.
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's switch through a keeper: code identity"), .serialized, hostTestLimit)
struct MacKeeperHandoverTests {
    /// `path` signed ad hoc with the Hardened Runtime as `identifier`, its modification time kept (the host's build id
    /// is read from it): its cdhash.
    static func sign(_ path: String, _ identifier: String) throws -> Data {
        let kept = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "-s", "-", "-o", "runtime", "-i", identifier, path]
        try codesign.run()
        codesign.waitUntilExit()
        try #require(codesign.terminationStatus == 0)
        if let kept { try FileManager.default.setAttributes([.modificationDate: kept], ofItemAtPath: path) }
        return try #require(Platform.CodeIdentity.cdhash(atPath: path))
    }

    /// The images of a scene: the new build's cdhash and the swapped-in image's path.
    final class Images: @unchecked Sendable {
        var new = Data()
        var evil = ""
        var server = ""
    }

    /// A scratch host on hardened copies of the built host, with `arguments(images)` and, when `server`, a hardened
    /// copy of the built server as its server child (its root the scratch folder, so its socket is the root's).
    func host(server: Bool = false, _ arguments: @escaping (Images) -> [String]) async throws -> (ScratchHostProcess, Images) {
        let images = Images()
        var extra: [String] = []
        let host = try await ScratchHostProcess(socketName: server ? "host.sock" : "h.sock", rootIsScratch: server, prepare: { dir in
            _ = try Self.sign(dir + "/old/vibeswitcher-host", "dev.vibeswitcher.test.keeper.old")
            images.new = try Self.sign(dir + "/new/vibeswitcher-host", "dev.vibeswitcher.test.keeper.new")
            try FileManager.default.createDirectory(atPath: dir + "/evil", withIntermediateDirectories: true)
            try installProgram(hostLauncher, atPath: dir + "/evil/vibeswitcher-host")
            _ = try Self.sign(dir + "/evil/vibeswitcher-host", "dev.vibeswitcher.test.keeper.evil")
            images.evil = dir + "/evil/vibeswitcher-host"
            if server {
                try FileManager.default.createDirectory(atPath: dir + "/server", withIntermediateDirectories: true)
                images.server = dir + "/server/vibeswitcher-server"
                let built = (hostLauncher as NSString).deletingLastPathComponent + "/" + BuildInfo.server
                try #require(FileManager.default.fileExists(atPath: built), "the built server isn't beside the host: \(built)")
                try installProgram(built, atPath: images.server)
                _ = try Self.sign(images.server, "dev.vibeswitcher.test.keeper.server")
            }
            extra = arguments(images) + (server ? ["--server", images.server] : [])
        }, late: { extra })
        return (host, images)
    }

    /// A scene: a host as `host` makes it, a client welcomed as the app, a counter session counting.
    func scene(server: Bool = false, _ arguments: @escaping (Images) -> [String]) async throws
        -> (host: ScratchHostProcess, images: Images, client: TestClient, counter: HostSession, startedAt: Date?) {
        let (host, images) = try await self.host(server: server, arguments)
        let (client, _, _, _, _, pid, startedAt) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(pid == host.pid)
        let counter = try await client.spawn(HostHandoverTests.counter)
        await client.attach(counter.id)
        #expect(await eventually { counted(client.text(counter.id)).last ?? 0 >= 3 })
        return (host, images, client, counter, startedAt)
    }

    /// Asks for a handover to the new build's path: the answer.
    func handOver(_ client: TestClient, _ host: ScratchHostProcess) async -> HostEvent? {
        let seq = client.send(.handover(executable: host.newBinary))
        _ = await eventually { client.reply(to: seq) != nil }
        return client.reply(to: seq)
    }

    /// The host as it was: the same process running the old build, started then, its counter still counting.
    func expectAsItWas(_ host: ScratchHostProcess, startedAt: Date?, counter: HostSession) async throws {
        let (client, _, _, sessions, _, pid, started) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(pid == host.pid && started == startedAt && host.process.isRunning)
        #expect(host.runningExecutable == URL(fileURLWithPath: host.oldBinary).resolvingSymlinksInPath().path)
        #expect(sessions.contains { $0.id == counter.id && $0.isLive })
        await client.attach(counter.id)
        let before = counted(client.text(counter.id)).last ?? 0
        #expect(await eventually { counted(client.text(counter.id)).last ?? 0 >= before + 3 }, "the counter stopped")
        #expect(!FileManager.default.fileExists(atPath: host.lock + ".handover"), "a state file was written")
    }

    /// (c) A switch to an image the test doesn't pin: refused before anything runs; the old host as it was.
    @Test func aSwitchToAnImageNotPinnedHandsOverNothing() async throws {
        let scene = try await scene { _ in ["--handover-test-keeper", String(repeating: "0f", count: 20)] }
        defer { scene.host.stop() }
        let answer = await handOver(scene.client, scene.host)
        guard case .error(let why)? = answer else { Issue.record("answered \(String(describing: answer)): \(scene.host.log)"); return }
        #expect(why.contains("isn't the host this scratch host's test pins"), "\(why)")
        try await expectAsItWas(scene.host, startedAt: scene.startedAt, counter: scene.counter)
    }

    /// (c) The target swapped after the path check (F6's window): the keeper started from the path runs the swapped
    /// code, its fresh token proves it, and the switch is refused before any state or descriptor is handed over; the old
    /// host as it was. Red before: the path was checked, then executed, and the swapped image took the sessions.
    @Test func aTargetSwappedAfterThePathCheckHandsOverNothing() async throws {
        let scene = try await scene { ["--handover-test-keeper", NodePins.hex($0.new), "--handover-test-swap-after-check", $0.evil] }
        defer { scene.host.stop() }
        let answer = await handOver(scene.client, scene.host)
        guard case .error(let why)? = answer else { Issue.record("answered \(String(describing: answer)): \(scene.host.log)"); return }
        #expect(why.contains("the keeper") && why.contains("doesn't run the code checked"), "\(why)")
        try await expectAsItWas(scene.host, startedAt: scene.startedAt, counter: scene.counter)
    }

    /// (c) The target swapped after the keeper's proof, just before the exec (the window that stays): the swapped image
    /// runs at the host's pid and asks the keeper, which refuses it: it gets no state, no secret, no terminal, no lock
    /// and no listener, and exits; the sessions end with it (the residual the design states). Red before: the swapped
    /// image inherited every descriptor and the state, and served the sessions.
    @Test func aTargetSwappedJustBeforeTheExecGetsNothing() async throws {
        let scene = try await scene { ["--handover-test-keeper", NodePins.hex($0.new), "--handover-test-swap-before-exec", $0.evil] }
        defer { scene.host.stop() }
        _ = await handOver(scene.client, scene.host)
        #expect(await eventually { !scene.host.process.isRunning }, "the swapped image runs on: \(scene.host.log)")
        #expect(scene.host.log.contains("handover keeper: refused the new image"), "\(scene.host.log)")
        #expect(!scene.host.log.contains("took over"), "the swapped image took the sessions over: \(scene.host.log)")
        #expect(!FileManager.default.fileExists(atPath: scene.host.lock + ".handover"), "a state file was written")
        #expect(await eventually { kill(scene.counter.childPID, 0) != 0 }, "a session runs on with no host")
    }

    /// (d) A switch to the pinned build: the server child is ended and reaped before the exec, and after it the new image
    /// runs a new one (another pid) whose connector, a pair the new image made, is the app's again: so its connector
    /// check runs against the new image's code. The sessions carry on. Red before: the old child was left to see its
    /// connector close after the exec, unreaped, and the new image's never replaced a checked one.
    @Test func afterASwitchTheServerChildIsANewProcess() async throws {
        let scene = try await scene(server: true) { ["--handover-test-keeper", NodePins.hex($0.new)] }
        defer { scene.host.stop() }
        // The server's own word that it reached the host through its connector and was welcomed (its stderr, the host's).
        let connected = "vibeswitcher-server: host link: welcome"
        #expect(await eventually(timeout: 120) { scene.host.log.contains(connected) }, "\(scene.host.log)")
        let first = try #require(Self.lastChild(scene.host.log), "\(scene.host.log)")
        let answer = await handOver(scene.client, scene.host)
        #expect(answer == .ok, "\(scene.host.log)")
        #expect(await eventually { scene.host.log.contains("took over 1 sessions") }, "\(scene.host.log)")
        #expect(scene.host.log.contains("server child pid \(first) ended for the handover"), "\(scene.host.log)")
        #expect(await eventually(timeout: 120) { Self.lastChild(scene.host.log).map { $0 != first } == true
                && scene.host.log.components(separatedBy: connected).count >= 3 }, "\(scene.host.log)")
        #expect(kill(first, 0) != 0 && errno == ESRCH, "the old server child is still there (unreaped)")
        let (client, _, _, sessions, _, pid, startedAt) = try await TestClient.welcomed(scene.host.socket, appKey: scene.host.appKey)
        #expect(pid == scene.host.pid && startedAt == scene.startedAt)
        #expect(scene.host.runningExecutable == URL(fileURLWithPath: scene.host.newBinary).resolvingSymlinksInPath().path)
        #expect(sessions.contains { $0.id == scene.counter.id && $0.isLive })
        await client.attach(scene.counter.id)
        #expect(await eventually { counted(client.text(scene.counter.id)).count >= 3 })
        #expect(!FileManager.default.fileExists(atPath: scene.host.lock + ".handover"), "a state file was written")
    }

    /// The pid of the last server child the log says started.
    static func lastChild(_ text: String) -> pid_t? {
        text.components(separatedBy: "\n").last { $0.contains("server child pid ") && $0.contains(" started from ") }
            .flatMap { $0.components(separatedBy: "server child pid ").last?.split(separator: " ").first }.flatMap { pid_t(String($0)) }
    }
}
