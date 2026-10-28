import Darwin
import Foundation
import Security

/// Whether a process runs the app's code, told by its code signature and not by its path: a process can exec the
/// app's binary under a pid that connected as something else, and a path says nothing of what was loaded from it.
/// Builds are ad-hoc signed (no team), so the identity is the code directory hash.
enum AppCode {
    /// The process `token` names, as it runs now (Security refuses a token whose pid exec'd since), is valid code
    /// whose cdhash is the one of the code at `executable`.
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

    /// `struct proc_archinfo` (xnu's sys/proc_info_private.h): the CPU type and subtype a process runs. Not in every
    /// SDK's public headers (the Command Line Tools' has neither it nor `PROC_PIDARCHINFO`), so declared here.
    struct Architecture: Equatable {
        var cpuType: cpu_type_t = 0
        var cpuSubtype: cpu_subtype_t = 0
    }

    /// `PROC_PIDARCHINFO`, the `proc_pidinfo` flavor that answers an `Architecture`.
    static let pidArchitectureFlavor: Int32 = 19

    /// The architecture the process `pid` runs (the slice of a universal binary it was started from).
    static func architecture(of pid: pid_t) -> Architecture? {
        var architecture = Architecture()
        let size = Int32(MemoryLayout<Architecture>.size)
        guard proc_pidinfo(pid, pidArchitectureFlavor, 0, &architecture, size) == size else { return nil }
        return architecture
    }

    /// The cdhash of the code on disk at `path` (for a universal binary, this machine's architecture).
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
