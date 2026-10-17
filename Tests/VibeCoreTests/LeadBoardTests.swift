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
        #expect(Slug.make(String(repeating: "long ", count: 30), taken: []).count <= 24)
        // Branch and worktree names stay short: the first few words.
        #expect(Slug.make("Add an add.sh script that sums two integers and prints the result", taken: []) == "add-an-add-sh")
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

struct BoardSafetyTests {
    @Test func anUnreadableBoardIsNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("board-\(UUID().uuidString)").path
        let store = BoardStore(root: root)
        try store.update { $0.tasks.append(LeadTask(slug: "one", title: "One", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))) }
        let file = root + "/.vibeswitcher/board.json"
        let edited = try String(contentsOfFile: file, encoding: .utf8).replacingOccurrences(of: "\"planned\"", with: "\"someday\"")
        try edited.write(toFile: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try store.update { $0.updates = [] } }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == edited)
    }

    @Test func aHeldLockIsReported() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)").path
        let held = FileLock.attempt(path)
        #expect(held != nil)
        #expect(FileLock.attempt(path) == nil)
        held?.release()
        #expect(FileLock.attempt(path) != nil)
    }
}

struct LeadSetupTests {
    @Test func aRepositoryWithNoLeadFolderYetIsSetUp() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        Git.run(["init", "-q", "-b", "main"], in: root)
        let workflow = try BoardStore(root: root).prepare()
        #expect(workflow == root + "/.vibeswitcher/workflow.md")
        #expect(try String(contentsOfFile: workflow, encoding: .utf8) == LeadWorkflow.template)
        #expect(Git.run(["check-ignore", "-q", ".vibeswitcher/workflow.md"], in: root).ok)
        // Your edits stay.
        try "---\nmax_workers: 1\n---".write(toFile: workflow, atomically: true, encoding: .utf8)
        _ = try BoardStore(root: root).prepare()
        #expect(try String(contentsOfFile: workflow, encoding: .utf8).contains("max_workers: 1"))
    }
}

