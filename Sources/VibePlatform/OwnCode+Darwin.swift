#if canImport(Darwin)
import Foundation

/// xnu's `csops(2)`: not in the SDK's public headers, so declared here (libsystem_kernel exports it).
@_silgen_name("csops") private func vibeCsops(_ pid: pid_t, _ ops: UInt32, _ addr: UnsafeMutableRawPointer?, _ size: Int) -> Int32

/// The cdhash of the code this process runs (`Platform.CodeIdentity.ownCdhash`), as the kernel holds it for the running
/// process (`csops(CS_OPS_CDHASH)`: the main executable's running slice), never read from the file now at the process's
/// path: a file renamed over that path after the start changes nothing here (the review of 2026-11-25, F1; Security's
/// static signing information for `SecCodeCopySelf` described the file found by path). Self-contained, so
/// `OwnCdhashTests` builds this very file into a probe whose own file it swaps while it runs.
enum OwnCode {
    /// `CS_OPS_CDHASH` (xnu's <sys/codesign.h>).
    static let cdhashOperation: UInt32 = 5

    static func cdhash() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 20)
        guard vibeCsops(getpid(), cdhashOperation, &bytes, bytes.count) == 0, bytes.contains(where: { $0 != 0 }) else { return nil }
        return Data(bytes)
    }
}
#endif
