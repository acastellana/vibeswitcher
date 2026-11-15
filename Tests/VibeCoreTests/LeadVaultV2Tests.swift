import Foundation
import Testing
@testable import VibeCore

/// The node's record in the vault (`LeadVaultV2`, the engine plan's EN-D11): the user's actions only the app records;
/// a `.user` seal verifies false once retired or past its life (T41 narrowed); a vault saved before the field reads as
/// before; and the Mac's vault hooks do nothing.
struct LeadVaultV2Tests {
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
        #expect(LeadVaultV2.verified([answer], [true], book: book, now: made + life - 1) == [true])
        #expect(LeadVaultV2.verified([answer], [true], book: book, now: made + life + 1) == [false])
        // A seal that didn't check stays false; another sender's seal has no life here.
        #expect(LeadVaultV2.verified([answer], [false], book: book, now: made) == [false])
        let report = SteerMessage(text: "done", from: .system("worker t"), agentPid: 1, at: made - 99_999)
        #expect(LeadVaultV2.verified([report], [true], book: book, now: made) == [true])
        // One the record never saw is as old as its own time says (which its seal covers).
        let unseen = SteerMessage(text: "old", from: .user, agentPid: 1, at: made - life - 1)
        #expect(LeadVaultV2.verified([unseen], [true], book: book, now: made) == [false])
        // A seal is recorded with its time as made, not the message's.
        #expect(book?.seals[answer.id] == made)
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
