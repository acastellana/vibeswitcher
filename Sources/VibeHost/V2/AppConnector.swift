import Foundation
import VibeCore

/// The host's end of an app connector (the stage 2 plan's S2-D1, the security architecture document's S2): on Linux
/// the app is the connections the host makes for its server child, which inherits the connector's other end. The
/// child asks for a connection by sending one byte; the host answers only a byte whose sender is the process it
/// expects (`sender`, the child's token) and, where asked, only while that process is non-dumpable. It then makes a
/// stream pair, keeps one end as a client that is the app from its first byte, and hands the other back over the
/// connector (`SCM_RIGHTS`). The client's half is `HostConnector` (VibeCore).
///
/// Until Task 7 the bytes on such a connection aren't checked for their sender: `checkPeer`'s `SO_PEERCRED` re-read
/// names the host itself on a pair it made, and Task 7's check of each message replaces it. No user's host runs on
/// Linux before then (the document's Principals).
///
/// The Mac has no connector (its app proves itself by its code, `AppProof`): `openAppConnector` gives nil there.
final class AppConnector {
    /// The host's end, nonblocking, close-on-exec, with its senders passed (`enableCredentials`).
    let fd: Int32
    /// The process whose requests are answered; nil until it is set: every request is refused.
    var sender: Platform.PeerToken?
    let requireNonDumpable: Bool
    let onDumpable: ((pid_t) -> Void)?
    /// A scratch host's test stand-in (see `TestAppPrincipal`): the test process's pid, which a handover carries with
    /// the descriptor. Nil for every other connector.
    var testPid: pid_t?
    private var source: DispatchSourceRead?
    /// The connections made through it, ended with it.
    private var made: [Made] = []
    private struct Made { weak var client: ClientConnection? }
    private(set) var closed = false

    init(fd: Int32, sender: Platform.PeerToken?, requireNonDumpable: Bool, onDumpable: ((pid_t) -> Void)?) {
        self.fd = fd
        self.sender = sender
        self.requireNonDumpable = requireNonDumpable
        self.onDumpable = onDumpable
    }

    /// Reads its requests on `queue`, each handed to `request`.
    func start(on queue: DispatchQueue, request: @escaping () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler(handler: request)
        source.setCancelHandler { [fd] in Sys.close(fd) }
        self.source = source
        source.resume()
    }

    /// A connection made through it: ended when it closes.
    func made(_ client: ClientConnection) {
        made.removeAll { $0.client == nil }
        made.append(Made(client: client))
    }

    /// Its end closed, and every connection made through it ended: what came from its child is no one's now.
    func close() {
        guard !closed else { return }
        closed = true
        if let source {
            source.cancel()
        } else {
            Sys.close(fd)
        }
        source = nil
        let clients = made.compactMap(\.client)
        made = []
        clients.forEach { $0.close() }
    }

    /// Whether no request can come again: the other end closed by every process that held it, or shut for writing by
    /// one of them (which reports no hang-up, and reads as an empty message for good: the read source would fire on it
    /// without end). Without waiting.
    var peerHasGone: Bool { Platform.Sockets.peerHasGone(fd) }
}

extension HostServer {
    /// Opens an app connector (see `AppConnector`): a `SOCK_SEQPACKET` pair, whose end the host keeps and reads on its
    /// queue, and whose other end it returns, close-on-exec here, for its caller to hand a child with `keep:` and then
    /// close in this process. That number names the connector to `setAppConnectorSender` and `closeAppConnector`.
    /// `sender`: the process whose requests are answered (nil: none yet; set it once the child is started).
    /// `requireNonDumpable`: a request is answered only while its sender is non-dumpable
    /// (`Platform.Processes.isDumpable` false), else refused, logged, and `onDumpable` called with its pid on the
    /// host's queue (Task 8a ends the child there). Nil on the Mac, which has no connector, and when the pair can't
    /// be made.
    public func openAppConnector(expecting sender: Platform.PeerToken?, requireNonDumpable: Bool, onDumpable: ((pid_t) -> Void)?) -> Int32? {
        guard !Platform.CodeIdentity.isAvailable, let (mine, theirs) = Platform.Sockets.pair(type: Platform.Sockets.seqpacket) else { return nil }
        Platform.Sockets.enableCredentials(mine)
        _ = fcntl(mine, F_SETFL, fcntl(mine, F_GETFL) | O_NONBLOCK)
        let connector = AppConnector(fd: mine, sender: sender, requireNonDumpable: requireNonDumpable, onDumpable: onDumpable)
        onQueue {
            // A number given out again: the caller closed the one it held, so that connector's child had its end.
            if let stale = appConnectors.removeValue(forKey: theirs) {
                note("host: app connector \(theirs) replaced by a new one under its number")
                stale.close()
            }
            appConnectors[theirs] = connector
            connector.start(on: queue) { [weak self, weak connector] in
                guard let self, let connector else { return }
                self.answer(connector, theirs)
            }
        }
        return theirs
    }

    /// Takes `fd`, an end of a `SOCK_SEQPACKET` pair this process inherited, as an app connector whose other end is
    /// `pid`'s: a scratch host's test stand-in for the app on Linux (see `TestAppPrincipal`), never dumpable-checked
    /// (a test process is dumpable). Made close-on-exec and nonblocking, its senders passed, and read on the host's
    /// queue as `openAppConnector`'s end is; registered under its own number, which a handover carries
    /// (`testAppConnectorForHandover`). False, and `fd` left alone, on the Mac (no connector there) and when `fd`
    /// isn't open.
    func adoptTestAppConnector(_ fd: Int32, pid: pid_t) -> Bool {
        guard !Platform.CodeIdentity.isAvailable, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { return false }
        Platform.Sockets.enableCredentials(fd)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let connector = AppConnector(fd: fd, sender: Platform.Processes.token(pid), requireNonDumpable: false, onDumpable: nil)
        connector.testPid = pid
        onQueue {
            appConnectors.removeValue(forKey: fd)?.close()
            appConnectors[fd] = connector
            connector.start(on: queue) { [weak self, weak connector] in
                guard let self, let connector else { return }
                self.answer(connector, fd)
            }
        }
        return true
    }

    /// The test stand-in's connector, for a handover's state (see `HostHandover.State.testAppConnector`): nil when
    /// there is none, or it has closed. On `queue`.
    var testAppConnectorForHandover: HostHandover.TestAppConnector? {
        appConnectors.values.first { $0.testPid != nil && !$0.closed }.map { HostHandover.TestAppConnector(fd: $0.fd, pid: $0.testPid!) }
    }

    /// The process whose requests on `connector` are answered from now on (the child started with it).
    public func setAppConnectorSender(_ token: Platform.PeerToken?, for connector: Int32) {
        onQueue { appConnectors[connector]?.sender = token }
    }

    /// Closes `connector`'s end in the host and ends every connection made through it. The caller's own copy of the
    /// other end, if it still holds one, is its to close.
    public func closeAppConnector(_ connector: Int32) {
        onQueue { appConnectors.removeValue(forKey: connector)?.close() }
    }

    /// Every connector closed, as the host stops. On `queue`.
    func closeAppConnectors() {
        let connectors = appConnectors.values
        appConnectors = [:]
        connectors.forEach { $0.close() }
    }

    /// One request read from `connector` and answered: a connection for the app, or a refusal said in the log. On
    /// `queue`.
    private func answer(_ connector: AppConnector, _ number: Int32) {
        guard !connector.closed else { return }
        var byte: UInt8 = 0
        let (count, from) = withUnsafeMutableBytes(of: &byte) { Platform.Sockets.receive(connector.fd, into: $0) }
        if count < 0 {
            guard errno != EAGAIN, errno != EINTR else { return }
            return closeConnector(connector, number, why: "its read failed (errno \(errno))")
        }
        if count == 0 {
            // A message of no bytes reads as the end does: told apart by the socket being shut for reading, as it is
            // once the other end has closed or been shut for writing.
            guard connector.peerHasGone else { return refuse(connector, number, "an empty request") }
            return closeConnector(connector, number, why: "its other end has closed")
        }
        guard let expected = connector.sender else { return refuse(connector, number, "a request before its process was named") }
        guard let from, from.sameImage(as: expected) else {
            return refuse(connector, number, "a request from \(from.map { "pid \($0.pid)" } ?? "a sender gone or unnamed"), not pid \(expected.pid)")
        }
        if connector.requireNonDumpable, Platform.Processes.isDumpable(from.pid) != false {
            refuse(connector, number, "pid \(from.pid) is dumpable (or can't be told): any process of the user could take its connections")
            connector.onDumpable?(from.pid)
            return
        }
        guard let (mine, theirs) = Platform.Sockets.pair(type: Platform.Sockets.stream) else {
            return refuse(connector, number, "no socket pair (errno \(errno))")
        }
        UnixSocket.configure(mine)
        Platform.Sockets.enableCredentials(mine)
        guard let client = addAppClient(fd: mine, peer: expected) else {
            Sys.close(mine)
            Sys.close(theirs)
            return
        }
        defer { Sys.close(theirs) }
        guard Platform.Sockets.sendDescriptor(theirs, over: connector.fd) else {
            let code = errno
            client.close()
            return refuse(connector, number, "the connection couldn't be handed over (errno \(code))")
        }
        connector.made(client)
        note("host: app connection made through connector \(number) for pid \(expected.pid)")
    }

    private func refuse(_ connector: AppConnector, _ number: Int32, _ why: String) {
        let line = "refused an app connection through connector \(number): \(why)"
        note("host: " + line)
        FileHandle.standardError.write(Data("vibeswitcher-host: \(line)\n".utf8))
    }

    private func closeConnector(_ connector: AppConnector, _ number: Int32, why: String) {
        note("host: app connector \(number) closed: \(why); its connections ended")
        if appConnectors[number] === connector { appConnectors[number] = nil }
        connector.close()
    }

    /// `body` on `queue`: at once when called there, else waited for.
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { body() } else { queue.sync(execute: body) }
    }
}
