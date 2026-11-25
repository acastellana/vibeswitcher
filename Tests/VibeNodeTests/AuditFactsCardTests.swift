import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A question allowing a model to audit a task (the lead's audit found none the floor leaves) shows, beside the lead's
/// words, what the vault says (`LeadEngine.auditFacts`): whether the audit asked it, at which commit, the workers' model
/// and the launches the host recorded. An in-process vault; no session, no host.
struct AuditFactsCardTests {
    private let scratch = Scratch()

    @Test func theCardsFactsComeFromTheVault() throws {
        let book = LeadVault.Book()
        book.configHome = scratch.url("home").path
        let root = scratch.url("repo").path
        let app = book.vault(folder: scratch.url("vault"), as: { .app })
        guard case .grant(let lead) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else { Issue.record("no lead"); return }
        #expect(book.answer(.bind(grant: lead, root: root, session: "lead"), from: .app) == .ok)
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "held", auditing: nil), from: .session("lead")) else { return }
        #expect(book.answer(.bind(grant: worker, root: root, session: "w"), from: .session("lead"), bound: .init(command: "claude --model fable -- go")) == .ok)
        try app.setReviewFloor(LeadReviewFloor().with(workerModel: "opus"), root: root)
        var board = LeadBoard()
        let commit = String(repeating: "ab", count: 20)
        let asked = board.ask("Audit held at \(commit.prefix(12)): which may audit it?", options: ["Audit held at \(commit.prefix(12)) on sonnet"],
                              priority: nil, whyNow: nil, proposal: nil, decideIn: nil, task: "held")
        // A question no audit asked: said so.
        #expect(LeadEngine.auditFacts(question: asked, root: root, vault: app) == ["no audit of held asked this question (the vault has no record of it): an answer to it allows no model"])
        #expect(book.answer(.offerAuditModels(root: root, task: "held", commit: commit, question: asked.id), from: .session("lead")) == .ok)
        let facts = LeadEngine.auditFacts(question: asked, root: root, vault: app)
        #expect(facts.contains("the audit of held at \(commit.prefix(12)) asked it: an answer allows that model for that commit only, once"), "\(facts)")
        #expect(facts.contains("workers' model: opus, by your review floor") && facts.contains("its workers were launched on: fable (the host's record)"), "\(facts)")
        #expect(LeadEngine.mayAskAuditModel(asked))
        // A worker can't file an offer.
        guard case .refused = book.answer(.offerAuditModels(root: root, task: "held", commit: commit, question: "q"), from: .session("w")) else {
            Issue.record("a worker filed an offer")
            return
        }
    }
}
