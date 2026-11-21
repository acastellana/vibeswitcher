import Foundation

/// The node's status as a store (the live plan's B2, the live wire contract's §5 `node`): one entry, under the node's id
/// (`NodeIds.node`), whose value is `status`'s result (`Requests.statusValue()`) without `sessions` and `leads` (their
/// own collections) and with `web` (the listener's state). `status` is computed, not kept, so the store looks: after
/// each batch of a store it watches (the host's sessions, the leads, the cards: `watch`), at each of the engine's
/// refreshes (`start(clock:)`), and when told (`look()`, the integration's, after an accepted request). A look that
/// finds the value as it was sends nothing (`Changes`' own rule). On the engine's queue.
public final class NodeStatusStore: @unchecked Sendable {
    /// The value's changes, under `NodeIds.node`: what the hub's `node` stream follows.
    public let changes = Changes<NodeWire.Value>()
    /// The engine's refresh period (`LeadEngine`'s, 3 s): a look on each, for what no store's change says (the host
    /// link's state, the host's notes, the engine's notices).
    public static let refreshEvery = 3
    /// `web` while the listener is off.
    public static let webOff: NodeWire.Value = .object(["state": .string("off"), "port": .null, "tokens": .int(0), "connections": .int(0)])

    public let queue: DispatchQueue
    private let status: () -> NodeWire.Value
    private let web: () -> NodeWire.Value
    private var watches: [Subscription] = []
    private var ticks: Subscription?

    /// `status`: `status`'s result now; `web`: the listener's state now (`webOff` until the integration has one). Both
    /// read on `queue`.
    public init(queue: DispatchQueue, status: @escaping () -> NodeWire.Value, web: @escaping () -> NodeWire.Value = { NodeStatusStore.webOff }) {
        self.queue = queue
        self.status = status
        self.web = web
    }

    /// On the server's `Requests` (its queue, its `statusValue()`).
    public convenience init(requests: Requests, web: @escaping () -> NodeWire.Value = { NodeStatusStore.webOff }) {
        self.init(queue: requests.queue, status: { [weak requests] in requests?.statusValue() ?? .null }, web: web)
    }

    /// The node's value now: `status` without `sessions` and `leads`, with `web`. Without `webTailnet` too (the user's
    /// node's tailnet page, `status`'s for the command line) and `update` (the update check's answer; the notices say it):
    /// the wire's `node` shape doesn't name them.
    public static func value(status: NodeWire.Value, web: NodeWire.Value) -> NodeWire.Value {
        guard case .object(var fields) = status else { return status }
        fields["sessions"] = nil
        fields["leads"] = nil
        fields["webTailnet"] = nil
        fields["switchBlockers"] = nil
        fields["update"] = nil
        fields["web"] = web
        return .object(fields)
    }

    /// Computes the value and sends it when it changed. On `queue`.
    public func look() {
        changes.send(NodeIds.node, Self.value(status: status(), web: web()))
    }

    /// A look after each batch `store` sends, on `queue`, until `stop()`. On `queue`.
    public func watch<T>(_ store: Changes<T>) {
        watches.append(store.subscribe(on: queue) { [weak self] _ in self?.look() })
    }

    /// A look now, and at each of `clock`'s refreshes until `stop()`. On `queue`.
    public func start(clock: NodeClock?) {
        look()
        ticks = clock?.every(Self.refreshEvery) { [weak self] in self?.look() }
    }

    /// No more looks: the clock's and the watched stores' let go. On `queue`.
    public func stop() {
        ticks?.cancel()
        ticks = nil
        watches.forEach { $0.cancel() }
        watches = []
    }
}
