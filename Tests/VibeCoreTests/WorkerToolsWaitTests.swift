import Foundation
import Testing
@testable import VibeCore

/// A worker's start, as issue #2 left it: its role is bound before its trust question is answered (Claude Code can
/// start its tool server at once), and a worker whose tools never connect is ended, its grant withdrawn, and the lead
/// told so, rather than left running unable to report.
struct WorkerToolsWaitTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func addTask(_ lead: LeadToolset) {
        let added = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "boundaries": ["only b.txt"]])
        #expect(!added.isError, "\(added.text)")
    }

    @Test func theRoleIsBoundBeforeTheTrustQuestionIsAnswered() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        addTask(lead)
        var boundAtTrust: String?
        runtime.onTrust = { _ in boundAtTrust = self.vault.current(.worker, root: root, task: "add-b")?.session ?? "none" }
        let started = lead.call("start_worker", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        let session = try #require(runtime.spawned.last)
        #expect(session.trust)
        #expect(boundAtTrust == session.id)
    }

    @Test func aWorkerWhoseToolsNeverConnectIsEndedAndTheLeadIsTold() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.toolsWait = 0.3
        lead.toolsPoll = 0.02
        addTask(lead)
        // Nothing asks the host who it is in the worker's session: its tool server never started.
        let started = lead.call("start_worker", ["task": "add-b"])
        #expect(started.isError)
        #expect(started.text.contains("add-b's worker was ended"), "\(started.text)")
        #expect(started.text.contains("vibeswitcher tools didn't connect"), "\(started.text)")
        #expect(started.text.contains("grant was withdrawn"), "\(started.text)")
        let session = try #require(runtime.spawned.last?.id)
        #expect(runtime.killed == [session])
        #expect(vault.current(.worker, root: root, task: "add-b") == nil)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .planned)
    }

    @Test func aWorkerWhoseToolServerAsksIsStarted() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.toolsWait = 30
        lead.toolsPoll = 0.02
        addTask(lead)
        // The worker's tool server asks who it is as soon as it starts, and again until its role is bound.
        let asked = DispatchSemaphore(value: 0)
        // Unowned: the runtime keeps this closure, and the test's scratch folders go only once both are gone.
        runtime.onSpawn = { [unowned runtime] session in
            let seat = FakeSeat(runtime, agent: LeadAgent(pid: 7000, tty: "ttys070", session: session))
            let mine = self.vault(for: seat)
            Thread.detachNewThread {
                while (try? mine.whoami(root: root)) == nil { Thread.sleep(forTimeInterval: 0.01) }
                asked.signal()
            }
        }
        let started = lead.call("start_worker", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        #expect(asked.wait(timeout: .now() + 30) == .success)
        #expect(runtime.killed.isEmpty)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .running)
    }
}
