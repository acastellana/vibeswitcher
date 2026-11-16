import Foundation

/// What the node's server keeps in the host's vault (the engine plan's EN-D11, the security architecture document's S3
/// and T41): the user's actions it accepted, each recorded before it is acted on, and the `.user` seals the host made,
/// so a `.user` message can't be replayed into a lead's inbox for long. Linux only: the Mac's vault has no such record,
/// its host lists no `HostProtocol.Capability.vaultV2` and refuses `HostRequest.vaultV2`
/// (`Sources/VibeHost/V2/VaultV2Handler.swift`), and the two hooks in `LeadVault.Book`'s `.seal` and `.verify` do
/// nothing there.
///
/// The record is the vault's saved state's optional `v2` (so the vault's format stays and an older build reads it), a
/// handover carries it with the rest, and only the app (the server child on Linux) writes or reads it.
public enum LeadVaultV2 {
    /// One user's-voice request the server accepted: its action id (the command line's, sent again on a retry), its
    /// kind (`answer`, `hold`, …, or `message` for the `.user` message an answer sends the lead), what it named (a card,
    /// a project), the digest of what it carried (SHA-256 in hex: never the text), and when it was recorded.
    public struct UserAction: Codable, Equatable, Sendable {
        public var action: String
        public var kind: String
        public var subject: String?
        public var digest: String
        public var at: Double

        public init(action: String, kind: String, subject: String?, digest: String, at: Double = Date().timeIntervalSince1970) {
            self.action = action
            self.kind = kind
            self.subject = subject
            self.digest = digest
            self.at = at
        }
    }

    /// `HostRequest.vaultV2`'s requests, each the app's alone.
    public enum Request: Codable, Equatable, Sendable {
        /// Records an accepted request; answered `recorded(first:)`, false when that action of that kind was recorded
        /// already (a retry: it was done once).
        case recordUserAction(action: String, kind: String, subject: String?, digest: String)
        /// The actions recorded at or after `since`, oldest first.
        case userActions(since: Double)
        /// Whether an action `action` was recorded with `digest`.
        case holds(action: String, digest: String)
        /// Whether a held `.user` message may go as the user's after a server restart (the close-out review): an action
        /// `action` of kind `message` was recorded with `digest` for the project `subject`, and no message of it was
        /// posted since (`spendUserActions`). Answered `holds`.
        case vouches(action: String, digest: String, subject: String)
        /// The `.user` messages these actions made were posted to their lead: none vouches after a restart from now on.
        case spendUserActions([String])
        /// The `.user` seals with these message ids verify false from now on (the server saw the lead take them).
        case retireUserSeals([String])
        /// The `.user` messages with these ids still wait in their lead's inbox, untaken (the server reads it at each
        /// look, and names only lines that are still what it posted): each seal's life starts again, if it is live, not
        /// retired, no check has passed it yet (`Book.checked`), and it was first made less than `renewedLifeCap` ago
        /// (`Book.first`). A message that waits while its lead's tool call runs long stays the user's when taken.
        case renewUserSeals([String])
    }

    public enum Reply: Codable, Equatable, Sendable {
        case recorded(first: Bool)
        case actions([UserAction])
        case holds(Bool)
        case ok
        case refused(String)
    }

    /// The record in the vault's state (`LeadVault.Book`'s `v2`).
    public struct Book: Codable, Equatable, Sendable {
        /// Newest last, `actionsKept` at most.
        public var actions: [UserAction] = []
        /// Each `.user` seal the host made, by the message's id: when.
        public var seals: [String: Double] = [:]
        /// Each `.user` seal retired, by the message's id: when.
        public var retired: [String: Double] = [:]
        /// Each `.user` seal a check first passed (the lead's hook taking its inbox, or a handover), by the message's
        /// id: when. Never renewed from then on, so a copy put back after it was taken lives a seal's life at most.
        public var checked: [String: Double] = [:]
        /// Each `.user` seal's first making, by the message's id (the security follow-ups' item 16): no renewal takes it
        /// past `renewedLifeCap` from then, so a seal lives `renewedLifeCap` plus one life at most.
        public var first: [String: Double] = [:]
        /// Each action whose `.user` message was posted to its lead, by action id: when (the close-out review). A copy
        /// `engine.json` still holds after a restart is vouched for no more.
        public var spent: [String: Double] = [:]
        /// Each `.user` seal's recipient, by the message's id: the session the host found its agent pid running in when
        /// it sealed it (the security follow-ups' item 19). Only that session's own check, as a lead's, is a taking. None
        /// once a seal under the id was made for another while its earlier one lived (see `sealed`).
        public var targets: [String: String] = [:]

        public init() {}

        /// A record saved before `checked`, `first`, `spent` or `targets` reads with none.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            actions = try container.decodeIfPresent([UserAction].self, forKey: .actions) ?? []
            seals = try container.decodeIfPresent([String: Double].self, forKey: .seals) ?? [:]
            retired = try container.decodeIfPresent([String: Double].self, forKey: .retired) ?? [:]
            checked = try container.decodeIfPresent([String: Double].self, forKey: .checked) ?? [:]
            first = try container.decodeIfPresent([String: Double].self, forKey: .first) ?? [:]
            spent = try container.decodeIfPresent([String: Double].self, forKey: .spent) ?? [:]
            targets = try container.decodeIfPresent([String: String].self, forKey: .targets) ?? [:]
        }
    }

    /// The kind the server records a `.user` message's digest under (beside its request's own kind).
    public static let messageKind = "message"

    /// How many actions the record keeps (the oldest go first).
    public static let actionsKept = 2_000
    /// How long a `.user` seal verifies after it was made or last renewed while its message waited untaken (T41
    /// narrowed, EN-D11), unless a scratch host's test sets another (`--test-user-seal-life`).
    public static let defaultSealLife: TimeInterval = 15 * 60
    /// How long after a `.user` seal was first made it can still be renewed (the security follow-ups' item 16): an answer
    /// waits through a long tool call (a merge's tests), never for ever.
    public static let renewedLifeCap: TimeInterval = 2 * 60 * 60

    /// What a look at the config passes as what its card showed (`LeadVault.checkConfig(root:shown:)`): the server's
    /// look before `config held` and before a lead start. Its one key is never a watched thing's
    /// (`ConfigSeal.isWatchedKey`), so the look seals nothing; and it's a look, not your accept, so it never ends a
    /// root's held first look, even with nothing held after it (the security follow-ups' item 20: an accept of a card
    /// that showed nothing, `shown: [:]`, still does).
    public static let configLook: [String: String] = [ConfigSeal.keyPrefix + "#look": "1"]

    /// Whether `shown` is a look's (`configLook`), not a card's.
    public static func isLook(_ shown: [String: String]?) -> Bool { shown?[ConfigSeal.keyPrefix + "#look"] != nil }

    private static let lifeLock = NSLock()
    nonisolated(unsafe) private static var life = defaultSealLife

    /// How long a `.user` seal verifies after it was made: `defaultSealLife`, or a scratch host's test's.
    public static var sealLife: TimeInterval {
        get { lifeLock.withLock { life } }
        set { lifeLock.withLock { life = max(1, newValue) } }
    }

    /// Whether the record is kept: on Linux only.
    public static var isOn: Bool { !Platform.CodeIdentity.isAvailable }

    /// The digest the record keeps of `text`: SHA-256, lower-case hex.
    public static func digest(_ text: String) -> String { BuildInfo.sha256(of: Data(text.utf8)) }

    // MARK: The book's side

    /// `request` from `caller` on `book` (made when there's none): the app's alone, on Linux alone.
    public static func answer(_ request: Request, from caller: LeadVault.Caller, book: inout Book?,
                              now: Double = Date().timeIntervalSince1970) -> Reply {
        guard isOn else { return .refused("This session host keeps no record of the user's actions (the Mac's).") }
        guard caller == .app else { return .refused("Only VibeSwitcher records and reads the user's actions.") }
        var record = book ?? Book()
        defer { book = record }
        switch request {
        case .recordUserAction(let action, let kind, let subject, let digest):
            guard !action.isEmpty, !kind.isEmpty else { return .refused("A user's action has an id and a kind.") }
            if record.actions.contains(where: { $0.action == action && $0.kind == kind }) { return .recorded(first: false) }
            record.actions.append(UserAction(action: action, kind: kind, subject: subject, digest: digest, at: now))
            if record.actions.count > actionsKept {
                record.actions.removeFirst(record.actions.count - actionsKept)
                let kept = Set(record.actions.map(\.action))
                record.spent = record.spent.filter { kept.contains($0.key) }
            }
            return .recorded(first: true)
        case .userActions(let since):
            return .actions(record.actions.filter { $0.at >= since })
        case .holds(let action, let digest):
            return .holds(record.actions.contains { $0.action == action && $0.digest == digest })
        case .vouches(let action, let digest, let subject):
            guard record.spent[action] == nil else { return .holds(false) }
            return .holds(record.actions.contains { $0.action == action && $0.kind == messageKind && $0.subject == subject && $0.digest == digest })
        case .spendUserActions(let actions):
            let recorded = Set(record.actions.map(\.action))
            for action in actions where recorded.contains(action) && record.spent[action] == nil { record.spent[action] = now }
            return .ok
        case .retireUserSeals(let ids):
            for id in ids { record.retired[id] = now }
            prune(&record, now: now)
            return .ok
        case .renewUserSeals(let ids):
            // Only a live seal, and once a third of its life went (so a look every few seconds writes nothing new); none
            // past the cap from its first making (one recorded before `first` counts from its newest).
            let life = sealLife
            for id in ids {
                guard let made = record.seals[id], record.retired[id] == nil, record.checked[id] == nil, now - made <= life, now - made >= life / 3 else {
                    continue
                }
                let first = record.first[id] ?? made
                record.first[id] = first
                guard now - first < renewedLifeCap else { continue }
                record.seals[id] = now
            }
            return .ok
        }
    }

    /// The `.seal` hook: a `.user` seal the host is about to make for `message` is recorded with its time and its
    /// recipient, `target`: the session the host found the message's agent pid running in (`agentSession`; nil: none it
    /// runs, so no session's check takes it), Linux only. The record is by the message's id, and an id can come back (a
    /// held message's, restored from `engine.json` after a server restart, which a same-uid process can rewrite): a seal
    /// under an id whose live seal was made for another recipient leaves it with none (the follow-up 19 review), so
    /// neither lead's check takes it; nor after any later seal under it while one lives (a recipient differs from none).
    /// Its renewal goes on until `renewedLifeCap`, and the app's check (a handover) still takes it.
    public static func sealed(_ message: SteerMessage, target: String? = nil, book: inout Book?, changed: inout Bool,
                              now: Double = Date().timeIntervalSince1970) {
        guard isOn, message.from == .user else { return }
        var record = book ?? Book()
        let contested = record.seals[message.id].map { now - $0 <= sealLife } == true && record.targets[message.id] != target
        record.seals[message.id] = now
        if record.first[message.id] == nil { record.first[message.id] = now }
        record.targets[message.id] = contested ? nil : target
        prune(&record, now: now)
        book = record
        changed = true
    }

    /// The `.verify` hook: `valid` (each message's seal checked against the key) with every `.user` one whose seal was
    /// retired, or made (or last renewed) more than `sealLife` ago, false (Linux only). When the seal was made is the
    /// record's, else the message's own time (which its seal covers). A recorded seal that passes is marked checked the
    /// first time (`Book.checked`): it is renewed no more. Only when `takes` (the security follow-ups' item 17): the
    /// check is a taking, the app's (a handover) or a lead's own hook taking its inbox; anyone else's check (a worker's,
    /// a process outside the sessions) reads and changes nothing, so it can't stop a waiting answer's renewal.
    public static func verified(_ messages: [SteerMessage], _ valid: [Bool], book: inout Book?, changed: inout Bool,
                                takes: Bool = true, now: Double = Date().timeIntervalSince1970) -> [Bool] {
        verified(messages, valid, book: &book, changed: &changed, taking: { _ in takes }, now: now)
    }

    /// As above, deciding for each message whether the check takes it: `taking` gets the session its seal was recorded
    /// for (`Book.targets`; nil: none recorded).
    static func verified(_ messages: [SteerMessage], _ valid: [Bool], book: inout Book?, changed: inout Bool,
                         taking: (_ target: String?) -> Bool, now: Double) -> [Bool] {
        guard isOn else { return valid }
        let life = sealLife
        var record = book
        let result = zip(messages, valid).map { message, valid -> Bool in
            guard valid, message.from == .user else { return valid }
            if record?.retired[message.id] != nil { return false }
            let made = record?.seals[message.id] ?? message.at
            guard now - made <= life else { return false }
            if record?.seals[message.id] != nil, record?.checked[message.id] == nil, taking(record?.targets[message.id]) {
                record?.checked[message.id] = now
                changed = true
            }
            return true
        }
        if record != book { book = record }
        return result
    }

    /// The `.verify` hook as the book calls it: a check by `caller` is a taking when it is the app's (a handover), for
    /// every message; or, for each message alone, when the caller is a session that holds a lead's role among `members`
    /// (every team's) and the message's seal was made for that same session (`Book.targets`): the lead's own hook taking
    /// its own inbox (the security follow-ups' items 17 and 19). Another project's lead checking this lead's message
    /// reads only, as does a lead's check of a seal recorded with no recipient. Who takes is decided here, not in the
    /// book's handler (the close-out review: the port map's kinds keep that hook to a line).
    public static func verified(_ messages: [SteerMessage], _ valid: [Bool], book: inout Book?, changed: inout Bool,
                                caller: LeadVault.Caller, members: [LeadVault.Member],
                                now: Double = Date().timeIntervalSince1970) -> [Bool] {
        guard isOn else { return valid }
        if caller == .app { return verified(messages, valid, book: &book, changed: &changed, taking: { _ in true }, now: now) }
        guard case .session(let session) = caller, members.contains(where: { $0.role == .lead && $0.session == session }) else {
            return verified(messages, valid, book: &book, changed: &changed, taking: { _ in false }, now: now)
        }
        return verified(messages, valid, book: &book, changed: &changed, taking: { target in
            target.map { $0.lowercased() == session.lowercased() } ?? false
        }, now: now)
    }

    /// Seals, retirements and checks older than a seal's life verify false by their age alone: they're dropped.
    static func prune(_ record: inout Book, now: Double) {
        let cutoff = now - max(sealLife, defaultSealLife) - 60
        record.seals = record.seals.filter { $0.value >= cutoff }
        record.retired = record.retired.filter { $0.value >= cutoff }
        let seals = record.seals
        record.checked = record.checked.filter { seals[$0.key] != nil || $0.value >= cutoff }
        record.first = record.first.filter { seals[$0.key] != nil }
        record.targets = record.targets.filter { seals[$0.key] != nil }
    }
}

/// The record of the user's actions as a client asks it (the node's server, through its connector): each call one
/// `HostRequest.vaultV2` (`ask`), refused as the host refuses it.
public struct LeadVaultV2Client: Sendable {
    public struct Refused: Error, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    let ask: @Sendable (LeadVaultV2.Request) throws -> LeadVaultV2.Reply

    public init(ask: @escaping @Sendable (LeadVaultV2.Request) throws -> LeadVaultV2.Reply) { self.ask = ask }

    private func call(_ request: LeadVaultV2.Request) throws -> LeadVaultV2.Reply {
        let reply: LeadVaultV2.Reply
        do { reply = try ask(request) } catch let refused as Refused { throw refused } catch { throw Refused("The session host didn't answer (\(error)).") }
        if case .refused(let why) = reply { throw Refused(why) }
        return reply
    }

    /// Records an accepted request (before it is acted on); false when that action of that kind was recorded already.
    @discardableResult
    public func recordUserAction(_ action: String, kind: String, subject: String?, digest: String) throws -> Bool {
        guard case .recorded(let first) = try call(.recordUserAction(action: action, kind: kind, subject: subject, digest: digest)) else {
            throw Refused("The session host answered something else.")
        }
        return first
    }

    public func userActions(since: Double = 0) throws -> [LeadVaultV2.UserAction] {
        guard case .actions(let actions) = try call(.userActions(since: since)) else { throw Refused("The session host answered something else.") }
        return actions
    }

    public func holds(action: String, digest: String) throws -> Bool {
        guard case .holds(let holds) = try call(.holds(action: action, digest: digest)) else { throw Refused("The session host answered something else.") }
        return holds
    }

    /// Whether a held `.user` message, `digest` of its text, may go as the user's to the lead of project `subject` after a
    /// restart: recorded for that project as a message of `action`, and none of it posted since.
    public func vouches(action: String, digest: String, subject: String) throws -> Bool {
        guard case .holds(let holds) = try call(.vouches(action: action, digest: digest, subject: subject)) else {
            throw Refused("The session host answered something else.")
        }
        return holds
    }

    /// The `.user` messages of these actions were posted: none of them vouches after a restart any more.
    public func spendUserActions(_ actions: [String]) throws {
        guard !actions.isEmpty else { return }
        _ = try call(.spendUserActions(actions))
    }

    public func retireUserSeals(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        _ = try call(.retireUserSeals(ids))
    }

    /// The `.user` messages `ids` still wait untaken in their lead's inbox: their seals' life starts again.
    public func renewUserSeals(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        _ = try call(.renewUserSeals(ids))
    }
}
