import Foundation
import VibeCore

/// `stop` without the node's server (the start plan's S3, ST-D7), in its two forms: the unit stopped through the user
/// manager (`systemctl --user stop vibeswitcher-node`, which acts on the unit, not on whatever listens on the
/// server's socket), or, on a machine without systemd, the host its record names ended by signal, once it is checked to
/// be that host. `StopSequence` runs either only after the typed code and the journal entry.
public enum NodeStopper {
    /// How long `systemctl --user stop` is given: the unit's `TimeoutStopSec` and 15 s more.
    public static let unitWait = TimeInterval(NodeUnit.timeoutStop + 15)

    /// `systemctl --user stop vibeswitcher-node` (by its absolute path, with `NodeStarter.environment(runtimeFolder:)`
    /// and nothing of this process's), waited for `wait` at most: nil, or a refusal naming the call.
    ///
    /// The plan's `stopUnit(systemctl:wait:)` takes the runtime folder too: the manager is reached through it, never
    /// through this process's `XDG_RUNTIME_DIR` (2026-11-16).
    public static func stopUnit(systemctl: String, runtimeFolder: String, wait: TimeInterval = unitWait) -> Result<Void, StartRefusal> {
        let arguments = ["--user", "stop", NodeStarter.unitName]
        let call = ConfigSeal.inert(([systemctl] + arguments).joined(separator: " "), limit: .max)
        guard let ran = NodeStarter.run(systemctl, arguments, environment: NodeStarter.environment(runtimeFolder: runtimeFolder), timeout: wait) else {
            return .failure(StartRefusal("\(call) couldn't be run, or didn't end within \(Int(wait)) s; see journalctl --user -u \(NodeStarter.unitName)", exitCode: 1))
        }
        guard ran.status == 0 else {
            return .failure(StartRefusal("\(call) exited \(ran.status); see journalctl --user -u \(NodeStarter.unitName)", exitCode: 1))
        }
        return .success(())
    }

    /// The host `root`'s record names, checked (`NodeCheck.recordedHost`: its start, its command line by `isHost`,
    /// non-dumpable), with its command line; or why nothing will be ended: no live host recorded (69, the node isn't
    /// running), or the pid now names another process ("nothing ended", and that removing the record clears it: a
    /// start replaces it too; the review of S3).
    public static func detachedHost(root: String, isHost: ([String]) -> Bool) -> Result<(record: NodeRecord, arguments: [String]), StartRefusal> {
        let record = NodeRecord.read(root: root)
        switch NodeCheck.recordedHost(record, isHost: isHost) {
        case .none(let why):
            return .failure(StartRefusal("the node isn't running: \(why) (\(ConfigSeal.inert(NodeRecord.path(root: root), limit: .max)))", exitCode: 69))
        case .other(let why):
            return .failure(StartRefusal("\(why); nothing ended (remove \(ConfigSeal.inert(NodeRecord.path(root: root), limit: .max)) to clear the record, or run `vibeswitcher start`, which replaces it)"))
        case .host(let pid):
            guard let record else { return .failure(StartRefusal("no host is recorded; nothing ended", exitCode: 69)) }
            return .success((record: record, arguments: Platform.Processes.arguments(pid)))
        }
    }

    /// Ends the host `root`'s record names, only once `detachedHost` takes it: SIGTERM, then SIGKILL after `grace`
    /// (the host checked again by its start first), collecting it when it is this process's child (a test). Then the
    /// processes found under it end too: waited for 10 s, then killed (each checked by its start). The record is removed
    /// once its host has ended.
    ///
    /// Without systemd no cgroup holds the host's processes, so they are found by the tree (`gathered`): what is under
    /// the host before its SIGTERM, read again every 100 ms while it ends and once more before its SIGKILL (a child it
    /// starts in its grace), then what is under each process found, read again once the host has ended and before
    /// each is killed (a child a session starts meanwhile). Not `KillMode=control-group`: a process that left the tree
    /// before it was read (a daemon a session's program double-forked, now init's) isn't found and outlives the stop
    /// (the security architecture document's S3 and S11 item 13, the weaker rule; the review of S3).
    public static func stopDetached(root: String, isHost: ([String]) -> Bool, grace: TimeInterval = 30) -> Result<Void, StartRefusal> {
        let record: NodeRecord
        switch detachedHost(root: root, isHost: isHost) {
        case .failure(let refused): return .failure(refused)
        case .success(let found): record = found.record
        }
        var under = gathered([], host: record.pid, while: record)
        Sys.kill(record.pid, SIGTERM)
        if !ended(record, within: grace, gathering: &under) {
            under = gathered(under, host: record.pid, while: record)
            if record.isLive() { Sys.kill(record.pid, SIGKILL) }
            guard ended(record, within: 10, gathering: &under) else {
                return .failure(StartRefusal("the node's host (pid \(record.pid)) didn't end, even after SIGKILL", exitCode: 1))
            }
        }
        endLeft(gathered(under, host: nil))
        NodeRecord.remove(root: root, ifStill: record)
        return .success(())
    }

    /// Whether `record`'s process ends within `wait` (collected when it is this process's child), adding what is under
    /// it to `under` every 100 ms meanwhile.
    static func ended(_ record: NodeRecord, within wait: TimeInterval, gathering under: inout [Platform.Processes.Link]) -> Bool {
        let deadline = MacTime.real.awake() + wait
        var looked = MacTime.real.awake()
        while true {
            if record.hasEnded() { return true }
            let now = MacTime.real.awake()
            guard now < deadline else { return false }
            if now - looked >= 0.1 {
                under = gathered(under, host: record.pid, while: record)
                looked = now
            }
            usleep(10_000)
        }
    }

    /// `known` (each still taken while it runs from its recorded start, or not: the caller checks again before it
    /// signals), with what is under `host` now (nil: the host has ended, its pid may be another's) and what is under
    /// each of `known` that still runs, each once (by pid and start), in the order found.
    public static func gathered(_ known: [Platform.Processes.Link], host: pid_t?) -> [Platform.Processes.Link] {
        var found = known
        func add(_ links: [Platform.Processes.Link]) {
            for link in links where !found.contains(where: { $0.pid == link.pid && $0.startTicks == link.startTicks }) { found.append(link) }
        }
        if let host { add(descendants(of: host)) }
        for link in known where NodeRecord.liveTicks(link.pid) == link.startTicks { add(descendants(of: link.pid)) }
        return found
    }

    /// `gathered` with the host's tree read only while `record` still names it (by its start, checked after the read:
    /// a pid given to another process meanwhile adds none of that one's children).
    static func gathered(_ known: [Platform.Processes.Link], host: pid_t, while record: NodeRecord) -> [Platform.Processes.Link] {
        let found = gathered(known, host: host)
        return record.isLive() ? found : gathered(known, host: nil)
    }

    /// The processes under `pid` (its children, theirs, and so on), each with its start: each read after its parent's
    /// listing, and taken only while its link still names that parent.
    static func descendants(of pid: pid_t) -> [Platform.Processes.Link] {
        var found: [Platform.Processes.Link] = []
        var next = Platform.Processes.children(pid).map { (pid: $0, parent: pid) }
        while let (child, parent) = next.popLast() {
            guard let link = Platform.Processes.link(child), link.parent == parent, !found.contains(where: { $0.pid == child }) else { continue }
            found.append(link)
            next += Platform.Processes.children(child).map { (pid: $0, parent: child) }
        }
        return found
    }

    /// Waits 10 s for each of `processes` to end, then kills those still running and what is under them now (each by
    /// its start) and waits 10 s more.
    static func endLeft(_ processes: [Platform.Processes.Link]) {
        func runs(_ link: Platform.Processes.Link) -> Bool { NodeRecord.liveTicks(link.pid) == link.startTicks }
        var running = processes
        for round in 0..<2 {
            let deadline = MacTime.real.awake() + 10
            while true {
                running = running.filter(runs)
                if running.isEmpty || MacTime.real.awake() >= deadline { break }
                usleep(20_000)
            }
            guard round == 0 else { break }
            running = gathered(running, host: nil)
            for link in running where runs(link) { Sys.kill(link.pid, SIGKILL) }
        }
    }
}
