import Foundation

/// Which alerts reach you (a banner, its sound, and the phone's copy of it) and what they say. A project lead's team
/// notifies only when its work is all done or you're needed: a question the lead asks you, the lead's terminal waiting
/// on a prompt, something broken that waits on you. Its workers and verifiers ask their lead, not you, and the lead's
/// turns end many times on the way, so those stay silent. Your own sessions notify as Settings › Notifications says.
public enum AlertRules {
    /// Settings › Notifications: they apply to the team's alerts too.
    public struct Settings: Equatable, Sendable {
        public var needsInput: Bool
        public var done: Bool
        public var reminders: Bool
        public var sound: Bool

        public init(needsInput: Bool = true, done: Bool = true, reminders: Bool = true, sound: Bool = true) {
            self.needsInput = needsInput
            self.done = done
            self.reminders = reminders
            self.sound = sound
        }
    }

    public enum Kind: Equatable, Sendable { case needsYou, done, reminder }

    public struct Alert: Equatable, Sendable {
        public var kind: Kind
        /// The banner's lines.
        public var title: String
        public var subtitle: String?
        public var body: String
        /// The banner plays the alert sound. Without banners allowed, needing you still plays one (`Kind.needsYou`).
        public var sound: Bool
        /// The terminal it's about: a click opens its session, and a newer alert about it replaces this banner. Empty:
        /// none known.
        public var tty: String
        /// What the phone shows of it (`Notifier.onAlert`).
        public var phoneTitle: String
        public var phoneBody: String
        /// Told once: the question's version or the all-done mark it's about. nil: each time it happens.
        public var key: String?
    }

    /// What a lead's board says to the user.
    public enum LeadEvent: Equatable, Sendable {
        /// An open question for the user, new or revised.
        case asked(LeadQuestion, project: String, leadTTY: String?)
        /// The board cleared: the all-done card appeared.
        case allDone(LeadAllDone, project: String, leadTTY: String?)
        /// Something broke that waits on the user (a base branch moved outside the lead's merges refused one of its
        /// merges: `baseMoved`). `key`: told once (nil: each time).
        case broken(title: String, body: String, leadTTY: String?, key: String?)
    }

    /// Lets each told-once alert through once (by its `key`).
    public struct Gate: Sendable {
        public private(set) var told: Set<String> = []

        public init() {}

        public mutating func pass(_ alert: Alert?) -> Alert? {
            guard let alert else { return nil }
            if let key = alert.key, !told.insert(key).inserted { return nil }
            return alert
        }
    }

    /// A session went to needing input, or its turn ended (`SessionStore.onAttention`). `question`: for a lead, the
    /// first open question its board asks the user.
    public static func attention(_ session: Session, question: LeadQuestion?, settings: Settings) -> Alert? {
        let needsInput = session.status == .needsInput
        switch session.teamRole {
        case .worker?, .verifier?:
            // Asking its lead, or done for its lead: the lead handles it.
            return nil
        case .lead?:
            // A turn that ended on a question for you; one with nothing to ask is silent (the all-done card says when
            // the work is finished).
            guard needsInput else { return question.flatMap { asked($0, project: session.project, leadTTY: session.tty, settings: settings) } }
            // Its terminal waits on a prompt.
            guard settings.needsInput else { return nil }
            let title = leadNeedsYou(session.project)
            let body = session.detail ?? ""
            return Alert(kind: .needsYou, title: title, subtitle: session.task, body: body, sound: settings.sound,
                         tty: session.tty, phoneTitle: title, phoneBody: body, key: nil)
        case nil:
            guard needsInput ? settings.needsInput : settings.done else { return nil }
            let title = needsInput ? "\(session.displayName) needs your input" : "\(session.displayName) is done"
            return Alert(kind: needsInput ? .needsYou : .done, title: title, subtitle: session.task ?? session.agent.displayName,
                         body: session.detail ?? "", sound: needsInput && settings.sound, tty: session.tty, phoneTitle: title,
                         phoneBody: [session.task, session.detail].compactMap { $0 }.joined(separator: "\n"), key: nil)
        }
    }

    /// A reminder about a session (`SessionStore.onNudge`): a team's are silent, but a lead still waiting on you keeps it.
    public static func nudge(_ nudge: Nudge, for session: Session, settings: Settings) -> Alert? {
        guard settings.reminders else { return nil }
        switch session.teamRole {
        case .worker?, .verifier?: return nil
        case .lead?: guard case .stillWaiting = nudge, session.status == .needsInput else { return nil }
        case nil: break
        }
        let task = session.task.map { " · \($0)" } ?? ""
        let name = session.displayName
        let phoneBody = session.activity ?? session.detail ?? ""
        switch nudge {
        case .stillWaiting(let minutes):
            return Alert(kind: .reminder, title: "\(name) is still waiting for you", subtitle: "For \(minutes) min" + task,
                         body: session.detail ?? "", sound: settings.sound, tty: session.tty,
                         phoneTitle: "\(name) is still waiting for you (\(minutes) min)", phoneBody: phoneBody, key: nil)
        case .stalled(let minutes):
            // A long command may be legitimate (a build, a test suite): say what, and let you judge.
            if let activity = session.activity {
                let title = "\(name): one command running for \(minutes) min"
                return Alert(kind: .reminder, title: title, subtitle: activity, body: "No other progress since it started. Check it isn't stuck.",
                             sound: false, tty: session.tty, phoneTitle: title, phoneBody: phoneBody, key: nil)
            }
            return Alert(kind: .reminder, title: "\(name) may be stuck", subtitle: "No progress for \(minutes) min" + task, body: "",
                         sound: false, tty: session.tty, phoneTitle: "\(name) may be stuck (\(minutes) min)", phoneBody: phoneBody, key: nil)
        }
    }

    public static func lead(_ event: LeadEvent, settings: Settings) -> Alert? {
        switch event {
        case .asked(let question, let project, let tty):
            return asked(question, project: project, leadTTY: tty, settings: settings)
        case .allDone(let mark, let project, let tty):
            guard settings.done else { return nil }
            // The card's first line, and its summary's headline (the written one until Claude's is there).
            let title = "All tasks finished in \(project)"
            let body = (mark.summary ?? BatchSummary.fallback(mark.tasks)).headline
            return Alert(kind: .done, title: title, subtitle: nil, body: body, sound: false, tty: tty ?? "",
                         phoneTitle: title, phoneBody: body, key: "all-done|\(mark.id)")
        case .broken(let title, let body, let tty, let key):
            guard settings.needsInput else { return nil }
            return Alert(kind: .needsYou, title: title, subtitle: nil, body: body, sound: settings.sound, tty: tty ?? "",
                         phoneTitle: title, phoneBody: body, key: key)
        }
    }

    /// A base branch that moved outside the lead's merges (`asking`: the move the window asks you about, in the lead's
    /// chat): silent while it waits on no one, since you commit on the base yourself and the lead's merge tells the lead.
    /// Once a merge of the lead's was refused for it (`refused`, the merge's mark), its merges wait on you: told once per
    /// move.
    public static func baseMoved(_ asking: LeadVault.BaseMove?, refused: LeadVault.BaseMoveRefusal?, root: String,
                                 leadTTY: String?) -> LeadEvent? {
        guard let asking, let refused, refused.branch == asking.branch, refused.to == asking.to else { return nil }
        let project = (root as NSString).lastPathComponent
        return .broken(title: "\(asking.branch) moved outside the lead's merges",
                       body: "\(asking.count) in \(project): the lead's merges wait on you. Accept them in the lead's chat, or keep its merges refused.",
                       leadTTY: leadTTY, key: "base-move|\(root)|\(asking.to)")
    }

    /// How long before the launch a question still counts as asked while the app relaunched (seconds).
    public static let relaunchGrace: Double = 60

    /// What a look at a lead's board tells the user: its open questions not told yet (each wording once: `seen` keeps
    /// them), and the all-done cards that appeared since the last look. `previous`: the board at the last look, nil at
    /// the first (after a launch, or once a lead starts); `launchedAt`: when the app started.
    public static func look(previous: LeadBoard?, board: LeadBoard, project: String, seen: inout Set<String>,
                            launchedAt: Double) -> [LeadEvent] {
        var events: [LeadEvent] = []
        for question in board.openQuestions where seen.insert("\(question.id)#\(question.version)").inserted {
            // At the first look, a wording from before the launch (less a minute, for one asked while the app
            // relaunched) was told then: an install doesn't ring again for every open question.
            if previous == nil, (question.lastRevision?.at ?? question.askedAt) < launchedAt - relaunchGrace { continue }
            events.append(.asked(question, project: project, leadTTY: board.leadTTY))
        }
        // The all-done card appeared since the last look (none at the first look after a launch: told before).
        if let previous {
            let told = Set((previous.allDone ?? []).map(\.id))
            for mark in board.allDone ?? [] where !told.contains(mark.id) && mark.seenAt == nil {
                events.append(.allDone(mark, project: project, leadTTY: board.leadTTY))
            }
        }
        return events
    }

    /// "The lead of acme needs you".
    static func leadNeedsYou(_ project: String) -> String { "The lead of \(project) needs you" }

    /// A lead's question for the user: once per wording, whether the board showed it first or the lead's turn ended on it.
    static func asked(_ question: LeadQuestion, project: String, leadTTY: String?, settings: Settings) -> Alert? {
        guard settings.needsInput else { return nil }
        let title = leadNeedsYou(project)
        let first = question.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? question.text
        let timer = question.isCounting ? "Going with ‘\(question.proposal ?? "")’ in \(question.decideInText) unless you answer" : nil
        let subtitle = timer ?? (question.version > 1 ? "It updated a question" : "It asks")
        return Alert(kind: .needsYou, title: title, subtitle: subtitle, body: first, sound: settings.sound, tty: leadTTY ?? "",
                     phoneTitle: title, phoneBody: (timer.map { $0 + ": " } ?? "") + first, key: "question|\(question.id)#\(question.version)")
    }
}
