import Foundation
import VibeCore

extension HostHandover {
    /// A web listening socket the host holds (H1, `HostWebListeners`), as a handover carries it: the new image holds it
    /// on, so the port is never free between two images.
    public struct WebListenerRecord: Codable, Equatable {
        /// `HostWebListen.Place`'s raw value.
        public var place: String
        public var address: String
        public var port: UInt16
        public var fd: Int32

        public init(place: String, address: String, port: UInt16, fd: Int32) {
            self.place = place
            self.address = address
            self.port = port
            self.fd = fd
        }
    }
}

/// The node's web listening sockets, held by the host for its whole life (H1, docs/process/v2-h1-plan.md; the
/// security architecture's S11 item 32): bound when its server child asks (`web listen`, over the child's connector,
/// which only the child can use: `AppConnector`), a duplicate handed to the child, and closed when the child says the
/// web went off (`web release`). The child's restarts and the host's handovers leave them held, so no other process of
/// the user can bind the port meanwhile. One socket at most for each place (`HostWebListen.Place`): a `listen` for
/// the address and port held gets that socket again (port 0 on a scratch host takes what is held); another address
/// (the tailnet's changed) closes the old one first and binds the new.
///
/// What the host checks itself (`HostWebListen.refusal`): loopback is 127.0.0.1, the tailnet an address in
/// 100.64.0.0/10, and on the user's host the port is the node's one. Each socket is close-on-exec here (`Platform.TCP.
/// listen`; a handover's `keep:` carries it, and the new image marks it again), so no session inherits it.
public final class HostWebListeners {
    struct Refusal: Error, Equatable {
        let why: String
        init(_ why: String) { self.why = why }
    }

    private struct Held {
        var address: String
        var port: UInt16
        var fd: Int32
    }

    private let lock = NSLock()
    private var held: [HostWebListen.Place: Held] = [:]
    private var closed = false
    /// The user's host: the port is `HostWebListen.port` alone.
    private var users: Bool
    private var noting: (String) -> Void

    init(usersHost: Bool, note: @escaping (String) -> Void) {
        users = usersHost
        noting = note
    }

    var usersHost: Bool { lock.withLock { users } }
    private func note(_ line: String) { lock.withLock { noting }(line) }

    /// Whose host this is, and its log: set once by `ServerChild.adopt` before any child asks.
    func configure(usersHost: Bool, note: @escaping (String) -> Void) {
        lock.withLock {
            users = usersHost
            noting = note
        }
    }

    /// The socket for `place` at `address`:`port`, bound now or held already: the host's own descriptor, which the
    /// caller sends (`SCM_RIGHTS` duplicates it) and never closes. Or why not. On the host's queue, as `release` is,
    /// so the descriptor stays open until it is sent.
    func listen(_ place: HostWebListen.Place, address: String, port: UInt16) -> Result<Int32, Refusal> {
        if let why = HostWebListen.refusal(place, address: address, port: port, usersHost: usersHost) { return .failure(Refusal(why)) }
        var said: [String] = []
        let result = lock.withLock { () -> Result<Int32, Refusal> in
            guard !closed else { return .failure(Refusal("the host is stopping")) }
            // A plugin's page is one request's origin: never a held socket again (a second page on the first's port would
            // share its origin). The new one is bound before the held one closes, so its port is another.
            var replaced: Held?
            if let kept = held[place] {
                if place != .page, kept.address == address, port == 0 || kept.port == port { return .success(kept.fd) }
                if place == .page { replaced = kept } else { Sys.close(kept.fd) }
                held[place] = nil
                said.append("web listener \(place.rawValue) \(kept.address):\(kept.port) closed: \(address):\(port) asked for instead")
            }
            defer { if let replaced { Sys.close(replaced.fd) } }
            switch Platform.TCP.listen(family: .ipv4, address: address, port: port, backlog: Self.backlog) {
            case .failure(let failure):
                return .failure(Refusal("\(address):\(port) couldn't be bound: \(failure)"))
            case .success(let fd):
                guard let bound = Platform.TCP.localPort(fd) else {
                    Sys.close(fd)
                    return .failure(Refusal("\(address):\(port) bound, but its port can't be read"))
                }
                held[place] = Held(address: address, port: bound, fd: fd)
                said.append("web listener \(place.rawValue) bound on \(address):\(bound), held for the server")
                return .success(fd)
            }
        }
        said.forEach(note)
        return result
    }

    /// The backlog of each socket: connections that arrive while no server accepts wait there.
    static let backlog: Int32 = 64

    /// What `place` holds closed (the web went off): its port free. Nothing when nothing is held.
    func release(_ place: HostWebListen.Place) {
        let kept = lock.withLock { held.removeValue(forKey: place) }
        guard let kept else { return }
        Sys.close(kept.fd)
        note("web listener \(place.rawValue) \(kept.address):\(kept.port) closed: the web went off")
    }

    /// The port held for `place` (tests, status).
    func port(_ place: HostWebListen.Place) -> UInt16? { lock.withLock { held[place]?.port } }

    /// What a handover carries.
    var records: [HostHandover.WebListenerRecord] {
        lock.withLock {
            held.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { HostHandover.WebListenerRecord(place: $0.key.rawValue, address: $0.value.address, port: $0.value.port, fd: $0.value.fd) }
        }
    }

    /// The sockets a handover carried, held again: each one this image inherited (open, not close-on-exec, none of
    /// `others`), listening on the address and port its record says, for a place and address the host would bind
    /// (`HostWebListen.refusal`), made close-on-exec. Any other is closed when inherited, and said.
    func adopt(_ records: [HostHandover.WebListenerRecord], others: Set<Int32>) {
        for record in records {
            let why = Self.refusal(record, others: others, usersHost: usersHost)
            if let why {
                if Self.isInherited(record.fd), !others.contains(record.fd) { Sys.close(record.fd) }
                note("web listener \(record.place) \(record.address):\(record.port) a handover carried not held again: \(why)")
                continue
            }
            guard let place = HostWebListen.Place(rawValue: record.place) else { continue }
            _ = fcntl(record.fd, F_SETFD, FD_CLOEXEC)
            lock.withLock {
                if let kept = held[place] { Sys.close(kept.fd) }
                held[place] = Held(address: record.address, port: record.port, fd: record.fd)
            }
            note("web listener \(record.place) \(record.address):\(record.port) held on across the handover")
        }
    }

    /// Why `record` isn't a socket to hold again, or nil.
    static func refusal(_ record: HostHandover.WebListenerRecord, others: Set<Int32>, usersHost: Bool) -> String? {
        guard let place = HostWebListen.Place(rawValue: record.place) else { return "no place \(record.place)" }
        if let why = HostWebListen.refusal(place, address: record.address, port: record.port, usersHost: usersHost) { return why }
        guard isInherited(record.fd), !others.contains(record.fd) else { return "descriptor \(record.fd) isn't one handed over" }
        guard Platform.TCP.isListening(record.fd), Platform.TCP.localPort(record.fd) == record.port,
              Platform.TCP.localAddress(record.fd) == record.address else {
            return "descriptor \(record.fd) doesn't listen on \(record.address):\(record.port)"
        }
        return nil
    }

    /// Whether `fd` is open, above 2, and not close-on-exec: inherited across the exec.
    static func isInherited(_ fd: Int32) -> Bool {
        guard fd > STDERR_FILENO else { return false }
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC == 0
    }

    /// Every socket closed, and none bound again (the host stops).
    func closeAll() {
        lock.withLock {
            closed = true
            for kept in held.values { Sys.close(kept.fd) }
            held = [:]
        }
    }

    /// Closes the descriptors `records` names that this image inherited and nothing else of `others` names: a
    /// handover's listeners no server child took (this image was started without `--server`).
    static func drop(_ records: [HostHandover.WebListenerRecord], others: Set<Int32>) {
        for record in records where isInherited(record.fd) && !others.contains(record.fd) { Sys.close(record.fd) }
    }
}
