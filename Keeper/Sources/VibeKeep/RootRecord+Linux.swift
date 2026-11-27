#if os(Linux)
import Foundation

extension Keep.Files {
    /// Linux: false. Nothing on Linux reads a root-owned record (`Platform.Service.nodePinsRecord` is nil there).
    public static func hasExtendedACL(_ fd: Int32) -> Bool? { false }
}
#endif
