import Foundation
import VibeCore

/// The server's dialer (the engine plan's E2; the security document's S2): a connection to its host's socket path,
/// which the server registered the connector it inherited for (`HostConnection.register(connector:for:)`), so stage
/// 2's registry makes it only through that connector (`HostConnector.connect(over:timeout:)`), never by the path. With
/// no connector registered for the path it makes none: a connection by the path would be `.unknown` to the host, which
/// refuses it the app's requests, and a server never makes one (the engine plan's Review Focus 4).
public struct ConnectorDialer: HostDialer {
    public let path: String

    /// Why there is no connection: no connector is registered for the path.
    public struct Unregistered: Error, CustomStringConvertible {
        public let path: String
        public var description: String {
            "No connector is registered for the session host at \(path): the server reaches its host only through the connector it inherited."
        }
    }

    public init(path: String) {
        self.path = path
    }

    public func connect(queue: DispatchQueue) throws -> HostConnection {
        guard HostConnection.connector(for: path) != nil else { throw Unregistered(path: path) }
        // Through the connector: the host answers with a connection it made for this process, its app (no proof asked).
        return try HostConnection(path: path, queue: queue, appKey: nil)
    }
}
