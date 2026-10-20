import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A verifier that submitted its audit has no job left (2026-10-20: two of genswap's ran on idle 14.7 h and 20.6 h):
/// the host ends its session `submittedGrace` after the vault stored its verdict, through its own logged end, as any
/// kill. Sessions here are scratch shells, never Claude.
struct SubmittedVerifierEndsTests {
    let root = "/tmp/submitted-verifier-repo"
    let temp = Scratch()

    /// The host's default leaves the verifier within the minute, with the housekeeping's 30 s on top.
    @Test func theGraceIsWithinTheMinute() {
        #expect(HostServer.submittedGrace >= 10 && HostServer.submittedGrace + 30 <= 60)
    }

    /// Teams as the lead starts them: a lead, a worker and a verifier, each in a session of its own; the worker and
    /// verifier send what the test gives them from inside their sessions.
    func team(_ book: LeadVault.Book, _ app: TestClient, socket: String) throws
        -> (lead: HostSession, worker: (HostSession, Courier), verifier: (HostSession, Courier)) {
        let workerCourier = try Courier(temp.url("worker").path, socket: socket)
        let verifierCourier = try Courier(temp.url("verifier").path, socket: socket)
        let lead = try app.spawn("sleep 60"), worker = try app.spawn(workerCourier.command), verifier = try app.spawn(verifierCourier.command)
        guard case .grant(let leadGrant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else { throw CancellationError() }
        #expect(book.answer(.bind(grant: leadGrant, root: root, session: lead.id.uuidString), from: .app) == .ok)
        let asLead = LeadVault.Caller.session(lead.id.uuidString)
        for (role, session) in [(LeadLaunch.Role.worker, worker), (.verifier, verifier)] {
            guard case .grant(let grant) = book.answer(.issue(role: role, root: root, task: "t", auditing: role == .verifier ? "c0ffee" : nil), from: asLead) else {
                throw CancellationError()
            }
            #expect(book.answer(.bind(grant: grant, root: root, session: session.id.uuidString), from: asLead) == .ok)
        }
        return (lead, (worker, workerCourier), (verifier, verifierCourier))
    }

    @Test func aVerifierEndsOnceItsVerdictIsInAndNothingElseDoes() throws {
        let book = LeadVault.Book()
        let log = temp.url("host.log").path
        let grace: TimeInterval = 2
        let host = try TestHost(vault: book, log: log, submittedGrace: grace)
        let app = try TestClient(host)
        let (lead, worker, verifier) = try team(book, app, socket: host.socket)
        defer { for session in [lead, worker.0, verifier.0] { _ = app.send(.kill(id: session.id)) } }
        let submit = HostRequest.vault(.submitVerdict(root: root, completion: .complete, integrity: .clean, summary: "ok"))

        // The worker's shell can't give a verdict: refused, and it isn't ended for trying.
        let refused = try worker.1.send([submit])
        guard case .vault(.refused)? = refused[2] else { Issue.record("a worker's verdict: \(String(describing: refused[2]))"); return }

        let asked = Date()
        let answers = try verifier.1.send([submit])
        guard case .vault(.verdict(let verdict?))? = answers[2] else { Issue.record("the verdict: \(String(describing: answers[2]))"); return }
        #expect(verdict.session == verifier.0.id.uuidString)
        // Not before its grace (its tool server records the verdict on the board and tells the lead meanwhile).
        if Date().timeIntervalSince(asked) < grace - 0.5 { #expect(kill(verifier.0.childPID, 0) == 0) }
        #expect(eventually { app.latest(verifier.0.id)?.isLive == false })
        #expect(Date().timeIntervalSince(asked) >= grace)
        // Ended as the host's own kill, said in its log.
        let said = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(said.contains("kill \(HostServer.short(verifier.0.id))") && said.contains("its verifier submitted its audit"), "\(said)")
        // Its record stays: the roster still says it submitted (the witness reads it), and the vault still answers.
        guard case .roster(let roster) = book.answer(.roster(root: root), from: .app) else { Issue.record("no roster"); return }
        #expect(roster.first { $0.session == verifier.0.id.uuidString }?.submittedAt != nil)
        #expect(book.answer(.verdict(root: root, task: "t"), from: .app) == .verdict(verdict))

        // The lead and the worker run on.
        Thread.sleep(forTimeInterval: 0.5)
        for session in [lead, worker.0] { #expect(app.latest(session.id)?.isLive != false && kill(session.childPID, 0) == 0) }
    }

    /// A verdict stored while no host scheduled its end (a handover in between): the housekeeping ends it.
    @Test func theHousekeepingEndsASubmittedVerifierTheHostDidntSchedule() throws {
        let book = LeadVault.Book()
        let host = try TestHost(vault: book, submittedGrace: 0.5, housekeeping: 0.5)
        let app = try TestClient(host)
        let (lead, worker, verifier) = try team(book, app, socket: host.socket)
        defer { for session in [lead, worker.0, verifier.0] { _ = app.send(.kill(id: session.id)) } }
        let stored = book.answer(.submitVerdict(root: root, completion: .incomplete, integrity: .clean, summary: "no"),
                                 from: .session(verifier.0.id.uuidString))
        guard case .verdict(_?) = stored else { Issue.record("not stored: \(stored)"); return }
        #expect(eventually { app.latest(verifier.0.id)?.isLive == false })
        #expect(app.latest(worker.0.id)?.isLive != false && kill(worker.0.childPID, 0) == 0)
    }
}
