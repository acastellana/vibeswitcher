import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Which host's vault holds its first look (the stage 2 plan's Task 10e, S2-D3; `VaultFirstLook`): on Linux the node's
/// host with no vault restored from a handover, and a scratch host only with `--hold-first-look`; never the Mac's.
struct VaultFirstLookTests {
    @Test func onlyAFreshNodeVaultOrAScratchHostAskedHoldsItsFirstLook() {
        let linux = !Platform.CodeIdentity.isAvailable
        let node = ["vibeswitcher-host", HostImages.nodeFlag]
        #expect(VaultFirstLook.holds(arguments: node, ownsLaunchers: true, restored: false) == linux)
        // A vault a handover carried keeps its own (in its state): set or not, it isn't set again here.
        #expect(!VaultFirstLook.holds(arguments: node, ownsLaunchers: true, restored: true))
        // A scratch host seals as before unless a test asks; the user's host never takes the test flag.
        #expect(!VaultFirstLook.holds(arguments: ["vibeswitcher-host", "--lock", "/x/h.lock"], ownsLaunchers: false, restored: false))
        #expect(VaultFirstLook.holds(arguments: ["vibeswitcher-host", VaultFirstLook.testFlag], ownsLaunchers: false, restored: false) == linux)
        #expect(!VaultFirstLook.holds(arguments: ["vibeswitcher-host", VaultFirstLook.testFlag], ownsLaunchers: true, restored: false))
        #expect(HostHardening.testFlags[VaultFirstLook.testFlag] == false)
        // A book is made not holding it.
        #expect(!LeadVault.Book().holdsFirstLook)
    }
}

/// The host's wiring of it (`vibeswitcher-host/main.swift`): a real scratch host, asked with `--hold-first-look` or
/// not. Asked, on Linux its vault holds its home's first look from the app's own look, records no rail of the lead's
/// with nothing recorded and says so in the host's log, and still holds it after a handover (restored from its state,
/// not set again); not asked, or on the Mac, it seals as before.
@Suite(.serialized, hostTestLimit) struct VaultFirstLookHostTests {
    @Test(arguments: [false, true])
    func aScratchHostAskedHoldsItsVaultsFirstLook(asked: Bool) async throws {
        let holds = asked && !Platform.CodeIdentity.isAvailable
        let host = try await ScratchHostProcess(arguments: asked ? [VaultFirstLook.testFlag] : [])
        var sessions: [HostSession] = []
        defer {
            for session in sessions where kill(session.childPID, 0) == 0 { kill(-session.childPID, SIGKILL) }
            host.stop()
        }
        let root = host.dir + "/repo"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let (app, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)

        // The app's own look (no card shown): held, nothing of your home recorded; or sealed as before.
        let look = app.vault(.setGuarded(root: root, hashes: [ConfigSeal.checkKey: "1"]))
        #expect(look == (holds ? .refused(ConfigSeal.heldRefusal) : .ok), "\(String(describing: look)) \(host.log)")
        func record(_ client: TestClient) -> [String: String] {
            guard case .guarded(let record?)? = client.vault(.guarded(root: root)) else { return [:] }
            return record
        }
        let homeRecorded = { (client: TestClient) in record(client).keys.filter { ConfigSeal.isWatchedKey($0) && ConfigSeal.isHome(key: $0) } }
        #expect(ConfigSeal.held(in: record(app)).contains("~/.claude/settings.json") == holds)
        #expect(homeRecorded(app).isEmpty == holds)

        // The lead (a session the vault binds as one) records workflow.md's rails as they are: held instead, and said.
        let courier = try Courier(host.dir + "/lead", socket: host.socket)
        let lead = try await app.spawn(courier.command)
        sessions = [lead]
        guard case .grant(let grant)? = app.vault(.issue(role: .lead, root: root, task: nil, auditing: nil)) else {
            Issue.record("the app got no lead grant: \(host.log)"); return
        }
        #expect(app.vault(.bind(grant: grant, root: root, session: lead.id.uuidString)) == .ok)
        let rail = LeadVault.hash("make test")
        let set = try await courier.send([.vault(.setGuarded(root: root, hashes: ["test_command": rail]))])
        #expect(set[2] == .vault(.ok), "\(set)")
        #expect((record(app)["test_command"] == nil) == holds, "\(record(app))")
        let said = "first look is held: workflow.md's test_command \(rail.prefix(12))"
        if holds {
            #expect(await eventually { ((try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "").contains(said) })
        } else {
            #expect(!((try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "").contains("first look is held"))
        }
        guard asked else { return }

        // Handed over before any accept: the next build's vault, restored, still holds it.
        let seq = app.send(.handover(executable: host.newBinary))
        #expect(await eventually { app.reply(to: seq) != nil })
        #expect(app.reply(to: seq) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("took over") })
        let (again, _, build, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(build == host.newBuild)
        let after = again.vault(.setGuarded(root: root, hashes: [ConfigSeal.checkKey: "1"]))
        #expect(after == (holds ? .refused(ConfigSeal.heldRefusal) : .ok), "\(String(describing: after))")
        #expect(homeRecorded(again).isEmpty == holds)
    }
}
