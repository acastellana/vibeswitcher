import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// `HostRequest.vaultV2` on a real host process (the engine plan's EN-D11): on Linux the host lists
/// `HostProtocol.Capability.vaultV2`, answers the app alone, and a scratch host's `--test-user-seal-life` sets how long
/// a `.user` seal verifies; the Mac's host doesn't list it and refuses every request.
@Suite(.serialized, hostTestLimit) struct VaultV2HostTests {
    private func ask(_ client: TestClient, _ request: LeadVaultV2.Request) async -> HostEvent? {
        let seq = client.send(.vaultV2(request))
        _ = await eventually { client.reply(to: seq) != nil || client.closed }
        return client.reply(to: seq)
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux: the server child is the app"))
    func theHostListsV2AndAnswersTheAppAlone() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (app, _, _, _, capabilities, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(capabilities?.contains(HostProtocol.Capability.vaultV2) == true)
        let recorded = await ask(app, .recordUserAction(action: "a1", kind: "answer", subject: "local:card:x", digest: "d1"))
        #expect(recorded == .vaultV2(.recorded(first: true)), "\(String(describing: recorded)) \(host.log)")
        #expect(await ask(app, .recordUserAction(action: "a1", kind: "answer", subject: nil, digest: "d1")) == .vaultV2(.recorded(first: false)))
        #expect(await ask(app, .holds(action: "a1", digest: "d1")) == .vaultV2(.holds(true)))
        // Another process, by the socket's path: not the app.
        let (other, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket)
        let refused = await ask(other, .holds(action: "a1", digest: "d1"))
        #expect(refused == .error(HostProtocol.unauthorized), "\(String(describing: refused))")
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux: a scratch host's test flag"))
    func aScratchHostsUserSealLifeIsItsTests() async throws {
        let host = try await ScratchHostProcess(arguments: ["--test-user-seal-life", "2"])
        defer { host.stop() }
        let (app, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        var message = SteerMessage(text: "yes", from: .user, agentPid: 0)
        guard case .seal(let seal)? = app.vault(.seal(message)) else { Issue.record("no seal: \(host.log)"); return }
        message.seal = seal
        #expect(app.vault(.verify([message])) == .verified([true]))
        // Past its life it verifies false, though its seal is the host's.
        #expect(await eventually(timeout: 30) { app.vault(.verify([message])) == .verified([false]) }, "\(host.log)")
    }

    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's host"))
    func theMacsHostRefusesV2() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (app, _, _, _, capabilities, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(capabilities?.contains(HostProtocol.Capability.vaultV2) != true)
        let reply = await ask(app, .recordUserAction(action: "a1", kind: "answer", subject: nil, digest: "d1"))
        guard case .vaultV2(.refused)? = reply else { Issue.record("not refused: \(String(describing: reply))"); return }
        #expect(!HostServer.capabilities.contains(HostProtocol.Capability.vaultV2))
    }
}
