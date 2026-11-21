import Foundation
import VibeCore

/// The host's end of an app connector (the stage 2 plan's S2-D1, the security architecture document's S2): on Linux
/// the app is the connections the host makes for its server child, which inherits the connector's other end. The
/// child asks for a connection by sending one byte; the host answers only a byte whose sender is the process it
/// expects (`sender`, the child's token) and, where asked, only while that process is non-dumpable. It then makes a
/// stream pair, keeps one end as a client that is the app from its first byte, and hands the other back over the
/// connector (`SCM_RIGHTS`). The client's half is `HostConnector` (VibeCore).
///
/// The bytes on such a connection are checked for their sender as an accepted connection's are (Task 7,
/// `checkSender` in SenderCheck.swift): the host's end has its senders passed from its creation, and a message from
/// any process but the one it was made for makes it no one's. (`checkPeer`'s `SO_PEERCRED` re-read would name the host
/// itself on a pair it made, and skips it.)
///
/// The Mac (the node on the Mac's step 3): the Mac app has no connector (it proves itself by its code, `AppProof`), but
/// the node's server child has one, a stream pair (`Platform.Sockets.connectorType`). A child's token can't be read at
/// its spawn there (`Platform.Processes.token` is nil), so its connector is told the child's pid and the cdhash its
/// server file had when the host loaded it (`setAppConnectorChild`): a request is answered only from that pid, as it
/// runs that code (`Platform.CodeIdentity.runs(_:cdhash:)`, Security's dynamic check, which also refuses a pid that
/// exec'd since), and its token, the first such request's, is then the connector's sender, as on Linux. Non-dumpable is
/// the Hardened Runtime there (`Platform.CodeIdentity.isHardened`). `adoptAppConnector` (a handover's, a test's stand-in)
/// stays Linux's.
final class AppConnector {
    /// The host's end, nonblocking, close-on-exec, with its senders passed (`enableCredentials`).
    let fd: Int32
    /// The process whose requests are answered; nil until it is set: every request is refused (on the Mac, until a
    /// request from `child` running `code`, whose token it then is).
    var sender: Platform.PeerToken?
    /// The Mac's form (`setAppConnectorChild`): the child's pid and the cdhash its code must have. Nil on Linux.
    var child: (pid: pid_t, code: Data)?
    let requireNonDumpable: Bool
    let onDumpable: ((pid_t) -> Void)?
    /// A scratch host's test stand-in (see `TestAppPrincipal`): the test process's pid, which a handover carries with
    /// the descriptor. Nil for every other connector.
    var testPid: pid_t?
    /// Called with its number when it closes by itself (its read failed, or its other end was closed or shut for
    /// writing), never when its holder closes it (`closeAppConnector`); on the host's queue. Task 8a's server child
    /// ends its child then (`ServerChild.connectorClosed`).
    var onClosed: ((Int32) -> Void)?
    private var source: DispatchSourceRead?
    /// The connections made through it, ended with it.
    private var made: [Made] = []
    private struct Made { weak var client: ClientConnection? }
    /// How many connections were made through it since it was opened or adopted, closed ones too.
    private(set) var madeCount = 0
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
        madeCount += 1
    }

    /// How many connections made through it are open now.
    var openConnections: Int { made.compactMap(\.client).filter { !$0.closed }.count }

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
    /// Opens an app connector (see `AppConnector`): a pair of `Platform.Sockets.connectorType` (`SOCK_SEQPACKET` on
    /// Linux, a stream on the Mac), whose end the host keeps and reads on its queue, and whose other end it returns, close-on-exec here, for its caller to hand a child with `keep:` and then
    /// close in this process. That number names the connector to `setAppConnectorSender` and `closeAppConnector`.
    /// `sender`: the process whose requests are answered (nil: none yet; set it once the child is started).
    /// `requireNonDumpable`: a request is answered only while its sender is non-dumpable
    /// (`Platform.Processes.isDumpable` false), else refused, logged, and `onDumpable` called with its pid on the
    /// host's queue (Task 8a ends the child there); on the Mac, while it runs under the Hardened Runtime
    /// (`Platform.CodeIdentity.isHardened`). `onClosed`: called with the number on the host's queue when the
    /// connector closes by itself (see `AppConnector.onClosed`). Nil on the Mac, where the app proves itself by its code
    /// (its server child's connector is `openServerChildConnector`'s), when the pair can't be made, and once the host
    /// has stopped (nothing registered after `closeAppConnectors`).
    public func openAppConnector(expecting sender: Platform.PeerToken?, requireNonDumpable: Bool, onDumpable: ((pid_t) -> Void)?,
                                 onClosed: ((Int32) -> Void)? = nil) -> Int32? {
        guard !Platform.CodeIdentity.isAvailable else { return nil }
        return makeAppConnector(expecting: sender, requireNonDumpable: requireNonDumpable, onDumpable: onDumpable, onClosed: onClosed)
    }

    /// The Mac's server child's connector (the node on the Mac's step 3): `openAppConnector`'s, on the Mac too, its
    /// requests answered once `setAppConnectorChild` (the Mac) or `setAppConnectorSender` (Linux) names its child.
    /// Never the Mac app's, nor a test's stand-in for it there.
    public func openServerChildConnector(requireNonDumpable: Bool, onDumpable: ((pid_t) -> Void)?, onClosed: ((Int32) -> Void)? = nil) -> Int32? {
        makeAppConnector(expecting: nil, requireNonDumpable: requireNonDumpable, onDumpable: onDumpable, onClosed: onClosed)
    }

    private func makeAppConnector(expecting sender: Platform.PeerToken?, requireNonDumpable: Bool, onDumpable: ((pid_t) -> Void)?,
                                  onClosed: ((Int32) -> Void)?) -> Int32? {
        guard let (mine, theirs) = Platform.Sockets.pair(type: Platform.Sockets.connectorType) else { return nil }
        Platform.Sockets.enableCredentials(mine)
        _ = fcntl(mine, F_SETFL, fcntl(mine, F_GETFL) | O_NONBLOCK)
        let connector = AppConnector(fd: mine, sender: sender, requireNonDumpable: requireNonDumpable, onDumpable: onDumpable)
        connector.onClosed = onClosed
        var registered = false
        onQueue {
            guard !stopped else { return }
            registered = true
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
        guard registered else {
            Sys.close(mine)
            Sys.close(theirs)
            return nil
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
        adoptAppConnector(fd, sender: Platform.Processes.token(pid), requireNonDumpable: false, onDumpable: nil, testPid: pid)
    }

    /// Takes `fd`, the host's end of an app connector this process inherited across a handover, as `openAppConnector`'s
    /// own end: answered for `sender` alone, refused while it is dumpable where `requireNonDumpable` (`onDumpable` then
    /// called), registered under `fd` itself, which `setAppConnectorSender` and `closeAppConnector` then name, and
    /// `onClosed` called with it when it closes by itself. Made close-on-exec and nonblocking, its senders passed.
    /// False, and `fd` left alone, on the Mac (no connector there), when `fd` isn't open, and once the host has stopped.
    func adoptAppConnector(_ fd: Int32, sender: Platform.PeerToken?, requireNonDumpable: Bool, onDumpable: ((pid_t) -> Void)?,
                           onClosed: ((Int32) -> Void)? = nil, testPid: pid_t? = nil) -> Bool {
        guard !Platform.CodeIdentity.isAvailable else { return false }
        var stopped = false
        onQueue { stopped = self.stopped }
        guard !stopped, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { return false }
        Platform.Sockets.enableCredentials(fd)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let connector = AppConnector(fd: fd, sender: sender, requireNonDumpable: requireNonDumpable, onDumpable: onDumpable)
        connector.testPid = testPid
        connector.onClosed = onClosed
        var registered = false
        onQueue {
            // Asked again in this turn: a stop from another thread may have come in between.
            guard !self.stopped else { return }
            registered = true
            appConnectors.removeValue(forKey: fd)?.close()
            appConnectors[fd] = connector
            connector.start(on: queue) { [weak self, weak connector] in
                guard let self, let connector else { return }
                self.answer(connector, fd)
            }
        }
        return registered
    }

    /// The host's end of the connector `number` names (the number `openAppConnector` gave out), for a handover's
    /// state; nil when there is none, or it has closed. On `queue`.
    func appConnectorEnd(_ number: Int32) -> Int32? {
        appConnectors[number].flatMap { $0.closed ? nil : $0.fd }
    }

    /// How many connections made through the connector `number` names are open now: none while its child has no
    /// request in flight (a request is one connection, `HostCall`). On `queue`.
    func appConnectionsOpen(through number: Int32) -> Int {
        appConnectors[number]?.openConnections ?? 0
    }

    /// How many connections were made through the connector `number` names since this image opened or adopted it,
    /// closed ones too: a child carried across a handover has made none until it connects again. On `queue`.
    func appConnectionsMade(through number: Int32) -> Int {
        appConnectors[number]?.madeCount ?? 0
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

    /// The Mac's form of `setAppConnectorSender` (see `AppConnector`): requests on `connector` are answered from now on
    /// only from `pid`, as it runs the code whose cdhash is `code`; the first such request's token is the connector's
    /// sender from then on.
    public func setAppConnectorChild(_ pid: pid_t, code: Data, for connector: Int32) {
        onQueue {
            appConnectors[connector]?.child = (pid, code)
            appConnectors[connector]?.sender = nil
        }
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
        // A connection's request is one byte; a web request (H1, `HostWebListen`) a few words, one message on Linux's
        // `SOCK_SEQPACKET` connector. The Mac's is a stream, where messages have no edges: one byte a request there, as
        // before, and no web request (the Mac node's H1 is its own step).
        var message = [UInt8](repeating: 0, count: Platform.Sockets.connectorType == Platform.Sockets.seqpacket ? 256 : 1)
        let (count, from) = message.withUnsafeMutableBytes { Platform.Sockets.receive(connector.fd, into: $0) }
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
        if let child = connector.child, connector.sender == nil {
            // The Mac's first request: from the child, running the code the host loaded; its token then the sender's.
            guard let from, from.pid == child.pid else {
                return refuse(connector, number, "a request from \(from.map { "pid \($0.pid)" } ?? "a sender gone or unnamed"), not pid \(child.pid)")
            }
            guard Platform.CodeIdentity.runs(from, cdhash: child.code) else {
                return refuse(connector, number, "pid \(from.pid) doesn't run the server's code (its cdhash as the host loaded it)")
            }
            connector.sender = from
        }
        guard let expected = connector.sender else { return refuse(connector, number, "a request before its process was named") }
        guard let from, from.sameImage(as: expected) else {
            return refuse(connector, number, "a request from \(from.map { "pid \($0.pid)" } ?? "a sender gone or unnamed"), not pid \(expected.pid)")
        }
        if connector.requireNonDumpable, Self.isNonDumpable(from) != true {
            refuse(connector, number, Platform.CodeIdentity.isAvailable
                   ? "pid \(from.pid) doesn't run under the Hardened Runtime, or can be debugged (or can't be told): any process of the user could take its connections"
                   : "pid \(from.pid) is dumpable (or can't be told): any process of the user could take its connections")
            connector.onDumpable?(from.pid)
            return
        }
        let request = Array(message.prefix(count))
        if HostWebListen.isWeb(request) { return answerWeb(request, connector, number, from: expected) }
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

    /// A web request from the server child (H1, `HostWebListen`), its sender checked as a connection's is: the web's
    /// listening socket bound or held for it (`ServerChild.webListeners`) and a duplicate sent with `web ok`, or the
    /// socket let go, or `web no: WHY`. Only the server child's connector holds web listeners: a test's stand-in for the
    /// app, or any connector with no server child, is refused.
    private func answerWeb(_ request: [UInt8], _ connector: AppConnector, _ number: Int32, from: Platform.PeerToken) {
        let reply = { (refusal: String?, fd: Int32?) in
            let bytes = HostWebListen.answer(refusal: refusal)
            if Platform.Sockets.send(bytes, with: fd.map { [$0] } ?? [], over: connector.fd) != bytes.count {
                self.note("host: a web answer through connector \(number) couldn't be sent (errno \(errno))")
            }
        }
        guard let parsed = HostWebListen.parse(request) else { return reply("not a web request", nil) }
        guard let child = serverChild, child.token.map({ from.sameImage(as: $0) }) == true else {
            note("host: refused a web request through connector \(number): not the server child's")
            return reply("only the server child holds the web's listeners", nil)
        }
        switch parsed {
        case .listen(let place, let address, let port):
            switch child.webListeners.listen(place, address: address, port: port) {
            case .success(let fd): reply(nil, fd)
            case .failure(let refusal):
                note("host: refused the web listener \(place.rawValue) \(address):\(port): \(refusal.why)")
                reply(refusal.why, nil)
            }
        case .release(let place):
            child.webListeners.release(place)
            reply(nil, nil)
        }
    }

    /// Whether the process `token` names is out of reach of the user's other processes: on Linux non-dumpable
    /// (`Platform.Processes.isDumpable` false), on the Mac under the Hardened Runtime and not debuggable
    /// (`Platform.CodeIdentity.isHardened`). nil when it can't be told.
    static func isNonDumpable(_ token: Platform.PeerToken) -> Bool? {
        Platform.CodeIdentity.isAvailable ? Platform.CodeIdentity.isHardened(token) : Platform.Processes.isDumpable(token.pid).map { !$0 }
    }

    private func refuse(_ connector: AppConnector, _ number: Int32, _ why: String) {
        tally.refusedAppConnection()
        let line = "refused an app connection through connector \(number): \(why)"
        note("host: " + line)
        FileHandle.standardError.write(Data("vibeswitcher-host: \(line)\n".utf8))
    }

    private func closeConnector(_ connector: AppConnector, _ number: Int32, why: String) {
        note("host: app connector \(number) closed: \(why); its connections ended")
        let registered = appConnectors[number] === connector
        if registered { appConnectors[number] = nil }
        connector.close()
        if registered { connector.onClosed?(number) }
    }

    /// `body` on `queue`: at once when called there, else waited for.
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { body() } else { queue.sync(execute: body) }
    }
}
