import AppKit
import VibeCore

/// Phone Access's dev-page previews: which localhost pages Chrome has open, the preview slots, their
/// loopback proxies (127.0.0.1:47824–47827) and the `tailscale serve` mappings (:8444–8447) that reach
/// them. Started and stopped by PhoneAccess on the main thread; the proxies call in from their queues.
final class DevPreviews {
    static let slotCount = 4
    static func publicPort(_ slot: Int) -> Int { PhoneAccess.httpsPort + 1 + slot }
    static func localPort(_ slot: Int) -> UInt16 { PhoneAccess.port + 1 + UInt16(slot) }
    static func localTarget(_ slot: Int) -> String { "http://127.0.0.1:\(localPort(slot))" }
    static var mappings: [Int: String] {
        Dictionary(uniqueKeysWithValues: (0..<slotCount).map { (publicPort($0), localTarget($0)) })
    }

    private let control: DispatchQueue
    private let lock = NSLock()
    // Under `lock`:
    private var slots = PreviewSlots(count: slotCount)
    private var context: (host: String, owner: String)?
    private var pageCache: (at: Date, result: Result<[DevPage], ChromeTabs.Failure>)?
    // Main thread:
    private var proxies: [PreviewProxy] = []
    /// Slots whose listener came up: only these count for health (a port held by something else is
    /// skipped, not a reason to restart every preview each health check).
    private var listening: Set<Int> = []
    private var running: String?
    private var generation = 0

    init(control: DispatchQueue) { self.control = control }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Starts the proxies and maps them on the tailnet. `completion(problem)` runs once every slot has been
    /// tried: nil when at least one slot works. Calling it again for the same host does nothing.
    func start(host: String, owner: String, completion: @escaping (String?) -> Void) {
        guard running != host else { return completion(nil) }
        stop()
        generation += 1
        let run = generation
        running = host
        withLock {
            context = (host, owner)
            slots = PreviewSlots(count: Self.slotCount)
            for slot in 0..<Self.slotCount { slots.setAvailable(slot, false) }
        }
        let group = DispatchGroup()
        var problems: [String] = []
        // A copy of the app that is still quitting can hold a port for a moment: retry like the main server.
        func startSlot(_ slot: Int, proxy: PreviewProxy, attempt: Int) {
            proxy.start(port: Self.localPort(slot), onReady: { [weak self] in
                guard let self, self.generation == run else { return group.leave() }
                self.listening.insert(slot)
                self.control.async {
                    let failure = TailscaleCLI.startServing(host: host, httpsPort: Self.publicPort(slot),
                                                            localTarget: Self.localTarget(slot))
                    DispatchQueue.main.async {
                        if self.generation == run {
                            if let failure { problems.append(failure.description) }
                            else { self.withLock { self.slots.setAvailable(slot, true) } }
                        }
                        group.leave()
                    }
                }
            }, onFailure: { [weak self] message in
                guard let self, self.generation == run, attempt < 5 else {
                    problems.append(message)
                    return group.leave()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard self.generation == run else { return group.leave() }
                    startSlot(slot, proxy: proxy, attempt: attempt + 1)
                }
            })
        }
        for slot in 0..<Self.slotCount {
            let proxy = makeProxy(slot)
            proxies.append(proxy)
            group.enter()
            startSlot(slot, proxy: proxy, attempt: 1)
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.generation == run else { return }
            let working = self.withLock { self.slots.slots.filter(\.available).count }
            completion(working == 0 ? (problems.first ?? "No preview port could be opened.") : nil)
        }
    }

    /// Closes the proxies (and their open pages) and takes the tailnet mappings down in the background.
    func stop() {
        generation += 1
        proxies.forEach { $0.stop() }
        proxies = []
        listening = []
        withLock {
            context = nil
            slots = PreviewSlots(count: Self.slotCount)
        }
        guard let host = running else { return }
        running = nil
        control.async { TailscaleCLI.stopServing(host: host, mappings: Self.mappings) }
    }

    /// On quit: synchronous, so nothing on the tailnet keeps pointing at ports we no longer own.
    func shutdown() {
        generation += 1
        proxies.forEach { $0.stop() }
        guard let host = running else { return }
        TailscaleCLI.stopServing(host: host, mappings: Self.mappings, timeout: 3)
    }

    var isHealthy: Bool { running == nil || listening.allSatisfy { proxies.indices.contains($0) && proxies[$0].isListening } }

    /// On the control queue (PhoneAccess's health check): puts back mappings that went missing.
    func repairMappings() {
        let (host, available) = withLock { (context?.host, slots.slots.indices.filter { slots.slots[$0].available }) }
        guard let host, !available.isEmpty, let served = TailscaleCLI.servedTargets(host: host) else { return }
        for slot in available where served[Self.publicPort(slot)] != Self.localTarget(slot) {
            _ = TailscaleCLI.startServing(host: host, httpsPort: Self.publicPort(slot), localTarget: Self.localTarget(slot))
        }
    }

    /// Off the main thread. Chrome's localhost tabs, cached for 5 s; `fresh` reads them again.
    func pages(fresh: Bool = false) -> Result<[DevPage], ChromeTabs.Failure> {
        if !fresh, let cache = withLock({ pageCache }), cache.at.timeIntervalSinceNow > -5 { return cache.result }
        let result = ChromeTabs.localPages()
        withLock { pageCache = (Date(), result) }
        return result
    }

    /// Whether a slot is currently showing that server (the phone shows a dot).
    func isOpen(_ target: PreviewTarget) -> Bool {
        withLock { slots.slots.contains { $0.target == target } }
    }

    /// A one-time link (60 s) that opens `page` in a slot, or nil when no slot is available.
    func open(_ page: DevPage) -> URL? {
        withLock {
            guard let host = context?.host, let opened = slots.open(page.target, path: page.path) else { return nil }
            return URL(string: "https://\(host):\(Self.publicPort(opened.slot))\(PreviewGate.enterPath)?t=\(opened.ticket)")
        }
    }

    private func makeProxy(_ slot: Int) -> PreviewProxy {
        let publicPort = Self.publicPort(slot)
        return PreviewProxy(label: "vibeswitcher.preview.\(slot)", context: { [weak self] in
            guard let self else { return nil }
            return self.withLock { () -> PreviewProxy.Context? in
                guard let context = self.context else { return nil }
                let origins = Set((0...Self.slotCount).map { "https://\(context.host):\(PhoneAccess.httpsPort + $0)" })
                return PreviewProxy.Context(owner: context.owner, ownOrigin: "https://\(context.host):\(publicPort)",
                                            siblingOrigins: origins, publicPort: publicPort)
            }
        }, redeem: { [weak self] ticket in
            guard let self else { return nil }
            return self.withLock { self.slots.redeem(ticket, slot: slot) }
        }, resolve: { [weak self] token in
            guard let self else { return nil }
            return self.withLock { self.slots.target(slot: slot, sessionToken: token) }
        })
    }
}
