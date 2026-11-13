#if canImport(Darwin)
import Foundation
import Security

// The Mac's code identity: the session host's `AppCode` bodies (Sources/VibeHost/AppCode.swift), moved here
// unchanged. Builds are ad-hoc signed (no team), so the identity is the code directory hash.
extension Platform.CodeIdentity {
    /// `struct proc_archinfo` (xnu's sys/proc_info_private.h): the CPU type and subtype a process runs. Not in every
    /// SDK's public headers (the Command Line Tools' has neither it nor `PROC_PIDARCHINFO`), so declared here.
    public struct Architecture: Equatable {
        public var cpuType: cpu_type_t = 0
        public var cpuSubtype: cpu_subtype_t = 0

        public init(cpuType: cpu_type_t = 0, cpuSubtype: cpu_subtype_t = 0) {
            self.cpuType = cpuType
            self.cpuSubtype = cpuSubtype
        }
    }

    /// `PROC_PIDARCHINFO`, the `proc_pidinfo` flavor that answers an `Architecture`.
    static let pidArchitectureFlavor: Int32 = 19

    enum System {
        static let isAvailable = true

        static func runs(_ token: audit_token_t, executable: String) -> Bool {
            // Universal binaries can run a different CPU subtype from Security's default on-disk selection
            // (e.g. arm64e.x1). Compare the configured executable's exact running slice, never a path alone.
            guard let architecture = architecture(of: token.pid),
                  let cdhash = cdhash(atPath: executable, architecture: architecture) else { return false }
            var token = token
            let audit = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
            var guest: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit] as CFDictionary, [], &guest) == errSecSuccess,
                  let guest else { return false }
            let hex = cdhash.map { String(format: "%02x", $0) }.joined()
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString("cdhash H\"\(hex)\"" as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { return false }
            // Dynamic validity: the kernel still holds the process's code valid, and it's the code the requirement names.
            return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
        }

        static func architecture(of pid: pid_t) -> Architecture? {
            var architecture = Architecture()
            let size = Int32(MemoryLayout<Architecture>.size)
            guard proc_pidinfo(pid, pidArchitectureFlavor, 0, &architecture, size) == size else { return nil }
            return architecture
        }

        static func cdhash(atPath path: String, architecture: Architecture? = nil) -> Data? {
            var code: SecStaticCode?
            let attributes: [CFString: Any] = architecture.map {
                [kSecCodeAttributeArchitecture: $0.cpuType, kSecCodeAttributeSubarchitecture: $0.cpuSubtype]
            } ?? [:]
            guard SecStaticCodeCreateWithPathAndAttributes(URL(fileURLWithPath: path) as CFURL, [], attributes as CFDictionary,
                                                           &code) == errSecSuccess, let code else { return nil }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
                  let information = information as? [String: Any] else { return nil }
            return information[kSecCodeInfoUnique as String] as? Data
        }
    }
}
#endif
