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
        /// The `.user` seals with these message ids verify false from now on (the server saw the lead take them).
        case retireUserSeals([String])
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

        public init() {}
    }

    /// How many actions the record keeps (the oldest go first).
    public static let actionsKept = 2_000
    /// How long a `.user` seal verifies after it was made (T41 narrowed, EN-D11), unless a scratch host's test sets
    /// another (`--test-user-seal-life`).
    public static let defaultSealLife: TimeInterval = 15 * 60

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
            if record.actions.count > actionsKept { record.actions.removeFirst(record.actions.count - actionsKept) }
            return .recorded(first: true)
        case .userActions(let since):
            return .actions(record.actions.filter { $0.at >= since })
        case .holds(let action, let digest):
            return .holds(record.actions.contains { $0.action == action && $0.digest == digest })
        case .retireUserSeals(let ids):
            for id in ids { record.retired[id] = now }
            prune(&record, now: now)
            return .ok
        }
    }

    /// The `.seal` hook: a `.user` seal the host is about to make for `message` is recorded with its time (Linux only).
    public static func sealed(_ message: SteerMessage, book: inout Book?, changed: inout Bool, now: Double = Date().timeIntervalSince1970) {
        guard isOn, message.from == .user else { return }
        var record = book ?? Book()
        record.seals[message.id] = now
        prune(&record, now: now)
        book = record
        changed = true
    }

    /// The `.verify` hook: `valid` (each message's seal checked against the key) with every `.user` one whose seal was
    /// retired, or made more than `sealLife` ago, false (Linux only). When the seal was made is the record's, else the
    /// message's own time (which its seal covers).
    public static func verified(_ messages: [SteerMessage], _ valid: [Bool], book: Book?, now: Double = Date().timeIntervalSince1970) -> [Bool] {
        guard isOn else { return valid }
        let life = sealLife
        return zip(messages, valid).map { message, valid in
            guard valid, message.from == .user else { return valid }
            if book?.retired[message.id] != nil { return false }
            let made = book?.seals[message.id] ?? message.at
            return now - made <= life
        }
    }

    /// Seals and retirements older than a seal's life verify false by their age alone: they're dropped.
    static func prune(_ record: inout Book, now: Double) {
        let cutoff = now - max(sealLife, defaultSealLife) - 60
        record.seals = record.seals.filter { $0.value >= cutoff }
        record.retired = record.retired.filter { $0.value >= cutoff }
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

    public func retireUserSeals(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        _ = try call(.retireUserSeals(ids))
    }
}
