import Foundation
import VibeCore

/// Check for Updates now (`vibeswitcher status --check-updates`, 2026-11-21): the update watch's look (`UpdateWatch`,
/// the same decision and record the 6 h watch uses) asked at once rather than at its time, its answer the reply. Read-only
/// as the watch is: it installs nothing and writes only the watch's record, whose next timed look is then 6 h away. The
/// user's voice with no typed word (`NodeWire.changesNothing`): never a session's, which could make the node ask GitHub
/// in a loop, nor a page's.
extension Requests {
    /// How long a check may take: gh's token, the runs and two compares, each call with its own bound (60 s).
    public static let updateCheckPatience: TimeInterval = 300

    func updateCheck(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let updates else {
            return reply(.init(re: request.id, error: .init(.refused, "this server doesn't check for updates (a scratch node asks GitHub nothing)")))
        }
        updates.look { reply(.init(re: request.id, result: updates.checked)) }
    }
}
