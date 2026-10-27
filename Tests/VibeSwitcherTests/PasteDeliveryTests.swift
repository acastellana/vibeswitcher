import CryptoKit
import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// E-07: a paste larger than the host's input buffer (1 MB) through the app's own client, on a scratch host (its own
/// socket, lock and key; never the user's) running scratch programs. It goes in whole and in order, or the user is
/// told exactly how much of it did; never cut while the sender hears nothing.
@MainActor
@Suite(.serialized)
struct PasteDeliveryTests {
    final class Scratch {
        /// The test bundle's own `Scratch` (this one's name hides it): holds the short folder the socket is in.
        let temp = VibeSwitcherTests.Scratch()
        let socket: String
        let server: HostServer
        let host: HostClient
        let key: SymmetricKey
        let folder = scratchRoot.appendingPathComponent("paste-\(UUID().uuidString.prefix(8))")

        @MainActor
        init() throws {
            let launcher = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
            socket = try temp.shortFolder("vsh-paste") + "/h.sock"
            let key = SymmetricKey(size: .bits256)
            self.key = key
            var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: launcher,
                                           baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                           hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
            config.idleExit = nil
            config.appKey = key
            config.appExecutable = HostServer.executable(of: getpid())
            server = HostServer(config: config)
            try server.start()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            host = HostClient(socketPath: socket, appKey: { key })
        }

        deinit {
            server.stop(terminateSessions: true)
            unlink(socket + ".lock")
            try? FileManager.default.removeItem(at: folder)
        }

        /// A program that reads nothing until `go` exists, then copies its input, as is, to `out`. Returned once its
        /// terminal is raw: before that the line discipline keeps 1,024 bytes of a line and drops the rest unread (on a
        /// busy Mac the first piece of a paste got there first, and the program never saw 255 KB of it).
        @MainActor
        func spawnReader() async throws -> (session: HostSession, out: String, go: String) {
            host.connectIfRunning()
            #expect(await until { self.host.state == .connected })
            let out = folder.appendingPathComponent("out").path, go = folder.appendingPathComponent("go").path
            let raw = folder.appendingPathComponent("raw").path
            var result: Result<HostSession, HostClientError>?
            host.spawn(SpawnRequest(cwd: "/tmp", command: "stty raw -echo && : > \(raw); while [ ! -e \(go) ]; do sleep 0.05; done; exec cat > \(out)",
                                    env: [:], cols: 80, rows: 24, keepShell: false, label: "Paste", agent: nil)) { result = $0 }
            #expect(await until { result != nil })
            let session = try #require(result).get()
            #expect(await until { FileManager.default.fileExists(atPath: raw) })
            return (session, out, go)
        }
    }

    final class Anchor {}

    /// 3 MB of letters, the letter changing every 1,000 bytes: a missing or misplaced piece shows.
    static let paste = Data((0..<(3 << 20)).map { UInt8(ascii: "A") + UInt8(($0 / 1_000) % 26) })

    static func contents(_ path: String) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data() }

    /// What the program got, once it got all of `expected` or something else (a byte missing, misplaced or extra):
    /// the wait ends on what the test checks, however slowly the machine copies it.
    static func received(_ path: String, _ expected: Data) async -> Data {
        var got = Data()
        _ = await until {
            got = contents(path)
            return got.count >= expected.count || !expected.starts(with: got)
        }
        return got
    }

    @Test func aPasteBeyondTheBufferGoesInWholeOnceTheProgramReads() async throws {
        let scratch = try Scratch()
        let (session, out, go) = try await scratch.spawnReader()
        // Nothing here is cut: the 30 s a busy Mac can spend between pieces isn't the program stopping.
        scratch.host.inputStallLimit = hangGuard
        var cuts: [(Int, Int, String)] = []
        scratch.host.onInputCut = { _, went, total, reason in cuts.append((went, total, reason)) }
        var done: Bool?
        scratch.host.send(session.id, bytes: Self.paste, reply: false) { done = $0 }
        // It isn't read for a while: the host's buffer fills and refuses the rest, which waits instead of being lost.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(done == nil)
        #expect(FileManager.default.createFile(atPath: go, contents: nil))
        #expect(await until { done != nil })
        #expect(done == true)
        #expect(await Self.received(out, Self.paste) == Self.paste)
        #expect(cuts.isEmpty)
    }

    @Test func aPasteThatCantGoInSaysHowMuchDid() async throws {
        let scratch = try Scratch()
        let (session, out, go) = try await scratch.spawnReader()
        scratch.host.inputStallLimit = 1
        var cuts: [(went: Int, total: Int, reason: String)] = []
        scratch.host.onInputCut = { _, went, total, reason in cuts.append((went, total, reason)) }
        // The terminal's paste: no one waits on it, so the user is the one told.
        scratch.host.send(session.id, bytes: Self.paste, reply: false)
        #expect(await until { !cuts.isEmpty })
        let cut = try #require(cuts.first)
        #expect(cut.total == Self.paste.count)
        #expect(cut.went > 0 && cut.went < cut.total, "\(cut.went)")
        #expect(cut.reason.contains("stopped reading"), "\(cut.reason)")
        // What it said went in is exactly what the program gets: the start of the paste, nothing after.
        #expect(FileManager.default.createFile(atPath: go, contents: nil))
        #expect(await Self.received(out, Self.paste.prefix(cut.went)) == Self.paste.prefix(cut.went))
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(Self.contents(out) == Self.paste.prefix(cut.went))
        #expect(cuts.count == 1)
    }

    @Test func theComposerHearsItDidntGoInAndItsEnterIsntSent() async throws {
        let scratch = try Scratch()
        let (session, out, go) = try await scratch.spawnReader()
        scratch.host.inputStallLimit = 1
        var cuts = 0
        scratch.host.onInputCut = { _, _, _, _ in cuts += 1 }
        var confirmed: Bool?
        let writes = [HostInput.Write(bytes: [UInt8](Self.paste), delay: 0), HostInput.Write(bytes: [0x0D], delay: 0.05)]
        scratch.host.send(session.id, writes: writes) { confirmed = $0 }
        #expect(await until { confirmed != nil })
        #expect(confirmed == false)
        // The composer keeps the message (its outbox): the client doesn't tell the user a second time.
        #expect(cuts == 0)
        #expect(FileManager.default.createFile(atPath: go, contents: nil))
        #expect(await until { !Self.contents(out).isEmpty })
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let got = Self.contents(out)
        #expect(!got.isEmpty && got.count < Self.paste.count)
        #expect(got == Self.paste.prefix(got.count))
        #expect(!got.contains(0x0D))
    }

    @Test func keysAndSmallWritesStillGoAtOnceAndInOrder() async throws {
        let scratch = try Scratch()
        let (session, out, go) = try await scratch.spawnReader()
        #expect(FileManager.default.createFile(atPath: go, contents: nil))
        scratch.host.inputStallLimit = hangGuard
        var cuts = 0
        scratch.host.onInputCut = { _, _, _, _ in cuts += 1 }
        // A big paste, then keys typed while it goes in: they follow it, not cut into it.
        scratch.host.send(session.id, bytes: Self.paste, reply: false)
        scratch.host.send(session.id, bytes: Data("zz".utf8), reply: false)
        var confirmed: Bool?
        scratch.host.send(session.id, writes: [HostInput.Write(bytes: Array("!".utf8), delay: 0)]) { confirmed = $0 }
        #expect(await until { confirmed != nil })
        #expect(confirmed == true)
        let expected = Self.paste + Data("zz!".utf8)
        #expect(await Self.received(out, expected) == expected)
        #expect(cuts == 0)
    }
}
