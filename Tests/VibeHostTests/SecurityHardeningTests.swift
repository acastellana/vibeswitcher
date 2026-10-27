import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

struct HostSecurityHardeningTests {
    @Test func unknownClientsCannotReadMutateOrSubscribeToSessions() throws {
        let host = try TestHost(vault: LeadVault.Book())
        let app = try TestClient(host)
        let other = try TestClient(host, asApp: false)
        defer { app.close(); other.close() }
        let session = try app.spawn("echo SYNTHETIC_PRIVATE; " + keepRunning)
        let hello = other.send(.hello(protocolVersion: HostProtocol.version, app: "untrusted"))
        #expect(eventually { other.reply(to: hello) != nil })
        guard case .welcome(_, _, let list, _, _, _) = other.reply(to: hello) else {
            Issue.record("No welcome"); return
        }
        #expect(list.isEmpty)
        let requests: [HostRequest] = [
            .spawn(SpawnRequest(cwd: scratchRoot.path, command: "exit 0", env: [:], cols: 80, rows: 24,
                                keepShell: false, label: "untrusted", agent: nil)),
            .attach(id: session.id, cols: 20, rows: 10), .screen(id: session.id),
            .styledScreen(id: session.id), .history(id: session.id, lines: 20),
            .input(id: session.id, bytes: Data("synthetic\n".utf8), reply: false),
            .inputUnit(id: session.id, writes: [.init(bytes: [13], delay: 0)], more: false),
            .resize(id: session.id, cols: 20, rows: 10), .remove(id: session.id), .shutdown,
        ]
        let sent = requests.map { other.send($0) }
        // A final answered request is a barrier for earlier requests that used to be silent.
        let barrier = other.send(.hello(protocolVersion: HostProtocol.version, app: "barrier"))
        #expect(eventually { other.reply(to: barrier) != nil })
        for seq in sent {
            guard case .error? = other.reply(to: seq) else {
                Issue.record("Unauthorized request \(seq) was not refused"); continue
            }
        }
        #expect(!other.hasEvent { if case .sessionChanged = $0 { return true }; return false })
        #expect(other.text(session.id).isEmpty)
        #expect(app.screen(session.id) != nil)
    }

    @Test func appHelloWaitsForProofBeforeReturningItsSessions() throws {
        let host = try TestHost(vault: LeadVault.Book())
        let creator = try TestClient(host)
        defer { creator.close() }
        let session = try creator.spawn(keepRunning)
        let app = try TestClient(host)
        defer { app.close() }
        let seq = app.send(.hello(protocolVersion: HostProtocol.version, app: "app"))
        #expect(eventually { app.reply(to: seq) != nil })
        guard case .welcome(_, _, let list, _, _, _) = app.reply(to: seq) else {
            Issue.record("No authenticated welcome"); return
        }
        #expect(list.contains { $0.id == session.id })
    }

    @Test func idleClientsCannotExhaustTheHostsDescriptors() throws {
        let host = try TestHost()
        var clients: [TestClient] = []
        defer { clients.forEach { $0.close() } }
        for _ in 0..<128 {
            let client = try TestClient(host, asApp: false)
            clients.append(client)
            let seq = client.send(.hello(protocolVersion: HostProtocol.version, app: "capacity"))
            #expect(eventually { client.reply(to: seq) != nil || client.closed })
        }
        let overflow = try TestClient(host, asApp: false)
        clients.append(overflow)
        let seq = overflow.send(.hello(protocolVersion: HostProtocol.version, app: "overflow"))
        #expect(eventually { overflow.reply(to: seq) != nil || overflow.closed })
        #expect(overflow.closed)
    }

    @Test func sessionCapacityIsEnforcedAndRemovingAnEndedSessionRestoresRoom() throws {
        let host = try TestHost(maxSessions: 1)
        let app = try TestClient(host)
        defer { app.close() }
        let first = try app.spawn("exit 0")
        #expect(eventually { app.latest(first.id)?.isLive == false })
        let request = SpawnRequest(cwd: scratchRoot.path, command: "exit 0", env: [:], cols: 80, rows: 24,
                                   keepShell: false, label: "capacity", agent: nil)
        let refused = app.send(.spawn(request))
        #expect(eventually { app.reply(to: refused) != nil })
        guard case .error? = app.reply(to: refused) else { Issue.record("Session cap bypassed"); return }
        let removed = app.send(.remove(id: first.id))
        #expect(eventually { app.reply(to: removed) == .ok })
        _ = try app.spawn("exit 0")
    }
}
