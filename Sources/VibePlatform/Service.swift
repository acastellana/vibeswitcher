import Foundation

extension Platform {
    /// What starts and supervises a user's long-running program on this system, where that program's log is read, and
    /// the user's runtime folder: the node's start, stop and status ask these instead of assuming Linux (the node on
    /// the Mac's design, docs/superpowers/specs/2026-11-19-v2-node-on-macos.md). Each system's answers are in a file of
    /// its own (Service+Linux.swift, Service+Darwin.swift).
    ///
    /// A tool is named only where this system has it, by its absolute path, never looked up on PATH: Linux's
    /// `systemctl` and `journalctl` are nil on the Mac, and the Mac's `launchctl` and `log` nil on Linux, so code
    /// written for one system's tool can't run the other's by mistake (their arguments have nothing in common).
    public enum Service {
        /// The user's service manager.
        public enum Manager: String, Sendable {
            /// The user's systemd (`systemctl --user`, units in `~/.config/systemd/user`): Linux. Whether it runs on a
            /// given machine (pid 1, its socket) is the node's to find out (`NodeFolders.mode`).
            case systemd
            /// launchd (`launchctl`, LaunchAgents in `~/Library/LaunchAgents`, the domain `gui/<uid>`): the Mac.
            case launchd
        }

        /// Where a service's log is read.
        public enum Log: String, Sendable {
            /// journald, read with `journalctl`: Linux.
            case journal
            /// The unified log, read with `log show` / `log stream`: the Mac.
            case unifiedLog
        }

        /// This system's service manager.
        public static var manager: Manager { System.manager }

        /// This system's log.
        public static var log: Log { System.log }

        /// `/usr/bin/systemctl` where the manager is systemd; nil elsewhere.
        public static var systemctl: String? { System.systemctl }

        /// `/usr/bin/journalctl` where the log is journald; nil elsewhere.
        public static var journalctl: String? { System.journalctl }

        /// `/bin/launchctl` where the manager is launchd; nil elsewhere.
        public static var launchctl: String? { System.launchctl }

        /// `/usr/bin/log` where the log is the unified log; nil elsewhere.
        public static var unifiedLogTool: String? { System.unifiedLogTool }

        /// The user's runtime folder, from the uid and never from `XDG_RUNTIME_DIR` (the start plan's ST-D2):
        /// `/run/user/<uid>` on Linux, where the user's manager listens (`systemd/private`). nil on the Mac, which has
        /// no such folder: launchd is reached by `launchctl` through its own Mach port, not through a folder of the
        /// user's.
        public static func runtimeFolder(uid: uid_t) -> String? { System.runtimeFolder(uid: uid) }
    }
}
