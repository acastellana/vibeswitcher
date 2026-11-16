import Foundation
import VibeCore

/// The confirmations the command line shows before it changes the node (the start plan's S2; `stop` and the detached
/// start are S3's, `switch` and `rollback` S8a's). Each says what the user's typed code will do, in the spec's words where it has them.
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

    /// `stop`'s through the server (S3; the app's `HostClient.RestartPlan.endAndReplace(live:)`, port-map row 100): how
    /// many sessions it ends, in all projects, and that the host stops after them.
    public static func stop(live: Int) -> String {
        guard live > 0 else { return "No session is live; this stops the host." }
        return "This ends \(live) \(live == 1 ? "session" : "sessions") in all projects (the leads first), then stops its host."
    }

    /// The `stop` fallback's through systemd (ST-D7): the unit stopped by the manager, every process in it with it.
    public static let stopUnit = "This stops your systemd unit \(NodeUnit.fileName) (`systemctl --user stop`): its host, its server and every session in it end (KillMode=control-group), without the server's orderly stop of the leads first."

    /// The `stop` fallback's on a machine without systemd (ST-D7): the recorded host, by its pid and command line, and
    /// what is found under it; not every process a session started (no cgroup holds them: `NodeStopper.stopDetached`,
    /// the review of S3).
    public static func stopDetached(pid: pid_t, arguments: [String]) -> String {
        "This ends the node's host, pid \(pid) (\(ConfigSeal.inert(arguments.joined(separator: " "), limit: .max))): SIGTERM, then SIGKILL after 30 s, and the processes found under it (its server, its sessions and theirs), without the server's orderly stop of the leads first. Without systemd a process that left the host's tree (a daemon a session started) isn't found, and keeps running."
    }

    /// The detached start's (ST-D6), on a machine without systemd: the host's command, its environment, where its output
    /// and its pid go (the pid file any worker can write), that nothing restarts it or starts it at login, and, when
    /// `current` names another commit, which build this is.
    public static func startDetached(unit: NodeUnit.Inputs, current: String?, log: String, record: String) -> String {
        var lines = [
            "No systemd here: this starts the node detached, in a session of its own, from the build of commit \(unit.commit):",
            "  \(NodeUnit.execStart(prefix: unit.prefix, commit: unit.commit).joined(separator: " "))",
            "  its environment: HOME=\(ConfigSeal.inert(unit.home, limit: .max)), PATH=\(ConfigSeal.inert(NodeUnit.path(swiftBin: unit.swiftBin, nodeBin: unit.nodeBin), limit: .max)), SWIFT_BACKTRACE=enable=no, and nothing of your shell's",
            "  its output: \(ConfigSeal.inert(log, limit: .max))",
            "  its pid: \(ConfigSeal.inert(record, limit: .max)), which you and any worker can write (\(weakerRule))",
            "Nothing restarts it when it ends, and nothing starts it when you log in; `vibeswitcher stop` ends it.",
        ]
        if let current, current != unit.commit {
            lines.append("current is \(ConfigSeal.inert(current, limit: 64)); this starts \(unit.commit), the build this command line is from")
        }
        return lines.joined(separator: "\n")
    }

    /// `switch`'s (S8a; the app's `HostClient.RestartPlan.handOver`, port-map row 100): the host hands over to the
    /// target's build and keeps every session, so it names no count; a running team keeps its build until its lead
    /// restarts (ST-D16); the seal holds every team until `vs config accept`, since the builds folder and the unit
    /// change (ST-D23). The code is still typed (EN-D5), where the app asked nothing.
    public static func `switch`(from: String, to: String) -> String {
        (["This switches the node from the build of commit \(ConfigSeal.inert(from, limit: 64)) to the build of commit \(ConfigSeal.inert(to, limit: 64)):"]
            + switchConsequences(to: to)).joined(separator: "\n")
    }

    /// `rollback`'s (S8a, ST-D14): the switch's, going back to `to`, the commit installed before the running build,
    /// with the `installs` line it was read from (`line`: the file is any worker's to edit, so the user reads it here).
    public static func rollback(from: String, to: String, line: String) -> String {
        ([
            "This rolls the node back from the build of commit \(ConfigSeal.inert(from, limit: 64)) to the build of commit \(ConfigSeal.inert(to, limit: 64)), the one installed before it:",
            "  its line in the installs record: \(ConfigSeal.inert(line, limit: .max)) (any worker can write that record: check the commit is one you installed)",
        ] + switchConsequences(to: to)).joined(separator: "\n")
    }

    /// What a switch to `to` does and leaves, for `switch` and `rollback`.
    static func switchConsequences(to: String) -> [String] {
        let commit = ConfigSeal.inert(to, limit: 64)
        return [
            "  the host hands over to \(commit)'s host, which keeps every session",
            "  a running team keeps its build until its lead restarts: the workers a lead started before the switch start the old build's tool server",
            "  your unit's ExecStart is rewritten to \(commit) and `current` names it, so the next start runs it",
            "  the seal holds every team until `vs config accept`, since the builds folder and the unit change (`vs config held` shows them)",
        ]
    }

    /// What `status` says of a node started detached (ST-D6).
    public static let weakerRule = "no systemd: the weaker voice rule; the node's pid file is yours, and any worker's, to write"

    /// The lines `status` adds for the node's mode: `weakerRule` for a node started detached, none otherwise.
    public static func statusLines(mode: NodeCheck.Mode) -> [String] {
        if case .detached = mode { return [weakerRule] }
        return []
    }
}
