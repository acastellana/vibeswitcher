#if canImport(Darwin)
import Foundation

// A socket's peer on the Mac: moved from VibePlatform's Sockets+Darwin.swift unchanged; `Platform.Sockets.peerUID` and
// `peerToken`, and `audit_token_t`'s `pid`, `pidVersion` and `sameImage(as:)` there, are one-line calls into these
// (`Platform.PeerToken` stays VibePlatform's name for `audit_token_t`).
extension Keep.Sockets {
    /// The user id of the process at the other end.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// The audit token of the process at the other end, as it runs now: its pid and pidversion (an exec changes the
    /// version), which Security's code checks take as the process's image. Not fixed when the connection was made
    /// (nor is LOCAL_PEERPID): it's whichever process last sent or received on the peer's socket, so it moves to a
    /// forked child that writes, and names the new image after the connector's exec.
    public static func peerToken(_ fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 ? token : nil
    }

    /// A token's pid, as libbsm's `audit_token_to_pid` reads it.
    public static func pid(_ token: audit_token_t) -> pid_t { pid_t(bitPattern: token.val.5) }

    /// A token's pidversion, as libbsm's `audit_token_to_pidversion` reads it.
    public static func pidVersion(_ token: audit_token_t) -> Int32 { Int32(bitPattern: token.val.7) }

    /// The same process image: the same pid, not exec'd since (nor a pid reused).
    public static func sameImage(_ token: audit_token_t, as other: audit_token_t) -> Bool {
        pid(token) == pid(other) && pidVersion(token) == pidVersion(other)
    }
}
#endif
