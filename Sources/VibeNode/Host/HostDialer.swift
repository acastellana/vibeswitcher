import Foundation
import VibeCore

/// How the engine's link to the session host (`HostLink`, the engine plan's E2) gets a connection: in the server, its
/// host's registered path, through the connector it inherited (`ConnectorDialer`, E2; the security document's S2); in
/// a test, a scratch host's (`NodeTestHost`). The link asks again for each reconnect.
public protocol HostDialer: Sendable {
    /// A new connection to the host, its events delivered on `queue`. Throws when none can be had now.
    func connect(queue: DispatchQueue) throws -> HostConnection
}
