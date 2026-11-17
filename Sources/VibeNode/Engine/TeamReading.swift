import Foundation
import VibeCore

/// What the witness reads of a lead's team at each look, on the engine's reads queue (`LeadEngine.reads`): a team's
/// transcripts are a few hundred KB each to parse (thirty of them froze the app's window when read on its main thread).
/// The sessions as they were when the look began, what each member it watches is doing (`LeadObserver.watching`), the
/// oldest message waiting for each worker, and the project's workflow.
///
/// The app's `TeamReading` (`Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift` 215-272), copied (the port
/// map's "Copied from the app"): the steer inboxes are read under the engine's root (`inbox`) and the Mac-wide test lock
/// is a parameter (`lock`), never this process's `VibePaths.root` (one root per test).
struct TeamReading {
    typealias Watched = (activity: LeadActivity, tail: TranscriptTail?, progress: TranscriptProgress?)

    /// The host's sessions, and the scan's agents in them, by host session id.
    var hosted: [String: HostSession] = [:]
    var sessions: [String: Session] = [:]
    var watched: [String: Watched] = [:]
    var held: [String: SteerMessage] = [:]
    /// The live workers with a run in line for the Mac-wide test and build lock (see `LeadWitness.Seen.lockWait`).
    var lockWaits: [String: TestLock.Wait] = [:]
    var workflow = LeadWorkflow()
    /// The lead's loop runs with workflow.md's auto_advance on: a verifier that ends without a verdict is its to
    /// audit again (see `LeadWitness.leftToAdvance`). Looked at only while a task is in review.
    var advancing = false
    /// The live members with no agent in the scan whose agent's process has exited, by a process table read here (see
    /// `HostSession.agentRuns`): only these have quit. One whose agent waits on a background command runs on.
    var agentGone: Set<String> = []

    /// The member `id`'s agent quit, leaving its session's shell open: the scan has no agent on it a minute on
    /// (`scanSaysQuit`, see `TableRead.agentQuit`), and its agent's own process has exited (`agentGone`).
    func agentQuit(_ id: String, session: Session?, scanSaysQuit: Bool) -> Bool {
        session == nil && scanSaysQuit && agentGone.contains(id)
    }

    /// Each live member's transcript is read whatever it shows: a worker's stall is one that reads as working too (see
    /// `LeadStall`), and a turn that ended on the account's usage limit reads as working (Claude Code fires no Stop hook
    /// on it): its transcript says so (see `UsageLimit`). `inbox`: the engine's root, whose steer inboxes hold what waits
    /// for each worker. `lock`: the Mac-wide test and build lock its workers queue on (none: no wait is read).
    static func read(root: String, board: LeadBoard, hosted: [String: HostSession], sessions: [String: Session],
                     observer: LeadObserver, inbox: URL, lock: TestLock?) -> TeamReading {
        var team = TeamReading(hosted: hosted, sessions: sessions)
        let workers = workerSessions(board)
        for id in board.tasks.flatMap(\.watched) where team.watched[id] == nil {
            guard let info = hosted[id], info.isLive, let session = sessions[id] else { continue }
            team.watched[id] = observer.watching(info, agentPid: session.pid)
            if workers.contains(id) {
                team.held[id] = SteerInbox.pending(tty: session.tty, root: inbox).filter { $0.agentPid == session.pid }.min { $0.at < $1.at }
            }
        }
        let folders = workers.compactMap { id in hosted[id].flatMap { $0.isLive ? (id, $0.cwd) : nil } }
        if !folders.isEmpty, let lock {
            team.lockWaits = lock.waits(for: Dictionary(folders, uniquingKeysWith: { first, _ in first }))
        }
        team.workflow = LeadWorkflow.load(from: (BoardStore(root: root).folder as NSString).appendingPathComponent("workflow.md"))
        team.advancing = team.workflow.autoAdvance && board.tasks.contains { $0.status == .review } && LeadAdvance.running(BoardStore(root: root))
        // The table is read only when the scan lacks a member's agent (rare), here off the engine's queue.
        let unseen = board.tasks.flatMap(\.watched).compactMap { id in
            hosted[id].flatMap { $0.isLive && sessions[id] == nil ? (id: id, session: $0) : nil }
        }
        if !unseen.isEmpty, let table = ProcessTable.trySnapshot() {
            team.agentGone = Set(unseen.filter { !$0.session.agentRuns(in: table) }.map(\.id))
        }
        return team
    }

    /// The sessions whose shells, held messages and test-lock waits are read: each task's worker and each team
    /// member's (`LeadTask.memberSessions`), watched as the worker is.
    static func workerSessions(_ board: LeadBoard) -> Set<String> {
        Set(board.tasks.flatMap { task in [task.worker].compactMap { $0 } + task.memberSessions.map(\.session) })
    }
}
