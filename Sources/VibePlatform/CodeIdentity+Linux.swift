#if os(Linux)
import Foundation

// Linux's code identity: none. Its programs carry no signature the kernel checks, so no process is told by the code
// it runs; every form answers "no such thing", and shared code reads `isAvailable` as "on Linux".
extension Platform.CodeIdentity {
    /// What the Mac's `Architecture` holds (a CPU type and subtype), for the one signature both systems share. Never
    /// read here: `architecture(of:)` is nil.
    public struct Architecture: Equatable {
        public var cpuType: Int32 = 0
        public var cpuSubtype: Int32 = 0

        public init(cpuType: Int32 = 0, cpuSubtype: Int32 = 0) {
            self.cpuType = cpuType
            self.cpuSubtype = cpuSubtype
        }
    }

    enum System {
        static let isAvailable = false

        /// False: no process runs code this can name.
        static func runs(_ token: Platform.PeerToken, executable: String) -> Bool { false }

        /// False: no process runs code this can name.
        static func runs(_ token: Platform.PeerToken, cdhash: Data) -> Bool { false }

        /// nil: Linux has no Hardened Runtime (its form is non-dumpable, `Platform.Processes.isDumpable`).
        static func isHardened(_ token: Platform.PeerToken) -> Bool? { nil }

        /// nil: nothing to read it from.
        static func architecture(of pid: pid_t) -> Architecture? { nil }

        /// nil: no code signature, so no code directory and no hash of one.
        static func cdhash(atPath path: String, architecture: Architecture? = nil) -> Data? { nil }
    }
}
#endif
