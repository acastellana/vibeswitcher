import Foundation
import VibeCore

/// A review row waiting on the account's usage (the parity table's "Usage shown to you"): its verifier stopped at a
/// limit, or the model its audit would start on is held back (`AccountUsage.hold`). No review clock runs while it waits.
///
/// The app's `ReviewUsageWait` (`Sources/VibeSwitcher/MainWindow/Lead/TeamRows.swift`), copied (the port map's
/// "Copied from the app").
public struct ReviewUsageWait: Equatable, Sendable {
    public var model: String?
    public var resetsAt: Double?

    public init(model: String?, resetsAt: Double?) {
        self.model = model
        self.resetsAt = resetsAt
    }

    /// "Fable", "the account".
    public var name: String { model.flatMap(AccountUsage.family).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "the account" }
    /// The row's state: "Waits for Fable", "Waits for usage limit".
    public var state: String { model == nil ? "Waits for usage limit" : "Waits for \(name)" }
    /// The row's dim line: "Fable's limit resets Nov 22, 09:00".
    public var line: String {
        let whose = model == nil ? "The account's" : "\(name)'s"
        return whose + " limit " + (resetsAt.map { "resets \(UsageLimit.resetText($0))" } ?? "reset time is not known")
    }
}

/// The account watch's part of the engine's look (the app's `TeamRows.usageWaits`, copied): which review rows wait on
/// a limit. Read on the engine's reads queue with the team (`TeamReading`), never as a row is shown.
enum UsageWaits {
    /// Each review task waiting on usage, by task id: its awaited verifier stopped at a limit (what its transcript
    /// says), or no verifier yet and the model its audit would start on held back by `team.usage`. A verifier still
    /// at work isn't waiting, even while new starts are held back. `root`: the project's, whose branch the security
    /// check reads when it decides which model the audit needs.
    static func reviews(_ board: LeadBoard, team: TeamReading, now: Date, root: String? = nil) -> [String: ReviewUsageWait] {
        var usage = team.usage
        // This look's refusals too, as status counts them, before the tool server has kept them.
        for task in board.tasks {
            for id in task.members {
                guard team.hosted[id]?.isLive == true, case .usageLimit(let limit)? = team.watched[id]?.activity,
                      var reading = AccountUsage.fromRefusal(limit, model: task.launchedModels?[id], now: now) else { continue }
                if reading.account == nil {
                    // A refusal already recorded before a /login belongs to that account, never the new one.
                    if usage.limits.contains(where: {
                        $0.reached && $0.name == reading.name && $0.model == reading.model
                            && $0.resetsAt == reading.resetsAt && $0.at == reading.at
                    }) { continue }
                    reading.account = usage.account
                }
                usage.limits.append(reading)
            }
        }
        var waits: [String: ReviewUsageWait] = [:]
        for task in board.tasks where task.status == .review && task.evidence == nil {
            let reviewing = task.awaitedVerifiers.contains { id in
                if case .working? = team.watched[id]?.activity { return team.hosted[id]?.isLive == true }
                return false
            }
            if reviewing { continue }
            let stopped = task.awaitedVerifiers.first { id in
                if case .usageLimit? = team.watched[id]?.activity { return team.hosted[id]?.isLive == true }
                return false
            }
            if let id = stopped, case .usageLimit(let limit)? = team.watched[id]?.activity {
                let model = task.launchedModels?[id].flatMap { $0.isEmpty ? nil : $0 }
                    ?? AccountUsage.fromRefusal(limit, model: nil, now: now)?.model
                waits[task.id] = ReviewUsageWait(model: model, resetsAt: limit.resetsAt)
                continue
            }
            guard task.verifier == nil, task.reviewLevel != .none || task.auditNeeded != nil || task.riskRaised != nil else { continue }
            let fallback = usage.fableHeldBack(now: now) != nil
            let workers = usage.startModel(team.workerModel, now: now)
            func auditModel(security: Bool) -> String {
                team.workflow.auditModel(workerModel: workers, taskModel: usage.startModel(task.intendedModel, now: now),
                    launchedModel: task.worker.flatMap { task.launchedModels?[$0] }.flatMap { $0.isEmpty || $0.hasPrefix("codex") ? nil : $0 },
                    heldBack: fallback ? AccountUsage.heldBackFamily : nil, security: security)
            }
            let ordinary = auditModel(security: false), secure = auditModel(security: true)
            var model = ordinary
            if ordinary != secure {
                // The branch is looked at only when its being a security change decides which held model it needs.
                guard usage.hold(model: ordinary, now: now, ignoring: team.ignoreUsageLimits) != nil
                    || usage.hold(model: secure, now: now, ignoring: team.ignoreUsageLimits) != nil else { continue }
                let security: Bool
                if let root, let branch = task.branch {
                    security = LeadToolset.securityReason(root: root, head: branch, workflow: team.workflow, raised: task.riskRaised) != nil
                } else {
                    // auditNeeded also says "Its review is audit." for an ordinary audit: only a security reason counts.
                    security = task.auditNeeded?.hasPrefix("It touches sensitive_paths (") == true || task.riskRaised.map { raised in
                        raised.byModel || LeadRisk.patterns.contains { $0.what != "adds locks or threads" && raised.reason.contains($0.what) }
                    } == true
                }
                if security { model = secure }
            }
            if let limit = usage.hold(model: model, now: now, ignoring: team.ignoreUsageLimits) {
                waits[task.id] = ReviewUsageWait(model: model, resetsAt: limit.resetsAt)
            }
        }
        return waits
    }
}
