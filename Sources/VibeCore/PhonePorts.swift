import Foundation

/// Phone Access's ports, in one place. The app's server listens on `server` (loopback) behind
/// `tailscale serve` on `https`; each dev-page preview slot has its own loopback proxy right after the
/// server and its own public port right after `https`.
public enum PhonePorts {
    public static let server: UInt16 = 47823
    public static let https = 8443
    public static let previewSlots = 4

    public static func previewLocal(_ slot: Int) -> UInt16 { server + 1 + UInt16(slot) }
    public static func previewPublic(_ slot: Int) -> Int { https + 1 + slot }
}
