import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

extension LeadVaultHostTests {
    /// The request sender is an actual nc child of a hosted scratch session, not a test-supplied identity.
    func checkSessionPermissions(readerIsLead: Bool) async throws {
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
        let reader = try await app.spawn("while [ ! -f '\(go.path)' ]; do sleep 0.02; done; "
            + nc(host, requests, answers, until: stop) + "; touch '\(done.path)'; " + keepRunning)
        let member = try await app.spawn("echo SYNTHETIC_TEAM_DATA; exec /bin/cat")
        let outsider = try await app.spawn("echo SYNTHETIC_OTHER_PROJECT; " + keepRunning)
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
        #expect(await eventually { answered(answers, 2...8) })
        FileManager.default.createFile(atPath: stop.path, contents: nil)
        #expect(await eventually { FileManager.default.fileExists(atPath: done.path) })
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

    /// Over the real socket: the lead's own session asks for a role on a session the app opened, then reads and types.
    /// The role stays unbound and the session stays out of reach.
    @Test func aLeadsRoleGoesOnlyOnASessionItStarted() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = LeadVault.Book()
        let host = try TestHost(vault: book)
        let app = try TestClient(host)
        defer { app.close() }
        let requests = folder.appendingPathComponent("bind.requests")
        let answers = folder.appendingPathComponent("bind.answers")
        let go = folder.appendingPathComponent("bind.go")
        let stop = folder.appendingPathComponent("bind.stop")
        let done = folder.appendingPathComponent("bind.done")
        let lead = try await app.spawn("while [ ! -f '\(go.path)' ]; do sleep 0.02; done; "
            + nc(host, requests, answers, until: stop) + "; touch '\(done.path)'; " + keepRunning)
        let outsider = try await app.spawn("echo SYNTHETIC_OTHER_PROJECT; " + keepRunning)
        guard case .grant(let leadGrant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("No lead grant"); return
        }
        #expect(book.answer(.bind(grant: leadGrant, root: root, session: lead.id.uuidString), from: .app) == .ok)
        let asLead = LeadVault.Caller.session(lead.id.uuidString)
        guard case .grant(let workerGrant) = book.answer(.issue(role: .worker, root: root, task: "access", auditing: nil), from: asLead) else {
            Issue.record("No worker grant"); return
        }
        try frames([
            .vault(.bind(grant: workerGrant, root: root, session: outsider.id.uuidString)),
            .screen(id: outsider.id),
            .inputUnit(id: outsider.id, writes: [.init(bytes: Array("synthetic-input\n".utf8), delay: 0)], more: false),
        ]).write(to: requests)
        FileManager.default.createFile(atPath: go.path, contents: nil)
        #expect(await eventually { answered(answers, 2...4) })
        FileManager.default.createFile(atPath: stop.path, contents: nil)
        #expect(await eventually { FileManager.default.fileExists(atPath: done.path) })
        let got = try replies(Data(contentsOf: answers))
        #expect(refused(got[2]), "bind: \(String(describing: got[2]))")
        guard case .error? = got[3] else { Issue.record("Read a session it didn't start: \(String(describing: got[3]))"); return }
        guard case .error? = got[4] else { Issue.record("Typed into a session it didn't start: \(String(describing: got[4]))"); return }
        guard case .member(let member) = book.answer(.current(role: .worker, root: root, task: "access"), from: .app) else {
            Issue.record("No answer"); return
        }
        #expect(member?.session == nil)
    }

    @Test func aLeadCanReadAndTypeIntoItsWorkerButCannotAccessAnotherProject() async throws {
        try await checkSessionPermissions(readerIsLead: true)
    }

    @Test func aWorkerCanReadItselfButCannotReadOrTypeIntoItsLeadOrAnotherProject() async throws {
        try await checkSessionPermissions(readerIsLead: false)
    }
}
