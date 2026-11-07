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
}
