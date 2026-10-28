import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The host's kill check with real sessions (2026-10-18): the lead ends a verifier that a later audit replaced (it
/// holds no role any more, and the lead that started it is gone), and the host says no, out loud, to a session that
/// never held a role in its team.
struct LeadEndsTeamTests {
    let root = "/tmp/lead-ends-team-repo"
    let temp = Scratch()

    @Test func theLeadEndsAReplacedVerifierAndIsToldNoForAStranger() throws {
        let book = LeadVault.Book()
        let host = try TestHost(vault: book)
        let app = try TestClient(host)
        let leadCourier = try Courier(temp.url("lead").path, socket: host.socket)
        let lead = try app.spawn(leadCourier.command)
        let replaced = try app.spawn("sleep 60"), current = try app.spawn("sleep 60"), stranger = try app.spawn("sleep 60")
        defer { for session in [lead, replaced, current, stranger] { _ = app.send(.kill(id: session.id)) } }

        guard case .grant(let leadGrant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no lead grant"); return
        }
        #expect(book.answer(.bind(grant: leadGrant, root: root, session: lead.id.uuidString), from: .app) == .ok)
        let asLead = LeadVault.Caller.session(lead.id.uuidString)
        for verifier in [replaced, current] {
            guard case .grant(let grant) = book.answer(.issue(role: .verifier, root: root, task: "t", auditing: "c0ffee"), from: asLead) else {
                Issue.record("no verifier grant"); return
            }
            #expect(book.answer(.bind(grant: grant, root: root, session: verifier.id.uuidString), from: asLead) == .ok)
        }

        let answers = try leadCourier.send([.kill(id: replaced.id), .kill(id: stranger.id)])
        #expect(answers[2] == .ok, "\(String(describing: answers[2]))")
        #expect(eventually { app.latest(replaced.id)?.isLive == false })
        guard case .error(let refusal)? = answers[3] else { Issue.record("a stranger's kill: \(String(describing: answers[3]))"); return }
        #expect(refusal.contains("not authorized"))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(app.latest(stranger.id)?.isLive != false && kill(stranger.childPID, 0) == 0)
    }
}
