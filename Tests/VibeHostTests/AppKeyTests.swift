import CryptoKit
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// How the host comes to hold the app's key (see `AppProof`), and the only ways it changes. Here the app's code is
/// `/usr/bin/nc`, driven by the test; this test process is some other program.
extension LeadVaultHostTests {
    func sessionLog() -> String { folder.appendingPathComponent("host.log").path }

    func logged(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    func sealed(_ event: HostEvent?) -> Bool {
        if case .vault(.seal)? = event { return true }
        return false
    }

    /// The key is never written to the log, nor an answer to a challenge.
    func expectNoSecrets(_ log: String, _ keys: [SymmetricKey]) {
        for key in keys {
            for form in [key.data.base64EncodedString(), key.data.map { String(format: "%02x", $0) }.joined()] {
                #expect(!log.contains(form))
            }
        }
    }

    @Test func aHeldKeyIsReplacedOnlyByTheAppsCodeWhileNoSessionRuns() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = LeadVault.Book()
        let host = try TestHost(vault: book, appExecutable: "/usr/bin/nc", log: sessionLog())
        let other = try TestClient(host, asApp: false)
        let session = try other.spawn("sleep 30")
        let fresh = SymmetricKey(size: .bits256)
        let message = SteerMessage(text: "x", from: .user, agentPid: 1)

        // While a session runs, not even the app's code.
        guard case .error? = try viaNC(host.socket, proof: nil, [.replaceAppKey(key: fresh.data)])[2] else { Issue.record("replaced with a session live"); return }
        #expect(book.appKey?.data == host.appKey.data)
        kill(-session.childPID, SIGKILL)
        #expect(eventually { other.latest(session.id)?.isLive == false })
        // No session, but not the app's code.
        let seq = other.send(.replaceAppKey(key: fresh.data))
        #expect(eventually { other.reply(to: seq) != nil })
        guard case .error? = other.reply(to: seq) else { Issue.record("replaced by another program"); return }
        #expect(book.appKey?.data == host.appKey.data)
        // The app's code, no session: replaced, and logged.
        #expect(try viaNC(host.socket, proof: nil, [.replaceAppKey(key: fresh.data)])[2] == .ok)
        #expect(book.appKey?.data == fresh.data)
        #expect(logged(sessionLog()).contains("replaced the app's key"))
        #expect(logged(sessionLog()).contains("refused to replace the app's key"))
        // Only the new key proves the app now.
        #expect(sealed(try viaNC(host.socket, proof: fresh, [.vault(.seal(message))])[2]))
        #expect(refused(try viaNC(host.socket, proof: host.appKey, [.vault(.seal(message))])[2]))
        expectNoSecrets(logged(sessionLog()), [fresh, host.appKey])
    }

    @Test func aHostWithNoKeyTakesOnlyTheFirstFromTheAppsCode() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = LeadVault.Book()
        let host = try TestHost(vault: book, appExecutable: "/usr/bin/nc", log: sessionLog(), holdsKey: false)
        let message = SteerMessage(text: "x", from: .user, agentPid: 1)
        // Another program, answering as the app does (it gives a keyless host its key first): not taken.
        let impostor = SymmetricKey(size: .bits256)
        let other = try TestClient(socket: host.socket, appKey: impostor)
        let hello = other.send(.hello(protocolVersion: HostProtocol.version, app: "x"))
        #expect(eventually { other.reply(to: hello) != nil })
        let screen = other.send(.screen(id: UUID()))
        #expect(eventually { other.reply(to: screen) != nil })
        #expect(book.appKey == nil)

        // The app's code: its key is the first, and the only one.
        let first = SymmetricKey(size: .bits256), second = SymmetricKey(size: .bits256)
        _ = try viaNC(host.socket, proof: nil, [.enrollApp(key: first.data)])
        #expect(book.appKey?.data == first.data)
        #expect(logged(sessionLog()).contains("took the app's first key"))
        _ = try viaNC(host.socket, proof: nil, [.enrollApp(key: second.data)])
        #expect(book.appKey?.data == first.data)
        #expect(sealed(try viaNC(host.socket, proof: first, [.vault(.seal(message))])[2]))
        #expect(refused(try viaNC(host.socket, proof: second, [.vault(.seal(message))])[2]))
        expectNoSecrets(logged(sessionLog()), [first, second, impostor])
    }
}
