import Foundation
import Testing
@testable import VibeCore

struct LeadBoardTests {
    func repo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("board-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        return url
    }

    @Test func boardRoundTripsThroughItsFile() throws {
        let store = BoardStore(root: try repo().path)
        let task = try store.update { board -> LeadTask in
            let task = LeadTask(slug: "add-login", title: "Add login",
                                contract: LeadContract(goal: "Users can log in", acceptance: ["test passes"], boundaries: ["only auth/"], context: ""))
            board.tasks.append(task)
            return task
        }
        #expect(store.load().tasks.map(\.slug) == ["add-login"])
        #expect(store.load().tasks.first?.status == .planned)
        try store.update { board in board.tasks[0].status = .running }
        #expect(store.load().task(task.id)?.status == .running)
    }

    @Test func concurrentUpdatesDontLoseWrites() throws {
        let store = BoardStore(root: try repo().path)
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            try? store.update { board in board.updates.append(LeadUpdate(title: "u\(index)", body: "")) }
        }
        #expect(store.load().updates.count == 20)
    }

    @Test func slugsAreSafeAndUnique() {
        #expect(Slug.make("Add login page!", taken: []) == "add-login-page")
        #expect(Slug.make("Add login page", taken: ["add-login-page"]) == "add-login-page-2")
        #expect(Slug.make("../../etc", taken: []) == "etc")
        #expect(Slug.make("Ünïcode ✨ title", taken: []) == "unicode-title")
        #expect(Slug.make("!!!", taken: []) == "task")
        #expect(Slug.make(String(repeating: "long ", count: 30), taken: []).count <= 40)
    }

    @Test func theFolderIsExcludedFromGitOnce() throws {
        let root = try repo()
        let store = BoardStore(root: root.path)
        try store.ensureExcluded()
        try store.ensureExcluded()
        let exclude = try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.components(separatedBy: "\n").filter { $0 == "/.vibeswitcher/" }.count == 1)
    }

    @Test func progressAndDecisionsAreAppended() throws {
        let store = BoardStore(root: try repo().path)
        try store.appendProgress("Planned two tasks")
        try store.appendProgress("Merged add-login")
        try store.appendDecision("Use SQLite", why: "no server to run")
        let progress = try String(contentsOfFile: store.folder + "/progress.md", encoding: .utf8)
        #expect(progress.contains("Planned two tasks") && progress.contains("Merged add-login"))
        let decisions = try String(contentsOfFile: store.folder + "/decisions.md", encoding: .utf8)
        #expect(decisions.contains("Use SQLite") && decisions.contains("no server to run"))
    }
}
