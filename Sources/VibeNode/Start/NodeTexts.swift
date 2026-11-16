import Foundation
import VibeCore

/// The confirmations the command line shows before it changes the node (the start plan's S2; `stop` is S3's, `switch`
/// and `rollback` S8a's). Each says what the user's typed code will do, in the spec's words where it has them.
public enum NodeTexts {
    /// `start`'s (ST-D5 step 7): the unit's key lines, `KillMode`'s consequence (the spec's sentence), the build it
    /// runs and, when they differ, the commit `current` names and how to run it (ST-D3), the commit the unit named
    /// before, and the swift and node folders its PATH adds. `atLogin`: it says the unit is enabled too. `enabledBy`:
    /// the folders found holding a link to the unit (`NodeStarter.enabledBy`), read before the code is asked; when
    /// there are any it says the unit is enabled already, and that the manager starts it at login without start's
    /// checks (ST-D4, the review of S2).
    ///
    /// The plan's `folders:` parameter is the unit's own `swiftBin` and `nodeBin` (2026-11-16).
    public static func start(unit: NodeUnit.Inputs, current: String?, previousCommit: String?, atLogin: Bool, enabledBy: [String]) -> String {
        var lines = [
            "This starts the node as your systemd unit \(NodeUnit.fileName), from the build of commit \(unit.commit):",
            "  ExecStart=\(NodeUnit.execStart(prefix: unit.prefix, commit: unit.commit).joined(separator: " "))",
            "  Restart=no: a host that ends stays down until you run start again",
            "  KillMode=control-group: \(NodeUnit.killModeConsequence)",
            "  TimeoutStopSec=\(NodeUnit.timeoutStop)",
            "  swift from \(ConfigSeal.inert(unit.swiftBin, limit: .max))",
            "  node from \(ConfigSeal.inert(unit.nodeBin, limit: .max))",
        ]
        if let previousCommit { lines.append("The unit named \(ConfigSeal.inert(previousCommit, limit: 64)) before; start runs that build again.") }
        if let current, current != unit.commit {
            lines.append("the unit runs \(unit.commit); current is \(ConfigSeal.inert(current, limit: 64)) (installed later): `vs switch \(ConfigSeal.inert(current, limit: 64))` runs it")
        }
        if !enabledBy.isEmpty {
            let folders = enabledBy.map { ConfigSeal.inert($0, limit: .max) }.joined(separator: ", ")
            lines.append("It is enabled already (a link to it in \(folders)): the manager starts it at login, without start's checks (`systemctl --user disable vibeswitcher-node` undoes that).")
        } else {
            lines.append(atLogin ? "It is enabled too: the manager starts it at login (`systemctl --user disable vibeswitcher-node` undoes that)."
                                 : "It isn't enabled (no link to it in your unit folder's .wants, .requires or .upholds folders): nothing starts it when you log in unless you run start --at-login.")
        }
        return lines.joined(separator: "\n")
    }
}
