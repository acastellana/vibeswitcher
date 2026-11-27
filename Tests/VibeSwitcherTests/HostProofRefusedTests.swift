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

        /// `vault`: the host keeps the app's key in it (none given here) instead of holding `key`.
        @MainActor
        init(vault: LeadVault.Book? = nil) throws {
            let launcher = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
            socket = try temp.shortFolder("vsh-proof") + "/h.sock"
            var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: launcher,
                                           baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                           hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
            config.idleExit = nil
            if let vault { config.vault = vault } else { config.appKey = key }
            config.appExecutable = HostServer.executable(of: getpid())
            server = HostServer(config: config)
            try server.start()
        }

        deinit {
            server.stop(terminateSessions: true)
            unlink(socket + ".lock")
        }

        /// The app's client with `key`, connected (welcomed), with nothing asked of the user (`teach`: as if you'd
        /// clicked Teach It This App's Key).
        @MainActor
        func client(_ key: SymmetricKey?, teach: Bool = false, asked: @escaping (String, Int) -> Void = { _, _ in }) async -> HostClient {
            let host = HostClient(socketPath: socket, appKey: { key }, note: { _ in })
            host.confirmKeyReset = { reason, live in asked(reason, live); return teach }
            host.connectIfRunning()
            #expect(await until { host.state == .connected })
            return host
        }
    }

    final class Anchor {}

    /// The alert says, before its button, that a reinstall or a Keychain reset does this and that another program may
    /// have replaced the key, and what to check first (2026-11-26: a process of your account can replace VibeSwitcher's
    /// Keychain keys). A vault that started over says so in its own words.
    @Test func theAlertNamesAReplacedKeyBeforeItsButton() {
        let refused = HostClient.keyResetAlert(reason: "That isn't the key this session host knows for VibeSwitcher.", live: 0)
        #expect(refused.messageText == "The session host doesn't recognise this VibeSwitcher.")
        for words in ["That isn't the key", "reinstalled", "Keychain is reset", "another program on this Mac replaced VibeSwitcher's key",
                      "Check first", "Keychain Access", "VibeSwitcher app key", "don't teach the host until"] {
            #expect(refused.informativeText.contains(words), "\(words)")
        }
        #expect(refused.buttons.map(\.title) == ["Teach It This App's Key", "Not Now"])
        let started = HostClient.keyResetAlert(reason: AppProof.vaultStartedOver, live: 0)
        #expect(started.messageText == "The team's vault could not be opened and was started again.")
        for words in ["Keychain reset", "another program on this Mac replaced the vault's key", "Check first", "VibeSwitcher lead vault",
                      "don't teach the host until", "kept as it was, at ~/.vibeswitcher/lead/vault.sealed",
                      "or is no longer there", "if you didn't move or delete it",
                      "nothing is saved over it until you answer", "vault.sealed.didnt-open-<date>"] {
            #expect(started.informativeText.contains(words), "\(words)")
        }
        #expect(started.buttons.map(\.title) == ["Teach It This App's Key", "Not Now"])
        // With sessions live, no button to teach: end them first.
        let live = HostClient.keyResetAlert(reason: AppProof.vaultStartedOver, live: 2)
        #expect(live.buttons.map(\.title) == ["OK"] && live.informativeText.contains("end every session (2 running)"))
    }

    /// A host whose vault started over takes the app's key only through that alert: the app is asked, in the
    /// started-over words, and only once you teach it does the app prove itself and see its sessions. Scratch vault
    /// (`VaultStorage(file:key:)` on a scratch file), the app's key from `AppProof.MemoryStore`.
    @Test func aStartedOverVaultAsksYouBeforeItTakesTheAppsKey() async throws {
        let temp = VibeSwitcherTests.Scratch()
        let file = temp.url("vault").appendingPathComponent("vault.sealed")
        let key = try #require(AppProof.MemoryStore().key())
        #expect(VaultStorage(file: file, key: SymmetricKey(size: .bits256)).book().adoptAppKey(key.data))
        let book = VaultStorage(file: file, key: SymmetricKey(size: .bits256)).book()
        let scene = try Scene(vault: book)

        var asked: [String] = []
        let declined = await scene.client(key) { reason, _ in asked.append(reason) }
        #expect(asked == [AppProof.vaultStartedOver] && declined.proofRefusal == AppProof.vaultStartedOver)
        #expect(book.appKey == nil)

        let taught = await scene.client(key, teach: true) { reason, _ in asked.append(reason) }
        #expect(await until { book.appKey?.data == key.data })
        #expect(await until { taught.state == .connected && taught.proofRefusal == nil })
        #expect(asked == [AppProof.vaultStartedOver, AppProof.vaultStartedOver])
    }

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
