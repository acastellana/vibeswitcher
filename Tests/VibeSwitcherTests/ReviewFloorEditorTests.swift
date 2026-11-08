import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// Settings › Project lead's review rules floor as the editor reads and saves it (`ReviewFloorEditor`).
@MainActor
struct ReviewFloorEditorTests {
    let temp = Scratch()

    /// Who asked the vault from the main thread.
    final class Asks: @unchecked Sendable {
        private let lock = NSLock()
        private var onMain: [Bool] = []
        func add(_ main: Bool) { lock.lock(); onMain.append(main); lock.unlock() }
        var all: [Bool] { lock.lock(); defer { lock.unlock() }; return onMain }
    }

    /// Settings opens on General, which shows the floor: its vault read (a host call that waits up to its timeout)
    /// runs off the main thread, and the floor it reads is shown when it answers.
    @Test func theFloorIsReadAndSavedOffTheMainThread() async throws {
        let root = temp.url("project").resolvingSymlinksInPath().path
        try VibePaths.ensurePrivate(URL(fileURLWithPath: BoardStore(root: root).folder))
        try LeadWorkflow.write(Data(LeadWorkflow.template.utf8), to: ReviewFloorEditor.workflowPath(root))
        let book = LeadVault.Book()
        let asks = Asks()
        let vault = LeadVault(folder: temp.url("vault")) { request in
            asks.add(Thread.isMainThread)
            return book.answer(request, from: .app)
        }
        let floor = LeadReviewFloor(auditFinders: 2, mergePolicy: .askSensitive, auditSamplePercent: 20)
        try vault.setReviewFloor(floor, root: root)
        let before = asks.all.count

        let editor = ReviewFloorEditor(vault: vault, projects: { [root] })
        editor.reload()
        #expect(editor.root == root)
        let read = await editor.$recorded.values.first { $0 != nil }
        #expect(read == floor)
        #expect(editor.finders == 2 && editor.policy == .askSensitive)

        editor.finders = 3
        editor.save()
        let saved = await editor.$recorded.values.first { $0?.auditFinders == 3 }
        #expect(saved??.auditFinders == 3)
        let asked = Array(asks.all.dropFirst(before))
        #expect(asked.count == 2 && !asked.contains(true), "on the main thread: \(asked)")
        #expect(try vault.reviewFloor(root: root)?.auditFinders == 3)
    }

    /// Two projects with a lead's workflow.md, and an editor whose vault answers at once.
    func floors() throws -> (editor: ReviewFloorEditor, vault: LeadVault, a: String, b: String) {
        let (a, b) = (temp.url("a").resolvingSymlinksInPath().path, temp.url("b").resolvingSymlinksInPath().path)
        for root in [a, b] {
            try VibePaths.ensurePrivate(URL(fileURLWithPath: BoardStore(root: root).folder))
            try LeadWorkflow.write(Data(LeadWorkflow.template.utf8), to: ReviewFloorEditor.workflowPath(root))
        }
        let book = LeadVault.Book()
        let vault = LeadVault(folder: temp.url("vault")) { book.answer($0, from: .app) }
        try vault.setReviewFloor(LeadReviewFloor(auditFinders: 2), root: a)
        try vault.setReviewFloor(LeadReviewFloor(auditFinders: 4), root: b)
        let editor = ReviewFloorEditor(vault: vault, projects: { [a, b] }, inline: true)
        editor.reload()
        return (editor, vault, a, b)
    }

    /// Settings' category shown again reads the floor again: what you were writing stays, with Save still on offer.
    @Test func comingBackToTheCategoryKeepsTheDraft() throws {
        let (editor, vault, a, _) = try floors()
        #expect(editor.root == a && editor.finders == 2 && !editor.unsaved)
        editor.finders = 5
        editor.sensitive = "src/vault/"
        editor.reload()
        #expect(editor.finders == 5 && editor.sensitive == "src/vault/")
        #expect(editor.unsaved && editor.changed)
        #expect(try vault.reviewFloor(root: a)?.auditFinders == 2, "a draft isn't saved")
    }

    @Test func switchingProjectKeepsEachDraftAndShowsTheOthersOwn() throws {
        let (editor, _, a, b) = try floors()
        editor.finders = 5
        editor.root = b
        #expect(editor.finders == 4 && !editor.unsaved)
        editor.finders = 3
        editor.root = a
        #expect(editor.finders == 5 && editor.unsaved)
        editor.root = b
        #expect(editor.finders == 3 && editor.unsaved)
    }

    @Test func revertAndSaveEndTheDraftAndUntouchedFieldsFollowTheVault() throws {
        let (editor, vault, a, b) = try floors()
        editor.finders = 5
        editor.root = b
        editor.root = a
        #expect(editor.finders == 5)
        editor.revert()
        #expect(editor.finders == 2 && !editor.unsaved)
        editor.root = b
        editor.root = a
        #expect(editor.finders == 2, "a reverted draft doesn't come back")

        editor.finders = 3
        editor.save()
        #expect(!editor.unsaved && editor.recorded?.auditFinders == 3)
        #expect(try vault.reviewFloor(root: a)?.auditFinders == 3)

        // Nothing edited: the fields follow what the vault says now.
        try vault.setReviewFloor(LeadReviewFloor(auditFinders: 4), root: a)
        editor.reload()
        #expect(editor.finders == 4 && !editor.unsaved)
    }

    /// A draft put back by hand to what's recorded is no draft: nothing to Save or Revert.
    @Test func editsUndoneByHandLeaveNoDraft() throws {
        let (editor, _, a, b) = try floors()
        editor.finders = 5
        editor.finders = 2
        editor.root = b
        editor.root = a
        #expect(editor.finders == 2 && !editor.unsaved)
    }

    /// With no floor recorded the fields show the project's values: nothing typed, so nothing is a draft.
    @Test func noFloorRecordedIsNotADraftUntilYouEdit() throws {
        let root = temp.url("fresh").resolvingSymlinksInPath().path
        try VibePaths.ensurePrivate(URL(fileURLWithPath: BoardStore(root: root).folder))
        try LeadWorkflow.write(Data(LeadWorkflow.template.utf8), to: ReviewFloorEditor.workflowPath(root))
        let book = LeadVault.Book()
        let editor = ReviewFloorEditor(vault: LeadVault(folder: temp.url("vault-fresh")) { book.answer($0, from: .app) },
                                       projects: { [root] }, inline: true)
        editor.reload()
        #expect(editor.recorded == nil && !editor.unsaved && editor.changed)
        editor.finders = 3
        #expect(editor.unsaved)
        editor.reload()
        #expect(editor.finders == 3)
    }
}
