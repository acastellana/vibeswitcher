import Foundation
import VibeCore

/// What the host saw that its server child should know (the stage 2 plan's Task 8b, the security architecture
/// document's S2), counted where no other part keeps it: the app connections it refused (`AppConnector`) and the paths
/// it took back (`HostPathWatch`). On the host's queue. The server child's restarts are `ServerChild`'s own; those of
/// the images before this one are carried here. A handover carries all of it (`HostHandover.State.tally`), so the
/// counts run from the host's start, as `startedAt` does, not from this image's.
final class HostTally {
    /// The most paths kept: the oldest go first.
    static let pathsKept = 100

    private(set) var refusedAppConnections = 0
    private(set) var replacedPaths: [String] = []
    /// The server child's restarts under the images before this one.
    private(set) var earlierServerRestarts = 0

    func refusedAppConnection() { refusedAppConnections += 1 }

    func replaced(_ path: String) {
        replacedPaths.append(path)
        if replacedPaths.count > Self.pathsKept { replacedPaths.removeFirst(replacedPaths.count - Self.pathsKept) }
    }

    /// The counts a handover carried, taken on (before the host serves). Nil: none.
    func restore(_ record: HostHandover.Tally?) {
        guard let record else { return }
        refusedAppConnections = max(0, record.refusedAppConnections)
        replacedPaths = Array(record.replacedPaths.suffix(Self.pathsKept))
        earlierServerRestarts = max(0, record.serverRestarts)
    }

    /// The counts as a handover carries them, with `serverRestarts` this image's.
    func record(serverRestarts: Int) -> HostHandover.Tally {
        HostHandover.Tally(serverRestarts: earlierServerRestarts + serverRestarts, replacedPaths: replacedPaths,
                           refusedAppConnections: refusedAppConnections)
    }
}

extension HostHandover {
    /// `HostTally`'s counts as a handover carries them (`State.tally`).
    public struct Tally: Codable, Equatable {
        /// The server child's restarts under every image so far.
        public var serverRestarts: Int
        public var replacedPaths: [String]
        public var refusedAppConnections: Int

        public init(serverRestarts: Int, replacedPaths: [String], refusedAppConnections: Int) {
            self.serverRestarts = serverRestarts
            self.replacedPaths = replacedPaths
            self.refusedAppConnections = refusedAppConnections
        }
    }
}

extension HostServer {
    /// The answer to `HostRequest.hostNotes` (the app's alone, `authorized`): `startedAt` the host's own (this process's,
    /// across handovers), with the server child's restarts and what `tally` counted, the images' before this one's
    /// included. On `queue`.
    func hostNotes(startedAt: Date) -> HostNotes {
        HostNotes(startedAt: startedAt, serverRestarts: tally.earlierServerRestarts + (serverChild?.restarts ?? 0),
                  replacedPaths: tally.replacedPaths, refusedAppConnections: tally.refusedAppConnections)
    }

    /// `tally` for a handover's state (`HostHandover.State.tally`): nil on the Mac, which counts nothing (no connector,
    /// no path watch), so its state stays as it was. On `queue`.
    var tallyForHandover: HostHandover.Tally? {
        Platform.CodeIdentity.isAvailable ? nil : tally.record(serverRestarts: serverChild?.restarts ?? 0)
    }
}
