import Foundation
import VibeCore

/// What the server makes of `build.switch` to a commit (the start plan's S8a and S8b; the app's `HostClient.plan` and
/// `restartPlan`, port-map rows 52 and 99), and the commit `rollback` goes back to (ST-D14). Pure: the server gives it
/// the running build (`HostNotes.build`), the commits installed (the install root's folders) and the live sessions'
/// roles.
///
/// The node never replaces its host to switch: every node host hands over (stage 2's 9c/9d), and `stop` is how the user
/// ends the sessions. So the app's `replace`, `endAndReplace` and `keepOutdated` have no node form.
public enum SwitchPlan {
    /// The plan for one switch.
    public enum Plan: Equatable, Sendable {
        /// The target is the build that runs: nothing to do.
        case already
        /// The target has no folder in the install root: `install-node.sh` lays it out first.
        case notInstalled
        /// The target isn't a commit (40 lowercase hex digits): never looked up in the install root.
        case badCommit
        /// A worker or a verifier is live (the rule on switches, S8; ST-D15): the live ones' roles, in the order given.
        case refusedWhileTeamsWork([LeadLaunch.Role])
        /// The host hands over to the target's host, keeping every session.
        case handOver(String)
    }

    /// The plan for a switch to `target`: `badCommit` first (before it is compared with anything), then `already` when
    /// it is `running`, `notInstalled` when it isn't among `installed`, `refusedWhileTeamsWork` while any of `live` is a
    /// worker or verifier, else `handOver`. A lead may stay: a team keeps its build until its lead restarts (ST-D16).
    public static func plan(running: String?, target: String, installed: [String], live: [LeadLaunch.Role]) -> Plan {
        guard NodeUnit.isCommit(target) else { return .badCommit }
        if target == running { return .already }
        guard installed.contains(target) else { return .notInstalled }
        let working = live.filter { $0 != .lead }
        guard working.isEmpty else { return .refusedWhileTeamsWork(working) }
        return .handOver(target)
    }

    /// The commit `rollback` goes to (ST-D14), from `<installRoot>/installs` (`installs`: its lines, `<commit> <ISO
    /// time>`, oldest first): the nearest line before `running`'s last that names another commit, with that line as
    /// written (the command line shows it inert: the file is any worker's to edit); nil when there is none or
    /// `running` isn't in the record. A line whose first word isn't a commit (40 lowercase hex digits) is skipped.
    public static func rollbackTarget(installs: [String], running: String) -> (commit: String, line: String)? {
        let named = installs.compactMap { line -> (commit: String, line: String)? in
            guard let first = line.split(whereSeparator: \.isWhitespace).first, NodeUnit.isCommit(String(first)) else { return nil }
            return (commit: String(first), line: line)
        }
        guard let last = named.lastIndex(where: { $0.commit == running }) else { return nil }
        return named[..<last].last { $0.commit != running }
    }
}
