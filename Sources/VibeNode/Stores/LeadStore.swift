import Foundation
import VibeCore

/// Each project's lead, by project id (`NodeIds.project(root:)`; the engine plan's E4): its root, the lead session
/// running for it (the live session labelled as its lead, the one its board names where two share the root), the
/// session the board names, the session the vault binds the lead's role to (EN-D14), the sessions a start replaced
/// (`StatusRules.replacedLeads`), the messages held for it (a goal for a running lead, what waited in a replaced lead's
/// inbox, a message sent while no lead the vault binds runs: E5 delivers them, and keeps them at rest in `engine.json`),
/// how many reports have waited for it too long, a notice when its board names a session the vault doesn't bind, and
/// what its last start said. `status` shows it. On the engine's queue; `changes` carries each project's value as it
/// changes.
public final class LeadStore: @unchecked Sendable {
    /// One project's lead, as `status` shows it.
    public struct Lead: Equatable, Sendable {
        public var project: String
        public var root: String
        /// The live lead session for the project, if one runs.
        public var session: UUID?
        /// The session the board names as the lead (`board.leadSession`), as last read.
        public var named: String?
        /// The session the vault binds the project's lead role to, as last asked.
        public var bound: String?
        /// Live lead sessions another session of the project replaced: each with the one that replaced it.
        public var replaced: [UUID: UUID] = [:]
        /// How many messages wait for the lead (E5 delivers them).
        public var held = 0
        /// How many reports have waited for the lead too long to be woken for (`LeadWake.waiting`: its draft, a dialog).
        public var reportsWaiting = 0
        /// What's wrong with delivering to it, when something is: the board names a session the vault doesn't bind the
        /// lead's role to (EN-D14), so what's sent to the lead is held.
        public var notice: String?
        /// A start is under way.
        public var starting = false
        /// What the last start said (`started`, `shown`, `waiting`, or a refusal), and when.
        public var lastStart: String?
        public var lastStartAt: Date?
        /// The push its lead asked for (push_remote) while it's open, as the vault last said (`PushAsks.swift`): the
        /// user settles it with `vibeswitcher push` or `decline-push`.
        public var push: LeadPush.Request?

        public init(project: String, root: String) {
            self.project = project
            self.root = root
        }

        public var value: NodeWire.Value {
            .object(["project": .string(project), "root": .string(root),
                     "session": session.map { .string(NodeIds.session(host: $0)) } ?? .null,
                     "named": named.map(NodeWire.Value.string) ?? .null, "bound": bound.map(NodeWire.Value.string) ?? .null,
                     "replaced": .array(replaced.keys.sorted { $0.uuidString < $1.uuidString }.map { .string(NodeIds.session(host: $0)) }),
                     "held": .int(held), "reportsWaiting": .int(reportsWaiting),
                     "notice": notice.map(NodeWire.Value.string) ?? .null, "starting": .bool(starting),
                     "lastStart": lastStart.map(NodeWire.Value.string) ?? .null,
                     "lastStartAt": lastStartAt.map(NodeWire.Value.date) ?? .null,
                     "push": push.map(Self.pushValue) ?? .null])
        }

        /// A push request as the wire carries it.
        static func pushValue(_ request: LeadPush.Request) -> NodeWire.Value {
            .object(["id": .string(request.id), "commit": .string(request.commit), "short": .string(request.short),
                     "branch": .string(request.branch), "remote": .string(request.remote), "target": .string(request.target),
                     "url": .string(request.url), "ahead": .int(request.ahead), "subjects": .array(request.subjects.map(NodeWire.Value.string)),
                     "askedAt": .date(Date(timeIntervalSince1970: request.askedAt))])
        }
    }

    /// A message held for a project's lead until it can be delivered (E5's): its text and sender, its place among what
    /// was sent (held messages go in that order), and the action id of the user's request that made it (EN-D9).
    public struct Held: Equatable, Sendable {
        /// Its id in the lead's inbox once posted, the same at rest and after a restart: one already there isn't posted
        /// again.
        public var id: String
        public var text: String
        public var from: SteerMessage.Sender
        /// Nil until it's held: `hold` gives it the next place.
        public var order: Int?
        public var action: String?
        public init(id: String = UUID().uuidString, text: String, from: SteerMessage.Sender, order: Int? = nil, action: String? = nil) {
            self.id = id
            self.text = text
            self.from = from
            self.order = order
            self.action = action
        }
    }

    public let changes = Changes<Lead>()
    /// By project id. On the engine's queue.
    public private(set) var leads: [String: Lead] = [:]
    /// The messages held for each project's lead, in the order sent. On the engine's queue.
    public private(set) var held: [String: [Held]] = [:]
    /// Called on the engine's queue each time what's held changed (the engine keeps it at rest).
    var heldChanged: () -> Void = {}
    /// The last place given to a message sent to a lead.
    private var sent = 0
    /// Lead sessions a start replaced, with their root: replaced from that moment, before the new lead's board names
    /// it (the app's `replacing`).
    private var replacing: [UUID: String] = [:]

    public init() {}

    /// The project of `root`, made when it's first seen.
    @discardableResult
    func lead(root: String, _ change: (inout Lead) -> Void = { _ in }) -> Lead {
        let project = NodeIds.project(root: root)
        var lead = leads[project] ?? Lead(project: project, root: root)
        change(&lead)
        leads[project] = lead
        changes.send(project, lead)
        return lead
    }

    /// The next place among what's sent to the leads.
    func next() -> Int {
        sent += 1
        return sent
    }

    /// Holds `message` for `root`'s lead, among what's held in the order sent (one without a place gets the next).
    func hold(_ message: Held, root: String) {
        let project = NodeIds.project(root: root)
        var message = message
        let order = message.order ?? next()
        message.order = order
        sent = max(sent, order)
        var waiting = held[project] ?? []
        waiting.insert(message, at: waiting.firstIndex { ($0.order ?? 0) > order } ?? waiting.endIndex)
        held[project] = waiting
        lead(root: root) { $0.held = waiting.count }
        heldChanged()
    }

    /// The held message of `project` at `order` went: it's held no more.
    func delivered(project: String, order: Int?) {
        guard let index = held[project]?.firstIndex(where: { $0.order == order }) else { return }
        held[project]?.remove(at: index)
        if held[project]?.isEmpty == true { held[project] = nil }
        if let lead = leads[project] { self.lead(root: lead.root) { $0.held = self.held[project]?.count ?? 0 } }
        heldChanged()
    }

    /// The messages held for `project`'s lead, taken out.
    public func takeHeld(project: String) -> [Held] {
        let taken = held.removeValue(forKey: project) ?? []
        if let lead = leads[project] { self.lead(root: lead.root) { $0.held = 0 } }
        if !taken.isEmpty { heldChanged() }
        return taken
    }

    /// `session` was replaced by a start of `root`'s lead.
    func replacing(_ session: UUID, root: String) {
        replacing[session] = root
    }

    /// A start of `root`'s lead that would have replaced a session didn't happen: nothing it marked stays marked.
    func notReplacing(root: String) {
        replacing = replacing.filter { $0.value != root }
    }

    /// The live lead sessions by root, from the host's list (`sessions`) and the session each root's board names
    /// (`named`, read on the reads queue, only where two share a root): the one the board names, else the newest (the
    /// app's `leadSessions`).
    static func leadSessions(_ sessions: [HostSession], named: (String) -> String?) -> [String: HostSession] {
        var result: [String: HostSession] = [:]
        for session in sessions where session.isLive && LeadTeams.role(label: session.label) == .lead {
            let root = (session.cwd as NSString).standardizingPath
            if let other = result[root] {
                let named = named(root)
                if other.id.uuidString == named || (session.id.uuidString != named && session.startedAt < other.startedAt) { continue }
            }
            result[root] = session
        }
        return result
    }

    /// Every project's lead session and replaced sessions from the host's list now (`sessions`) and the boards' named
    /// leads as last read (`holders`, by root): a replaced session is one a start replaced, or one labelled as its
    /// project's lead other than the one its board names while that one runs too (`StatusRules.replacedLeads`).
    func update(sessions: [HostSession], holders: [String: UUID]) {
        let live = sessions.filter { $0.isLive && LeadTeams.role(label: $0.label) == .lead }
        replacing = replacing.filter { id, _ in live.contains { $0.id == id } }
        let running = Self.leadSessions(sessions) { root in holders[root]?.uuidString }
        let pairs = live.map { (id: $0.id, root: ($0.cwd as NSString).standardizingPath) }
        var replaced = StatusRules.replacedLeads(pairs, holders: holders)
        for (id, root) in replacing where replaced[id] == nil {
            if let holder = running[root], holder.id != id { replaced[id] = holder.id }
        }
        let roots = Set(leads.values.map(\.root)).union(running.keys)
        for root in roots {
            let current = leads[NodeIds.project(root: root)]
            let session = running[root]?.id
            let mine = replaced.filter { id, _ in pairs.contains { $0.id == id && $0.root == root } }
            guard current?.session != session || current?.replaced != mine || current == nil else { continue }
            lead(root: root) {
                $0.session = session
                $0.replaced = mine
            }
        }
    }
}
