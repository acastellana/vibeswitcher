import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// Your answer approving a held merge, as the app records it: on the board, and in the vault for the task whose branch
/// is at that commit, where merge looks for it. A scratch repository, inbox and home; the host client never connects
/// (no lead runs: what the lead is told is held).
@MainActor
struct LeadApprovalAnswerTests {
    let temp = Scratch()

    struct World {
        let root: String
        let commit: String
        let vault: LeadVault
        let controller: LeadController
    }

    func world(vault: LeadVault? = nil) throws -> World {
        AppStatus.enabled = false
        let url = temp.url("approval")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        Git.run(["checkout", "-q", "-b", "agent/change"], in: root)
        try "two\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["commit", "-q", "-am", "change"], in: root)
        Git.run(["checkout", "-q", "main"], in: root)
        let commit = Git.run(["rev-parse", "agent/change"], in: root).output

        let book = LeadVault.Book()
        let folder = temp.url("vault")
        let vault = vault ?? book.vault(folder: folder, as: { .app })
        let inbox = temp.url("inbox")
        let home = temp.url("home")
        let stateDir = temp.url("state")
        for dir in [inbox, home, stateDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let host = HostClient(socketPath: "/tmp/vsh-ap-\(UUID().uuidString.prefix(8)).sock")
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        let controller = LeadController(host: host, store: store, vault: vault, inbox: inbox, home: home.path) { _ in "exec /bin/sleep 600 #" }
        controller.answersTrust = false
        return World(root: root, commit: commit, vault: vault, controller: controller)
    }

    func ask(_ world: World, _ options: [String]) throws -> LeadQuestion {
        try BoardStore(root: world.root).update { board in
            board.ask("Merge change?", options: options, priority: .blocking, whyNow: nil, proposal: nil, decideIn: nil)
        }
    }

    func answered(_ world: World, _ question: LeadQuestion) -> Bool {
        BoardStore(root: world.root).load().questions.first { $0.id == question.id }?.answer != nil
    }

    @Test func yourApprovalIsRecordedInTheVaultForTheTaskAtThatCommit() async throws {
        let world = try world()
        let approval = LeadWorkflow.approval(of: world.commit)
        let notYet = try ask(world, [approval, "Not yet"])
        world.controller.answer(notYet, root: world.root, with: "Not yet")
        #expect(await until { answered(world, notYet) })
        #expect(try !world.vault.approved(root: world.root, task: "change", commit: world.commit))

        let question = try ask(world, [approval, "Not yet"])
        world.controller.answer(question, root: world.root, with: approval)
        #expect(await until { (try? world.vault.approved(root: world.root, task: "change", commit: world.commit)) == true })
        #expect(world.controller.answerNotices[question.id] == nil)
        // Bound to the task and the commit.
        #expect(try !world.vault.approved(root: world.root, task: "other", commit: world.commit))
        #expect(try !world.vault.approved(root: world.root, task: "change", commit: String(repeating: "0", count: 40)))
    }

    @Test func anApprovalOfACommitNoTaskIsAtSaysItWasntRecorded() async throws {
        let world = try world()
        let nowhere = LeadWorkflow.approval(of: String(repeating: "0", count: 40))
        let question = try ask(world, [nowhere, "Not yet"])
        world.controller.answer(question, root: world.root, with: nowhere)
        #expect(await until { world.controller.answerNotices[question.id] != nil })
        #expect(world.controller.answerNotices[question.id]?.contains("wasn't recorded") == true)
        #expect(answered(world, question))
    }

    @Test func aVaultThatRefusesTheApprovalSaysSo() async throws {
        // The vault as it answers anything but the app.
        let refusing = LeadVault.Book().vault(folder: temp.url("vault"), as: { .unknown })
        let world = try world(vault: refusing)
        let approval = LeadWorkflow.approval(of: world.commit)
        let question = try ask(world, [approval, "Not yet"])
        world.controller.answer(question, root: world.root, with: approval)
        #expect(await until { world.controller.answerNotices[question.id] != nil })
        #expect(world.controller.answerNotices[question.id]?.contains("Your approval wasn't recorded") == true)
        #expect(try !refusing.approved(root: world.root, task: "change", commit: world.commit))
    }
}
