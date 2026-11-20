import Foundation
import VibeCore

/// The check a held `.user` message passes after a server restart (the engine plan's EN-D9): whether the vault's record
/// of the user's actions (EN-D11) holds the action that made it as a message with the message's digest, for the project
/// it's held for, and none of it was posted since (the close-out review: `LeadVaultV2.Request.vouches`). E6 gives the
/// vault's; until then nothing passes it (`NoUserActions`).
public protocol UserActions: Sendable {
    /// Whether the record vouches for a message of `action` with `digest` (`EngineState.digest`) to the lead of
    /// `project` (`NodeIds.project`); nil when it can't be asked.
    func vouches(action: String, digest: String, project: String) -> Bool?
}

/// No record of the user's actions: no held `.user` message is vouched for after a restart.
public struct NoUserActions: UserActions {
    public init() {}
    public func vouches(action: String, digest: String, project: String) -> Bool? { nil }
}

/// The engine's own state file, `<root>/v2/engine.json` (format 1; the engine plan's EN-D9): what isn't the user's and
/// what a restarted server needs not to repeat itself. E5 keeps the held messages there; E8 adds the witness's told keys,
/// auto_advance's first sightings, the last host start seen, the roots with a lead under it and the last host restart
/// (each optional: a file of E5's reads as before, rule 3). None of those is taken as the user's either. Nothing in it
/// is taken as its sender's: a worker of the user's uid can write it, so a held `.user` message goes as the user's after
/// a restart only when the vault's record of the user's actions holds the action id it carries with the digest of its
/// text as it is now (`restored`); any other goes as from an unverified sender (`SteerInbox.unverified`), saying so,
/// never sealed as the user's, the lead's or VibeSwitcher's. The record binds the action to the project it was recorded
/// for and spends it once its message was posted, so a past message of the user's (its action id is in `status`) put
/// back in the file, for its lead or another project's, isn't the user's again.
public struct EngineState: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    /// A message held for a project's lead (`LeadStore.Held`), with the root it is for.
    public struct Held: Codable, Equatable, Sendable {
        /// Its id in the lead's inbox once posted (`LeadStore.Held.id`; nil from a file that has none: a new one).
        public var id: String?
        public var root: String
        /// Its place among what was sent: held messages go in this order.
        public var order: Int
        public var text: String
        public var from: SteerMessage.Sender
        /// The action id of the user's request that made it (a `.user` message's), as the command line sent it.
        public var action: String?

        public init(id: String? = nil, root: String, order: Int, text: String, from: SteerMessage.Sender, action: String? = nil) {
            self.id = id
            self.root = root
            self.order = order
            self.text = text
            self.from = from
            self.action = action
        }
    }

    /// A session host's restart the engine saw (E8): the welcome's start time differed from the one this file held. Every
    /// project's lead and team ended with the old host, and its vault started over.
    public struct Restart: Codable, Equatable, Sendable {
        /// When the host that welcomed the engine started, and when the one before it had (seconds since 1970).
        public var at: Double
        public var before: Double
        /// The roots whose lead ran under the old host, each until a lead starts there again.
        public var gone: [String]

        public init(at: Double, before: Double, gone: [String]) {
            self.at = at
            self.before = before
            self.gone = gone
        }
    }

    /// What reopens a project's lead after a host restart (`vibeswitcher lead FOLDER --resume`, the app's restart card
    /// and `RestartReopen.Entry`): the conversation it carried, kept while it runs. Only a hint: a worker of the user's uid
    /// can write this file, so the reopen takes nothing from it but which conversation to look at, and that only once
    /// the user asked for it on the command line, the vault's accepts were made and the transcript checks out
    /// (`LeadEngine.resumable`: inside the agents' folders, in Claude's folder for the project's own repository, named by
    /// its conversation id and carrying the lead's name). The model, the advisor and the grant are the start's own, as
    /// for any lead; the workers listed are for `status` to show (the reopened lead is told from its board).
    public struct Reopen: Codable, Equatable, Sendable {
        /// A worker running when this was last written: its task, its session and its branch.
        public struct Worker: Codable, Equatable, Sendable {
            public var task: String
            public var session: String
            public var branch: String

            public init(task: String, session: String, branch: String) {
                self.task = task
                self.session = session
                self.branch = branch
            }
        }

        /// The host session the lead ran in.
        public var session: String
        /// Claude's own session id for it (its hook's, else its transcript's name): what `--resume` takes.
        public var conversation: String?
        /// Its transcript, as `NodeSessions` checked it.
        public var transcript: String?
        /// What it was started on.
        public var model: String?
        public var advisor: String?
        public var workers: [Worker]

        public init(session: String, conversation: String? = nil, transcript: String? = nil, model: String? = nil, advisor: String? = nil,
                    workers: [Worker] = []) {
            self.session = session
            self.conversation = conversation
            self.transcript = transcript
            self.model = model
            self.advisor = advisor
            self.workers = workers
        }
    }

    public var format: Int
    /// In the order sent.
    public var held: [Held]
    /// The witness's events already told, by root and key (`LeadEngine.told`): none is told twice across a restart (E8).
    /// Absent from a file written before E8.
    public var told: [String]?
    /// When the witness first saw each verifier auto_advance audits again end, and each worker it released, by root and
    /// session (`LeadEngine.advanceSeen`, seconds since 1970): each nudged once across a restart (E8).
    public var firstSightings: [String: Double]?
    /// The start time of the last session host that welcomed the engine (seconds since 1970): a welcome with another is a
    /// host restart (E8).
    public var hostStartedAt: Double?
    /// The roots with a lead that ran under that host: a host restart ended them.
    public var leads: [String]?
    /// The last host restart the engine saw, while `status` says so.
    public var restart: Restart?
    /// What reopens each project's lead after a host restart, by root (`Reopen`). Absent from a file written before it.
    public var reopen: [String: Reopen]?

    public init(held: [Held] = [], told: [String]? = nil, firstSightings: [String: Double]? = nil, hostStartedAt: Double? = nil,
                leads: [String]? = nil, restart: Restart? = nil, reopen: [String: Reopen]? = nil) {
        format = Self.currentFormat
        self.held = held
        self.told = told
        self.firstSightings = firstSightings
        self.hostStartedAt = hostStartedAt
        self.leads = leads
        self.restart = restart
        self.reopen = reopen
    }

    /// `<root>/v2/engine.json`.
    public static func url(root: URL) -> URL {
        root.appendingPathComponent("v2", isDirectory: true).appendingPathComponent("engine.json")
    }

    /// The state at `root`, and what was wrong with the file when it couldn't be taken (none: missing or read): a
    /// file that doesn't read, or of another format, is an empty state, and the problem says what was lost.
    public static func load(root: URL) -> (state: EngineState, problem: String?) {
        let url = url(root: root)
        guard let data = try? Data(contentsOf: url) else {
            let missing = !FileManager.default.fileExists(atPath: url.path)
            return (EngineState(), missing ? nil : "\(url.path) doesn't read: what it held is lost")
        }
        guard let state = try? JSONDecoder().decode(EngineState.self, from: data) else {
            return (EngineState(), "\(url.path) isn't an engine state: what it held is lost")
        }
        guard state.format == currentFormat else {
            return (EngineState(), "\(url.path) is of format \(state.format), not \(currentFormat): what it held is lost")
        }
        return (state, nil)
    }

    /// Writes it at `root` (0600, in a 0700 `v2` folder), whole and renamed into place. A root that isn't there (its
    /// node removed) is never made again for it: that throws.
    public func save(root: URL) throws {
        let url = Self.url(root: root)
        guard FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path]) }
        try VibePaths.ensurePrivate(url.deletingLastPathComponent(), within: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try VibePaths.writePrivate(try encoder.encode(self), to: url)
    }

    /// A message's digest, as the vault's record of user actions keeps it: SHA-256 of its text, in hex.
    public static func digest(_ text: String) -> String { BuildInfo.sha256(of: Data(text.utf8)) }

    /// Who a held message that was marked as the user's but can't be vouched for goes as: an unverified sender, never
    /// the user nor VibeSwitcher (`SteerInbox.unverified`'s words).
    public static let notVouchedSender = SteerMessage.Sender.system(SteerInbox.unverifiedSender + ", marked as the user's; not the user's word")

    /// What such a message says before its text.
    public static let notVouchedPrefix = "Held for you before this node's server restarted, marked as the user's, but it couldn't be "
        + "vouched for (no record of the user's request with this text), so it is not the user's word: "

    /// What a held message not marked as the user's says before its text after a restart: nothing vouches for the sender
    /// the file names.
    public static let restartedPrefix = "Held for you before this node's server restarted; nothing vouches for its sender since: "

    /// The held messages as they may go after a restart, in order, each with its id: a `.user` one stays the user's
    /// only when `actions` vouches for its action with its text's digest for its root's project now, and only the first
    /// held with that action (a copy beside it is a replay); else it goes from `notVouchedSender`, saying so, its action
    /// dropped (`notVouched`: how many). Any other (marked as the lead's or VibeSwitcher's) goes from the
    /// unverified sender `SteerInbox.unverified` names for it, saying so (`unvouchedSenders`: how many): the file is
    /// no seal, and a planted entry would otherwise be posted sealed as VibeSwitcher's.
    public static func restored(_ held: [Held], actions: UserActions) -> (held: [Held], notVouched: Int, unvouchedSenders: Int) {
        var (notVouched, unvouchedSenders) = (0, 0)
        var vouched: Set<String> = []
        let restored = held.sorted { $0.order < $1.order }.map { message -> Held in
            guard message.from == .user else {
                unvouchedSenders += 1
                let sender = SteerInbox.unverified(SteerMessage(text: message.text, from: message.from, agentPid: 0)).from
                return Held(id: message.id, root: message.root, order: message.order, text: prefixed(restartedPrefix, message.text), from: sender)
            }
            if let action = message.action, !vouched.contains(action),
               actions.vouches(action: action, digest: digest(message.text), project: NodeIds.project(root: message.root)) == true {
                vouched.insert(action)
                return message
            }
            notVouched += 1
            return Held(id: message.id, root: message.root, order: message.order, text: prefixed(notVouchedPrefix, message.text), from: notVouchedSender)
        }
        return (restored, notVouched, unvouchedSenders)
    }

    /// `text` saying `prefix` first, once: one held again across a second restart doesn't say it twice.
    static func prefixed(_ prefix: String, _ text: String) -> String {
        text.hasPrefix(restartedPrefix) || text.hasPrefix(notVouchedPrefix) ? text : prefix + text
    }
}
