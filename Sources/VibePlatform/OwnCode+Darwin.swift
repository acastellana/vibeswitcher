#if canImport(Darwin)
import Foundation
import Security

/// The cdhash of the code this process runs (`Platform.CodeIdentity.ownCdhash`): self-contained (Foundation and
/// Security only), so `OwnCdhashTests` builds this very file into a probe whose own file it swaps while it runs.
enum OwnCode {
    static func cdhash() -> Data? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(me, to: SecStaticCode.self), [], &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }
        return information[kSecCodeInfoUnique as String] as? Data
    }
}
#endif
