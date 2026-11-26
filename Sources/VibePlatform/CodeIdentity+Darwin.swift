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
            return runs(token, cdhash: cdhash)
        }

        /// The guest the audit token names, as Security finds it (it refuses a token whose pid exec'd since).
        static func guest(_ token: audit_token_t) -> SecCode? {
            var token = token
            let audit = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
            var guest: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit] as CFDictionary, [], &guest) == errSecSuccess else { return nil }
            return guest
        }

        // The dynamic status word's flags (xnu's <kern/cs_blobs.h>): valid, the Hardened Runtime, get-task-allow, and
        // a debugger attached.
        static let validFlag: UInt32 = 0x0000_0001
        static let getTaskAllowFlag: UInt32 = 0x0000_0004
        static let runtimeFlag: UInt32 = 0x0001_0000
        static let debuggedFlag: UInt32 = 0x1000_0000

        static func isHardened(_ token: audit_token_t) -> Bool? {
            guard let guest = guest(token) else { return nil }
            var information: CFDictionary?
            // A guest is a code object too: Security reads its dynamic status with kSecCSDynamicInformation.
            guard SecCodeCopySigningInformation(unsafeBitCast(guest, to: SecStaticCode.self),
                                                SecCSFlags(rawValue: numericCast(kSecCSDynamicInformation)), &information) == errSecSuccess,
                  let information = information as? [String: Any],
                  let status = (information[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value else { return nil }
            return isHardened(status: status)
        }

        /// Whether a dynamic status word says valid, hardened and not debuggable.
        static func isHardened(status: UInt32) -> Bool {
            status & validFlag != 0 && status & runtimeFlag != 0 && status & (getTaskAllowFlag | debuggedFlag) == 0
        }

        static func runs(_ token: audit_token_t, cdhash: Data) -> Bool {
            guard let guest = guest(token) else { return false }
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

        /// `kSecCodeSignatureRuntime` in a signature's flags (xnu's `CS_RUNTIME`, as `codesign --options runtime` sets).
        static let signatureRuntimeFlag: UInt32 = 0x0001_0000

        static func isSignedHardened(atPath path: String) -> Bool? {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
            // Every slice's signature valid, as it is now on disk.
            guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: numericCast(kSecCSCheckAllArchitectures)), nil) == errSecSuccess else { return false }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: numericCast(kSecCSSigningInformation)), &information) == errSecSuccess,
                  let information = information as? [String: Any],
                  let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value else { return nil }
            let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            return flags & signatureRuntimeFlag != 0 && (entitlements["com.apple.security.get-task-allow"] as? Bool) != true
        }

        static func ownCdhash() -> Data? { OwnCode.cdhash() }

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
