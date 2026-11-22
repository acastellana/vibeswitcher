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
        /// Which feature plugins the user turned on or off (`vibeswitcher plugin on|off NAME`, the user's voice, recorded
        /// first as its own action), by id: answered `plugins`. A plugin with nothing here is as its plugin says by default.
        case plugins
        /// The user turned `id` on or off: kept here, where no session's write reaches (the plugins definition's rule 5).
        case setPlugin(id: String, on: Bool)
        /// The plugin requests settled (answered, withdrawn, expired, gone), by `<plugin>:<id>`: answered `settled`. A
        /// request still on disk is never drawn again once settled, across the server's restarts.
        case settledRequests
        /// These plugin requests are settled now (kept `settledKept` at most).
        case settleRequests([String])
        /// When this record began (its first request since the host's vault began: a host restart starts it over).
        /// Answered `since`.
        case recordSince
        /// The feature plugins' settings the user set (`vibeswitcher set KEY VALUE` on a plugin's key), by key
        /// (`<plugin>.<name>`): answered `pluginSettings`.
        case pluginSettings
        /// The user set a plugin's setting `key` to `value` (nil: back to its default): kept here, where no session's write
        /// reaches, as on and off are.
        case setPluginSetting(key: String, value: String?)
    }

    public enum Reply: Codable, Equatable, Sendable {
        case recorded(first: Bool)
        case actions([UserAction])
        case holds(Bool)
        case ok
        case refused(String)
        case plugins([String: Bool])
        case settled([String])
        case since(Double)
        case pluginSettings([String: String])
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
        /// The feature plugins' record in one field: on and off (`on:<id>`), the settled requests (`settled:<plugin>:<id>`,
        /// when), the settings (`setting:<plugin>.<name>`). One field, not three: a tenth stored field on this record made
        /// the host crash (SIGSEGV) on a config look (`config held`), which reads like a stack too near its end on that
        /// path; see the plugins report of 2026-11-22.
        public var plugin: [String: String] = [:]

        /// Each feature plugin the user turned on or off, by id (`setPlugin`).
        public var plugins: [String: Bool] {
            get { Self.part(plugin, "on:").mapValues { $0 == "true" } }
            set { Self.setPart(&plugin, "on:", newValue.mapValues { $0 ? "true" : "false" }) }
        }
        /// Each plugin request settled, by `<plugin>:<id>`: when (`settleRequests`).
        public var settledRequests: [String: Double] {
            get { Self.part(plugin, "settled:").compactMapValues(Double.init) }
            set { Self.setPart(&plugin, "settled:", newValue.mapValues { String($0) }) }
        }
        /// Each feature plugin's setting the user set, by key (`setPluginSetting`).
        public var pluginSettings: [String: String] {
            get { Self.part(plugin, "setting:") }
            set { Self.setPart(&plugin, "setting:", newValue) }
        }

        /// The names a build before the one field kept them under: read, never written.
        enum OldKeys: String, CodingKey { case plugins, settledRequests, pluginSettings }

        static func part(_ record: [String: String], _ prefix: String) -> [String: String] {
            Dictionary(uniqueKeysWithValues: record.filter { $0.key.hasPrefix(prefix) }.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
        }

        static func setPart(_ record: inout [String: String], _ prefix: String, _ part: [String: String]) {
            record = record.filter { !$0.key.hasPrefix(prefix) }
            for (key, value) in part { record[prefix + key] = value }
        }

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
            if let one = try container.decodeIfPresent([String: String].self, forKey: .plugin) {
                plugin = one
            } else {
                // A record from a build that kept these as fields of their own (a handover carries it): taken as it was.
                let old = try decoder.container(keyedBy: OldKeys.self)
                plugins = try old.decodeIfPresent([String: Bool].self, forKey: .plugins) ?? [:]
                settledRequests = try old.decodeIfPresent([String: Double].self, forKey: .settledRequests) ?? [:]
                pluginSettings = try old.decodeIfPresent([String: String].self, forKey: .pluginSettings) ?? [:]
            }
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

    private static let lifeLock = NSLock()
    nonisolated(unsafe) private static var life = defaultSealLife

    /// How long a `.user` seal verifies after it was made: `defaultSealLife`, or a scratch host's test's.
    public static var sealLife: TimeInterval {
        get { lifeLock.withLock { life } }
        set { lifeLock.withLock { life = max(1, newValue) } }
    }

    /// Whether this host keeps the record: on Linux, every host; on the Mac, a node host only, which says so
    /// (`recordsOnThisHost`, set by `HostServer` once it is one: the review of 2026-11-21), never the Mac app's.
    public static var isOn: Bool { !Platform.CodeIdentity.isAvailable || recordsOnThisHost }

    /// Set by a Mac node host (one host to a process): its vault keeps the record, the hooks included.
    public static var recordsOnThisHost: Bool {
        get { lifeLock.withLock { nodeHost } }
        set { lifeLock.withLock { nodeHost = newValue } }
    }
    nonisolated(unsafe) private static var nodeHost = false

    /// The digest the record keeps of `text`: SHA-256, lower-case hex.
    public static func digest(_ text: String) -> String { BuildInfo.sha256(of: Data(text.utf8)) }

    // MARK: The book's side

    /// `request` from `caller` on `book` (made when there's none): the app's alone, on Linux alone.
    /// `on`: whether this host keeps the record (`isOn`; the host's handler passes its own answer).
    public static func answer(_ request: Request, from caller: LeadVault.Caller, book: inout Book?,
                              now: Double = Date().timeIntervalSince1970, on: Bool = isOn) -> Reply {
        guard on else { return .refused("This session host keeps no record of the user's actions (the Mac's).") }
        guard caller == .app else { return .refused("Only VibeSwitcher records and reads the user's actions.") }
        var record = book ?? Book()
        if record.plugin[sinceKey] == nil { record.plugin[sinceKey] = String(now) }
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
        case .plugins:
            return .plugins(record.plugins)
        case .setPlugin(let id, let on):
            guard pluginID(id) else { return .refused("A plugin's id is a short lower-case word.") }
            record.plugins[id] = on
            return .plugins(record.plugins)
        case .recordSince:
            return .since(record.plugin[sinceKey].flatMap(Double.init) ?? now)
        case .settledRequests:
            return .settled(record.settledRequests.keys.sorted())
        case .settleRequests(let keys):
            guard keys.count <= 1_000, keys.allSatisfy({ $0.utf8.count <= 80 }) else { return .refused("At most 1000 request names of 80 bytes.") }
            for key in keys { record.settledRequests[key] = now }
            // A request lives 7 days at most: its name is kept a day past that, then goes; the newest `settledKept` at most.
            record.settledRequests = record.settledRequests.filter { now - $0.value < 8 * 86_400 }
            if record.settledRequests.count > settledKept {
                let kept = record.settledRequests.sorted { $0.value > $1.value }.prefix(settledKept)
                record.settledRequests = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
            }
            return .ok
        case .pluginSettings:
            return .pluginSettings(record.pluginSettings)
        case .setPluginSetting(let key, let value):
            let parts = key.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, pluginID(String(parts[0])), pluginID(String(parts[1])) else {
                return .refused("A plugin's setting is named <plugin>.<name>, each a short lower-case word.")
            }
            guard (value?.utf8.count ?? 0) <= pluginSettingBytes else { return .refused("A plugin's setting is \(pluginSettingBytes / 1024) KiB at most.") }
            record.pluginSettings[key] = value
            return .pluginSettings(record.pluginSettings)
        }
    }

    /// The plugin record's key for when the record began.
    static let sinceKey = "record:since"

    /// How many settled plugin requests the record keeps.
    public static let settledKept = 5_000

    /// The most a plugin's setting holds.
    public static let pluginSettingBytes = 8 * 1024

    /// A feature plugin's id as the record keeps it: 1 to 32 of a-z, 0-9 and -, starting with a letter.
    public static func pluginID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, ("a"..."z").contains(first), id.unicodeScalars.count <= 32 else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The `.seal` hook: a `.user` seal the host is about to make for `message` is recorded with its time and its
    /// recipient, `target`: the session the host found the message's agent pid running in (`agentSession`; nil: none it
    /// runs, so no session's check takes it), Linux only. The record is by the message's id, and an id can come back (a
    /// held message's, restored from `engine.json` after a server restart, which a same-uid process can rewrite): a seal
    /// under an id whose live seal was made for another recipient leaves it with none (the follow-up 19 review), so
    /// neither lead's check takes it; nor after any later seal under it while one lives (a recipient differs from none).
    /// Its renewal goes on until `renewedLifeCap`, and the app's check (a handover) still takes it.
    public static func sealed(_ message: SteerMessage, target: String? = nil, book: inout Book?, changed: inout Bool,
                              now: Double = Date().timeIntervalSince1970, on: Bool = isOn) {
        guard on, message.from == .user else { return }
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
                                takes: Bool = true, now: Double = Date().timeIntervalSince1970, on: Bool = isOn) -> [Bool] {
        verified(messages, valid, book: &book, changed: &changed, taking: { _ in takes }, now: now, on: on)
    }

    /// As above, deciding for each message whether the check takes it: `taking` gets the session its seal was recorded
    /// for (`Book.targets`; nil: none recorded).
    static func verified(_ messages: [SteerMessage], _ valid: [Bool], book: inout Book?, changed: inout Bool,
                         taking: (_ target: String?) -> Bool, now: Double, on: Bool = isOn) -> [Bool] {
        guard on else { return valid }
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
                                now: Double = Date().timeIntervalSince1970, on: Bool = isOn) -> [Bool] {
        guard on else { return valid }
        if caller == .app { return verified(messages, valid, book: &book, changed: &changed, taking: { _ in true }, now: now, on: on) }
        guard case .session(let session) = caller, members.contains(where: { $0.role == .lead && $0.session == session }) else {
            return verified(messages, valid, book: &book, changed: &changed, taking: { _ in false }, now: now, on: on)
        }
        return verified(messages, valid, book: &book, changed: &changed, taking: { target in
            target.map { $0.lowercased() == session.lowercased() } ?? false
        }, now: now, on: on)
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

    /// The feature plugins the user turned on or off, by id (none: each as its plugin says by default).
    public func plugins() throws -> [String: Bool] {
        guard case .plugins(let plugins) = try call(.plugins) else { throw Refused("The session host answered something else.") }
        return plugins
    }

    /// When this record began: a host restart starts the vault, and it, over.
    public func recordSince() throws -> Date {
        guard case .since(let at) = try call(.recordSince) else { throw Refused("The session host answered something else.") }
        return Date(timeIntervalSince1970: at)
    }

    /// The plugin requests settled (`<plugin>:<id>`).
    public func settledRequests() throws -> [String] {
        guard case .settled(let keys) = try call(.settledRequests) else { throw Refused("The session host answered something else.") }
        return keys
    }

    /// These plugin requests are settled now.
    public func settleRequests(_ keys: [String]) throws {
        guard !keys.isEmpty else { return }
        _ = try call(.settleRequests(keys))
    }

    /// The feature plugins' settings the user set, by key (`<plugin>.<name>`).
    public func pluginSettings() throws -> [String: String] {
        guard case .pluginSettings(let settings) = try call(.pluginSettings) else { throw Refused("The session host answered something else.") }
        return settings
    }

    /// Keeps the user's `value` for a plugin's setting `key` (nil: its default); what is kept now.
    @discardableResult
    public func setPluginSetting(_ key: String, to value: String?) throws -> [String: String] {
        guard case .pluginSettings(let settings) = try call(.setPluginSetting(key: key, value: value)) else {
            throw Refused("The session host answered something else.")
        }
        return settings
    }

    /// Keeps that the user turned `id` on or off; what is kept now.
    @discardableResult
    public func setPlugin(_ id: String, on: Bool) throws -> [String: Bool] {
        guard case .plugins(let plugins) = try call(.setPlugin(id: id, on: on)) else { throw Refused("The session host answered something else.") }
        return plugins
    }
}
