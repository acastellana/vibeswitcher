import Foundation

/// Who a session sandbox is for (the session sandbox plan, "What each role can read, write, run and reach"): what
/// `SandboxPlanner` gives a box depends on it alone, never on what the session asks.
public enum SandboxRole: String, Codable, Sendable, CaseIterable {
    /// A worker: its worktree, its git folders, the toolchain, the agent's own config.
    case worker
    /// A verifier's agent: its audit checkout, never a worker's worktree.
    case verifier
    /// The lead: its checkout through a layer of its own (nothing it writes reaches the real one).
    case lead
    /// A run of a branch's code (a merge's tests, an audit's run, `init_command`, a verifier's command): a scratch home
    /// and worktree, no door, no terminal, no agent, no network.
    case branchRun
}

/// Why a box can't be planned, or a project's sandbox setting can't be taken: what was refused, and why, in words a
/// card or a log line can show.
public struct SandboxRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// The workflow.md key it came from, when it came from one.
    public var key: String?
    /// What was refused: a path, a host, a value.
    public var value: String
    public var reason: String

    public init(key: String? = nil, value: String, reason: String) {
        self.key = key
        self.value = value
        self.reason = reason
    }

    public var description: String {
        (key.map { "\($0): " } ?? "") + "\(value): \(reason)"
    }
}
