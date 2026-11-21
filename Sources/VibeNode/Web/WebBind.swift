import Foundation
import VibeCore

/// Where the node's web listening sockets come from (H1, docs/process/v2-h1-plan.md; the security architecture's S11
/// item 32). The server process takes them from the session host (`host`), which binds each when the web goes on, holds
/// it while it stays on (across the server's restarts and the host's handovers, so no other process of the user can
/// bind the port between two servers) and closes it when the server says the web went off. The server itself never
/// binds then: a refusal is the web's state (`NodeWebListener.State.refused`), never a socket of its own instead.
/// In-process tests, with no host, bind here (`direct`).
public struct WebBind: Sendable {
    /// The socket for a place at an address and port (0: the kernel's pick, a scratch host's), listening, this
    /// process's to close; or why not.
    public var listen: @Sendable (_ place: HostWebListen.Place, _ address: String, _ port: UInt16, _ backlog: Int32) -> Result<Int32, WebListener.Failure>
    /// The web at a place went off: whoever holds its socket lets it go.
    public var release: @Sendable (_ place: HostWebListen.Place) -> Void
    public init(listen: @escaping @Sendable (HostWebListen.Place, String, UInt16, Int32) -> Result<Int32, WebListener.Failure>,
                release: @escaping @Sendable (HostWebListen.Place) -> Void) {
        self.listen = listen
        self.release = release
    }

    /// Bound in this process, closed with its listener.
    public static let direct = WebBind(listen: { _, address, port, backlog in
        Platform.TCP.listen(family: .ipv4, address: address, port: port, backlog: backlog).mapError { .system($0) }
    }, release: { _ in })

    /// How long a question to the host waits: it answers on its one queue, and the server's queue waits meanwhile.
    public static let hostPatience: TimeInterval = 5

    /// The server process's: the host's (`host`) where its connector carries web requests (Linux's `SOCK_SEQPACKET`);
    /// on the Mac, whose connector is a stream, this process's (`direct`) until the Mac node's own H1 step, so its web
    /// comes up as before. `connectorType`: `Platform.Sockets.connectorType` (a test's other).
    public static func forServer(connector: Int32, connectorType: Int32 = Platform.Sockets.connectorType,
                                 note: @escaping @Sendable (String) -> Void) -> WebBind {
        connectorType == Platform.Sockets.seqpacket ? host(connector: connector, note: note) : direct
    }

    /// From the session host, over the server's `connector` (`HostConnector.web`). `note`: the server's log.
    public static func host(connector: Int32, note: @escaping @Sendable (String) -> Void) -> WebBind {
        WebBind(listen: { place, address, port, _ in
            do {
                switch try HostConnector.web(.listen(place, address: address, port: port), over: connector, timeout: hostPatience) {
                case .ok(let fd?): return .success(fd)
                case .ok(nil): return .failure(.host("its answer carried no socket"))
                case .refused(let why): return .failure(.host(why))
                }
            } catch {
                return .failure(.host("\(error)"))
            }
        }, release: { place in
            do {
                if case .refused(let why) = try HostConnector.web(.release(place), over: connector, timeout: hostPatience) {
                    note("the web's \(place.rawValue) socket wasn't let go by the session host: \(why)")
                }
            } catch {
                note("the web's \(place.rawValue) socket wasn't let go by the session host: \(error)")
            }
        })
    }
}
