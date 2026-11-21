import Foundation

extension Platform {
    /// Whether a process runs a given program's code, told by its code signature and not by its path: a process can
    /// exec the program's file under a pid that connected as something else, and a path says nothing of what was
    /// loaded from it.
    ///
    /// The Mac's forms are the session host's cdhash check and its read of a process's architecture, moved here
    /// unchanged (CodeIdentity+Darwin.swift). Linux has no code signatures: its forms answer "no such thing"
    /// (CodeIdentity+Linux.swift), and the app there is the connections the host makes for its server child (the stage
    /// 2 plan's S2-D1), not a process that runs some code.
    ///
    /// `isAvailable` is also the one value shared code outside this module reads to tell the systems apart (the stage
    /// 2 plan's Global Constraints: `PlatformLintTests` forbids asking which system it is there): "on Linux" is
    /// `!Platform.CodeIdentity.isAvailable`, and a switch on it does nothing on the Mac.
    public enum CodeIdentity {
        /// Whether code identity can be checked here: true on the Mac (the cdhash check), false on Linux.
        public static var isAvailable: Bool { System.isAvailable }

        /// The process `token` names, as it runs now, is valid code whose cdhash is the one of the code at
        /// `executable`. The Mac: Security's dynamic check of the guest the audit token names (Security refuses a
        /// token whose pid exec'd since), against the cdhash of the exact slice the process runs. Linux: false.
        public static func runs(_ token: Platform.PeerToken, executable: String) -> Bool {
            System.runs(token, executable: executable)
        }

        /// The process `token` names, as it runs now, is valid code whose cdhash is `cdhash` (read before, from the
        /// file the process was started from: `cdhash(atPath:architecture:)`), whatever its path names by now. The Mac:
        /// Security's dynamic check of the guest the audit token names, as `runs(_:executable:)`; it refuses a token
        /// whose pid exec'd since. Linux: false.
        public static func runs(_ token: Platform.PeerToken, cdhash: Data) -> Bool {
            System.runs(token, cdhash: cdhash)
        }

        /// Whether the process `token` names runs under the Hardened Runtime as it runs now, and can't be debugged:
        /// its dynamic code status valid, with the runtime flag (`CS_RUNTIME`: `DYLD_` variables ignored, another
        /// process's `task_for_pid` refused) and neither `get-task-allow` (`CS_GET_TASK_ALLOW`) nor a debugger attached
        /// (`CS_DEBUGGED`). The Mac's form of Linux's non-dumpable (the server child's connector asks it: the node on
        /// the Mac's step 3). nil when it can't be told, and on Linux.
        public static func isHardened(_ token: Platform.PeerToken) -> Bool? { System.isHardened(token) }

        /// Whether the code on disk at `path` is signed, validly as it is now, with the Hardened Runtime
        /// (`codesign --options runtime`: every slice's signature valid, the runtime flag set) and without
        /// `get-task-allow`: what the install's Mac signing gives the node's binaries (scripts/lib/mac-sign.sh), so the
        /// processes they start pass `isHardened`. nil when it can't be read, and on Linux.
        public static func isSignedHardened(atPath path: String) -> Bool? { System.isSignedHardened(atPath: path) }

        /// The architecture the process `pid` runs (the slice of a universal binary it was started from); nil when it
        /// can't be read. Linux: nil.
        public static func architecture(of pid: pid_t) -> Architecture? { System.architecture(of: pid) }

        /// The cdhash of the code on disk at `path` (for a universal binary, `architecture`'s slice, or this
        /// machine's); nil when it has none or can't be read. Linux: nil.
        public static func cdhash(atPath path: String, architecture: Architecture? = nil) -> Data? {
            System.cdhash(atPath: path, architecture: architecture)
        }
    }
}
