import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

extension LeadVaultHostTests {
    /// The request sender is an actual nc child of a hosted scratch session, not a test-supplied identity.
    func checkSessionPermissions(readerIsLead: Bool) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = LeadVault.Book()
        let host = try TestHost(vault: book)
        let app = try TestClient(host)
        defer { app.close() }
        let requests = folder.appendingPathComponent("access.requests")
        let answers = folder.appendingPathComponent("access.answers")
        let go = folder.appendingPathComponent("access.go")
        let stop = folder.appendingPathComponent("access.stop")
        let done = folder.appendingPathComponent("access.done")
        let reader = try app.spawn("while [ ! -f '\(go.path)' ]; do sleep 0.02; done; "
            + nc(host, requests, answers, until: stop) + "; touch '\(done.path)'; " + keepRunning)
        let member = try app.spawn("echo SYNTHETIC_TEAM_DATA; exec /bin/cat")
        let outsider = try app.spawn("echo SYNTHETIC_OTHER_PROJECT; " + keepRunning)
        let leadID = readerIsLead ? reader.id : member.id
        let workerID = readerIsLead ? member.id : reader.id
        guard case .grant(let lead) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("No lead grant"); return
        }
        #expect(book.answer(.bind(grant: lead, root: root, session: leadID.uuidString), from: .app) == .ok)
        let asLead = LeadVault.Caller.session(leadID.uuidString)
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "access", auditing: nil), from: asLead) else {
            Issue.record("No worker grant"); return
        }
        #expect(book.answer(.bind(grant: worker, root: root, session: workerID.uuidString), from: asLead) == .ok)
        try frames([
            .screen(id: reader.id), .screen(id: member.id), .screen(id: outsider.id),
            .inputUnit(id: member.id, writes: [.init(bytes: Array("synthetic-team-input\n".utf8), delay: 0)], more: false),
            .attach(id: outsider.id, cols: 80, rows: 24), .history(id: outsider.id, lines: 20),
            .styledScreen(id: outsider.id),
        ]).write(to: requests)
        FileManager.default.createFile(atPath: go.path, contents: nil)
        #expect(eventually { answered(answers, 2...8) })
        FileManager.default.createFile(atPath: stop.path, contents: nil)
        #expect(eventually { FileManager.default.fileExists(atPath: done.path) })
        let got = try replies(Data(contentsOf: answers))
        guard case .screenText? = got[2] else { Issue.record("Own screen refused"); return }
        if readerIsLead {
            guard case .screenText? = got[3] else { Issue.record("Lead cannot read its worker"); return }
            #expect(got[5] == .ok)
        } else {
            for seq in [3, 5] {
                guard case .error? = got[seq] else { Issue.record("Worker accessed its lead: \(seq)"); continue }
            }
        }
        for seq in [4, 6, 7, 8] {
            guard case .error? = got[seq] else { Issue.record("Cross-project access allowed: \(seq)"); continue }
        }
        guard case .welcome(_, _, let visible, _, _, _)? = got[1] else { Issue.record("No session list"); return }
        #expect(Set(visible.map(\.id)) == (readerIsLead ? Set([reader.id, member.id]) : Set([reader.id])))
    }

    @Test func aLeadCanReadAndTypeIntoItsWorkerButCannotAccessAnotherProject() throws {
        try checkSessionPermissions(readerIsLead: true)
    }

    @Test func aWorkerCanReadItselfButCannotReadOrTypeIntoItsLeadOrAnotherProject() throws {
        try checkSessionPermissions(readerIsLead: false)
    }
}
