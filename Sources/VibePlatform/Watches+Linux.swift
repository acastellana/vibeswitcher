#if os(Linux)
import Foundation

/// The process's one inotify instance, which every `FolderWatch` and `FileWatch` on Linux is a client of. The kernel
/// gives a user 128 instances (fs.inotify.max_user_instances), shared with the desktop's apps and every other process
/// of the user's: an instance per watch ran out on a node with many sessions and boards, and on parallel test runs.
/// Here a process holds one, whatever it watches; what each watch costs is one kernel watch of the user's
/// (fs.inotify.max_user_watches, 524288 on this machine and 8192 on old kernels), and one per watched inode however many
/// watches share it.
///
/// What a node uses (2026-11-23): an instance in each of its processes (the host, the server, each lead's tool server);
/// kernel watches: the host up to 2 (its socket's and lock's folders), the server 2 (the sessions' state folder, its
/// socket's folder), 1 a lead's board (its `.vibeswitcher` folder), 1 a transcript a page or the command line follows
/// (dropped a while after the last follower goes), and 1 in each lead's tool server (its project's folder). A session
/// costs none of its own: twenty sessions under five leads, each followed, are about 30 of the user's watches.
///
/// Invariants (each relied on below):
/// 1. One instance a process: made at the first watch asked for (asked again at a later watch while it can't be made),
///    and never closed. A watch that can't be made for want of a kernel resource is counted (`Platform.Watches`).
/// 2. One kernel watch (its descriptor, `wd`) a watched inode, whatever path named it, its mask the union of every
///    mask asked of it since it was made (IN_MASK_ADD: a kernel mask never shrinks). Each client is told only the
///    events its own mask asks for, and besides those the overflow (5) and the watch's end (IN_IGNORED, 4).
/// 3. The table (`clients`, by wd) changes only under `lock`, and every inotify_add_watch and inotify_rm_watch is made
///    under it. So a wd in the table is a live kernel watch or one the kernel ended whose IN_IGNORED isn't read yet; the
///    last client of a wd going removes the kernel watch and the table's entry in one step; a client added after that
///    gets a new kernel watch, and a wd's entry holds only clients whose add returned that wd.
/// 4. The kernel ending a watch (IN_IGNORED: its inode gone, its file system unmounted) takes its entry out of the
///    table; its clients are told (a watch's end: gone) and nothing more. inotify gives wds out cyclically
///    (idr_alloc_cyclic), so a wd isn't given again until its counter wraps: an event read late for a wd whose entry
///    went finds none and is dropped, never told to another watch. A client's stop finds itself in its wd's entry by
///    identity, so a stop after the entry went removes nothing of anyone else's.
/// 5. IN_Q_OVERFLOW (events dropped: the kernel's queue for the instance, fs.inotify.max_queued_events, was full) is
///    told to every client: each reads what it watches again.
/// 6. Events are read by a thread of the hub's own, blocked in poll(2) (not a dispatch source: it hears while every
///    pooled thread is busy, as a waiting watch did with its own instance), and by a client's `flush()` just before it
///    takes its events, so whatever the kernel queued before the client looks is in what it takes, as one change.
///    Reads are one at a time (`readLock`), and a read's events are told in the order read.
/// 7. Nothing of a client's is called with `lock` or `readLock` held: a client is told by its condition's signal
///    (`wait`) or by a block put on its own queue (`deliver`), at most one outstanding, which takes every event told
///    until it runs. A client stopped is out of the table at once, and a block already on its queue finds it stopped and
///    calls nothing; a handler already running may finish.
final class InotifyHub: @unchecked Sendable {
    static let shared = InotifyHub()

    private let lock = NSLock()
    /// Under `lock`: the instance (-1 until made), and each kernel watch's clients.
    private var instance: Int32 = -1
    private var clients: [Int32: [InotifyClient]] = [:]
    private let readLock = NSLock()

    /// A client of the kernel's watch of `path` for `mask`'s events (with IN_ONLYDIR when `folder`): nil when the path
    /// can't be watched, or the instance or the watch can't be made (then counted, `Platform.Watches`).
    func watch(_ path: String, mask: UInt32, folder: Bool) -> InotifyClient? {
        lock.lock()
        defer { lock.unlock() }
        if instance < 0 {
            let made = inotify_init1(Int32(IN_NONBLOCK) | Int32(IN_CLOEXEC))
            guard made >= 0 else {
                Platform.Watches.noteUnmade(path, "no inotify instance (errno \(errno)), fs.inotify.max_user_instances")
                return nil
            }
            instance = made
            let thread = Thread { [self] in read(made) }
            thread.name = "vibeswitcher.inotify"
            thread.start()
        }
        let wd = inotify_add_watch(instance, path, mask | UInt32(IN_MASK_ADD) | (folder ? UInt32(IN_ONLYDIR) : 0))
        guard wd >= 0 else {
            let code = errno
            if code == ENOSPC || code == ENOMEM { Platform.Watches.noteUnmade(path, "no inotify watch left (errno \(code)), fs.inotify.max_user_watches") }
            return nil
        }
        let client = InotifyClient(hub: self, wd: wd, mask: mask)
        clients[wd, default: []].append(client)
        return client
    }

    /// `client` out of the table; its kernel watch removed when it was the last of it. Its own `stop` calls this.
    func remove(_ client: InotifyClient) {
        lock.lock()
        defer { lock.unlock() }
        guard var list = clients[client.wd], let at = list.firstIndex(where: { $0 === client }) else { return }
        list.remove(at: at)
        if list.isEmpty {
            clients[client.wd] = nil
            // EINVAL when the kernel ended it already (its IN_IGNORED not read yet): nothing to do.
            _ = inotify_rm_watch(instance, client.wd)
        } else {
            clients[client.wd] = list
        }
    }

    /// Every event the kernel queued by now read and told to its clients. Any thread, no lock of a client's held.
    func flush() {
        let instance = lock.withLock { self.instance }
        guard instance >= 0 else { return }
        drain(instance)
    }

    /// How many kernel watches the table holds, and how many clients they have in all. For the tests.
    var census: (watches: Int, clients: Int) {
        lock.withLock { (clients.count, clients.values.reduce(0) { $0 + $1.count }) }
    }

    /// `body` run while no read of the instance can happen (the hub's thread and every `flush` wait). For the tests.
    func holdingReads<T>(_ body: () throws -> T) rethrows -> T {
        readLock.lock()
        defer { readLock.unlock() }
        return try body()
    }

    /// The instance's descriptor, -1 until made. For the tests.
    var descriptor: Int32 { lock.withLock { instance } }

    /// The hub's thread: waits for the instance to be readable, then reads it. For the process's life.
    private func read(_ instance: Int32) {
        while true {
            var polled = pollfd(fd: instance, events: Int16(POLLIN), revents: 0)
            let count = poll(&polled, 1, -1)
            if count < 0 && errno == EINTR { continue }
            if count > 0 { drain(instance) }
        }
    }

    /// Reads `instance` until it is empty (not blocking), each read's events then told to their clients.
    private func drain(_ instance: Int32) {
        readLock.lock()
        defer { readLock.unlock() }
        // An event is 16 bytes and its entry's name, 256 at most.
        let header = MemoryLayout<inotify_event>.size
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Glibc.read(instance, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            // EAGAIN: the queue is empty.
            guard count > 0 else { return }
            var masks: [Int32: UInt32] = [:]
            var order: [Int32] = []
            var overflow = false
            var offset = 0
            while offset + header <= count {
                let event = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: inotify_event.self) }
                offset += header + Int(event.len)
                if event.mask & UInt32(IN_Q_OVERFLOW) != 0 { overflow = true }
                guard event.wd >= 0 else { continue }
                if masks[event.wd] == nil { order.append(event.wd) }
                masks[event.wd, default: 0] |= event.mask
            }
            let told: [(InotifyClient, UInt32)] = lock.withLock {
                var told: [(InotifyClient, UInt32)] = []
                if overflow {
                    for list in clients.values { for client in list { told.append((client, UInt32(IN_Q_OVERFLOW))) } }
                }
                for wd in order {
                    let mask = masks[wd] ?? 0
                    for client in clients[wd] ?? [] { told.append((client, mask)) }
                    if mask & UInt32(IN_IGNORED) != 0 { clients[wd] = nil }
                }
                return told
            }
            for (client, mask) in told { client.tell(mask) }
        }
    }
}

/// One watch's share of the hub: the events its mask asks for, kept until it takes them (`wait`) or told on its queue
/// (`deliver`). Read one of the two ways, never both.
final class InotifyClient: @unchecked Sendable {
    /// What every client is told besides its own mask's events.
    static let always = UInt32(IN_Q_OVERFLOW) | UInt32(IN_IGNORED) | UInt32(IN_UNMOUNT)

    let wd: Int32
    let mask: UInt32
    private weak var hub: InotifyHub?
    private let condition = NSCondition()
    // Under `condition`.
    private var pending: UInt32 = 0
    private var stopped = false
    private var waiting = 0
    private var queue: DispatchQueue?
    private var handler: (@Sendable (UInt32) -> Void)?
    /// A block is on `queue` that will take `pending`.
    private var scheduled = false

    init(hub: InotifyHub, wd: Int32, mask: UInt32) {
        self.hub = hub
        self.wd = wd
        self.mask = mask
    }

    /// The hub read `events` for this client's watch (or an overflow). Never calls the client's code.
    func tell(_ events: UInt32) {
        let mine = events & (mask | Self.always)
        guard mine != 0 else { return }
        condition.lock()
        defer { condition.unlock() }
        guard !stopped else { return }
        pending |= mine
        if let queue, !scheduled {
            scheduled = true
            queue.async { [self] in fire() }
        }
        condition.broadcast()
    }

    /// On the client's queue: whatever the kernel queued by now read, then every event told since taken, and given.
    private func fire() {
        hub?.flush()
        condition.lock()
        scheduled = false
        let events = pending
        pending = 0
        let handler = stopped ? nil : self.handler
        condition.unlock()
        if events != 0 { handler?(events) }
    }

    /// Whether a thread is inside `wait()` now. For the tests.
    var isWaitedOn: Bool { condition.withLock { waiting > 0 } }

    /// Blocks until events come, and takes every one told by then (the kernel's queue read first): nil once stopped, and
    /// for a client given to `deliver`.
    func wait() -> UInt32? {
        condition.lock()
        guard !stopped, handler == nil else {
            condition.unlock()
            return nil
        }
        waiting += 1
        defer {
            waiting -= 1
            condition.unlock()
        }
        while pending == 0 && !stopped { condition.wait() }
        guard !stopped else { return nil }
        condition.unlock()
        hub?.flush()
        condition.lock()
        guard !stopped else { return nil }
        let events = pending
        pending = 0
        return events
    }

    /// From now on `handler` is given the events on `queue` (those told before it included). Once; not on a client
    /// stopped or waited on.
    func deliver(on queue: DispatchQueue, _ handler: @escaping @Sendable (UInt32) -> Void) {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped, self.handler == nil, waiting == 0 else { return }
        self.queue = queue
        self.handler = handler
        if pending != 0, !scheduled {
            scheduled = true
            queue.async { [self] in fire() }
        }
    }

    /// No more events, and out of the hub's table (its kernel watch removed when it was the last of it). Any thread, a
    /// handler's own included; again is nothing.
    func stop() {
        condition.lock()
        guard !stopped else { return condition.unlock() }
        stopped = true
        handler = nil
        pending = 0
        condition.broadcast()
        condition.unlock()
        hub?.remove(self)
    }

    /// Whether `stop()` was called. For the tests.
    var isStopped: Bool { condition.withLock { stopped } }
}
#endif
