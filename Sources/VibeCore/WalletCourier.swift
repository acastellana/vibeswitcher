import Foundation

/// Carries wallet requests to the Wallet Manager's Mac and their results back (docs/protocol/wallet-request.md, "The life of a
/// request"): checks a request, records it (`WalletRequestStore`), sends it with `PassageLink`, takes the Wallet Manager peer's results
/// for outstanding requests from the inbox, and keeps `passage listen` running exactly while one is outstanding.
/// With a `WalletLocalLink` for its link, the same over a folder pair to a Wallet Manager on this Mac (a watch on the
/// folder for `passage listen`): every rule here is the one rule for both.
/// Every call may block on passage: call it off the main thread. Any thread.
public final class WalletCourier: @unchecked Sendable {
    /// How a `send` went: refused here before passage ran, or passage's own outcome.
    public enum SendOutcome: Equatable, Sendable {
        /// The request wasn't sent: it breaks the format (key material included), it's expired, or its id is taken.
        case refused(String)
        /// What the link said: passage's outcome, or the transport on one Mac's in the same terms.
        case passage(PassageLink.SendOutcome)
    }

    /// How long after `expiresAt` results are still taken: one in flight when it expired still lands.
    public static let resultGrace: TimeInterval = 3600
    /// The name of the queue `looks` is, when there is one.
    static let looksLabel = "dev.vibeswitcher.wallet-looks"
    /// The shortest time between two starts of `passage listen`, so one that ends at once isn't started in a loop.
    public static let restartDelay: TimeInterval = 60

    public let link: any WalletTransport
    public let store: WalletRequestStore
    private let log: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var records: [String: WalletRequestStore.Record] = [:]
    /// Inbox paths already taken, or ignored and logged by this courier: each is looked at once.
    private var handled: Set<String> = []
    private var listener: (any WalletListening)?
    private var listenerStarted: Date?
    private var endNoted = false
    /// Set by `retire`: it listens and looks no more.
    private var retired = false
    /// What the last look for results failed with, if it did (`WalletTransport.logsARepeatedFailureOnce`).
    private var lastFailure: String?
    private var hearTaken: (@Sendable ([WalletResult]) -> Void)?
    /// Where a look the listener asks for runs when the link wants a queue of the courier's own for them
    /// (`WalletTransport.looksOnAQueueOfItsOwn`); nil: GCD's shared utility queue, as `passage listen`'s lines always did.
    let looks: DispatchQueue?
    /// One poll at a time (`poll`): the asks made, the asks a finished run covered, and whether one runs.
    private let polls = NSCondition()
    private var pollsAsked = 0
    private var pollsDone = 0
    private var polling = false

    /// Loads the records `store` holds, and starts `passage listen` if any is outstanding.
    public init(link: any WalletTransport, store: WalletRequestStore = WalletRequestStore(),
                log: @escaping @Sendable (String) -> Void = { Breadcrumbs.shared.note("wallet: " + $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.link = link
        looks = link.looksOnAQueueOfItsOwn ? DispatchQueue(label: Self.looksLabel, qos: .utility) : nil
        self.store = store
        self.log = log
        self.now = now
        for var record in store.load(now: now(), log: log) {
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

    deinit { listener?.stop(grace: 5) }

    /// The records it keeps and the inbox paths it has looked at (the soak bench's counters).
    public var kept: (records: Int, handled: Int) { lock.withLock { (records.count, handled.count) } }

    // MARK: Requests

    /// Waiting on the Wallet Manager: sent (or being sent), with no final result, and not past `expiresAt` + `resultGrace`.
    public var outstanding: [WalletRequest] {
        lock.lock()
        defer { lock.unlock() }
        let time = now()
        dropPastWindowLocked(at: time)
        return outstandingLocked(at: time).map(\.request)
    }

    /// Forgets, in memory only, the records whose results window is over (`expiresAt` + `resultGrace`): nothing more
    /// is taken for them, and their cards are gone. Their files stay until the store prunes them; their inbox paths
    /// stay looked at while the inbox lists them (`poll`).
    private func dropPastWindowLocked(at time: Date) {
        for (id, record) in records where time >= record.request.expiresAt.addingTimeInterval(Self.resultGrace) {
            records[id] = nil
        }
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
        if let why = request.implausibleTime(now: now()) { return .refused(why) }
        // Known not to be reachable (the transport on one Mac: its folders, its liveness file): nothing is recorded or
        // written, and a record an earlier send left stays as it is.
        if let why = link.notReachable() {
            log("request \(request.id) to \(link.destination): not reachable: \(why)")
            return .passage(.peerNotListening(why))
        }
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
            outcome = link.deliver(file: file, id: request.id)
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
                if outcome == .sent, record.sentAt == nil { record.sentAt = Date(timeIntervalSince1970: floor(now().timeIntervalSince1970)) }
                records[request.id] = record
                do { try store.save(record) } catch { log("couldn't record request \(request.id) as \(record.state.rawValue): \(error)") }
            } else {
                records[request.id] = nil
                store.remove(request.id)
            }
        }
        lock.unlock()
        log("request \(request.id) to \(link.destination): \(outcome)")
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
    ///
    /// One `passage inbox` runs at a time: asked while one runs (a listen line, the desk's look), it waits for the run
    /// that covers its ask (the one under way says "poll again" and runs once more, however many asked meanwhile) and
    /// returns nothing (what that run took went to `onTaken`).
    @discardableResult
    public func poll() -> [WalletResult] {
        polls.lock()
        pollsAsked += 1
        let mine = pollsAsked
        if polling {
            while pollsDone < mine { polls.wait() }
            polls.unlock()
            return []
        }
        polling = true
        polls.unlock()
        return drainPolls()
    }

    /// Polls asked for and not yet covered by a finished run (a test's view).
    var pollsPending: Int { polls.withLock { pollsAsked - pollsDone } }

    /// A line `passage listen` printed: a poll, started on a thread of its own unless one runs, which then polls again
    /// once it's done (however many lines came meanwhile).
    func heardListenLine() {
        polls.lock()
        pollsAsked += 1
        let start = !polling
        polling = true
        polls.unlock()
        guard start else { return }
        (looks ?? DispatchQueue.global(qos: .utility)).async { [self] in _ = drainPolls() }
    }

    /// Polls until every ask made so far is covered; `polling` is set by the caller.
    private func drainPolls() -> [WalletResult] {
        var taken: [WalletResult] = []
        polls.lock()
        while pollsDone < pollsAsked {
            let covered = pollsAsked
            polls.unlock()
            taken += pollOnce()
            polls.lock()
            pollsDone = covered
            polls.broadcast()
        }
        polling = false
        polls.unlock()
        return taken
    }

    private func pollOnce() -> [WalletResult] {
        if lock.withLock({ retired }) { return [] }
        let entries: [PassageLink.InboxEntry]
        switch link.arrivals() {
        case let .success(list):
            entries = list
            lock.withLock { lastFailure = nil }
        case let .failure(failure):
            let repeated = lock.withLock { () -> Bool in
                defer { lastFailure = "\(failure)" }
                return link.logsARepeatedFailureOnce && lastFailure == "\(failure)"
            }
            if !repeated { log("\(failure)") }
            return []
        }
        lock.lock()
        let time = now()
        dropPastWindowLocked(at: time)
        // Only the paths the inbox still lists are remembered: what it no longer has can't come back to be looked at.
        handled.formIntersection(entries.map(\.path))
        var candidates: [(entry: PassageLink.InboxEntry, result: WalletResult)] = []
        for entry in entries where !handled.contains(entry.path) {
            func ignore(_ why: String) {
                handled.insert(entry.path)
                log("ignored \(entry.path): \(why)")
            }
            let id: String
            do {
                id = try link.requestID(of: entry)
            } catch {
                ignore("\(error)")
                continue
            }
            guard let record = records[id] else { ignore("a result for an unknown request id \(id)"); continue }
            guard !record.finished else { ignore("a result for request \(id), already finished (\(record.results.last!.status.rawValue))"); continue }
            guard isOutstanding(record, at: time) else { ignore("a result for request \(id), expired"); continue }
            let result: WalletResult
            do {
                result = try WalletResult.parse(link.bytes(of: entry))
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
            do {
                try store.save(record)
            } catch WalletRequestFormat.Failure.tooLarge(let bytes) {
                log("ignored \(entry.path): with it, request \(result.id)'s record would be \(bytes) bytes, over the \(WalletRequestFormat.maxFileBytes)-byte limit")
                continue
            } catch {
                log("couldn't record result \(result.sequence) for \(result.id): \(error)")
            }
            records[result.id] = record
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
        return listener.flatMap { $0.isRunning ? $0.process?.pid : nil }
    }

    /// Whether it listens now: `passage listen` runs, or the folder is watched.
    public var isListening: Bool { lock.withLock { listener?.isRunning == true } }

    /// " (pid 123)" for a listener that is a process.
    private func pidText(_ listener: any WalletListening) -> String { listener.process.map { " (pid \($0.pid))" } ?? "" }

    /// Starts `passage listen` when a request is outstanding and none runs (not twice within `restartDelay`), and stops
    /// it, by its pid, when none is. Each result it hears is taken by `poll`.
    public func syncListener() {
        lock.lock()
        let time = now()
        dropPastWindowLocked(at: time)
        let wanted = !outstandingLocked(at: time).isEmpty
        var stopping: (any WalletListening)?
        if let running = listener, !running.isRunning {
            if !endNoted { log("\(link.listening)\(pidText(running)) ended: \(running.exitStatus.map(String.init) ?? "?")") }
            endNoted = true
            if !wanted { listener = nil }
        }
        if wanted, !retired, listener?.isRunning != true, listenerStarted.map({ time.timeIntervalSince($0) >= Self.restartDelay }) ?? true {
            do {
                let started = try link.watch { [weak self] in self?.heardListenLine() }
                listener = started
                listenerStarted = time
                endNoted = false
                // Its pid and start time, so a crash that orphans it doesn't leave it running past the next launch.
                if let process = started.process { ListenRecord.save(pid: process.pid, executable: process.executable, in: store.folder, log: log) }
                log("\(link.listening) started\(pidText(started)): \(outstandingLocked(at: time).count) request(s) outstanding")
            } catch {
                listenerStarted = time
                log("couldn't start \(link.listening): \(error)")
            }
        } else if !wanted, let running = listener {
            stopping = running
            listener = nil
            listenerStarted = nil
        }
        lock.unlock()
        if let stopping {
            stopping.stop(grace: 5)
            if let process = stopping.process { ListenRecord.clear(pid: process.pid, in: store.folder) }
            log("\(link.listening)\(pidText(stopping)) stopped: no request outstanding")
        }
    }

    /// Stops `passage listen` whatever is outstanding (the app quitting).
    public func close() {
        lock.lock()
        let running = listener
        listener = nil
        listenerStarted = nil
        lock.unlock()
        running?.stop(grace: 5)
        if let process = running?.process { ListenRecord.clear(pid: process.pid, in: store.folder) }
    }

    /// Stops it for good (Settings › Wallet no longer has its Wallet Manager chosen): what it listens with is stopped,
    /// none is started again, and no look for results starts after this returns (one under way ends by itself). Its
    /// records stay in the store for the courier made when it's chosen again. The desk retires only the courier of the
    /// transport on one Mac, so nothing reads its folders once the user chose otherwise.
    public func retire() {
        lock.withLock { retired = true }
        close()
    }

    // MARK: A listener a crash left

    /// The running `passage listen`'s pid, start time and program, kept in `passage-listen.pid` beside the records
    /// while it runs. The app ending without `close` (a crash, a kill) leaves it running, a child of no one; at the
    /// next launch `endOrphan` ends it, by its pid, once the process with that pid has that start time and is
    /// `<program> … listen` (a pid used again since is never touched).
    public enum ListenRecord {
        public static let fileName = "passage-listen.pid"

        struct Saved: Equatable {
            var pid: Int32
            var start: Start
            var executable: String
        }

        /// A process's start time as the kernel keeps it (seconds and microseconds).
        struct Start: Equatable {
            var seconds: UInt64
            var microseconds: UInt64
        }

        public static func file(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

        /// The process's start time, unless it's gone or a zombie.
        static func start(of pid: Int32) -> Start? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { return nil }
            return Start(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
        }

        static func save(pid: Int32, executable: String, in folder: URL, log: (String) -> Void) {
            guard let start = start(of: pid) else { return }
            do {
                try VibePaths.ensurePrivate(folder)
                try VibePaths.writePrivate(Data("\(pid) \(start.seconds) \(start.microseconds)\n\(executable)\n".utf8), to: file(in: folder))
            } catch {
                log("couldn't keep passage listen's pid \(pid): \(error)")
            }
        }

        static func read(in folder: URL) -> Saved? {
            guard let data = try? WalletAsk.read(file(in: folder)), let text = String(data: data, encoding: .utf8) else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 2 else { return nil }
            let numbers = lines[0].split(separator: " ")
            guard numbers.count == 3, let pid = Int32(numbers[0]), pid > 1, let seconds = UInt64(numbers[1]), let micro = UInt64(numbers[2]),
                  lines[1].hasPrefix("/") else { return nil }
            return Saved(pid: pid, start: Start(seconds: seconds, microseconds: micro), executable: String(lines[1]))
        }

        /// Removes the record if it's `pid`'s (a courier made since may have written its own).
        static func clear(pid: Int32, in folder: URL) {
            guard read(in: folder)?.pid == pid else { return }
            try? FileManager.default.removeItem(at: file(in: folder))
        }

        /// Whether `arguments` (a process's argv) are `executable`'s `listen`: the program itself, or a script's
        /// interpreter given it, with `listen` last.
        static func isListen(_ arguments: [String], executable: String) -> Bool {
            arguments.last == "listen" && arguments.dropLast().contains(executable)
        }

        /// At launch, before any courier listens: ends the `passage listen` an earlier run left (SIGTERM to its pid,
        /// SIGKILL after `grace` if that very process still runs), only when the pid's process has the start time and
        /// the command line recorded. The record goes either way. True when it signalled one.
        @discardableResult
        public static func endOrphan(in folder: URL, grace: TimeInterval = 5, log: @escaping @Sendable (String) -> Void) -> Bool {
            guard let saved = read(in: folder) else {
                try? FileManager.default.removeItem(at: file(in: folder))
                return false
            }
            try? FileManager.default.removeItem(at: file(in: folder))
            guard saved.pid != getpid(), start(of: saved.pid) == saved.start,
                  isListen(ProcessTable.commandLine(pid: saved.pid), executable: saved.executable) else { return false }
            kill(saved.pid, SIGTERM)
            log("ended passage listen (pid \(saved.pid)) an earlier run left running")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
                guard start(of: saved.pid) == saved.start, isListen(ProcessTable.commandLine(pid: saved.pid), executable: saved.executable) else { return }
                kill(saved.pid, SIGKILL)
                log("killed passage listen (pid \(saved.pid)): it didn't end on SIGTERM")
            }
            return true
        }
    }
}
