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
        guard let cdhash = cdhash(atPath: executable) else { return false }
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

    /// The cdhash of the code on disk at `path` (for a universal binary, this machine's architecture).
    static func cdhash(atPath path: String) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }
        return information[kSecCodeInfoUnique as String] as? Data
    }
}
