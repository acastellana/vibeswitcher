import Foundation
import VibeCore

/// The account's usage as a node shows it (the parity table's "Usage shown to you"; the app's account watch,
/// `LeadController`'s `TeamReading.read`): what the roles' status lines and Claude's refusals said, kept by their tool
/// servers in `account-usage.json` under the node's root (`AccountUsageStore`; `UsageStatusLine` through the door).
/// No credential is read: the account Claude Code is logged in to is its `~/.claude.json` id, its email masked.
///
/// Read once a refresh on the engine's reads queue (`LeadEngine.refreshNow`), kept on the engine (`usage`), and given
/// to `status` and the `node` stream (`usage`), to `vibeswitcher status` and `settings` (`lines`), to the teams
/// (`TeamReading`, whose review rows wait on a limit: `UsageWaits`), and so to the boards and the page.
public enum NodeUsage {
    /// What one refresh read.
    public struct Reading: Equatable, Sendable {
        public var usage = AccountUsage()
        /// The model workers start on: Claude's settings in the node's home (nil: Claude's default).
        public var workerModel: String?
        /// Settings' Ignore usage limits (`node-limits.json`, `MacLimits.fileName`).
        public var ignoring = false
        public var now = Date()

        public init(usage: AccountUsage = AccountUsage(), workerModel: String? = nil, ignoring: Bool = false, now: Date = Date()) {
            self.usage = usage
            self.workerModel = workerModel
            self.ignoring = ignoring
            self.now = now
        }
    }

    /// The usage kept under the node's root (`files`), the account `home`'s Claude Code is logged in to, and its
    /// settings. Reads the disk: off the engine's queue.
    public static func read(files: NodeSettings.Files, home: String, now: Date = Date()) -> Reading {
        Reading(usage: AccountUsageStore(file: files.usage, home: home).load(), workerModel: LeadWorkflow.claudeModel(command: "claude", home: home),
                ignoring: MacLimits.load(from: files.limits).ignoreUsageLimits, now: now)
    }

    /// As `status` and the `node` stream carry it (`WireSchema`'s `node.usage`): the limits still holding on the
    /// account logged in to, the most used first (`AccountUsage.current`); that account's masked name; whether Ignore
    /// usage limits is on; the share at which leads stop starting work; until when Fable is held back. Never an
    /// account's id or email.
    public static func value(_ reading: Reading) -> NodeWire.Value {
        let usage = reading.usage
        let limits = usage.current(now: reading.now).limits
        return .object([
            "account": usage.account.map { .string(usage.name(of: $0)) } ?? .null,
            "limits": .array(limits.map { limit in
                .object(["name": .string(limit.name), "label": .string(limit.label), "model": limit.model.map(NodeWire.Value.string) ?? .null,
                         "usedPercent": .int(Int(limit.usedPercent.rounded())), "reached": .bool(limit.reached),
                         "resetsAt": limit.resetsAt.map { .date(Date(timeIntervalSince1970: $0)) } ?? .null,
                         "holds": .bool(limit.reached || (!reading.ignoring && limit.usedPercent >= AccountUsage.threshold)),
                         "text": .string(limit.text)])
            }),
            "ignored": .bool(reading.ignoring),
            "threshold": .int(Int(AccountUsage.threshold)),
            "fableHeldBack": usage.fableHeldBack(now: reading.now).map { .date(Date(timeIntervalSince1970: AccountUsage.ends($0))) } ?? .null,
        ])
    }

    /// `vibeswitcher status`'s and `settings`' lines for `value` (`value(_:)`'s): one for the limits known, one when
    /// Fable is held back. Every string from the wire shown inert.
    public static func lines(_ value: NodeWire.Value?) -> [String] {
        guard let value, value.object != nil else { return [] }
        let inert = { (text: String?) in ConfigSeal.inert(text ?? "", limit: 200) }
        let limits = value["limits"]?.array ?? []
        let ignored = value["ignored"]?.bool == true
        let whose = value["account"]?.string.map { " for \(inert($0))" } ?? ""
        var lines = ["usage\(whose) (best effort, what the sessions' status lines and Claude's refusals said): "
            + (limits.isEmpty ? "nothing known" : limits.map { inert($0["text"]?.string) }.joined(separator: "; "))
            + (ignored ? " " + AccountUsage.ignoredMark : "")]
        let holding = limits.filter { $0["holds"]?.bool == true }
        if !holding.isEmpty {
            lines.append(ignored ? "  only a limit Claude refused a request at holds work back (Ignore usage limits is on)"
                : "  leads start no workers or audits on the models these hold back: \(holding.compactMap { $0["label"]?.string }.map(inert).joined(separator: ", "))")
        }
        if let until = value["fableHeldBack"]?.string.flatMap(NodeWire.date) {
            lines.append("  Fable held back until \(UsageLimit.resetText(until.timeIntervalSince1970)): workers on Opus, audits on another model under the review floor")
        }
        return lines
    }
}
