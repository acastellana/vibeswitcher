import Foundation

/// The phone's preview slots. Each slot shows one dev server at a time. The phone gets a one-time ticket
/// (60 s) for a slot; redeeming it on that slot's port yields the slot's session token, which the slot's
/// cookie carries from then on. Giving a slot to another server ends its session, so a tab still open
/// on the old server can't see the new one.
public struct PreviewSlots: Sendable {
    public static let ticketLifetime: TimeInterval = 60
    /// A session nobody used for this long ends; the page has to be opened again from the phone.
    public static let idleLimit: TimeInterval = 12 * 3600

    public struct Slot: Equatable, Sendable {
        public var target: PreviewTarget?
        public var sessionToken: String?
        public var lastUsed = Date.distantPast
        /// False while its listener or Tailscale mapping isn't up.
        public var available = true
    }

    private struct Ticket: Sendable {
        var slot: Int
        var path: String
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
    /// and a new ticket that opens `path` there. Nil when no slot is available.
    public mutating func open(_ target: PreviewTarget, path: String, now: Date = Date(),
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
        tickets[ticket] = Ticket(slot: index, path: path, expires: now.addingTimeInterval(Self.ticketLifetime))
        return (index, ticket)
    }

    /// Single use: the ticket is gone after this call, whatever the outcome. `clearSite` is true on the
    /// first redeem since the slot got its server: whatever the port showed before (its storage, cache,
    /// service worker) must not leak into this one.
    public mutating func redeem(_ ticket: String, slot: Int, now: Date = Date(), newToken: () -> String = RemoteAuth.newToken)
        -> (path: String, sessionToken: String, clearSite: Bool)? {
        guard let entry = tickets.removeValue(forKey: ticket), entry.slot == slot, entry.expires > now,
              slots.indices.contains(slot), slots[slot].target != nil else { return nil }
        let clearSite = slots[slot].sessionToken == nil
        let token = slots[slot].sessionToken ?? newToken()
        slots[slot].sessionToken = token
        slots[slot].lastUsed = now
        return (entry.path, token, clearSite)
    }

    /// What a request on `slot` carrying `sessionToken` may reach, or nil.
    public mutating func target(slot: Int, sessionToken: String?, now: Date = Date()) -> PreviewTarget? {
        guard let sessionToken, slots.indices.contains(slot), let expected = slots[slot].sessionToken,
              RemoteAuth.constantTimeEquals(expected, sessionToken) else { return nil }
        guard now.timeIntervalSince(slots[slot].lastUsed) <= Self.idleLimit else {
            // Idle too long: the session ends (the page must be opened again from the phone).
            slots[slot].sessionToken = nil
            return nil
        }
        slots[slot].lastUsed = now
        return slots[slot].target
    }

    private mutating func clear(_ index: Int) {
        slots[index].target = nil
        slots[index].sessionToken = nil
        tickets = tickets.filter { $0.value.slot != index }
    }
}
