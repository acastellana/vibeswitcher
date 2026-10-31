import Foundation

/// Carries wallet requests to the Wallet Manager's Mac and their results back (docs/protocol/wallet-request.md, "The life of a
/// request"): checks a request, records it (`WalletRequestStore`), sends it with `PassageLink`, takes the Wallet Manager peer's results
/// for outstanding requests from the inbox, and keeps `passage listen` running exactly while one is outstanding.
/// Every call may block on passage: call it off the main thread. Any thread.
public final class WalletCourier: @unchecked Sendable {
    /// How a `send` went: refused here before passage ran, or passage's own outcome.
    public enum SendOutcome: Equatable, Sendable {
        /// The request wasn't sent: it breaks the format (key material included), it's expired, or its id is taken.
        case refused(String)
        case passage(PassageLink.SendOutcome)
    }

    /// How long after `expiresAt` results are still taken: one in flight when it expired still lands.
    public static let resultGrace: TimeInterval = 3600
    /// The shortest time between two starts of `passage listen`, so one that ends at once isn't started in a loop.
    public static let restartDelay: TimeInterval = 60

    public let link: PassageLink
    public let store: WalletRequestStore
    private let log: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var records: [String: WalletRequestStore.Record] = [:]
    /// Inbox paths already taken, or ignored and logged by this courier: each is looked at once.
    private var handled: Set<String> = []
    private var listener: PassageListener?
    private var listenerStarted: Date?
    private var endNoted = false
    private var hearTaken: (@Sendable ([WalletResult]) -> Void)?

    /// Loads the records `store` holds, and starts `passage listen` if any is outstanding.
    public init(link: PassageLink, store: WalletRequestStore = WalletRequestStore(),
                log: @escaping @Sendable (String) -> Void = { Breadcrumbs.shared.note("wallet: " + $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.link = link
        self.store = store
        self.log = log
        self.now = now
        for var record in store.load(log: log) {
            // Left `sending` by a run that stopped mid-send: it may have gone, and no send of this run is under way, so
            // it's `unsure` (outstanding, and it may be sent again under its id).
            if record.state == .sending {
                record.state = .unsure
                do { try store.save(record) } catch { log("couldn't record request \(record.request.id) as unsure: \(error)") }
                log("request \(record.request.id) was being sent when the app last stopped: unsure")
            }
            records[record.request.id] = record
            handled.formUnion(record.inboxFiles)
        }
        syncListener()
    }

    deinit { listener?.stop() }

    // MARK: Requests

    /// Waiting on the Wallet Manager: sent (or being sent), with no final result, and not past `expiresAt` + `resultGrace`.
    public var outstanding: [WalletRequest] {
        lock.lock()
        defer { lock.unlock() }
        return outstandingLocked(at: now()).map(\.request)
    }

    public func record(_ id: String) -> WalletRequestStore.Record? {
        lock.lock()
        defer { lock.unlock() }
        return records[id]
    }

    private func outstandingLocked(at time: Date) -> [WalletRequestStore.Record] {
        records.values.filter { isOutstanding($0, at: time) }.sorted { $0.request.createdAt < $1.request.createdAt }
    }

    private func isOutstanding(_ record: WalletRequestStore.Record, at time: Date) -> Bool {
        !record.finished && time < record.request.expiresAt.addingTimeInterval(Self.resultGrace)
    }

    /// Checks `request` (the strict parser, on the very bytes that go), records it as sending, starts listening, sends
    /// it as `wallet-request-<id>.json`, and drops the record only when passage says it didn't go (2–5). When the Wallet Manager
    /// may have it all the same (exit 1, a signal, out of time) the record stays, `unsure`, and still takes results; the
    /// same request may then be sent again, under its id (the Wallet Manager acts on an id once, and ignores a repeat).
    public func send(_ request: WalletRequest) -> SendOutcome {
        let bytes: Data
        do {
            bytes = try request.encoded()
        } catch {
            log("refused request \(request.id): \(error)")
            return .refused("\(error)")
        }
        guard !request.isExpired(now: now()) else { return .refused("the request expired at \(WalletRequestFormat.string(request.expiresAt))") }
        lock.lock()
        let resend = records[request.id] != nil
        if let known = records[request.id] {
            guard known.state == .unsure, known.request == request, !known.finished else {
                lock.unlock()
                return .refused("a request with id \(request.id) was sent already")
            }
        } else {
            let record = WalletRequestStore.Record(request: request, state: .sending)
            do {
                try store.save(record)
            } catch {
                lock.unlock()
                return .refused("couldn't record the request: \(error)")
            }
            records[request.id] = record
        }
        lock.unlock()
        // Listening before it goes: the Wallet Manager's first result may come back at once.
        syncListener()

        let outbox = store.folder.appendingPathComponent("outbox", isDirectory: true)
        let file = outbox.appendingPathComponent(WalletRequest.fileName(request.id))
        let outcome: PassageLink.SendOutcome
        var written = false
        do {
            try VibePaths.ensurePrivate(outbox)
            try VibePaths.writePrivate(bytes, to: file)
            written = true
            outcome = link.send(file: file, id: request.id)
        } catch {
            outcome = .unexpected("couldn't write the request file: \(error)")
        }
        try? FileManager.default.removeItem(at: file)

        lock.lock()
        // The record as it is now: a poll while passage ran may have taken results for it.
        if var record = records[request.id] {
            let arrived = outcome == .sent || !record.results.isEmpty
            // A resend that didn't go leaves the first send's doubt as it was.
            if arrived || resend || (written && outcome.mayHaveArrived) {
                record.state = arrived ? .sent : .unsure
                records[request.id] = record
                do { try store.save(record) } catch { log("couldn't record request \(request.id) as \(record.state.rawValue): \(error)") }
            } else {
                records[request.id] = nil
                store.remove(request.id)
            }
        }
        lock.unlock()
        log("request \(request.id) to \(link.walletPeer): \(outcome)")
        syncListener()
        return .passage(outcome)
    }

    /// Forgets the request (Discard on its card): its record goes, from memory and from `store`, and its results are
    /// no longer taken; `passage listen` stops when nothing else is outstanding. A request the Wallet Manager may have (`unsure`)
    /// may still be acted on there: forgetting it only stops VibeSwitcher listening for it. False when it isn't known.
    @discardableResult
    public func forget(_ id: String) -> Bool {
        lock.lock()
        let known = records.removeValue(forKey: id)
        if known != nil { store.remove(id) }
        lock.unlock()
        guard let known else { return false }
        log("forgot request \(id) (\(known.state.rawValue), \(known.results.count) result(s))")
        syncListener()
        return true
    }

    /// Hears every result taken, by any `poll` (the ones `passage listen` sets off included), on the polling thread,
    /// after the records are saved. Nil: none.
    public func onTaken(_ hear: (@Sendable ([WalletResult]) -> Void)?) {
        lock.lock()
        hearTaken = hear
        lock.unlock()
    }

    // MARK: Results

    /// Takes the Wallet Manager peer's new results for outstanding requests from the inbox, in `sequence` order, and returns
    /// them. Everything else it finds is ignored and logged once: a file from another peer, one that isn't a result,
    /// a result for an id that isn't outstanding (unknown, finished, expired), one that doesn't parse or whose id isn't
    /// its name's, and a result that isn't after the last one taken (a repeat, or one after a final result).
    @discardableResult
    public func poll() -> [WalletResult] {
        let entries: [PassageLink.InboxEntry]
        switch link.inbox() {
        case let .success(list): entries = list
        case let .failure(failure):
            log("\(failure)")
            return []
        }
        lock.lock()
        let time = now()
        var candidates: [(entry: PassageLink.InboxEntry, result: WalletResult)] = []
        for entry in entries where !handled.contains(entry.path) {
            func ignore(_ why: String) {
                handled.insert(entry.path)
                log("ignored \(entry.path): \(why)")
            }
            guard entry.peerID == link.walletPeer else { ignore("from peer \(entry.peerID), not the Wallet Manager peer \(link.walletPeer)"); continue }
            guard let id = WalletResult.id(fromFileName: entry.name) else { ignore("not a wallet result (\(entry.name))"); continue }
            guard let record = records[id] else { ignore("a result for an unknown request id \(id)"); continue }
            guard !record.finished else { ignore("a result for request \(id), already finished (\(record.results.last!.status.rawValue))"); continue }
            guard isOutstanding(record, at: time) else { ignore("a result for request \(id), expired"); continue }
            let result: WalletResult
            do {
                result = try WalletResult.parse(link.read(entry))
            } catch {
                ignore("refused: \(error)")
                continue
            }
            guard result.id == id else { ignore("its id \(result.id) isn't its name's \(id)"); continue }
            candidates.append((entry, result))
        }
        var taken: [WalletResult] = []
        for (entry, result) in candidates.enumerated().sorted(by: { ($0.element.result.sequence, $0.offset) < ($1.element.result.sequence, $1.offset) }).map(\.element) {
            handled.insert(entry.path)
            guard var record = records[result.id] else { continue }
            if record.finished {
                log("ignored \(entry.path): a second result for request \(result.id), already finished (\(record.results.last!.status.rawValue))")
                continue
            }
            guard result.sequence > record.lastSequence else {
                log("ignored \(entry.path): result \(result.sequence) for request \(result.id) isn't after \(record.lastSequence)")
                continue
            }
            record.results.append(result)
            record.inboxFiles.append(entry.path)
            records[result.id] = record
            do { try store.save(record) } catch { log("couldn't record result \(result.sequence) for \(result.id): \(error)") }
            log("result \(result.sequence) for request \(result.id): \(result.status.rawValue)")
            taken.append(result)
        }
        let hear = hearTaken
        lock.unlock()
        syncListener()
        if !taken.isEmpty { hear?(taken) }
        return taken
    }

    // MARK: Listening

    /// The running `passage listen`'s pid, if one runs.
    public var listenerPID: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return listener.flatMap { $0.isRunning ? $0.pid : nil }
    }

    /// Starts `passage listen` when a request is outstanding and none runs (not twice within `restartDelay`), and stops
    /// it, by its pid, when none is. Each result it hears is taken by `poll`.
    public func syncListener() {
        lock.lock()
        let time = now()
        let wanted = !outstandingLocked(at: time).isEmpty
        var stopping: PassageListener?
        if let running = listener, !running.isRunning {
            if !endNoted { log("passage listen (pid \(running.pid)) ended: \(running.exitStatus.map(String.init) ?? "?")") }
            endNoted = true
            if !wanted { listener = nil }
        }
        if wanted, listener?.isRunning != true, listenerStarted.map({ time.timeIntervalSince($0) >= Self.restartDelay }) ?? true {
            do {
                listener = try link.listen { [weak self] in
                    DispatchQueue.global(qos: .utility).async { self?.poll() }
                }
                listenerStarted = time
                endNoted = false
                log("passage listen started (pid \(listener!.pid)): \(outstandingLocked(at: time).count) request(s) outstanding")
            } catch {
                listenerStarted = time
                log("couldn't start passage listen: \(error)")
            }
        } else if !wanted, let running = listener {
            stopping = running
            listener = nil
            listenerStarted = nil
        }
        lock.unlock()
        if let stopping {
            stopping.stop()
            log("passage listen (pid \(stopping.pid)) stopped: no request outstanding")
        }
    }

    /// Stops `passage listen` whatever is outstanding (the app quitting).
    public func close() {
        lock.lock()
        let running = listener
        listener = nil
        listenerStarted = nil
        lock.unlock()
        running?.stop()
    }
}
