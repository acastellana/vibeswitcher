import CryptoKit
import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// The app's own client and the lead's tool server typing text+Enter units into one session at once, on a scratch host
/// (its own socket, lock and key; never the user's) running a scratch program. Messaging audit 2026-10-22 #2: the
/// app's queue kept its own units whole, but the tool server's text and Enter went in on their own between them.
@MainActor
@Suite(.serialized)
struct InputUnitDeliveryTests {
    final class Scratch {
        /// The test bundle's own `Scratch` (this one's name hides it): holds the short folder the socket is in.
        let temp = VibeSwitcherTests.Scratch()
        let socket: String
        let server: HostServer
        let host: HostClient
        let folder: URL
        let key: SymmetricKey

        /// `capabilities`: the host's (one from before units leaves `inputUnits` out).
        @MainActor
        init(capabilities: [String] = HostServer.capabilities) throws {
            let key = SymmetricKey(size: .bits256)
            self.key = key
            let launcher = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
            socket = try temp.shortFolder("vsh-unit") + "/h.sock"
            folder = temp.url("units")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: launcher,
                                           baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                           hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
            config.idleExit = nil
            config.appKey = key
            config.appExecutable = HostServer.executable(of: getpid())
            config.capabilities = capabilities
            server = HostServer(config: config)
            try server.start()
            host = HostClient(socketPath: socket, appKey: { key })
        }

        deinit {
            server.stop(terminateSessions: true)
            unlink(socket + ".lock")
        }

        /// A session copying its lines (Enter ends one) to `out`; returned once its terminal stopped echoing.
        @MainActor
        func spawnLines() async throws -> (session: HostSession, out: String) {
            host.connectIfRunning()
            #expect(await until { self.host.state == .connected })
            let out = folder.appendingPathComponent("out").path, ready = folder.appendingPathComponent("ready").path
            var result: Result<HostSession, HostClientError>?
            host.spawn(SpawnRequest(cwd: folder.path, command: "stty -echo && : > '\(ready)' && exec cat > '\(out)'",
                                    env: [:], cols: 80, rows: 24, keepShell: false, label: "Lines", agent: nil)) { result = $0 }
            #expect(await until { result != nil })
            let session = try #require(result).get()
            #expect(await until { FileManager.default.fileExists(atPath: ready) })
            return (session, out)
        }

        nonisolated static func lines(_ path: String) -> [String] {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    final class Anchor {}

    /// The app's units and the tool server's, sent at once: `count` of each, every one a line.
    func sendAtOnce(_ scratch: Scratch, count: Int) async throws -> (got: [String], app: [String], tools: [String], typed: Int) {
        let (session, out) = try await scratch.spawnLines()
        let app = (0..<count).map { "app message \($0)" }, tools = (0..<count).map { "tool server message \($0)" }
        let socket = scratch.socket, id = session.id, key = scratch.key
        // The tool server's, as `HostRuntime.type` sends them: each on a connection of its own, off the main thread.
        let typing = Task.detached {
            tools.filter { text in
                (try? HostCall.type(HostInput.writes(text: text, submit: true, key: nil), into: id, socket: socket, appKey: key, timeout: hangGuard)) != nil
            }.count
        }
        // The app's, as the phone's replies and the lead's wake-ups: one unit each, on its queue.
        var confirmed = 0
        for text in app { scratch.host.send(id, writes: HostInput.writes(text: text, submit: true, key: nil), confirmed: { if $0 { confirmed += 1 } }) }
        let typed = await typing.value
        #expect(await until { confirmed == count && Scratch.lines(out).count >= 2 * count })
        return (Scratch.lines(out), app, tools, typed)
    }

    @Test func theAppsUnitsAndTheToolServersAtOnceGoInWhole() async throws {
        let scratch = try Scratch()
        let (got, app, tools, typed) = try await sendAtOnce(scratch, count: 10)
        #expect(scratch.host.hostCapabilities.contains(HostProtocol.Capability.inputUnits))
        #expect(typed == tools.count)
        #expect(got.sorted() == (app + tools).sorted(), "\(got)")
        #expect(got.filter { $0.hasPrefix("app") } == app)
        #expect(got.filter { $0.hasPrefix("tool") } == tools)
    }

    /// Audit F1, the verifier's case: the app's paced paste (`HostClient.send(_:bytes:reply:done:)`: a piece, then a
    /// screen read as its receipt) into a program that isn't reading yet, while another client holds the session
    /// between its unit's parts. The pieces waiting behind the unit were each answered as taken, then refused once it
    /// was over: the paste was told it went in, and lost most of itself.
    @Test func aPasteBehindAnotherClientsHeldUnitGoesInWhole() async throws {
        let scratch = try PasteDeliveryTests.Scratch()
        let (session, out, go) = try await scratch.spawnReader()
        // The other client (a tool server, say): its unit's first part in, the session held for the next.
        let queue = DispatchQueue(label: "holder")
        let holder = try HostConnection(path: scratch.socket, queue: queue, appKey: scratch.key)
        var answers: [Int: HostEvent] = [:]
        holder.onEvent = { envelope in if let seq = envelope.replyTo { DispatchQueue.main.async { answers[seq] = envelope.event } } }
        let held = try queue.sync { try holder.send(.inputUnit(id: session.id, writes: [HostInput.Write(bytes: Array("x".utf8), delay: 0)], more: true)) }
        #expect(await until { answers[held] != nil })
        #expect(answers[held] == .ok)
        var went: Bool?
        scratch.host.send(session.id, bytes: PasteDeliveryTests.paste, reply: false) { went = $0 }
        // The paste meanwhile gets as far as the host's room: then its pieces are refused, and sent again.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(went == nil)
        // The unit over (its part that won't come let go), the program starts reading.
        let release = try queue.sync { try holder.send(.inputUnit(id: session.id, writes: [], more: false)) }
        #expect(await until { answers[release] != nil })
        FileManager.default.createFile(atPath: go, contents: nil)
        let expected = Data("x".utf8) + PasteDeliveryTests.paste
        let got = await PasteDeliveryTests.received(out, expected)
        #expect(await until { went != nil })
        #expect(went == true)
        #expect(got.count == expected.count)
        #expect(got == expected, "first difference at \(zip(got, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(got.count, expected.count))")
        queue.sync { holder.close() }
    }

    @Test func anOlderHostStillGetsEveryonesTextAndEnter() async throws {
        let scratch = try Scratch(capabilities: HostServer.capabilities.filter { $0 != HostProtocol.Capability.inputUnits })
        let (session, out) = try await scratch.spawnLines()
        #expect(!scratch.host.hostCapabilities.contains(HostProtocol.Capability.inputUnits))
        // One after the other (at once, such a host can still interleave them: what this change is for), each the old way.
        var confirmed: Bool?
        scratch.host.send(session.id, writes: HostInput.writes(text: "from the app", submit: true, key: nil), confirmed: { confirmed = $0 })
        #expect(await until { confirmed != nil })
        #expect(confirmed == true)
        let socket = scratch.socket, id = session.id, key = scratch.key
        try await Task.detached {
            try HostCall.type(ComposerText.writes("from the tool server", bracketed: false), into: id, socket: socket, appKey: key, timeout: hangGuard)
        }.value
        #expect(await until { Scratch.lines(out).count >= 2 })
        #expect(Scratch.lines(out) == ["from the app", "from the tool server"])
    }
}
