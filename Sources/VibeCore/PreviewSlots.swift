import Foundation

/// The phone's preview slots. Each slot shows one dev server at a time. A paired phone gets a one-time
/// ticket (60 s) for a slot; redeeming it on that slot's port yields that phone's session token for the
/// slot, which the slot's cookie carries from then on. A session belongs to the phone that asked for the
/// ticket: removing the phone ends it. Giving a slot to another server ends all of its sessions, so a tab
/// still open on the old server can't see the new one.
public struct PreviewSlots: Sendable {
    public static let ticketLifetime: TimeInterval = 60
    /// A session nobody used for this long ends; the page has to be opened again from the phone.
    public static let idleLimit: TimeInterval = 12 * 3600
    /// And every session ends this long after it began, however much it's used.
    public static let lifetime: TimeInterval = 24 * 3600

    public struct Session: Equatable, Sendable {
        public var token: String
        /// The paired device it was opened for.
        public var device: String
        public var started: Date
        public var lastUsed: Date
    }

    public struct Slot: Equatable, Sendable {
        public var target: PreviewTarget?
        /// One per device that opened a page here.
        public var sessions: [Session] = []
        public var lastUsed = Date.distantPast
        /// False while its listener or Tailscale mapping isn't up.
        public var available = true
    }

    private struct Ticket: Sendable {
        var slot: Int
        var path: String
        var device: String
        var expires: Date
    }

    public private(set) var slots: [Slot]
    private var tickets: [String: Ticket] = [:]

    public init(count: Int) {
        slots = Array(repeating: Slot(), count: count)
    }

    public mutating func setAvailable(_ index: Int, _ available: Bool) {
        guard slots.indices.contains(index) else { return }
        slots[index].available = available
        if !available { clear(index) }
    }

    /// A slot for `target` (the one already showing it, else a free one, else the least recently used)
    /// and a new ticket that opens `path` there for `device`. Nil when no slot is available.
    public mutating func open(_ target: PreviewTarget, path: String, device: String, now: Date = Date(),
                              newToken: () -> String = RemoteAuth.newToken) -> (slot: Int, ticket: String)? {
        tickets = tickets.filter { $0.value.expires > now }
        let usable = slots.indices.filter { slots[$0].available }
        guard let index = usable.first(where: { slots[$0].target == target })
                ?? usable.first(where: { slots[$0].target == nil })
                ?? usable.min(by: { slots[$0].lastUsed < slots[$1].lastUsed }) else { return nil }
        if slots[index].target != target {
            clear(index)
            slots[index].target = target
        }
        slots[index].lastUsed = now
        let ticket = newToken()
        tickets[ticket] = Ticket(slot: index, path: path, device: device, expires: now.addingTimeInterval(Self.ticketLifetime))
        return (index, ticket)
    }

    /// Single use: the ticket is gone after this call, whatever the outcome. `clearSite` is true when the
    /// device gets a new session here (the first redeem since the slot got its server, or since its last
    /// session ended): whatever the port showed before in that browser (its storage, cache, service worker)
    /// must not leak into this one.
    public mutating func redeem(_ ticket: String, slot: Int, now: Date = Date(), newToken: () -> String = RemoteAuth.newToken)
        -> (path: String, sessionToken: String, clearSite: Bool)? {
        guard let entry = tickets.removeValue(forKey: ticket), entry.slot == slot, entry.expires > now,
              slots.indices.contains(slot), slots[slot].target != nil else { return nil }
        endExpired(slot, now: now)
        slots[slot].lastUsed = now
        if let index = slots[slot].sessions.firstIndex(where: { $0.device == entry.device }) {
            slots[slot].sessions[index].lastUsed = now
            return (entry.path, slots[slot].sessions[index].token, false)
        }
        let token = newToken()
        slots[slot].sessions.append(Session(token: token, device: entry.device, started: now, lastUsed: now))
        return (entry.path, token, true)
    }

    /// What a request on `slot` carrying `sessionToken` may reach, or nil. Counts as use.
    public mutating func target(slot: Int, sessionToken: String?, now: Date = Date()) -> PreviewTarget? {
        guard slots.indices.contains(slot) else { return nil }
        // Idle too long or too old: the session ends (the page must be opened again from the phone).
        endExpired(slot, now: now)
        guard let index = sessionIndex(slot: slot, token: sessionToken) else { return nil }
        slots[slot].sessions[index].lastUsed = now
        slots[slot].lastUsed = now
        return slots[slot].target
    }

    /// Whether `sessionToken` is a live session on `slot`, without counting as use.
    public func isLive(slot: Int, sessionToken: String?, now: Date = Date()) -> Bool {
        guard slots.indices.contains(slot), let index = sessionIndex(slot: slot, token: sessionToken) else { return false }
        return !Self.isExpired(slots[slot].sessions[index], now: now)
    }

    /// Ends every session and ticket of `device` (it was unpaired). Returns the tokens that ended.
    @discardableResult
    public mutating func revoke(device: String) -> [(slot: Int, token: String)] {
        tickets = tickets.filter { $0.value.device != device }
        var ended: [(slot: Int, token: String)] = []
        for index in slots.indices {
            ended += slots[index].sessions.filter { $0.device == device }.map { (index, $0.token) }
            slots[index].sessions.removeAll { $0.device == device }
        }
        return ended
    }

    private static func isExpired(_ session: Session, now: Date) -> Bool {
        now.timeIntervalSince(session.lastUsed) > idleLimit || now.timeIntervalSince(session.started) > lifetime
    }

    private mutating func endExpired(_ slot: Int, now: Date) {
        slots[slot].sessions.removeAll { Self.isExpired($0, now: now) }
    }

    private func sessionIndex(slot: Int, token: String?) -> Int? {
        guard let token else { return nil }
        // Every session is compared (in constant time), so timing doesn't tell which one nearly matched.
        var found: Int?
        for (index, session) in slots[slot].sessions.enumerated() where RemoteAuth.constantTimeEquals(session.token, token) {
            found = index
        }
        return found
    }

    private mutating func clear(_ index: Int) {
        slots[index].target = nil
        slots[index].sessions = []
        tickets = tickets.filter { $0.value.slot != index }
    }
}
