import Foundation
import VibeCore

/// The egress proxy as the host keeps it (the session sandbox plan's SB9): one child per node, started from the host's
/// own sealed copy (`vibeswitcher-host --egress-proxy --control N`), non-dumpable from its exec, and started again
/// after `restartAfter` whenever it ends, as the parsers are. The host holds every session's listener and rules here,
/// so a proxy started again is given them all again: a box's network comes back with it.
///
/// The control socket is a `SOCK_SEQPACKET` pair made at each start: each message whole, the listener riding on its
/// `add` (`EgressProxy.Control`). The child ends when its end closes, which is when this stops or the host goes.
public final class EgressChild: @unchecked Sendable {
    private let image: Platform.ProcessSelf.SealedCopy
    private let environment: [String]
    private let restartAfter: TimeInterval
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "egress.child")
    // On `queue`.
    private var listeners: [UUID: (fd: Int32, rules: EgressRules)] = [:]
    private var control: Int32 = -1
    private var child: pid_t?
    private var watch: (any Platform.Cancellable)?
    private var stopped = false
    private var starts = 0

    /// `image`: the host's sealed copy to start the proxy from (the caller keeps it open). `environment`: the proxy's.
    public init(image: Platform.ProcessSelf.SealedCopy, environment: [String] = [], restartAfter: TimeInterval = 1,
                log: @escaping @Sendable (String) -> Void) {
        self.image = image
        self.environment = environment.filter { !$0.hasPrefix(Platform.ProcessSelf.imageVariable + "=") }
        self.restartAfter = restartAfter
        self.log = log
    }

    /// The proxy's pid now; nil while none runs.
    public var pid: pid_t? { queue.sync { child } }
    /// How many times it was started.
    public var started: Int { queue.sync { starts } }

    public func start() { queue.async { self.spawn() } }

    /// `listener` (taken: this keeps it, and closes it when the session ends) served for `session` under `rules`.
    public func add(listener: Int32, session: UUID, rules: EgressRules) {
        _ = fcntl(listener, F_SETFD, fcntl(listener, F_GETFD) | FD_CLOEXEC)
        queue.async {
            if let old = self.listeners[session] { Sys.close(old.fd) }
            self.listeners[session] = (listener, rules)
            self.send(.add(session: session, rules: rules), listener: listener)
        }
    }

    /// The session's listener closed here and in the proxy.
    public func end(session: UUID) {
        queue.async {
            guard let old = self.listeners.removeValue(forKey: session) else { return }
            Sys.close(old.fd)
            self.send(.end(session: session), listener: nil)
        }
    }

    /// No more starts; the proxy ends (its control closed, then SIGKILL), and every listener here is closed.
    public func stop() {
        queue.sync {
            stopped = true
            watch?.cancel()
            if control >= 0 { Sys.close(control) }
            control = -1
            if let child {
                kill(child, SIGKILL)
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0, errno == EINTR {}
            }
            child = nil
            listeners.values.forEach { Sys.close($0.fd) }
            listeners = [:]
        }
    }

    deinit { stop() }

    /// On `queue`.
    private func send(_ message: EgressProxy.Control, listener: Int32?) {
        guard control >= 0, let bytes = try? JSONEncoder().encode(message) else { return }
        if Platform.Sockets.send(Array(bytes), with: listener.map { [$0] } ?? [], over: control) < 0 {
            log("egress proxy: a control message didn't go (errno \(errno)); it is given again at its next start")
        }
    }

    /// On `queue`: a fresh control pair, the child from the copy, every listener given again.
    private func spawn() {
        guard !stopped, child == nil else { return }
        guard Platform.ProcessSelf.restoreMode(of: image.fd) else {
            log("egress proxy not started: its sealed copy's mode couldn't be put back")
            return scheduleRestart()
        }
        guard let pair = Platform.Sockets.pair(type: Platform.Sockets.seqpacket) else {
            log("egress proxy not started: no control socket (errno \(errno))")
            return scheduleRestart()
        }
        var spawn = Platform.Spawn(executable: image.path,
                                   arguments: ["vibeswitcher-host", EgressProxy.flag, EgressProxy.controlFlag, String(pair.1)])
        spawn.environment = environment + ["\(Platform.ProcessSelf.imageVariable)=\(image.fd)"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.keep = [image.fd, pair.1]
        spawn.group = .ownGroup
        let result = spawn.start()
        Sys.close(pair.1)
        switch result {
        case .failure(let error):
            Sys.close(pair.0)
            log("egress proxy not started (errno \(error.code))")
            scheduleRestart()
        case .success(let pid):
            control = pair.0
            child = pid
            starts += 1
            watch = Platform.ProcessExit.watch(pid, queue: queue) { [weak self] in self?.ended(pid) }
            log("egress proxy pid \(pid) started from the host's sealed copy")
            for (session, held) in listeners { send(.add(session: session, rules: held.rules), listener: held.fd) }
        }
    }

    /// On `queue`: the child ended; collected, and started again unless stopped.
    private func ended(_ pid: pid_t) {
        guard child == pid else { return }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        child = nil
        watch = nil
        if control >= 0 { Sys.close(control) }
        control = -1
        guard !stopped else { return }
        log("egress proxy pid \(pid) ended (status \(status)); starting it again")
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + restartAfter) { [weak self] in self?.spawn() }
    }
}
