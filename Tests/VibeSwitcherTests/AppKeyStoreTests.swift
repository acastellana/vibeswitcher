import CryptoKit
import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// The app proves itself to the host with the key its store holds (see `AppKeyStore`): the login Keychain in the app,
/// memory here, so no test reaches the Keychain (2026-10-19: a scratch HOME has no login keychain, and macOS answered
/// each test run's SecItem calls with a "Keychain Not Found" dialog in the user's face).
@MainActor
struct AppKeyStoreTests {
    let temp = Scratch()

    /// A store that counts how often it's asked.
    final class Counted: AppKeyStore, @unchecked Sendable {
        let held = AppProof.MemoryStore()
        private let lock = NSLock()
        private var asked = 0
        var reads: Int { lock.withLock { asked } }
        func key() -> SymmetricKey? {
            lock.withLock { asked += 1 }
            return held.key()
        }
    }

    @Test func aMemoryStoreKeepsTheKeyItMadeOrWasGiven() {
        let store = AppProof.MemoryStore()
        let key = store.key()
        #expect(key?.data.count == AppProof.keySize)
        #expect(store.key()?.data == key?.data)
        let given = SymmetricKey(size: .bits256)
        #expect(AppProof.MemoryStore(key: given).key()?.data == given.data)
    }

    /// The app's client reads its store once, however many connections it makes.
    @Test func theAppsKeyIsReadFromItsStoreOnce() {
        // The app's every other connection answers with it too (the one place it's set; nothing else here reads it).
        let before = HostConnection.appKey
        defer { HostConnection.appKey = before }
        let store = Counted()
        let key = HostClient.appKey(from: store)
        let first = key()
        #expect(first?.data == store.held.key()?.data)
        #expect(key()?.data == first?.data)
        #expect(store.reads == 1)
        #expect(HostConnection.appKey?.data == first?.data)
    }

    /// A client keyed from its store proves itself to a host that holds no key: the host takes it as the app's first
    /// key, and the connection is the app's.
    @Test func aHostWithNoKeyTakesTheStoresKeyAndTheClientProvesItself() async throws {
        let socket = try temp.shortFolder("vsh-ak") + "/h.sock"
        let book = LeadVault.Book()
        var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: "/usr/bin/true",
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": temp.url("home").path],
                                       hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
        config.idleExit = nil
        config.vault = book
        config.appExecutable = HostServer.executable(of: getpid())
        let server = HostServer(config: config)
        try server.start()
        defer {
            server.stop(terminateSessions: true)
            unlink(socket + ".lock")
        }
        let store = AppProof.MemoryStore()
        var notes: [String] = []
        let host = HostClient(socketPath: socket, appKey: { store.key() }, note: { notes.append($0) })
        host.connectIfRunning()
        #expect(await until { host.state == .connected })
        #expect(await until { book.appKey != nil })
        #expect(book.appKey?.data == store.key()?.data)
        #expect(!notes.contains { $0.contains("proof refused") })
    }
}
