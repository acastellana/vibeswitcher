import Foundation
import VibeCore

/// The server's socket (the engine plan's EN-D3, the security architecture document's S2 and S3):
/// `<root>/v2/server.sock`, the file 0600 in its folder 0700. Credentials are passed on the listener before the first
/// accept, so every connection's bytes come with their sender; a peer of another uid is closed at accept; each read
/// goes through `Platform.Sockets.receive`, and bytes from any process other than the one accepted (S5's rule on this
/// socket) get no reply: `bye`, the close and a log line. A line that isn't a JSON object, or is over 1 MiB, gets
/// `bye` and the close.
///
/// Bounded as the host's and the web's listeners are (the architecture review's row 4), so no process of the user can
/// starve the engine's queue or grow the server's memory: at most `maxConnections` connections (the newest past it gets
/// `bye` and the close), at most `maxPending` bytes waiting to be written to one (a reader that doesn't read is closed),
/// at most `chunksPerTurn` reads of a connection and `acceptsPerTurn` accepts a turn of the queue, and an accept that
/// fails for want of descriptors or memory suspends accepting for `acceptPause` instead of firing again at once.
///
/// What a sender is (`PeerFacts`, its ancestry, cgroup, environment and terminal from /proc) is read once per
/// connection, at its accept, for the hello and its `anyone` requests; every request whose kind judges the sender (the
/// user's voice, the lead's tool server, a private read, any kind not named) reads it again, as it always did. Every
/// read's sender is checked against the process accepted either way.
///
/// The socket keeps its path as the host keeps its own: the folder is watched, and at each housekeeping (30 s, or a
/// scratch host's `--test-housekeeping`) the path is checked against the file the listener is bound to
/// (`Platform.Sockets.boundFile(of:at:)`, or the file's device and inode recorded at the bind where the kernel can't
/// say); on a mismatch a fresh listener is bound at the path, with a log line, the folder made again first (0700) when
/// it was removed or renamed, and watched again when it is another folder than the one watched. Each housekeeping asks the host's notes
/// too (`Requests.refreshNotes`), until E7's refresh does. On the engine's queue (`requests.queue`).
public final class NodeServer: @unchecked Sendable {
    /// The connections open at once. Past it (or past the share a peer that isn't the user's voice may take), the
    /// heaviest holder's longest-idle connection is closed to make room (`evictee`), never the newest.
    public static let maxConnections = 64
    /// The connections one process may hold; its next one gets `bye` and the close. Well below `maxConnections`, so no
    /// one process locks out the user's command line or the leads' tool servers.
    public static let maxPerPeer = 8
    /// The slots only a peer that may be the user's voice takes (`Requests.mayBeUsersVoice`): the others share
    /// `maxConnections` less these.
    public static let reservedForUser = 8
    /// The connections one share (`Requests.share`: a session, a cgroup, a process) that isn't the user's may hold, its
    /// processes together: a peer that forks for more is held to it.
    public static let maxPerShare = 16
    /// How long a connection told `bye` may take to be written its last bytes before it is closed outright.
    public static let closingLife: TimeInterval = 2
    /// The bytes waiting to be written to one connection past which it is closed (its reader doesn't read).
    public static let maxPending = 8 << 20
    /// Reads of one connection (each up to 64 KiB) in a turn of the queue; the source fires again while more waits.
    public static let chunksPerTurn = 16
    /// Accepts in a turn of the queue.
    public static let acceptsPerTurn = 64
    /// How long accepting stops after it failed for want of descriptors or memory (EMFILE, ENFILE, ENOBUFS, ENOMEM).
    public static let acceptPause: TimeInterval = 1

    public let queue: DispatchQueue
    public let requests: Requests
    public let socketPath: String
    public let folder: URL
    private let housekeeping: Int
    /// A scratch server's test's cgroup root (`ServerArguments.testCgroupRoot`), fixed at the start: every sender's
    /// cgroup is read from there. nil on the user's node, always.
    private let cgroupRoot: String?
    /// The runners a scratch server's test runs under (`ServerArguments.testRunnerAbove`), read once at the start:
    /// not counted as a sender's. None on the user's node, always.
    private let runnersAbove: [PeerFacts.Ancestor]
    private let clock: NodeClock?
    private let note: (String) -> Void

    private var listener: Int32 = -1
    private var listening: DispatchSourceRead?
    /// The file `bind` made, as `lstat` saw it then: the check where the kernel can't say.
    private var bound: (device: UInt64, inode: UInt64)?
    private var watch: Platform.FolderWatch?
    /// The folder `watch` watches, by device and inode.
    private var watched: (device: UInt64, inode: UInt64)?
    private var ticks: Subscription?
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// Accepting suspended (`pauseAccepting`); said once per pause. A process past its share said once until it is
    /// under it again; an eviction said once until the server has room again.
    private var acceptPaused = false
    private var capNoted: Set<pid_t> = []
    private var evictNoted = false
    /// The live protocol's hub (`NodeLive`, the live plan's I1): `subscribe` and `unsubscribe` on this socket are its, for
    /// any peer of the uid (LW-D8), and their events come between replies on the same lines. None: both are refused.
    public var hub: LiveHub?

    /// `root`: the node's root (`<root>/v2/server.sock`). `housekeeping`: seconds between checks of the path (and asks
    /// of the host's notes), on `clock` (none: only on the folder's changes). `note`: the server's log. `cgroupRoot`
    /// and `runnersAbove`: a scratch server's test's, or nil and none.
    public init(root: URL, requests: Requests, housekeeping: Int = ServerArguments.housekeeping, clock: NodeClock?,
                cgroupRoot: String? = nil, runnersAbove: [PeerFacts.Ancestor] = [], note: @escaping (String) -> Void = { _ in }) {
        self.requests = requests
        self.cgroupRoot = cgroupRoot
        self.runnersAbove = runnersAbove
        queue = requests.queue
        folder = root.appendingPathComponent("v2", isDirectory: true)
        socketPath = folder.appendingPathComponent("server.sock").path
        self.housekeeping = housekeeping
        self.clock = clock
        self.note = note
    }

    /// Whether a peer of `peerUID` may stay connected to a server of `ownUID`: the same user only (nil: unknown, no).
    public static func admits(peerUID: uid_t?, ownUID: uid_t) -> Bool { peerUID == ownUID }

    /// Makes the folder (0700), binds the socket (0600), and from then on accepts, checks its path and asks the host's
    /// notes at each housekeeping. Throws when the socket can't be made.
    public func start() throws {
        try VibePaths.ensurePrivate(folder)
        try queue.sync {
            try bind()
            watchFolder()
        }
        ticks = clock?.every(housekeeping) { [weak self] in
            guard let self else { return }
            self.checkPath()
            self.requests.refreshNotes()
        }
    }

    /// A fresh listener at the path (whatever is there is replaced), credentials passed before its first accept. On
    /// `queue`.
    private func bind() throws {
        let fd = try UnixSocket.listen(path: socketPath)
        Platform.Sockets.enableCredentials(fd)
        var info = stat()
        bound = lstat(socketPath, &info) == 0 ? (UInt64(truncatingIfNeeded: info.st_dev), UInt64(truncatingIfNeeded: info.st_ino)) : nil
        listening?.cancel()
        acceptPaused = false
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { Sys.close(fd) }
        listening = source
        source.resume()
    }

    /// The folder watched from now on, unless the folder at its path is the one watched already. On `queue`.
    private func watchFolder() {
        var info = stat()
        guard lstat(folder.path, &info) == 0 else { return }
        let now = (UInt64(truncatingIfNeeded: info.st_dev), UInt64(truncatingIfNeeded: info.st_ino))
        if let watched, watched == now, watch != nil { return }
        watch?.stop()
        watch = nil
        watched = now
        if let made = Platform.FolderWatch(path: folder.path) {
            made.deliver(on: queue) { [weak self] _ in self?.checkPath() }
            watch = made
        }
    }

    /// Whether the path still names the listener's file; if not, a fresh listener there (in the folder made again
    /// when it went, and watched again), said in the log. On `queue`.
    func checkPath() {
        guard listener >= 0 else { return }
        let ours: Bool
        switch Platform.Sockets.boundFile(of: listener, at: socketPath) {
        case .bound: ours = true
        case .another: ours = false
        case .sharesLowBits, .cantSay:
            var info = stat()
            ours = lstat(socketPath, &info) == 0 && bound.map { $0.device == UInt64(truncatingIfNeeded: info.st_dev) && $0.inode == UInt64(truncatingIfNeeded: info.st_ino) } == true
        }
        guard !ours else { return }
        note("the server's socket \(socketPath) named another file: bound again")
        do {
            try VibePaths.ensurePrivate(folder)
            try bind()
        } catch {
            note("the server's socket couldn't be bound again: \(error)")
        }
        watchFolder()
    }

    // MARK: Connections

    private func acceptAll(_ listener: Int32) {
        for _ in 0..<Self.acceptsPerTurn {
            let fd = Platform.Sockets.accept(listener)
            guard fd >= 0 else {
                let code = errno
                if code == EINTR || code == ECONNABORTED { continue }
                if Self.lastsAWhile(code) { pauseAccepting(code) }
                return
            }
            let uid = Platform.Sockets.peerUID(fd)
            guard Self.admits(peerUID: uid, ownUID: getuid()), let token = Platform.Sockets.peerToken(fd) else {
                note("refused a connection from uid \(uid.map(String.init) ?? "unknown")")
                Sys.close(fd)
                continue
            }
            UnixSocket.configure(fd)
            // Every connection that still holds a descriptor counts, one closing too (it is closed within `closingLife`).
            let open = Array(connections.values)
            let facts = PeerFacts.read(pid: token.pid, token: token, cgroupRoot: cgroupRoot, runnersAbove: runnersAbove)
            let voice = requests.mayBeUsersVoice(facts)
            let share = requests.share(facts)
            let holders = open.map {
                Holder(id: ObjectIdentifier($0), pid: $0.token.pid, share: $0.share, voice: $0.voice, requested: $0.requested,
                       idleSince: $0.idleSince, kept: $0.subscribed || $0.toolServer)
            }
            switch Self.admission(holders, pid: token.pid, share: share, voice: voice) {
            case .refuse(let why):
                refuseAtAccept(fd, why)
                if capNoted.insert(token.pid).inserted { note("pid \(token.pid)'s connection refused: \(why) (said once until it is admitted)") }
                continue
            case .evict(let victim):
                guard let closing = connections[victim] else { continue }
                if !evictNoted {
                    evictNoted = true
                    note("the server has \(open.count) connections open: closed one of pid \(closing.token.pid)'s (its share, \(closing.share), held the most) to make room (said once until there is room)")
                }
                bye("closed to make room for another connection: this process's share held the most, and this one was the longest idle", code: "busy", closing, hard: true)
            case .admit:
                if open.count < Self.maxConnections - Self.reservedForUser { evictNoted = false }
            }
            capNoted.remove(token.pid)
            let connection = Connection(fd: fd, token: token)
            connection.voice = voice
            connection.share = share
            connection.idleSince = MacTime.real.awake()
            connections[ObjectIdentifier(connection)] = connection
            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            read.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.readable(connection)
            }
            read.setCancelHandler { connection.sourceEnded() }
            connection.sources += 1
            connection.reading = read
            read.resume()
            connection.facts = facts
            send(NodeWire.line(requests.hello(peer: facts, token: token)), on: connection)
        }
    }

    /// One write to a connection not kept (whatever of it the new socket takes), and the close.
    private func refuseAtAccept(_ fd: Int32, _ reason: String) {
        let line = NodeWire.line(NodeWire.Bye(reason: reason, code: "busy"))
        _ = line.withUnsafeBytes { Platform.Sockets.send(fd, $0.baseAddress, $0.count) }
        Sys.close(fd)
    }

    /// A connection as the caps weigh it.
    struct Holder: Equatable {
        var id: ObjectIdentifier
        var pid: pid_t
        /// Its share (`Requests.share`).
        var share: String
        /// Its process may be the user's voice (at its accept).
        var voice: Bool
        /// It sent a request since its hello.
        var requested: Bool
        /// Its accept, or its last request, on the awake clock.
        var idleSince: TimeInterval
        /// Never closed to make room: it holds a live subscription, or a lead's tool server posts on it.
        var kept: Bool = false
    }

    /// What a newcomer's connection gets.
    enum Admission: Equatable {
        case admit
        /// Closed at once, saying why.
        case refuse(String)
        /// Admitted, this one closed to make room.
        case evict(ObjectIdentifier)
    }

    /// A newcomer from `pid`, in `share`, that may be the user's voice (`voice`), among the connections `open` (every
    /// one that holds a descriptor, closing ones too):
    /// - refused past its process's `maxPerPeer`, or, when it isn't the user's, past its share's `maxPerShare`;
    /// - admitted while there is room: `maxConnections`, less `reservedForUser` when it isn't the user's;
    /// - else, admitted in place of a connection of the share holding the most, only when that share holds more than
    ///   the newcomer's would with it (never at an equal share), never one kept (`Holder.kept`), and never the user's for
    ///   another's: of that share's connections, one with no request since its hello first, then the longest idle;
    /// - else refused.
    static func admission(_ open: [Holder], pid: pid_t, share: String, voice: Bool) -> Admission {
        guard open.filter({ $0.pid == pid }).count < maxPerPeer else {
            return .refuse("this process has \(maxPerPeer) connections open to the server: close one first")
        }
        let own = open.filter { $0.share == share }.count
        if !voice, own >= maxPerShare {
            return .refuse("this process's share (\(share)) has \(maxPerShare) connections open to the server: close one first")
        }
        guard open.count >= (voice ? maxConnections : maxConnections - reservedForUser) else { return .admit }
        let candidates = open.filter { !$0.kept && $0.share != share && (voice || !$0.voice) }
        let byShare = Dictionary(grouping: candidates, by: \.share)
        let full = Dictionary(grouping: open, by: \.share).mapValues(\.count)
        let rank = { (holder: Holder) in (holder.requested ? 1 : 0, holder.idleSince) }
        let idlest = { (list: [Holder]) in list.min { rank($0) < rank($1) } }
        // The share holding the most; of equal ones, the one whose idlest connection ranks first.
        let heaviest = byShare.filter { (full[$0.key] ?? 0) > own + 1 }.max { one, other in
            let (a, b) = (full[one.key] ?? 0, full[other.key] ?? 0)
            guard a == b, let first = idlest(one.value), let second = idlest(other.value) else { return a < b }
            return rank(first) > rank(second)
        }
        guard let victim = heaviest.flatMap({ idlest($0.value) }) else {
            return .refuse("the server has \(open.count) connections open: try again later")
        }
        return .evict(victim.id)
    }

    /// Whether an accept's failure lasts (no descriptor left in the process or the system, no memory): accepting again
    /// at once would fail again, the listener's source firing for as long as a connection waits.
    static func lastsAWhile(_ code: Int32) -> Bool { [EMFILE, ENFILE, ENOBUFS, ENOMEM].contains(code) }

    /// Accepting suspended for `acceptPause`, said once. The source suspended is the one resumed, whatever happened to
    /// it meanwhile (a source cancelled while suspended ends only once resumed, and mustn't be let go suspended).
    private func pauseAccepting(_ code: Int32) {
        guard !acceptPaused, let source = listening else { return }
        acceptPaused = true
        note("the server couldn't accept a connection (errno \(code)): it tries again in \(Int(Self.acceptPause)) s")
        source.suspend()
        queue.asyncAfter(deadline: .now() + Self.acceptPause) { [weak self] in
            source.resume()
            if let self, (self.listening as AnyObject?) === (source as AnyObject) { self.acceptPaused = false }
        }
    }

    /// One turn's reads: `read` called until it says to stop, at most `chunksPerTurn` times. Whether it stopped by
    /// itself (false: the turn's share is spent, and the source fires again while more waits).
    @discardableResult static func readTurn(_ read: () -> Bool) -> Bool {
        for _ in 0..<chunksPerTurn where !read() { return true }
        return false
    }

    /// What a connection sent is taken a turn at a time: at most `requestsPerTurn` lines, the rest kept, its reads
    /// stopped (its read source suspended) until they are taken, in the next turns, after whatever else waits on the
    /// queue (the review of the runtime hardening: 1 MiB of minimal lines is some 33,000 requests, each judged afresh,
    /// and one block of them would hold the queue past the watchdog). Then up to `chunksPerTurn` reads.
    private func readable(_ connection: Connection) {
        if !connection.turnAsked { connection.taken = 0 }
        guard takeWaiting(connection) else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        Self.readTurn { [self] in
            guard !connection.closing, connection.waiting.isEmpty else { return false }
            let (count, sender) = chunk.withUnsafeMutableBytes { Platform.Sockets.receive(connection.fd, into: $0) }
            if count == 0 {
                close(connection)
                return false
            }
            if count < 0 {
                if errno != EAGAIN, errno != EINTR { close(connection) }
                return false
            }
            guard let sender, sender.sameImage(as: connection.token) else {
                note("refused the connection of pid \(connection.token.pid): bytes on it came from another process (pid \(sender.map { String($0.pid) } ?? "unknown"))")
                bye("a request came from another process than the one that connected", code: "auth", connection, hard: true)
                return false
            }
            connection.waiting += connection.lines.append(Data(chunk[0..<count])).map { ($0, sender) }
            if connection.lines.tooLong {
                bye("a line over \(NodeWire.maxLine) bytes", code: "too-long", connection, hard: true)
                return false
            }
            return takeWaiting(connection)
        }
    }

    /// The requests taken in one turn of the queue, from one connection.
    public static let requestsPerTurn = 32

    /// Takes what `connection` sent and isn't taken yet, within this turn's share (`requestsPerTurn`, counted on the
    /// connection). Whether all of it is taken: if not, its reads are stopped and the next share comes in a later turn.
    private func takeWaiting(_ connection: Connection) -> Bool {
        while !connection.waiting.isEmpty, !connection.closing {
            guard connection.taken < Self.requestsPerTurn else {
                laterTurn(connection)
                return false
            }
            let (line, sender) = connection.waiting.removeFirst()
            connection.taken += 1
            take(line, from: sender, on: connection)
        }
        resumeReading(connection)
        return !connection.closing
    }

    /// The connection's reads stopped and its next share asked for a later turn of the queue (after what waits on it).
    private func laterTurn(_ connection: Connection) {
        if !connection.readStopped, let reading = connection.reading {
            reading.suspend()
            connection.readStopped = true
        }
        guard !connection.turnAsked else { return }
        connection.turnAsked = true
        queue.async { [weak self, weak connection] in
            guard let self, let connection else { return }
            connection.turnAsked = false
            connection.taken = 0
            guard !connection.closing else { return }
            if self.takeWaiting(connection) { self.readable(connection) }
        }
    }

    /// The connection's reads started again (its share taken), when they were stopped.
    private func resumeReading(_ connection: Connection) {
        guard connection.readStopped else { return }
        connection.readStopped = false
        connection.reading?.resume()
    }

    private func take(_ line: Data, from sender: Platform.PeerToken, on connection: Connection) {
        connection.requested = true
        connection.idleSince = MacTime.real.awake()
        let request: NodeWire.Request
        switch NodeWire.unwrap(line) {
        case .request(let unwrapped): request = unwrapped
        case .refused(let reply, let code, let reason):
            if let reply { send(NodeWire.line(reply), on: connection) }
            return bye(reason, code: code, connection, hard: true)
        }
        if NodeWire.kinds[request.kind] == .leadToolServer { connection.toolServer = true }
        if request.kind == "subscribe" { connection.subscribed = true }
        guard NodeWire.taken.contains(request.kind) else {
            let (reply, end) = NodeWire.unknownKind(request)
            send(NodeWire.line(reply), on: connection)
            if let end { bye(end.reason, code: end.code, connection) }
            return
        }
        if LiveHub.kinds.contains(request.kind) {
            guard let hub else {
                return send(NodeWire.line(NodeWire.Reply(re: request.id, error: .init(.unknownKind, "this server has no live hub"))), on: connection)
            }
            _ = hub.handle(request, on: connection.transport(of: self), rights: .read)
            return
        }
        // A kind any process may ask takes what was read of its sender at the accept (the same process: every read's
        // sender is checked against it); every other kind judges the sender as it is now.
        let atAccept = NodeWire.kinds[request.kind] == .anyone ? connection.facts : nil
        let facts = atAccept ?? PeerFacts.read(pid: sender.pid, token: sender, cgroupRoot: cgroupRoot, runnersAbove: runnersAbove)
        // `Requests` answers on `queue`.
        requests.handle(request, from: facts, token: sender) { [weak self, weak connection] reply in
            guard let self, let connection else { return }
            // Never a line over the limit: the reader would drop it and close (`replyLine`).
            let line = NodeWire.replyLine(reply)
            guard line.count - 1 <= NodeWire.maxLine else { return self.bye("a reply over \(NodeWire.maxLine) bytes", code: "too-long", connection) }
            self.send(line, on: connection)
        }
    }

    /// The connections open now (tests).
    public var connectionCount: Int { queue.sync { connections.count } }

    // MARK: Writing

    /// The last line, then the close: once what waits is written, within `closingLife` at most. `hard` (an eviction, a
    /// protocol error): closed at once after the bye's one write, whatever else waited dropped, so a peer can't keep a
    /// connection, its descriptor and its output by not reading.
    private func bye(_ reason: String, code: String, _ connection: Connection, hard: Bool = false) {
        guard !connection.closing else { return }
        send(NodeWire.line(NodeWire.Bye(reason: reason, code: code)), on: connection)
        connection.closing = true
        connection.waiting = []
        resumeReading(connection)
        connection.reading?.cancel()
        connection.reading = nil
        if hard || connection.pending.isEmpty { return close(connection) }
        queue.asyncAfter(deadline: .now() + Self.closingLife) { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.close(connection)
        }
    }

    private func send(_ data: Data, on connection: Connection) {
        guard !connection.closed else { return }
        guard connection.pending.count + data.count <= Self.maxPending else {
            note("closed the connection of pid \(connection.token.pid): \(connection.pending.count + data.count) bytes waited to be written to it, past \(Self.maxPending)")
            return close(connection)
        }
        connection.pending.append(data)
        flush(connection)
    }

    private func flush(_ connection: Connection) {
        while !connection.pending.isEmpty {
            let written = connection.pending.withUnsafeBytes { Platform.Sockets.send(connection.fd, $0.baseAddress, $0.count) }
            if written > 0 {
                connection.pending.removeFirst(written)
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN {
                if connection.writing == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
                    source.setEventHandler { [weak self, weak connection] in
                        guard let self, let connection else { return }
                        self.flush(connection)
                    }
                    source.setCancelHandler { connection.sourceEnded() }
                    connection.sources += 1
                    connection.writing = source
                    source.resume()
                }
                return
            }
            return close(connection)
        }
        connection.writing?.cancel()
        connection.writing = nil
        if connection.closing { return close(connection) }
        connection.lineTransport?.drained()
    }

    /// The connection closed: its sources cancelled, and its socket closed once the last of them has ended (a
    /// descriptor closed under a live source could be another's by the time the source lets it go).
    private func close(_ connection: Connection) {
        guard !connection.closed else { return }
        connection.closed = true
        connection.closing = true
        connection.pending = Data()
        connection.waiting = []
        // A suspended source cancelled ends only once resumed: its descriptor would never be closed.
        resumeReading(connection)
        connection.reading?.cancel()
        connection.writing?.cancel()
        connection.reading = nil
        connection.writing = nil
        connection.closeWhenUnwatched()
        connections[ObjectIdentifier(connection)] = nil
        if let transport = connection.lineTransport { hub?.closed(transport) }
    }

    /// The hub's events and replies on `connection`'s lines, and how many bytes wait there. On `queue`.
    fileprivate func sendMessage(_ message: Data, on connection: Connection) {
        // A live message past the line's limit would be dropped by the reader: a bye saying so instead.
        guard message.count <= NodeWire.maxLine else { return bye("a live message of \(message.count) bytes, past the line's limit of \(NodeWire.maxLine)", code: "too-long", connection) }
        send(message + Data([UInt8(ascii: "\n")]), on: connection)
    }

    fileprivate func byeFromHub(code: String, reason: String, on connection: Connection) { bye(reason, code: code, connection) }

    /// One client: its socket, the process accepted (`SO_PEERCRED`), what it sent so far and what waits to go out.
    final class Connection {
        let fd: Int32
        let token: Platform.PeerToken
        var lines = NodeWire.Lines()
        var pending = Data()
        /// Lines read and not yet taken (past a turn's share), each with the process that sent it.
        var waiting: [(Data, Platform.PeerToken)] = []
        /// The lines taken in this turn; whether its reads are stopped (its source suspended); whether a later turn
        /// is asked for.
        var taken = 0
        var readStopped = false
        var turnAsked = false
        /// What was read of the process at its accept (for the hello and its `anyone` requests).
        var facts: PeerFacts?
        /// Whether its process may be the user's voice, at its accept (`Requests.mayBeUsersVoice`); its share
        /// (`Requests.share`); whether a lead's tool server posts on it, or it subscribed to a live stream (either: never
        /// closed to make room).
        var voice = false
        var share = ""
        var toolServer = false
        var subscribed = false
        /// Whether it sent a request since its hello, and since when it has been idle (the awake clock).
        var requested = false
        var idleSince: TimeInterval = 0
        /// No more is read: what is pending goes, then the close.
        var closing = false
        var closed = false
        var reading: DispatchSourceRead?
        var writing: DispatchSourceWrite?
        /// The sources on `fd` not yet ended (their cancel handlers, on the queue, count them down).
        var sources = 0
        private var descriptorClosed = false
        /// The connection as the hub's transport, made on its first `subscribe`.
        fileprivate var lineTransport: LineTransport?

        fileprivate func transport(of server: NodeServer) -> LineTransport {
            if let made = lineTransport { return made }
            let made = LineTransport(server: server, connection: self)
            lineTransport = made
            return made
        }

        init(fd: Int32, token: Platform.PeerToken) {
            self.fd = fd
            self.token = token
        }

        func sourceEnded() {
            sources -= 1
            closeWhenUnwatched()
        }

        func closeWhenUnwatched() {
            guard closed, sources == 0, !descriptorClosed else { return }
            descriptorClosed = true
            Sys.close(fd)
        }
    }
}

/// A Unix socket's connection as the hub writes to it (LW-D8): each message a line, after the replies before it. It
/// stops being `writable` from `busyBytes` waiting to be written, and `onWritable` follows once they all are. On the
/// server's queue, as the hub is.
fileprivate final class LineTransport: LiveTransport, @unchecked Sendable {
    /// The bytes waiting from which the hub holds a connection's events (and folds them) until it drains.
    static let busyBytes = 1 << 20

    private weak var server: NodeServer?
    private weak var connection: NodeServer.Connection?
    private var owed = false
    var onWritable: (() -> Void)?

    init(server: NodeServer, connection: NodeServer.Connection) {
        self.server = server
        self.connection = connection
    }

    func send(_ message: Data) {
        guard let server, let connection else { return }
        server.sendMessage(message, on: connection)
    }

    var writable: Bool {
        guard let connection, !connection.closed else { return false }
        guard connection.pending.count >= Self.busyBytes else { return true }
        owed = true
        return false
    }

    /// Everything waiting was written.
    func drained() {
        guard owed else { return }
        owed = false
        onWritable?()
    }

    func close(code: String, reason: String) {
        guard let server, let connection else { return }
        server.byeFromHub(code: code, reason: reason, on: connection)
    }
}
