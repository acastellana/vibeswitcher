import Foundation
import VibeCore

/// What the host saw that its server child should know (the stage 2 plan's Task 8b, the security architecture
/// document's S2), counted where no other part keeps it: the app connections it refused (`AppConnector`), the paths
/// it took back and its lock path while another process holds the file there (`HostPathWatch`). On the host's queue. The server child's restarts are `ServerChild`'s own; those of
/// the images before this one are carried here. A handover carries all of it (`HostHandover.State.tally`), so the
/// counts run from the host's start, as `startedAt` does, not from this image's.
final class HostTally {
    /// The most paths kept: the oldest go first.
    static let pathsKept = 100

    private(set) var refusedAppConnections = 0
    private(set) var replacedPaths: [String] = []
    /// The server child's restarts under the images before this one.
    private(set) var earlierServerRestarts = 0
    /// The lock path while the file it names is another process's to lock (`HostPathWatch`); nil: not now. Not
    /// carried: the next image's watch checks the path as it begins (and a handover is refused meanwhile).
    private(set) var lockHeldElsewhere: String?
    /// How many times `lockHeldElsewhere` began.
    private(set) var lockHeldElsewhereCount = 0

    func refusedAppConnection() { refusedAppConnections += 1 }

    /// `path` (the lock path) names a file another process holds locked, from now on; nil: no longer.
    func lockHeld(elsewhere path: String?) {
        if path != nil, lockHeldElsewhere == nil { lockHeldElsewhereCount += 1 }
        lockHeldElsewhere = path
    }

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
        lockHeldElsewhereCount = max(0, record.lockHeldElsewhereCount ?? 0)
    }

    /// The counts as a handover carries them, with `serverRestarts` this image's.
    func record(serverRestarts: Int) -> HostHandover.Tally {
        HostHandover.Tally(serverRestarts: earlierServerRestarts + serverRestarts, replacedPaths: replacedPaths,
                           refusedAppConnections: refusedAppConnections,
                           lockHeldElsewhereCount: lockHeldElsewhereCount > 0 ? lockHeldElsewhereCount : nil)
    }
}

extension HostHandover {
    /// `HostTally`'s counts as a handover carries them (`State.tally`).
    public struct Tally: Codable, Equatable {
        /// The server child's restarts under every image so far.
        public var serverRestarts: Int
        public var replacedPaths: [String]
        public var refusedAppConnections: Int
        /// `HostTally.lockHeldElsewhereCount`; nil: none, or a build that didn't count it.
        public var lockHeldElsewhereCount: Int?

        public init(serverRestarts: Int, replacedPaths: [String], refusedAppConnections: Int, lockHeldElsewhereCount: Int? = nil) {
            self.serverRestarts = serverRestarts
            self.replacedPaths = replacedPaths
            self.refusedAppConnections = refusedAppConnections
            self.lockHeldElsewhereCount = lockHeldElsewhereCount
        }
    }
}

extension HostServer {
    /// The answer to `HostRequest.hostNotes` (the app's alone, `authorized`): `startedAt` the host's own (this process's,
    /// across handovers), with the server child's restarts and what `tally` counted, the images' before this one's
    /// included. On `queue`.
    func hostNotes(startedAt: Date) -> HostNotes {
        HostNotes(startedAt: startedAt, serverRestarts: tally.earlierServerRestarts + (serverChild?.restarts ?? 0),
                  replacedPaths: tally.replacedPaths, refusedAppConnections: tally.refusedAppConnections,
                  lockHeldElsewhere: tally.lockHeldElsewhere, lockHeldElsewhereCount: tally.lockHeldElsewhereCount)
    }

    /// `tally` for a handover's state (`HostHandover.State.tally`): nil on the Mac, which counts nothing (no connector,
    /// no path watch), so its state stays as it was. On `queue`.
    var tallyForHandover: HostHandover.Tally? {
        Platform.CodeIdentity.isAvailable ? nil : tally.record(serverRestarts: serverChild?.restarts ?? 0)
    }
}
