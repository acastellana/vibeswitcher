import Foundation

/// Where the board's tasks came from, week by week (`LeadTask.origin`): how many bugs the user reported against those
/// the system found (incidents, the log watcher, flakes, audits), counted by when each task was created. Status says
/// the last 7 days' and the 7 before's; Statistics counts the same way (`SetupScorecard`).
public struct LeadOrigins: Equatable, Sendable {
    /// Tasks created in the span, by origin; `unsaid`: created with none said.
    public var counts: [LeadTask.Origin: Int] = [:]
    public var unsaid = 0

    public init(counts: [LeadTask.Origin: Int] = [:], unsaid: Int = 0) {
        self.counts = counts
        self.unsaid = unsaid
    }

    /// The tasks among `tasks` created in [start, end): each counted once, by its `originKind` (a value this build
    /// doesn't know counts as other).
    public init(_ tasks: [(createdAt: Double, origin: String?)], from start: Double, to end: Double) {
        for task in tasks where start <= task.createdAt && task.createdAt < end {
            guard let said = task.origin, !said.trimmingCharacters(in: .whitespaces).isEmpty else { unsaid += 1; continue }
            counts[LeadTask.Origin(text: said) ?? .other, default: 0] += 1
        }
    }

    /// All tasks counted (n).
    public var total: Int { counts.values.reduce(0, +) + unsaid }
    public var userReported: Int { counts[.userReport] ?? 0 }
    public var systemFound: Int { counts.filter { $0.key.systemFound }.values.reduce(0, +) }

    /// "2 user_report, 1 incident, 1 audit, 3 not said (n = 7)"; "none (n = 0)".
    public var text: String {
        var parts = LeadTask.Origin.allCases.compactMap { origin in counts[origin].flatMap { $0 > 0 ? "\($0) \(origin.rawValue)" : nil } }
        if unsaid > 0 { parts.append("\(unsaid) not said") }
        return (parts.isEmpty ? "none" : parts.joined(separator: ", ")) + " (n = \(total))"
    }

    /// Status's line: "Task origins (by creation; last 7 days): 2 user_report, 1 incident (n = 3) · the 7 days before:
    /// … · bugs you reported 2 vs found by the system 1"; nil when no task created in either week has an origin said
    /// (a board from before origins: nothing to count, and status stays short).
    public static func statusLine(_ tasks: [LeadTask], now: Double) -> String? {
        let week = 7 * 86_400.0
        let pairs = tasks.filter { $0.removedAt == nil }.map { (createdAt: $0.createdAt, origin: $0.origin) }
        let this = LeadOrigins(pairs, from: now - week, to: now + 1), last = LeadOrigins(pairs, from: now - 2 * week, to: now - week)
        guard this.total - this.unsaid + last.total - last.unsaid > 0 else { return nil }
        return "Task origins (by creation; last 7 days): \(this.text) · the 7 days before: \(last.text) · bugs you reported "
            + "\(this.userReported) vs found by the system \(this.systemFound) this week (\(last.userReported) vs \(last.systemFound) the week before)."
    }
}
