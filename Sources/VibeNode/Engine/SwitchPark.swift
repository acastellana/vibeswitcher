import Foundation
import VibeCore

/// A build switch parks the workers that only wait on their lead (2026-11-21: a real switch waited about an hour and a
/// half because the lead kept finished workers open, and the rule on switches refuses while any worker or verifier
/// session lives).
///
/// **Why not carry them across.** Decision 6 (the security architecture's S8, the start plan's ST-D15) keeps the switch
/// between tasks: a switched server is replaced once idle, with a 30 s bound, on the grounds that no team member's request
/// is in flight, and a worker's tool server and its box would cross the handover. An idle worker still has both, and its
/// lead can wake it with one message at any moment, so the rule's reason holds for it too. So a worker isn't carried: it
/// is parked, as the lead's `stop_worker` ends one and as `releaseWorker` frees a finished worker's slot during its
/// audit. Its session ends, its worktree, branch and commits stay, the board marks its end as no news (`stopped`), and
/// `start_worker` continues there when the lead needs it again (a worker's conversation isn't resumed: as after a host
/// restart, `RestartResume.swift`).
///
/// **Which.** Only a task's own worker, live, labelled a worker's, idle between turns with nothing waiting: not mid-turn,
/// not at a prompt, not on a background command (`LeadActivity.idle(background: nil)`, read now from its transcript), no
/// message held for it in its inbox, and none delivered since its last report (`messagedAt` before `since`). It is looked
/// at again and ended under the task's delivery lock (`deliver-<slug>`, the lead's `deliver` takes it too), so no message
/// goes in between. A verifier, a finder, a team member, or a worker mid-turn is never parked: the switch is refused
/// naming it, as before.
///
/// **When.** Only inside `build.switch`, the user's voice behind the typed code, after the checks that would refuse the
/// switch anyway (the target installed, no held change). Each lead is told which of its workers were parked and why.
public enum SwitchPark {
    /// A worker parked, or one that would be (`status`'s `switchParks`).
    public struct Worker: Equatable, Sendable {
        public var root: String
        public var slug: String
        public var session: UUID
        public var tty: String
        public var label: String

        /// As `switchBlockers` names a session: its terminal and label.
        public var named: String { "\(tty) (\(ConfigSeal.inert(label, limit: 80)))" }
    }

    /// Whether `task`'s `worker` may be parked by what it looks like now. `activity`: what its transcript says;
    /// `held`: whether a message waits for it in its inbox.
    public static func parkable(task: LeadTask, worker: String, activity: LeadActivity?, held: Bool) -> Bool {
        guard task.worker?.lowercased() == worker.lowercased(), task.stopped?.lowercased() != worker.lowercased(), !held,
              let activity, activity.text == LeadActivity.idle(background: nil).text else { return false }
        return (task.messagedAt ?? 0) < (task.since ?? .infinity)
    }

    /// The lead's message for `parked` (its own workers), from the node.
    public static func told(_ parked: [Worker], commit: String) -> String {
        let tasks = parked.map(\.slug).joined(separator: ", ")
        return "The user switched VibeSwitcher's build (to \(commit.prefix(12))). A switch runs only between turns, so the "
            + (parked.count == 1 ? "worker" : "workers") + " of \(tasks), idle since "
            + (parked.count == 1 ? "its" : "their") + " last report, "
            + (parked.count == 1 ? "was" : "were") + " ended for it (parked, as stop_worker ends one): "
            + (parked.count == 1 ? "its worktree, branch and commits stay" : "their worktrees, branches and commits stay")
            + ". start_worker continues there when you need "
            + (parked.count == 1 ? "it" : "them") + " again."
    }
}

extension LeadEngine {
    /// The live workers that only wait on their lead, by the witness's last look (`idleWorkers`): what `status` says a
    /// switch would park. A hint only: `parkForSwitch` looks again. On `queue`.
    func switchParkHint(_ live: [HostSession]) -> [SwitchPark.Worker] {
        candidates(live).filter { idleWorkers[$0.root]?.contains($0.session.uuidString.lowercased()) == true }
    }

    /// Each live session labelled a worker's that is a board's task's worker, not yet marked stopped. On `queue`.
    private func candidates(_ live: [HostSession]) -> [SwitchPark.Worker] {
        live.compactMap { session -> SwitchPark.Worker? in
            guard session.isLive, LeadTeams.role(label: session.label) == .worker else { return nil }
            let id = session.id.uuidString.lowercased()
            for (root, board) in boards {
                if let task = board.tasks.first(where: { $0.worker?.lowercased() == id && $0.stopped?.lowercased() != id }) {
                    return SwitchPark.Worker(root: root, slug: task.slug, session: session.id, tty: session.tty, label: session.label)
                }
            }
            return nil
        }
    }

    /// Parks the workers of `live` that only wait on their lead (`SwitchPark`), for a switch to `commit`: each looked at
    /// again and ended under its task's delivery lock, its board's task marked, a progress line written, its lead told.
    /// `done` hears on `queue` the workers parked. From the engine's queue.
    func parkForSwitch(_ live: [HostSession], commit: String, done: @escaping ([SwitchPark.Worker]) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let found = candidates(live)
        guard !found.isEmpty else { return done([]) }
        let scanned = Dictionary((sessions?.sessions ?? []).compactMap { session in session.hostID.map { ($0, session) } },
                                 uniquingKeysWith: { first, _ in first })
        let hosted = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let (observer, inbox, link, note) = (observer, root, link, note)
        reads.async({ _ -> [SwitchPark.Worker] in
            var parked: [SwitchPark.Worker] = []
            for worker in found {
                guard let info = hosted[worker.session], let scan = scanned[worker.session] else { continue }
                let id = worker.session.uuidString
                let store = BoardStore(root: worker.root)
                let ended = (try? Self.underDeliveryLock(store: store, slug: worker.slug) { () -> Bool in
                    guard let task = store.load().task(worker.slug) else { return false }
                    let activity = observer.watching(info, agentPid: scan.pid).activity
                    let held = !SteerInbox.pending(tty: scan.tty, root: inbox).filter { $0.agentPid == scan.pid }.isEmpty
                    guard SwitchPark.parkable(task: task, worker: id, activity: activity, held: held) else { return false }
                    link.kill(worker.session)
                    try? store.update { board in
                        guard let index = board.taskIndex(worker.slug), board.tasks[index].worker?.lowercased() == id.lowercased() else { return }
                        board.tasks[index].stopped = board.tasks[index].worker
                    }
                    try? store.appendProgress("Parked \(worker.slug)'s worker (idle since its last report) for a build switch to \(commit.prefix(12)); start_worker continues in its worktree")
                    return true
                }) ?? false
                if ended { parked.append(worker) }
            }
            return parked
        }) { [weak self] parked in
            guard let self else { return done(parked) }
            for root in Set(parked.map(\.root)) {
                let mine = parked.filter { $0.root == root }
                note("build.switch: parked \(mine.map(\.slug).joined(separator: ", ")) in \(LeadMail.project(of: root)) (idle since their last report)")
                let text = SwitchPark.told(mine, commit: commit)
                deliver(built: { text }, from: .system("vibeswitcher"), root: root, action: nil)
            }
            done(parked)
        }
    }

    /// `body` holding the task's delivery lock, the lead's own (`LeadToolset.exclusively("deliver-<slug>")`:
    /// `.vibeswitcher/run/deliver-<slug>.lock`), so no message to the worker goes in between a look and its end.
    static func underDeliveryLock<T>(store: BoardStore, slug: String, _ body: () throws -> T) throws -> T {
        let folder = (store.folder as NSString).appendingPathComponent("run")
        try? VibePaths.ensurePrivate(URL(fileURLWithPath: folder, isDirectory: true))
        let path = (folder as NSString).appendingPathComponent("deliver-\(slug).lock")
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ParkRefusal("couldn't open \(path) to take its lock: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw ParkRefusal("couldn't take the lock \(path): \(String(cString: strerror(errno)))") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// Why a delivery lock couldn't be taken.
struct ParkRefusal: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
