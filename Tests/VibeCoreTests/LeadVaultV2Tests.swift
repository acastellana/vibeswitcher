import Foundation
import Testing
@testable import VibeCore

/// The node's record in the vault (`LeadVaultV2`, the engine plan's EN-D11): the user's actions only the app records;
/// a `.user` seal verifies false once retired or past its life (T41 narrowed); a vault saved before the field reads as
/// before; and the Mac's vault hooks do nothing.
struct LeadVaultV2Tests {
    /// The record per host (the review of 2026-11-21): `on` decides, on both systems, for the answer and both hooks; the
    /// default is Linux's every host and, on the Mac, only a host that said it's a node host (`recordsOnThisHost`).
    @Test func theRecordIsKeptWhereTheHostSaysSo() {
        #expect(LeadVaultV2.isOn == (!Platform.CodeIdentity.isAvailable || LeadVaultV2.recordsOnThisHost))
        let request = LeadVaultV2.Request.recordUserAction(action: "a", kind: "set", subject: nil, digest: "d")
        var book: LeadVaultV2.Book?
        #expect(LeadVaultV2.answer(request, from: .app, book: &book, on: true) == .recorded(first: true))
        if case .refused = LeadVaultV2.answer(request, from: .app, book: &book, on: false) {} else { Issue.record("recorded while off") }
        let message = SteerMessage(text: "yes", from: .user, agentPid: 42)
        var changed = false
        var off: LeadVaultV2.Book?
        LeadVaultV2.sealed(message, book: &off, changed: &changed, on: false)
        #expect(off == nil && !changed)
        LeadVaultV2.sealed(message, book: &off, changed: &changed, on: true)
        #expect(off?.seals[message.id] != nil && changed)
        // Retired, it verifies false where the record is kept, and as the key says where it isn't.
        _ = LeadVaultV2.answer(.retireUserSeals([message.id]), from: .app, book: &off, on: true)
        #expect(LeadVaultV2.verified([message], [true], book: &off, changed: &changed, on: true) == [false])
        #expect(LeadVaultV2.verified([message], [true], book: &off, changed: &changed, on: false) == [true])
    }

    /// The Mac's tasks, item 14: the record is the book's, not the process's. A book set to keep it (a checked Mac node
    /// host's) records a user's seal through its `.seal` hook and refuses a retired one through `.verify`; another book in
    /// the same process, never set, records nothing and verifies by the key alone, on the Mac. Linux: every book keeps it.
    /// Before, one process-wide switch (`recordsOnThisHost`, one-way) decided for every book, so a test that made a node
    /// host left it on for every host after it, and setting one book changed nothing.
    @Test func theRecordIsTheBooksNotTheProcesss() {
        let node = LeadVault.Book(), other = LeadVault.Book()
        #expect(node.recordsActions == !Platform.CodeIdentity.isAvailable && other.recordsActions == node.recordsActions)
        node.recordsActions = true
        let message = SteerMessage(text: "yes", from: .user, agentPid: 42)
        guard case .seal(let seal) = node.answer(.seal(message), from: .app), case .seal(let otherSeal) = other.answer(.seal(message), from: .app) else {
            Issue.record("a user's message from the app wasn't sealed")
            return
        }
        #expect(node.v2 { $0?.seals[message.id] } != nil, "the node host's book didn't record the user's seal")
        #expect(other.v2 { $0?.seals[message.id] != nil } == !Platform.CodeIdentity.isAvailable, "another book recorded as the node host's")
        var sealedNode = message, sealedOther = message
        sealedNode.seal = seal
        sealedOther.seal = otherSeal
        _ = node.v2 { LeadVaultV2.answer(.retireUserSeals([message.id]), from: .app, book: &$0, on: true) }
        #expect(node.answer(.verify([sealedNode]), from: .app) == .verified([false]), "a retired seal verified on the node host's book")
        #expect(other.answer(.verify([sealedOther]), from: .app) == .verified([true]))
    }

    private let scratch = Scratch()
    private static let linux = !Platform.CodeIdentity.isAvailable

    private func ask(_ book: LeadVault.Book, _ request: LeadVaultV2.Request, from caller: LeadVault.Caller = .app) -> LeadVaultV2.Reply {
        book.v2 { LeadVaultV2.answer(request, from: caller, book: &$0) }
    }

    @Test(.enabled(if: linux, "Linux: the record is kept there only")) func onlyTheAppRecordsAUserAction() {
        let book = LeadVault.Book()
        var saved: [Data] = []
        book.onChange = { saved.append($0) }
        let record = LeadVaultV2.Request.recordUserAction(action: "a1", kind: "answer", subject: "local:card:x", digest: "d1")
        for caller in [LeadVault.Caller.session("lead-session"), .unknown] {
            guard case .refused = ask(book, record, from: caller) else { Issue.record("\(caller) recorded an action"); return }
            guard case .refused = ask(book, .holds(action: "a1", digest: "d1"), from: caller) else { Issue.record("\(caller) read the record"); return }
        }
        #expect(saved.isEmpty)
        #expect(ask(book, record) == .recorded(first: true))
        #expect(saved.count == 1)
        #expect(ask(book, record) == .recorded(first: false))
        #expect(ask(book, .holds(action: "a1", digest: "d1")) == .holds(true))
        #expect(ask(book, .holds(action: "a1", digest: "other")) == .holds(false))
        guard case .actions(let actions) = ask(book, .userActions(since: 0)) else { Issue.record("no actions"); return }
        #expect(actions.map(\.action) == ["a1"] && actions.first?.subject == "local:card:x")
        // Kept with the vault: a handover's copy holds it.
        let carried = LeadVault.Book(restoring: book.serialized)
        #expect(ask(carried, .holds(action: "a1", digest: "d1")) == .holds(true))
    }

    @Test(.enabled(if: linux, "Linux: the record is kept there only")) func aRetiredUserSealVerifiesFalse() throws {
        let book = LeadVault.Book()
        let app = book.vault(folder: scratch.url("vault"), as: { .app })
        var answer = SteerMessage(text: "Answer to your question: yes", from: .user, agentPid: 42)
        answer.seal = try app.seal(answer)
        var other = SteerMessage(text: "another", from: .user, agentPid: 42)
        other.seal = try app.seal(other)
        var lead = SteerMessage(text: "from the lead", from: .system("vibeswitcher"), agentPid: 42)
        lead.seal = try app.seal(lead)
        #expect(try app.verify([answer, other, lead]) == [true, true, true])
        #expect(ask(book, .retireUserSeals([answer.id, lead.id])) == .ok)
        // Retired: false; the others as before (only `.user` seals are the record's).
        #expect(try app.verify([answer, other, lead]) == [false, true, true])
        #expect(try LeadVault.Book(restoring: book.serialized).vault(folder: scratch.url("vault"), as: { .app }).verify([answer]) == [false])
    }

    @Test(.enabled(if: linux, "Linux: the record is kept there only")) func aUserSealExpiresAfterItsTime() {
        var book: LeadVaultV2.Book?
        var changed = false
        let made = 1_800_000_000.0
        let answer = SteerMessage(text: "yes", from: .user, agentPid: 1, at: made - 3_600)
        LeadVaultV2.sealed(answer, book: &book, changed: &changed, now: made)
        #expect(changed)
        let life = LeadVaultV2.defaultSealLife
        func verified(_ message: SteerMessage, _ valid: Bool = true, at now: Double) -> Bool? {
            LeadVaultV2.verified([message], [valid], book: &book, changed: &changed, now: now).first
        }
        #expect(verified(answer, at: made + life - 1) == true)
        #expect(verified(answer, at: made + life + 1) == false)
        // A seal that didn't check stays false; another sender's seal has no life here.
        #expect(verified(answer, false, at: made) == false)
        let report = SteerMessage(text: "done", from: .system("worker t"), agentPid: 1, at: made - 99_999)
        #expect(verified(report, at: made) == true)
        // One the record never saw is as old as its own time says (which its seal covers).
        let unseen = SteerMessage(text: "old", from: .user, agentPid: 1, at: made - life - 1)
        #expect(verified(unseen, at: made) == false)
        // A seal is recorded with its time as made, not the message's.
        #expect(book?.seals[answer.id] == made)
    }

    /// The E6 review: a `.user` message that waits untaken in its lead's inbox (a long tool call: no hook takes it) has
    /// its seal renewed by the server at each look, so it is still the user's when taken past the first life; once a
    /// check passed it (the hook took it), or it was retired, or its life ran out, it is renewed no more, so a copy put
    /// back lives one life at most.
    @Test(.enabled(if: linux, "Linux: the record is kept there only")) func aWaitingUserSealIsRenewedUntilItIsChecked() throws {
        var book: LeadVaultV2.Book?
        var changed = false
        let life = LeadVaultV2.defaultSealLife
        let made = 1_800_000_000.0
        let answer = SteerMessage(text: "yes", from: .user, agentPid: 1, at: made)
        LeadVaultV2.sealed(answer, book: &book, changed: &changed, now: made)
        func renew(_ ids: [String], at now: Double) -> LeadVaultV2.Reply { LeadVaultV2.answer(.renewUserSeals(ids), from: .app, book: &book, now: now) }
        func verified(_ message: SteerMessage, at now: Double) -> Bool? {
            LeadVaultV2.verified([message], [true], book: &book, changed: &changed, now: now).first
        }
        // Only the app renews; a renewal before a third of the life went writes nothing.
        let before = book
        guard case .refused = LeadVaultV2.answer(.renewUserSeals([answer.id]), from: .session("worker"), book: &book, now: made + life / 2) else {
            Issue.record("a worker renewed a seal")
            return
        }
        #expect(renew([answer.id], at: made + 1) == .ok)
        #expect(book == before)
        // Waiting: renewed twice, it verifies well past its first life.
        #expect(renew([answer.id], at: made + life * 0.9) == .ok)
        #expect(renew([answer.id], at: made + life * 1.8) == .ok)
        #expect(book?.seals[answer.id] == made + life * 1.8)
        changed = false
        #expect(verified(answer, at: made + life * 2.5) == true)
        #expect(changed && book?.checked[answer.id] == made + life * 2.5)
        // Checked (taken): renewed no more, so a copy dies with this life.
        #expect(renew([answer.id], at: made + life * 2.7) == .ok)
        #expect(book?.seals[answer.id] == made + life * 1.8)
        #expect(verified(answer, at: made + life * 2.9) == false)
        // A seal whose life ran out isn't brought back; a retired one isn't renewed.
        let late = SteerMessage(text: "late", from: .user, agentPid: 1, at: made)
        LeadVaultV2.sealed(late, book: &book, changed: &changed, now: made)
        #expect(renew([late.id], at: made + life + 1) == .ok)
        #expect(book?.seals[late.id] == made)
        let retired = SteerMessage(text: "retired", from: .user, agentPid: 1, at: made)
        LeadVaultV2.sealed(retired, book: &book, changed: &changed, now: made)
        _ = LeadVaultV2.answer(.retireUserSeals([retired.id]), from: .app, book: &book, now: made + 1)
        #expect(renew([retired.id], at: made + life / 2) == .ok)
        #expect(book?.seals[retired.id] == made)
        // A record saved before `checked` reads.
        let older = try JSONSerialization.data(withJSONObject: ["actions": [], "seals": ["x": made], "retired": [:]] as [String: Any])
        #expect(try JSONDecoder().decode(LeadVaultV2.Book.self, from: older).seals == ["x": made])
    }

    /// The security follow-ups' item 16: a waiting `.user` message's seal is renewed while it waits, but never past
    /// `renewedLifeCap` from its first making: a line kept "waiting" for a day (renewed at every look) verifies false by
    /// then, so a sealed copy put back a day later isn't the user's.
    @Test(.enabled(if: linux, "Linux: the record is kept there only")) func aUserSealIsRenewedNoLongerThanItsCap() {
        var book: LeadVaultV2.Book?
        var changed = false
        let life = LeadVaultV2.defaultSealLife
        let made = 1_800_000_000.0
        let answer = SteerMessage(text: "yes", from: .user, agentPid: 1, at: made)
        LeadVaultV2.sealed(answer, book: &book, changed: &changed, now: made)
        // The server's looks renew it every half life while it waits, for a day.
        var now = made
        while now < made + 86_400 {
            now += life / 2
            #expect(LeadVaultV2.answer(.renewUserSeals([answer.id]), from: .app, book: &book, now: now) == .ok)
        }
        let renewed = book?.seals[answer.id] ?? .infinity
        #expect(renewed > made + life && renewed < made + 3 * 3_600, "\(renewed - made)")
        #expect(LeadVaultV2.verified([answer], [true], book: &book, changed: &changed, now: now) == [false])
    }

    /// The security follow-ups' item 17: a seal check is a read for anyone but the app (a handover) and a lead's own
    /// session (its hook taking its inbox). A worker's or an outsider's check of a waiting answer passes but leaves it
    /// unchecked, so the server's renewal of it goes on; the lead's check marks it.
    @Test(.enabled(if: linux, "Linux: the record is kept there only")) func onlyATakingMarksAUserSealChecked() throws {
        let home = scratch.url("home").resolvingSymlinksInPath().path
        let folder = scratch.url("vault")
        let root = (home as NSString).appendingPathComponent("repo")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = LeadVault.Book()
        book.configHome = home
        let app = book.vault(folder: folder, as: { .app }, agentSession: { $0 == 42 ? "lead-session" : nil })
        try app.bind(try app.startLead(root: root, branch: "main"), root: root, session: "lead-session")
        let lead = book.vault(folder: folder, as: { .session("lead-session") })
        try lead.bind(try lead.issue(role: .worker, root: root, task: "parser"), root: root, session: "worker-session")
        var answer = SteerMessage(text: "Answer to your question: yes", from: .user, agentPid: 42)
        answer.seal = try app.seal(answer)
        for caller in [LeadVault.Caller.session("worker-session"), .session("someone-else"), .unknown] {
            #expect(try book.vault(folder: folder, as: { caller }).verify([answer]) == [true], "\(caller)")
        }
        #expect(book.v2 { $0?.checked[answer.id] } == nil)
        #expect(try lead.verify([answer]) == [true])
        #expect(book.v2 { $0?.checked[answer.id] } != nil)
    }

    /// The security follow-ups' item 19: a lead's check is a taking only for the messages sealed for it (the session its
    /// agent ran in when the host sealed them). Another project's lead checking B's waiting answer leaves it unchecked,
    /// so its renewal goes on; B's own lead's check marks it; the app's check (a handover) takes any.
    @Test(.enabled(if: linux, "Linux: the record is kept there only")) func aLeadTakesOnlyTheMessagesSealedForIt() throws {
        let home = scratch.url("home").resolvingSymlinksInPath().path
        let folder = scratch.url("vault")
        let rootA = (home as NSString).appendingPathComponent("repo-a")
        let rootB = (home as NSString).appendingPathComponent("repo-b")
        for root in [rootA, rootB] { try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = LeadVault.Book()
        book.configHome = home
        let sessions: [Int32: String] = [41: "lead-a", 42: "lead-b"]
        let app = book.vault(folder: folder, as: { .app }, agentSession: { sessions[$0] })
        try app.bind(try app.startLead(root: rootA, branch: "main"), root: rootA, session: "lead-a")
        try app.bind(try app.startLead(root: rootB, branch: "main"), root: rootB, session: "lead-b")
        let leadA = book.vault(folder: folder, as: { .session("lead-a") })
        let leadB = book.vault(folder: folder, as: { .session("lead-b") })
        var answer = SteerMessage(text: "Answer to your question: yes", from: .user, agentPid: 42)
        answer.seal = try app.seal(answer)
        // A's lead checks B's answer: it passes, and is taken by no one.
        #expect(try leadA.verify([answer]) == [true])
        #expect(book.v2 { $0?.checked[answer.id] } == nil)
        // B's own lead's check takes it.
        #expect(try leadB.verify([answer]) == [true])
        #expect(book.v2 { $0?.checked[answer.id] } != nil)
        // In one batch each message alone: A's check of its own and B's takes only A's.
        var forA = SteerMessage(text: "Answer: no", from: .user, agentPid: 41)
        forA.seal = try app.seal(forA)
        var forB = SteerMessage(text: "Answer: maybe", from: .user, agentPid: 42)
        forB.seal = try app.seal(forB)
        #expect(try leadA.verify([forB, forA]) == [true, true])
        #expect(book.v2 { $0?.checked[forA.id] } != nil)
        #expect(book.v2 { $0?.checked[forB.id] } == nil)
        // A seal the host found no session for: no lead's check takes it; the app's does.
        var nobodys = SteerMessage(text: "Answer: later", from: .user, agentPid: 99)
        nobodys.seal = try app.seal(nobodys)
        #expect(try leadB.verify([nobodys]) == [true])
        #expect(book.v2 { $0?.checked[nobodys.id] } == nil)
        #expect(try app.verify([nobodys, forB]) == [true, true])
        #expect(book.v2 { $0?.checked[nobodys.id] != nil && $0?.checked[forB.id] != nil })
    }

    /// The follow-up 19 review: a seal's recipient is tied to its message id, and an id can come back (a held message's,
    /// restored from `engine.json` after a server restart, is a same-uid process's to rewrite). A later seal of B's
    /// waiting answer's id for A's lead leaves the id with no recipient: A's taking of its copy, and every later one,
    /// leaves B's answer unchecked, so its renewal goes on; a seal again for the same recipient keeps it.
    @Test(.enabled(if: linux, "Linux: the record is kept there only")) func aSealAgainUnderAnIdForAnotherLeadTakesItsRecipient() throws {
        let home = scratch.url("home").resolvingSymlinksInPath().path
        let folder = scratch.url("vault")
        let rootA = (home as NSString).appendingPathComponent("repo-a")
        let rootB = (home as NSString).appendingPathComponent("repo-b")
        for root in [rootA, rootB] { try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = LeadVault.Book()
        book.configHome = home
        let sessions: [Int32: String] = [41: "lead-a", 42: "lead-b"]
        let app = book.vault(folder: folder, as: { .app }, agentSession: { sessions[$0] })
        try app.bind(try app.startLead(root: rootA, branch: "main"), root: rootA, session: "lead-a")
        try app.bind(try app.startLead(root: rootB, branch: "main"), root: rootB, session: "lead-b")
        let leadA = book.vault(folder: folder, as: { .session("lead-a") })
        let leadB = book.vault(folder: folder, as: { .session("lead-b") })
        var answer = SteerMessage(text: "Answer to your question: yes", from: .user, agentPid: 42)
        answer.seal = try app.seal(answer)
        // A held message for A's project, its id rewritten to B's answer's, posted to A's lead after a restart.
        var copy = SteerMessage(text: "Hold: carry on", from: .user, agentPid: 41)
        copy.id = answer.id
        copy.seal = try app.seal(copy)
        #expect(book.v2 { $0?.targets[answer.id] } == nil)
        #expect(try leadA.verify([copy]) == [true])
        #expect(book.v2 { $0?.checked[answer.id] } == nil)
        // Sealed for A once more: still no recipient, so A's taking still leaves B's answer unchecked.
        copy.seal = try app.seal(copy)
        #expect(try leadA.verify([copy]) == [true])
        #expect(book.v2 { $0?.checked[answer.id] } == nil)
        // B's own answer still passes; the app's check (a handover) takes it.
        #expect(try leadB.verify([answer]) == [true])
        #expect(try app.verify([answer]) == [true])
        #expect(book.v2 { $0?.checked[answer.id] } != nil)
        // A message sealed again for the same lead keeps its recipient: that lead's check takes it.
        var again = SteerMessage(text: "Answer: no", from: .user, agentPid: 42)
        again.seal = try app.seal(again)
        again.seal = try app.seal(again)
        #expect(book.v2 { $0?.targets[again.id] } == "lead-b")
        #expect(try leadB.verify([again]) == [true])
        #expect(book.v2 { $0?.checked[again.id] } != nil)
    }

    /// A vault saved before the field (no `v2` key) reads as before, and one without anything recorded saves none.
    @Test func aBookWithoutTheV2FieldReadsAsBefore() throws {
        let folder = scratch.url("vault")
        let book = LeadVault.Book()
        let app = book.vault(folder: folder, as: { .app })
        let root = scratch.url("repo").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try app.issue(role: .lead, root: root, task: nil)
        let saved = book.serialized
        let object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(object["v2"] == nil)
        #expect(LeadVault.Book.reads(saved))
        let restored = LeadVault.Book(restoring: saved)
        #expect(restored.vault(folder: folder, as: { .app }).current(.lead, root: root, task: nil) != nil)
        // With a record, then the key taken out (an older build's save): it still reads, the rest intact.
        if Self.linux { #expect(ask(book, .recordUserAction(action: "a", kind: "answer", subject: nil, digest: "d")) == .recorded(first: true)) }
        var withRecord = try #require(try JSONSerialization.jsonObject(with: book.serialized) as? [String: Any])
        #expect((withRecord["v2"] != nil) == Self.linux)
        withRecord["v2"] = nil
        let older = try JSONSerialization.data(withJSONObject: withRecord)
        #expect(LeadVault.Book.reads(older))
        #expect(LeadVault.Book(restoring: older).vault(folder: folder, as: { .app }).current(.lead, root: root, task: nil) != nil)
    }

    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's vault")) func theMacsVaultHooksDoNothing() throws {
        let book = LeadVault.Book()
        let app = book.vault(folder: scratch.url("vault"), as: { .app })
        var answer = SteerMessage(text: "yes", from: .user, agentPid: 42, at: Date().timeIntervalSince1970 - 86_400)
        answer.seal = try app.seal(answer)
        guard case .refused = ask(book, .retireUserSeals([answer.id])) else { Issue.record("the Mac's vault kept a record"); return }
        guard case .refused = ask(book, .recordUserAction(action: "a", kind: "answer", subject: nil, digest: "d")) else { Issue.record("recorded"); return }
        // Day-old and named retired: it verifies as today.
        #expect(try app.verify([answer]) == [true])
        let object = try #require(try JSONSerialization.jsonObject(with: book.serialized) as? [String: Any])
        #expect(object["v2"] == nil)
    }
}
