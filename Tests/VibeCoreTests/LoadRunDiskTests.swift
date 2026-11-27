import Foundation
import Testing
@testable import VibeCore

/// New work waits while the disk can't hold the load runs of the tasks in flight (see `LoadRunDisk`): on 2026-11-18
/// the disk sat at 11–14 GB free against scripts/test-under-load.sh's 15 GB floor, five finished workers waited one to
/// three hours for their required load run, and new workers kept starting and taking more. The free-disk reading is
/// injected; the floor is the fixture project's own load script's.
extension LeadAdvanceTests {
    static let gb = DiskSpace.gigabyte

    /// The fixture team, its project with a load script whose floor is 15, and its disk reading `free`'s.
    func diskTeam(_ free: Locked<Int64>) throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let (root, runtime, lead) = try team()
        try FileManager.default.createDirectory(atPath: root + "/scripts", withIntermediateDirectories: true)
        try commit("scripts/test-under-load.sh", "#!/bin/bash\n# Not on a nearly full disk.\nfloor_gb=15\nfree_gb=1\n", in: root)
        lead.freeSpace = { _ in free.get() }
        return (root, runtime, lead)
    }

    /// The threshold: 15 GiB plus disk_headroom_gb's 6 GB.
    static let threshold = LoadRunDisk.bytes(15) + 6 * gb

    @Test func theFloorIsReadFromTheProjectsLoadScript() throws {
        let root = try repo()
        #expect(LoadRunDisk.floorGB(root: root) == nil)
        try FileManager.default.createDirectory(atPath: root + "/scripts", withIntermediateDirectories: true)
        try "x=1\n  floor_gb=12.5   # GB\nfloor_gb=99\n".write(toFile: root + "/scripts/test-under-load.sh", atomically: true, encoding: .utf8)
        #expect(LoadRunDisk.floorGB(root: root) == 12.5)
        // This repository's own script reads (its line kept as one floor_gb=N).
        let ours = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        #expect(LoadRunDisk.floorGB(root: ours) != nil)
        #expect(LeadWorkflow.parse(LeadWorkflow.template).diskHeadroomGB == 6)
        #expect(LeadWorkflow.parse("---\ndisk_headroom_gb: 2.5\n---").diskHeadroomGB == 2.5)
        #expect(LeadWorkflow().diskHeadroomGB == 6)
    }

    @Test func startWorkerWaitsForTheDiskTheTasksInFlightNeedAndIsWokenWhenItsBack() throws {
        let free = Locked<Int64>(12 * Self.gb)
        let (root, runtime, lead) = try diskTeam(free)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        let refused = lead.call("start_worker", ["task": "one"])
        #expect(refused.isError)
        // Free space, the floor and the headroom, named.
        #expect(refused.text.contains("only 12.0 GB of disk free, under the 22.1 GB a new worker waits for"), "\(refused.text)")
        #expect(refused.text.contains("floor_gb=15 in scripts/test-under-load.sh"), "\(refused.text)")
        #expect(refused.text.contains("disk_headroom_gb (6 GB in workflow.md)"), "\(refused.text)")
        #expect(refused.text.contains("VibeSwitcher sends you one message once there's room again"), "\(refused.text)")
        #expect(runtime.spawned.isEmpty)
        #expect(task("one", root)?.status == .planned)
        // status's Mac line: the free disk, and that starts wait for it.
        let held = try #require(lead.call("status", [:]).text.split(separator: "\n").first { $0.hasPrefix("Mac (all projects)") })
        #expect(held.contains("12.0 GB of disk free") && held.contains("New workers wait for disk"), "\(held)")

        // The room-again witness: not while the disk is still short, once when it's back.
        var waits = roomWaits
        let disk = Locked<Int64>(20 * Self.gb)
        waits.freeSpace = { path in
            #expect(path == root + "/.vibeswitcher/worktrees")
            return disk.get()
        }
        let mac = MacLoad.count([], load: 1)
        #expect(waits.look(mac: mac, limits: MacLimits(maxSessions: 6)).isEmpty)
        disk.set(23 * Self.gb)
        let told = waits.look(mac: mac, limits: MacLimits(maxSessions: 6))
        #expect(told.map(\.root) == [root])
        #expect(told.first?.text.hasPrefix("The Mac has room again for what was refused: start_worker(one). ") == true, "\(told)")
        #expect(told.first?.text.contains("23.0 GB of disk free") == true, "\(told)")
        #expect(waits.look(mac: mac, limits: MacLimits(maxSessions: 6)).isEmpty)

        // Above the threshold: it starts as before, and status says no hold.
        free.set(Self.threshold)
        #expect(!lead.call("start_worker", ["task": "one"]).isError)
        #expect(runtime.spawned.count == 1)
        let roomy = try #require(lead.call("status", [:]).text.split(separator: "\n").first { $0.hasPrefix("Mac (all projects)") })
        #expect(roomy.contains("22.1 GB of disk free") && !roomy.contains("New workers wait"), "\(roomy)")
        // A roomy disk (twice the room or more) goes unsaid: status stays bounded.
        free.set(2 * Self.threshold)
        let ample = try #require(lead.call("status", [:]).text.split(separator: "\n").first { $0.hasPrefix("Mac (all projects)") })
        #expect(!ample.contains("of disk free") && !ample.contains("New workers wait"), "\(ample)")
    }

    /// A task in flight whose worker starts again in its worktree (blocked, sent back from an audit, a failed merge)
    /// takes no new disk: only a worker that makes a worktree waits.
    @Test func aWorkerRestartedInItsTasksWorktreeDoesntWaitForDisk() throws {
        let free = Locked<Int64>(Self.threshold)
        let (root, runtime, lead) = try diskTeam(free)
        for title in ["One", "Two"] { _ = lead.call("add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        #expect(!lead.call("start_worker", ["task": "one"]).isError)
        let blocked = try seat("worker-one", runtime).call("report", ["status": "blocked", "summary": "needs a decision"])
        #expect(!blocked.isError, "\(blocked.text)")
        #expect(task("one", root)?.status == .blocked)
        let stopped = lead.call("stop_worker", ["task": "one"])
        #expect(!stopped.isError, "\(stopped.text)")
        free.set(12 * Self.gb)
        let restarted = lead.call("start_worker", ["task": "one"])
        #expect(!restarted.isError, "\(restarted.text)")
        #expect(runtime.spawned.count == 2)
        let refused = lead.call("start_worker", ["task": "two"])
        #expect(refused.isError && refused.text.contains("only 12.0 GB of disk free"), "\(refused.text)")
        #expect(runtime.spawned.count == 2)
    }

    @Test func theHeadroomIsTheLeadsToSetAndAProjectWithoutALoadScriptIsntHeld() throws {
        let free = Locked<Int64>(17 * Self.gb)
        let (root, runtime, lead) = try diskTeam(free)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        #expect(lead.call("start_worker", ["task": "one"]).isError)
        #expect(!lead.call("configure", ["disk_headroom_gb": 0]).isError)
        #expect(lead.workflow.diskHeadroomGB == 0)
        #expect(lead.call("configure", ["disk_headroom_gb": "-1"]).isError)
        #expect(!lead.call("start_worker", ["task": "one"]).isError)
        #expect(runtime.spawned.count == 1)
        // No load script: no load run to keep room for.
        Git.run(["rm", "-q", "scripts/test-under-load.sh"], in: root)
        free.set(5 * Self.gb)
        _ = lead.call("add_task", ["title": "Two", "goal": "g", "acceptance": ["a"]])
        #expect(!lead.call("configure", ["disk_headroom_gb": 6]).isError)
        let started = lead.call("start_worker", ["task": "two"])
        #expect(!started.isError, "\(started.text)")
    }

    @Test func autoAdvanceHoldsPlannedTasksWithTheReasonAndStartsThemWhenRoomReturns() async throws {
        let free = Locked<Int64>(13 * Self.gb)
        let (root, runtime, lead) = try diskTeam(free)
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Waits", "goal": "g", "acceptance": ["a"]])
        #expect(await advancing.until { reports(runtime).contains { $0.contains("Planned tasks wait to start") } }, "\(reports(runtime))")
        let said = try #require(reports(runtime).first { $0.contains("Planned tasks wait to start") })
        #expect(said.contains("only 13.0 GB of disk free, under the 22.1 GB a new worker waits for"), "\(said)")
        #expect(said.contains("floor_gb=15") && said.contains("disk_headroom_gb (6 GB"), "\(said)")
        #expect(task("waits", root)?.status == .planned)
        #expect(runtime.spawned.isEmpty)
        let kept = roomWaits.waits()
        #expect(kept.count == 1 && kept[0].wait.auto == true && kept[0].wait.what == "start_worker(waits)" && kept[0].wait.disk == Self.threshold,
                "\(kept)")
        // Said once: more passes don't say it again.
        await advancing.settle()
        #expect(reports(runtime).filter { $0.contains("Planned tasks wait to start") }.count == 1)

        // Room again: the app's watch nudges this lead's server (telling the lead nothing), and the task starts.
        free.set(Self.threshold)
        var waits = roomWaits
        waits.freeSpace = { _ in free.get() }
        #expect(waits.look(mac: MacLoad.count([], load: 0.5), limits: MacLimits(maxSessions: 6)).isEmpty)
        #expect(roomWaits.waits().isEmpty)
        #expect(await advancing.until { task("waits", root)?.status == .running })
    }

    /// While boosted, the favored project's start that waits for disk keeps no sessions' room (audit finding F1): it
    /// can't take them until the disk has room, which can be hours, so another project's start or audit isn't held for
    /// it, by start_worker's check (`heldFor`) or the witness's (`look`). Once its disk is back, it keeps its room again.
    @Test func aFavoredStartWaitingForDiskKeepsNoRoomForItsSessions() {
        let alpha = "/Users/x/dev/alpha", beta = "/Users/x/dev/beta"
        let free = Locked<Int64>(12 * Self.gb)
        var waits = roomWaits
        waits.freeSpace = { path in path.hasPrefix(alpha + "/") ? free.get() : 100 * Self.gb }
        let now = Date()
        waits.record(root: alpha, what: "start_worker(a)", need: 1, disk: Self.threshold, now: now)
        // One session's room left: alpha's, or beta's.
        let mac = MacLoad(load: 2, holders: [MacLoad.Holder(project: "gamma", sessions: 5)])
        let limits = MacLimits(maxSessions: 6).boosted(by: BoostState(on: true, why: "automatic: away, on AC",
                                                                      limits: BoostLimits(maxSessions: 6), favored: alpha))
        #expect(limits.maxSessions == 6)
        #expect(waits.heldFor(root: beta, need: 1, mac: mac, limits: limits, now: now) == nil)
        // The lead's reader is the one read when given.
        #expect(waits.heldFor(root: beta, need: 1, mac: mac, limits: limits, freeSpace: { _ in 100 * Self.gb }, now: now)?.what == "start_worker(a)")
        waits.record(root: beta, what: "start_worker(b)", need: 1, now: now + 1)
        #expect(waits.look(mac: mac, limits: limits, now: now + 2).map(\.root) == [beta])
        #expect(waits.waits().map(\.wait.root) == [alpha])

        // The disk back: alpha's start keeps its room again, and is woken first.
        free.set(Self.threshold)
        #expect(waits.heldFor(root: beta, need: 1, mac: mac, limits: limits, now: now)?.what == "start_worker(a)")
        waits.record(root: beta, what: "start_worker(c)", need: 1, now: now + 3)
        #expect(waits.look(mac: mac, limits: limits, now: now + 4).map(\.root) == [alpha])
        #expect(waits.waits().map(\.wait.root) == [beta])
    }
}
