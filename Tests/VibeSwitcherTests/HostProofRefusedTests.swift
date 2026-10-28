import CryptoKit
import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// A host that doesn't take the app's proof (another key: the Keychain item was deleted, or another build's) shows the
/// app none of its sessions. The app says so, rather than showing an empty list as if there were none. On a scratch
/// host (its own socket, lock and key; never the user's) running a scratch program.
@MainActor
@Suite(.serialized)
struct HostProofRefusedTests {
    final class Scene {
        let temp = VibeSwitcherTests.Scratch()
        let socket: String
        let server: HostServer
        let key = SymmetricKey(size: .bits256)

        @MainActor
        init() throws {
            let launcher = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
            socket = try temp.shortFolder("vsh-proof") + "/h.sock"
            var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: launcher,
                                           baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                           hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
            config.idleExit = nil
            config.appKey = key
            config.appExecutable = HostServer.executable(of: getpid())
            server = HostServer(config: config)
            try server.start()
        }

        deinit {
            server.stop(terminateSessions: true)
            unlink(socket + ".lock")
        }

        /// The app's client with `key`, connected (welcomed), with nothing asked of the user.
        @MainActor
        func client(_ key: SymmetricKey?, asked: @escaping (String, Int) -> Void = { _, _ in }) async -> HostClient {
            let host = HostClient(socketPath: socket, appKey: { key }, note: { _ in })
            host.confirmKeyReset = { reason, live in asked(reason, live); return false }
            host.connectIfRunning()
            #expect(await until { host.state == .connected })
            return host
        }
    }

    final class Anchor {}

    @Test func aRefusedProofIsShownNotAnEmptyList() async throws {
        let scene = try Scene()
        let app = await scene.client(scene.key)
        var spawned: Result<HostSession, HostClientError>?
        app.spawn(SpawnRequest(cwd: scratchRoot.path, command: "sleep 3600", env: [:], cols: 80, rows: 24, keepShell: false,
                               label: "Proof", agent: nil)) { spawned = $0 }
        #expect(await until { spawned != nil })
        let session = try #require(spawned).get()
        #expect(app.proofRefusal == nil)

        var asked: [String] = []
        let stranger = await scene.client(SymmetricKey(size: .bits256)) { reason, _ in asked.append(reason) }
        #expect(stranger.proofRefusal != nil)
        #expect(asked.count == 1 && asked.first == stranger.proofRefusal)
        // Connected, and shown nothing: the refusal is what the window shows.
        #expect(stranger.sessions.isEmpty)

        // No key at all (the Keychain wouldn't give it): nothing to prove with, said as plainly.
        let keyless = await scene.client(nil)
        #expect(keyless.proofRefusal == HostConnection.noKey)
        #expect(keyless.sessions.isEmpty)

        // The app's own key: proved, its sessions shown.
        #expect(app.sessions.contains { $0.id == session.id })
        let again = await scene.client(scene.key)
        #expect(again.proofRefusal == nil)
        #expect(again.sessions.contains { $0.id == session.id })
    }
}
