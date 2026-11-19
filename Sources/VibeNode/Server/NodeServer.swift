import Foundation
import VibeCore

/// The server's socket (the engine plan's EN-D3, the security architecture document's S2 and S3):
/// `<root>/v2/server.sock`, the file 0600 in its folder 0700. Credentials are passed on the listener before the first
/// accept, so every connection's bytes come with their sender; a peer of another uid is closed at accept; each read
/// goes through `Platform.Sockets.receive`, and bytes from any process other than the one accepted (S5's rule on this
/// socket) get no reply: `bye`, the close and a log line. A line that isn't a JSON object, or is over 1 MiB, gets
/// `bye` and the close.
///
/// The socket keeps its path as the host keeps its own: the folder is watched, and at each housekeeping (30 s, or a
/// scratch host's `--test-housekeeping`) the path is checked against the file the listener is bound to
/// (`Platform.Sockets.boundFile(of:at:)`, or the file's device and inode recorded at the bind where the kernel can't
/// say); on a mismatch a fresh listener is bound at the path, with a log line, the folder made again first (0700) when
/// it was removed or renamed, and watched again when it is another folder than the one watched. Each housekeeping asks the host's notes
/// too (`Requests.refreshNotes`), until E7's refresh does. On the engine's queue (`requests.queue`).
public final class NodeServer: @unchecked Sendable {
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
        while true {
            let fd = Platform.Sockets.accept(listener)
            guard fd >= 0 else { return }
            let uid = Platform.Sockets.peerUID(fd)
            guard Self.admits(peerUID: uid, ownUID: getuid()), let token = Platform.Sockets.peerToken(fd) else {
                note("refused a connection from uid \(uid.map(String.init) ?? "unknown")")
                Sys.close(fd)
                continue
            }
            UnixSocket.configure(fd)
            let connection = Connection(fd: fd, token: token)
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
            let facts = PeerFacts.read(pid: token.pid, token: token, cgroupRoot: cgroupRoot, runnersAbove: runnersAbove)
            send(NodeWire.line(requests.hello(peer: facts)), on: connection)
        }
    }

    private func readable(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !connection.closing {
            let (count, sender) = chunk.withUnsafeMutableBytes { Platform.Sockets.receive(connection.fd, into: $0) }
            if count == 0 { return close(connection) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { return }
                return close(connection)
            }
            guard let sender, sender.sameImage(as: connection.token) else {
                note("refused the connection of pid \(connection.token.pid): bytes on it came from another process (pid \(sender.map { String($0.pid) } ?? "unknown"))")
                return bye("a request came from another process than the one that connected", connection)
            }
            for line in connection.lines.append(Data(chunk[0..<count])) {
                take(line, from: sender, on: connection)
                if connection.closing { return }
            }
            if connection.lines.tooLong { return bye("a line over \(NodeWire.maxLine) bytes", connection) }
        }
    }

    private func take(_ line: Data, from sender: Platform.PeerToken, on connection: Connection) {
        guard NodeWire.isObject(line) else { return bye("not a JSON object", connection) }
        guard let request = NodeWire.decode(NodeWire.Request.self, line) else {
            return bye("not a request (v, id and kind are needed)", connection)
        }
        guard request.v <= NodeWire.version else {
            send(NodeWire.line(NodeWire.Reply(re: request.id, error: .init(.version, "this server speaks version \(NodeWire.version)"))), on: connection)
            return bye("a newer version than this server's", connection)
        }
        guard NodeWire.taken.contains(request.kind) else {
            send(NodeWire.line(NodeWire.Reply(re: request.id, error: .init(.unknownKind, "this server doesn't take \(request.kind)"))), on: connection)
            if request.must == true { bye("a request this server must understand and doesn't (\(request.kind))", connection) }
            return
        }
        if request.kind == "subscribe" || request.kind == "unsubscribe" || request.kind == "chat.page" {
            guard let hub else {
                return send(NodeWire.line(NodeWire.Reply(re: request.id, error: .init(.unknownKind, "this server has no live hub"))), on: connection)
            }
            _ = hub.handle(request, on: connection.transport(of: self), rights: .read)
            return
        }
        let facts = PeerFacts.read(pid: sender.pid, token: sender, cgroupRoot: cgroupRoot, runnersAbove: runnersAbove)
        // `Requests` answers on `queue`.
        requests.handle(request, from: facts) { [weak self, weak connection] reply in
            guard let self, let connection else { return }
            self.send(NodeWire.line(reply), on: connection)
        }
    }

    /// The connections open now (tests).
    public var connectionCount: Int { queue.sync { connections.count } }

    // MARK: Writing

    private func bye(_ reason: String, code: String? = nil, _ connection: Connection) {
        guard !connection.closing else { return }
        send(NodeWire.line(NodeWire.Bye(reason: reason, code: code)), on: connection)
        connection.closing = true
        connection.reading?.cancel()
        connection.reading = nil
        if connection.pending.isEmpty { close(connection) }
    }

    private func send(_ data: Data, on connection: Connection) {
        guard !connection.closed else { return }
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
        send(message + Data([UInt8(ascii: "\n")]), on: connection)
    }

    fileprivate func byeFromHub(code: String, reason: String, on connection: Connection) { bye(reason, code: code, connection) }

    /// One client: its socket, the process accepted (`SO_PEERCRED`), what it sent so far and what waits to go out.
    final class Connection {
        let fd: Int32
        let token: Platform.PeerToken
        var lines = NodeWire.Lines()
        var pending = Data()
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
