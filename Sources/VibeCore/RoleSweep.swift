import Foundation

/// The app ending what the lead's tools don't (an older build of them ends only a task's newest session, and only when
/// the lead calls cleanup): every worker and verifier session of a finished task (merged, folded, abandoned or cleaned
/// up), in every project the vault holds a team for, found by the vault's roster (see `LeadTeams.finishedRoles`), on
/// its own from the boards. And the witness of what still runs an hour on (an end the host didn't carry out): one
/// message across all projects (`LeadWitness.strandedText`), at most once an hour.
///
/// `look` runs on `queue` (the roster is a call to the host, the boards are files); the controller hands it the
/// window's sessions as they are and takes its ends and messages back to the main thread.
public final class RoleSweep: @unchecked Sendable {
    /// Every team's roster (the app's call to the host's vault). Throws when the host can't be asked or doesn't know
    /// the request (an older host): nothing is ended then.
    public var roster: () throws -> [LeadVault.RosterEntry]
    /// A repository's board, by its root.
    public var board: (String) -> LeadBoard
    /// Asks the host to end a session (the app's own kill).
    public var end: (HostSession) -> Void
    /// Tells the stranded sessions' message (every running lead, and the user).
    public var tell: (String) -> Void
    /// What the roster says each verifier submitted, by session (see `LeadWitness.Seen.submittedAt`).
    public var submitted: ([String: Double]) -> Void = { _ in }
    /// When each worker and verifier holding its role was bound to its session, and when its tools connected, by
    /// session (see `LeadWitness.Seen.boundAt`): one bound by a host that keeps the time.
    public var tools: ([String: (bound: Double, tools: Double?)]) -> Void = { _ in }
    /// How long a session asked to end has before it's asked again (and before it may be told as stranded).
    public var askAgainAfter: TimeInterval = 60
    /// What it ends is noted here: the app's breadcrumbs.
    public var note: (String) -> Void = { Breadcrumbs.shared.note($0) }

    public let queue: DispatchQueue
    /// When each session still running was first asked to end, and last.
    private var asked: [UUID: (first: Date, last: Date)] = [:]
    /// When the stranded sessions were last told.
    public private(set) var toldAt: Date?
    /// The boards as last read (only on `queue`).
    private var files = LeadFiles()

    public init(roster: @escaping () throws -> [LeadVault.RosterEntry], board: ((String) -> LeadBoard)? = nil,
                end: @escaping (HostSession) -> Void, tell: @escaping (String) -> Void,
                queue: DispatchQueue = DispatchQueue(label: "VibeSwitcher.role-sweep", qos: .utility)) {
        self.roster = roster
        self.queue = queue
        self.end = end
        self.tell = tell
        self.board = { _ in LeadBoard() }
        self.board = board ?? { [unowned self] root in self.files.board(root) }
    }

    /// One look, on `queue`: ends the finished tasks' role sessions not asked lately, and tells the stranded ones
    /// when an hour has passed since they were last told. `hosted`: the window's sessions; `idleSince`: since when
    /// one has been idle (nil while working, or not known); `agent`: its agent's pid and resident memory.
    public func look(hosted: [HostSession], idleSince: (HostSession) -> Double?, agent: (HostSession) -> (pid: Int32?, memory: Int64?), now: Date = Date()) {
        guard let roster = try? roster() else { return }
        submitted(roster.reduce(into: [:]) { all, entry in if let at = entry.submittedAt { all[entry.session] = at } })
        tools(roster.reduce(into: [:]) { all, entry in
            if entry.holds, let bound = entry.boundAt { all[entry.session] = (bound, entry.toolsAt) }
        })
        let live = Set(hosted.filter(\.isLive).map(\.id.uuidString))
        let roots = Set(roster.filter { live.contains($0.session) }.map(\.root))
        let boards = Dictionary(uniqueKeysWithValues: roots.map { ($0, board($0)) })
        files.keep(roots)
        let finished = LeadTeams.finishedRoles(roster, hosted: hosted, boards: boards)
        let running = Set(finished.map(\.session.id))
        asked = asked.filter { running.contains($0.key) }
        for role in finished {
            let id = role.session.id
            if let last = asked[id]?.last, now.timeIntervalSince(last) < askAgainAfter { continue }
            note("role sweep: ending the \(role.role.rawValue) on \(role.task.slug) (\(role.project), \(role.task.status.rawValue)), session \(id.uuidString.prefix(8)) pid \(role.session.childPID)\(asked[id] == nil ? "" : ", asked again")")
            asked[id] = (asked[id]?.first ?? now, now)
            end(role.session)
        }
        // Not one just asked to end: it has `askAgainAfter` to go first.
        let lingering = finished.filter { role in asked[role.session.id].map { now.timeIntervalSince($0.first) >= askAgainAfter } ?? true }
        let stranded = LeadTeams.stranded(lingering, idleSince: idleSince, agent: agent, now: now)
        guard let text = LeadWitness.strandedText(stranded, now: now),
              toldAt.map({ now.timeIntervalSince($0) >= LeadWitness.strandedEvery }) ?? true else { return }
        toldAt = now
        tell(text)
    }
}
