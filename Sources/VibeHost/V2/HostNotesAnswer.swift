import Foundation
import VibeCore

/// What the host saw that its server child should know (the stage 2 plan's Task 8b, the security architecture
/// document's S2), counted where no other part keeps it: the app connections it refused (`AppConnector`) and the paths
/// it took back (`HostPathWatch`). On the host's queue. The server child's restarts are `ServerChild`'s own.
final class HostTally {
    /// The most paths kept: the oldest go first.
    static let pathsKept = 100

    private(set) var refusedAppConnections = 0
    private(set) var replacedPaths: [String] = []

    func refusedAppConnection() { refusedAppConnections += 1 }

    func replaced(_ path: String) {
        replacedPaths.append(path)
        if replacedPaths.count > Self.pathsKept { replacedPaths.removeFirst(replacedPaths.count - Self.pathsKept) }
    }
}

extension HostServer {
    /// The answer to `HostRequest.hostNotes` (the app's alone, `authorized`): `startedAt` the host's own (this process's,
    /// across handovers), with the server child's restarts and what `tally` counted. On `queue`.
    func hostNotes(startedAt: Date) -> HostNotes {
        HostNotes(startedAt: startedAt, serverRestarts: serverChild?.restarts ?? 0, replacedPaths: tally.replacedPaths,
                  refusedAppConnections: tally.refusedAppConnections)
    }
}
