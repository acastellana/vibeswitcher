import Foundation
import Testing
@testable import VibeCore

/// The disk never fills up silently: cleanup takes a task's temporary folders and build output too, the lead is told
/// before the disk fills, start_worker refuses on a nearly full disk, and a full disk doesn't send an agent the same
/// messages round and round.
struct DiskSpaceTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }
    static let gb = DiskSpace.gigabyte

    func folder(_ name: String) throws -> URL {
        let url = temp.url(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    func repo() throws -> String {
        let root = try folder("disk-lead").path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// A folder with a file of `bytes` in it (and a session's subfolder, as Claude makes them).
    @discardableResult
    func fill(_ url: URL, bytes: Int = 4096) throws -> URL {
        let session = url.appendingPathComponent(UUID().uuidString).appendingPathComponent("scratchpad")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: session.appendingPathComponent("output.log"))
        return url
    }

    /// Claude's temporary folder for sessions run in `folder`, under `scratch`.
    func temporary(for folder: String, in scratch: URL) -> URL {
        scratch.appendingPathComponent(ClaudeScratch.name(for: folder), isDirectory: true)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Claude's temporary folders

    @Test func claudeNamesAFoldersTemporaryFolderByItsPath() {
        #expect(ClaudeScratch.name(for: "/Users/albert/dev/vibeswitcher/.vibeswitcher/worktrees/fix-the-chat-layout")
                == "-Users-albert-dev-vibeswitcher--vibeswitcher-worktrees-fix-the-chat-layout")
    }

    /// Past 200 characters Claude cuts the name and adds a hash of the whole path (these are from its own code, run
    /// with Node): a deep project's tasks, alike for 200 characters, keep folders of their own.
    @Test func claudeCutsALongNameAndHashesThePath() throws {
        let deep = "/Users/x/dev/" + String(repeating: "a-very-long-project-folder-name/", count: 6) + ".vibeswitcher/worktrees/"
        #expect(ClaudeScratch.name(for: deep + "fix-the-chat-layout") == "-Users-x-dev-"
                + String(repeating: "a-very-long-project-folder-name-", count: 5) + "a-very-long-project-folder--yokhzf")
        #expect(ClaudeScratch.name(for: "/tmp/é/" + String(repeating: "x", count: 200))
                == "-tmp---" + String(repeating: "x", count: 193) + "-2pechf")
        // Counted in UTF-16 units, as JavaScript does: a character beyond them is two.
        #expect(ClaudeScratch.name(for: "/tmp/🙂/" + String(repeating: "x", count: 200))
                == "-tmp----" + String(repeating: "x", count: 192) + "-7dc8pv")

        let scratch = try folder("scratch")
        try fill(temporary(for: deep + "fix-the-chat", in: scratch))
        try fill(temporary(for: deep + "fix-the-chat-layout", in: scratch))
        #expect(ClaudeScratch.folders(for: deep + "fix-the-chat", in: scratch).map(\.lastPathComponent) == [ClaudeScratch.name(for: deep + "fix-the-chat")])
        #expect(ClaudeScratch.folders(for: deep + "fix-the-chat-layout", in: scratch).map(\.lastPathComponent)
                == [ClaudeScratch.name(for: deep + "fix-the-chat-layout")])
    }

    @Test func onlyTheFoldersOwnTemporaryFolderIsFound() throws {
        let scratch = try folder("scratch")
        let worktree = "/Users/x/dev/app/.vibeswitcher/worktrees/fix-the-chat"
        try fill(temporary(for: worktree, in: scratch))
        // A task whose name only starts the same, and another project's task of the same name.
        try fill(temporary(for: worktree + "-layout", in: scratch))
        try fill(temporary(for: "/Users/x/dev/other/.vibeswitcher/worktrees/fix-the-chat", in: scratch))
        #expect(ClaudeScratch.folders(for: worktree, in: scratch).map(\.lastPathComponent) == [ClaudeScratch.name(for: worktree)])
    }

    // MARK: cleanup

    @Test func cleanupRemovesTheTasksTemporaryFoldersAndBuildOutput() throws {
        let root = try repo()
        let scratch = try folder("scratch")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.scratchRoot = scratch
        lead.freeSpace = { _ in 100 * Self.gb }
        for title in ["One", "One more"] { _ = lead.call("add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        #expect(!lead.call("start_worker", ["task": "one"]).isError)
        #expect(!lead.call("start_worker", ["task": "one-more"]).isError)
        let worktree = Worktrees.path(root: root, slug: "one")
        let build = URL(fileURLWithPath: worktree).appendingPathComponent(".build")
        try fill(build, bytes: 100_000)
        // The worker's and the verifier's sessions both ran in the worktree: one temporary folder, a subfolder each.
        let mine = try fill(fill(temporary(for: worktree, in: scratch), bytes: 200_000))
        let running = try fill(temporary(for: Worktrees.path(root: root, slug: "one-more"), in: scratch))
        let otherProject = try fill(temporary(for: "/Users/x/dev/other/.vibeswitcher/worktrees/one", in: scratch))

        let cleaned = lead.call("cleanup", ["task": "one", "force": true])
        #expect(!cleaned.isError)
        #expect(cleaned.text.contains("freed"))
        #expect(!exists(mine))
        #expect(!exists(build))
        #expect(!FileManager.default.fileExists(atPath: worktree))
        // A running task's folder and another project's stay.
        #expect(exists(running))
        #expect(exists(otherProject))
    }

    @Test func cleanupTakesWhatFinishedTasksLeftBehindToo() throws {
        let root = try repo()
        let scratch = try folder("scratch")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.scratchRoot = scratch
        lead.freeSpace = { _ in 100 * Self.gb }
        for title in ["Old", "New"] { _ = lead.call("add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        _ = lead.call("start_worker", ["task": "old"])
        #expect(!lead.call("cleanup", ["task": "old", "force": true]).isError)
        // Its sessions wrote there after (or an older cleanup didn't know to remove it).
        let left = try fill(temporary(for: Worktrees.path(root: root, slug: "old"), in: scratch))
        _ = lead.call("start_worker", ["task": "new"])
        #expect(!lead.call("cleanup", ["task": "new", "force": true]).isError)
        #expect(!exists(left))
        // And cleanup of a task already cleaned up just takes what's left.
        let again = try fill(temporary(for: Worktrees.path(root: root, slug: "old"), in: scratch))
        #expect(!lead.call("cleanup", ["task": "old", "force": true]).isError)
        #expect(!exists(again))
    }

    // MARK: Low disk space

    @Test func theWitnessTellsTheLeadOncePerEpisode() throws {
        let root = try repo()
        let scratch = try folder("scratch")
        var free: Int64 = 20 * Self.gb
        var disk = LeadWitness.Disk(free: { _ in free }, scratch: scratch)
        var board = LeadBoard()
        board.tasks = [LeadTask(slug: "big", title: "Big", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: "")),
                       LeadTask(slug: "small", title: "Small", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))]
        board.tasks[0].status = .done
        try fill(temporary(for: Worktrees.path(root: root, slug: "big"), in: scratch), bytes: 2_000_000)
        try fill(temporary(for: Worktrees.path(root: root, slug: "small"), in: scratch), bytes: 10_000)
        let workflow = LeadWorkflow()
        let tell = { () -> String? in disk.event(root: root, board: board, workflow: workflow) }

        #expect(tell() == nil)
        free = 8 * Self.gb
        let told = try #require(tell())
        #expect(told.contains("8.0 GB free"))
        #expect(told.contains("big's temporary folder 2"))
        #expect(told.contains("finished: cleanup removes it"))
        let big = try #require(told.range(of: "big's")), small = try #require(told.range(of: "small's"))
        #expect(big.lowerBound < small.lowerBound)
        // Still low, lower, or back up a little: the same episode.
        for level in [7.0, 2.0, 10.5] {
            free = DiskSpace.bytes(level)
            #expect(tell() == nil)
        }
        // Back up for real, then low again: a new episode.
        free = 12 * Self.gb
        #expect(tell() == nil)
        free = 9 * Self.gb
        #expect(tell()?.contains("9.0 GB free") == true)
    }

    @Test func theWarningIsSetInTheWorkflow() throws {
        var disk = LeadWitness.Disk(free: { _ in 15 * Self.gb }, scratch: try folder("scratch"))
        let root = try repo()
        #expect(disk.check(root: root, workflow: LeadWorkflow()) == nil)
        let workflow = LeadWorkflow.parse("---\ndisk_warning_gb: 20\ndisk_floor_gb: 1.5\n---")
        #expect(workflow.diskWarningGB == 20)
        #expect(workflow.diskFloorGB == 1.5)
        #expect(disk.check(root: root, workflow: workflow) == 15 * Self.gb)
        #expect(LeadWorkflow.parse("---\ndisk_warning_gb: lots\n---").diskWarningGB == 10)
        #expect(LeadWorkflow.template.contains("disk_warning_gb: 10"))
        #expect(LeadWorkflow.parse(LeadWorkflow.template).diskFloorGB == 3)
    }

    @Test func statusShowsLowDiskSpaceWithWhatTakesIt() throws {
        let root = try repo()
        let scratch = try folder("scratch")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.scratchRoot = scratch
        lead.freeSpace = { _ in 50 * Self.gb }
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "one"])
        try fill(temporary(for: Worktrees.path(root: root, slug: "one"), in: scratch), bytes: 300_000)
        #expect(!lead.call("status", [:]).text.contains("Disk space is low"))
        lead.freeSpace = { _ in 6 * Self.gb }
        let status = lead.call("status", [:]).text
        #expect(status.contains("Disk space is low: 6.0 GB free"))
        #expect(status.contains("one's temporary folder"))
        #expect(status.contains("one's worktree"))
    }

    @Test func startWorkerRefusesBelowTheFloor() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.scratchRoot = try folder("scratch")
        var asked: [String] = []
        lead.freeSpace = { path in asked.append(path); return 2 * Self.gb }
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        let refused = lead.call("start_worker", ["task": "one"])
        #expect(refused.isError)
        #expect(refused.text.contains("only 2.0 GB free"))
        #expect(refused.text.contains("disk_floor_gb (3 GB"))
        #expect(runtime.spawned.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "one")))
        #expect(BoardStore(root: root).load().task("one")?.status == .planned)
        // The volume asked about is the worktrees'.
        #expect(asked.last == root + "/.vibeswitcher/worktrees")
        // A lower floor, set with configure, lets it start.
        #expect(!lead.call("configure", ["disk_floor_gb": 1]).isError)
        #expect(!lead.call("start_worker", ["task": "one"]).isError)
        #expect(runtime.spawned.count == 1)
    }

    @Test func configureSetsAndClearsTheDiskLimits() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let set = lead.call("configure", ["disk_warning_gb": "25", "disk_floor_gb": 2.5])
        #expect(!set.isError)
        #expect(set.text.contains("disk_warning_gb: 25"))
        #expect(lead.workflow.diskFloorGB == 2.5)
        #expect(lead.call("configure", ["disk_floor_gb": "-1"]).isError)
        #expect(!lead.call("configure", ["disk_warning_gb": ""]).isError)
        #expect(lead.workflow.diskWarningGB == 10)
    }

    // MARK: A full disk and the inbox

    func stop(_ root: URL, disk full: Bool, written: inout [String]) -> Data? {
        var out: [String] = []
        let reply = SteerReply.answer(["hook_event_name": "Stop"], tty: "ttys001", agentPid: 42, root: root,
                                      check: { url, ids in full ? false : SteerInbox.writeCheck(url, ids: ids) },
                                      write: { out.append(String(decoding: $0, as: UTF8.self)); return true })
        written += out
        return reply
    }

    @Test func aFullDiskTellsTheAgentOnceAndThenStaysQuiet() throws {
        let root = temp.url("steer")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 1...7 {
            try SteerInbox.post(SteerMessage(id: "r\(index)", text: "report \(index)", from: .system("worker"), agentPid: 42), tty: "ttys001", root: root)
        }
        var written: [String] = []
        // The disk is full: one notice, the reports still waiting, none of them handed.
        let first = try #require(stop(root, disk: true, written: &written))
        let object = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "Stop")
        let reason = try #require(specific["additionalContext"] as? String)
        #expect(reason.contains("disk is probably full"))
        #expect(reason.contains("7 messages wait"))
        #expect(!reason.contains("report 1"))
        // Every Stop after that, while it's full: nothing (a reply would keep the agent going round).
        for _ in 0..<10 { #expect(stop(root, disk: true, written: &written) == nil) }
        #expect(written.count == 1)
        #expect(SteerInbox.pending(tty: "ttys001", root: root).count == 7)
        #expect(SteerInbox.delivered(tty: "ttys001", root: root).isEmpty)
        // A write succeeds: the reports go, once.
        let delivered = try #require(stop(root, disk: false, written: &written))
        #expect(String(decoding: delivered, as: UTF8.self).contains("report 7"))
        #expect(SteerInbox.delivered(tty: "ttys001", root: root) == Set((1...7).map { "r\($0)" }))
        #expect(SteerInbox.pending(tty: "ttys001", root: root).isEmpty)
        #expect(stop(root, disk: false, written: &written) == nil)
        // Full again later: told again, once.
        try SteerInbox.post(SteerMessage(id: "r8", text: "report 8", from: .system("worker"), agentPid: 42), tty: "ttys001", root: root)
        #expect(stop(root, disk: true, written: &written).map { String(decoding: $0, as: UTF8.self).contains("A message waits") } == true)
        #expect(stop(root, disk: true, written: &written) == nil)
        #expect(SteerInbox.pending(tty: "ttys001", root: root).map(\.id) == ["r8"])
    }

    @Test func theAppTypesTheNoticeOnceToo() throws {
        let root = temp.url("steer")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SteerInbox.post(SteerMessage(id: "a", text: "hello", from: .lead("lead"), agentPid: 42), tty: "ttys001", root: root)
        var handed: [[String]] = []
        for _ in 0..<3 {
            SteerInbox.deliver(tty: "ttys001", agentPid: 42, root: root, check: { _, _ in false }) { messages in
                handed.append(messages.map(\.id))
                return messages.count
            }
        }
        #expect(handed == [["disk-full"]])
        #expect(SteerInbox.pending(tty: "ttys001", root: root).map(\.id) == ["a"])
    }

    @Test func theCheckIsARealWrite() throws {
        let url = try folder("check").appendingPathComponent("ttys001.check")
        #expect(SteerInbox.writeCheck(url, ids: ["a", "b"]))
        #expect(try String(contentsOf: url, encoding: .utf8) == "a\nb\n")
        #expect(!SteerInbox.writeCheck(URL(fileURLWithPath: "/no/such/folder/ttys001.check"), ids: ["a"]))
    }
}

extension DiskSpaceTests {
    @Test func workersAreToldToKeepTheirTemporaryFolderSmall() {
        let task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        #expect(LeadPrompts.worker(task: task, root: "/r", workflow: LeadWorkflow()).contains("Keep your temporary folder small"))
    }
}
