#if canImport(Darwin)
import Foundation
import Security

// The dynamic check by audit token: moved from VibePlatform's CodeIdentity+Darwin.swift (`Platform.CodeIdentity.System`)
// unchanged; its old names there are one-line calls into these. The rest of `CodeIdentity` (a file's cdhash, its own,
// architectures) stays in VibePlatform.
extension Keep.CodeIdentity {
    /// The guest the audit token names, as Security finds it (it refuses a token whose pid exec'd since).
    public static func guest(_ token: audit_token_t) -> SecCode? {
        var token = token
        let audit = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit] as CFDictionary, [], &guest) == errSecSuccess else { return nil }
        return guest
    }

    // The dynamic status word's flags (xnu's <kern/cs_blobs.h>): valid, the Hardened Runtime, get-task-allow, and
    // a debugger attached.
    public static let validFlag: UInt32 = 0x0000_0001
    public static let getTaskAllowFlag: UInt32 = 0x0000_0004
    public static let runtimeFlag: UInt32 = 0x0001_0000
    public static let debuggedFlag: UInt32 = 0x1000_0000

    /// Whether the process `token` names runs under the Hardened Runtime as it runs now, and can't be debugged; nil
    /// when it can't be told.
    public static func isHardened(_ token: audit_token_t) -> Bool? {
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
    public static func isHardened(status: UInt32) -> Bool {
        status & validFlag != 0 && status & runtimeFlag != 0 && status & (getTaskAllowFlag | debuggedFlag) == 0
    }

    /// The process `token` names, as it runs now, is valid code whose cdhash is `cdhash`.
    public static func runs(_ token: audit_token_t, cdhash: Data) -> Bool {
        guard let guest = guest(token) else { return false }
        let hex = cdhash.map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("cdhash H\"\(hex)\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        // Dynamic validity: the kernel still holds the process's code valid, and it's the code the requirement names.
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
}
#endif
