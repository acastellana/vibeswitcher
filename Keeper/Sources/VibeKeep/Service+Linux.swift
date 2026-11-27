#if os(Linux)
import Foundation

// Linux (moved from VibePlatform's Service+Linux.swift, unchanged).
extension Keep.Service {
    // No such record on Linux: its checks are the unit's cgroup and the sealed copies (unchanged).
    public static func nodePinsRecord(uid: uid_t) -> [String]? { nil }
}
#endif
