#if canImport(Darwin)
import Foundation

// The Mac (moved from VibePlatform's Service+Darwin.swift, unchanged).
extension Keep.Service {
    // The node's record of its builds' cdhashes, root's to write (the node on the Mac's design, "The anchor").
    public static func nodePinsRecord(uid: uid_t) -> [String]? { ["Library", "Application Support", "VibeSwitcher", "node-\(uid).pins"] }
}
#endif
