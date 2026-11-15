import Foundation
import VibeCore

/// Each project's lead, by project id (`NodeIds.project(root:)`; the engine plan's E4): its root, the lead session
/// running for it (the live session labelled as its lead, the one its board names where two share the root), the
/// session the board names, the session the vault binds the lead's role to (EN-D14), the sessions a start replaced
/// (`StatusRules.replacedLeads`), the messages held for it (a goal for a running lead, what waited in a replaced lead's
/// inbox: E5 delivers them), and what its last start said. `status` shows it. On the engine's queue; `changes` carries
/// each project's value as it changes.
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
        /// A start is under way.
        public var starting = false
        /// What the last start said (`started`, `shown`, `waiting`, or a refusal), and when.
        public var lastStart: String?
        public var lastStartAt: Date?

        public init(project: String, root: String) {
            self.project = project
            self.root = root
        }

        public var value: NodeWire.Value {
            .object(["project": .string(project), "root": .string(root),
                     "session": session.map { .string(NodeIds.session(host: $0)) } ?? .null,
                     "named": named.map(NodeWire.Value.string) ?? .null, "bound": bound.map(NodeWire.Value.string) ?? .null,
                     "replaced": .array(replaced.keys.sorted { $0.uuidString < $1.uuidString }.map { .string(NodeIds.session(host: $0)) }),
                     "held": .int(held), "starting": .bool(starting),
                     "lastStart": lastStart.map(NodeWire.Value.string) ?? .null,
                     "lastStartAt": lastStartAt.map(NodeWire.Value.date) ?? .null])
        }
    }

    /// A message held for a project's lead until it can be delivered (E5's): its text and sender, in the order sent.
    public struct Held: Equatable, Sendable {
        public var text: String
        public var from: SteerMessage.Sender
        public init(text: String, from: SteerMessage.Sender) {
            self.text = text
            self.from = from
        }
    }

    public let changes = Changes<Lead>()
    /// By project id. On the engine's queue.
    public private(set) var leads: [String: Lead] = [:]
    /// The messages held for each project's lead, in the order sent. On the engine's queue.
    public private(set) var held: [String: [Held]] = [:]
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

    /// Holds `message` for `root`'s lead, after what's held already.
    func hold(_ message: Held, root: String) {
        let project = NodeIds.project(root: root)
        held[project, default: []].append(message)
        lead(root: root) { $0.held = self.held[project]?.count ?? 0 }
    }

    /// The messages held for `project`'s lead, taken out (E5 delivers them).
    public func takeHeld(project: String) -> [Held] {
        let taken = held.removeValue(forKey: project) ?? []
        if let lead = leads[project] { self.lead(root: lead.root) { $0.held = 0 } }
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
