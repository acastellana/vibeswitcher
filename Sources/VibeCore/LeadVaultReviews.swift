import Foundation

/// Review levels (`LeadTask.Review`) and the worker's "done": what lets a `review: none` task merge with no verdict.
/// Kept in the vault, like verdicts: board.json is in the project's `.vibeswitcher` folder, which every session of the
/// team can write, so a worker that set its own task to none there, or wrote itself a "done" report, would get its work
/// merged unchecked. merge goes by the stricter of the board's level and this one, which only the lead sets, and by the
/// commit the task's own worker last reported done on.
extension LeadVault {
    /// What the vault knows of a task for a merge without an audit.
    public struct Unaudited: Equatable, Sendable {
        /// The lead's level; none when it set none (or nothing).
        public var review: LeadTask.Review
        /// The commit its worker last reported done on; nil when its last report wasn't done, or there was none.
        public var reported: String?
    }

    /// The lead sets the task's review level.
    public func setReview(_ review: LeadTask.Review, root: String, task: String) throws {
        _ = try call(.setReview(root: root, task: task, review: review))
    }

    /// The task's own worker reported done on `commit` (nil: its report wasn't done).
    public func reportDone(root: String, task: String, commit: String?) throws {
        _ = try call(.reportDone(root: root, task: task, commit: commit))
    }

    /// The task's review level and its worker's last "done", as the vault has them.
    public func unaudited(root: String, task: String) throws -> Unaudited {
        guard case .unaudited(let review, let reported) = try call(.unaudited(root: root, task: task)) else { throw Self.unexpected }
        return Unaudited(review: review ?? .none, reported: reported)
    }
}
