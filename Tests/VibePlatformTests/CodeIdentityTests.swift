import Foundation
import Testing
@testable import VibePlatform

/// `Platform.CodeIdentity`'s checks of a running process by the cdhash read before and by its Hardened Runtime (the
/// node on the Mac's step 3: the server child's connector on the Mac takes a request only from the child it started,
/// running the server's code, hardened). Linux has neither: false and nil. On the Mac the process checked is this
/// one, named by its audit token as a socket's peer names it; the hosted Mac runs it (docs/process/v2-mac-tasks.md).
struct CodeIdentityTests {
    /// This process's own token, as the other end of a pair it just wrote on reads it (`LOCAL_PEERTOKEN` names the last
    /// process that used the peer's socket).
    static func ownToken() throws -> Platform.PeerToken? {
        let (mine, theirs) = try #require(Platform.Sockets.pair(type: Platform.Sockets.stream))
        defer { Sys.close(mine); Sys.close(theirs) }
        Platform.Sockets.enableCredentials(theirs)
        var byte = UInt8(ascii: "t")
        try #require(Platform.Sockets.send(mine, &byte, 1) == 1)
        return withUnsafeMutableBytes(of: &byte) { Platform.Sockets.receive(theirs, into: $0) }.sender
    }

    @Test func aProcessRunsTheCodeWhoseCdhashWasReadBefore() throws {
        let own = try #require(Bundle.main.executablePath)
        let token = try #require(try Self.ownToken())
        guard Platform.CodeIdentity.isAvailable else {
            #expect(!Platform.CodeIdentity.runs(token, cdhash: Data(repeating: 1, count: 20)))
            #expect(Platform.CodeIdentity.isHardened(token) == nil)
            #expect(Platform.CodeIdentity.cdhash(atPath: own) == nil)
            return
        }
        let cdhash = try #require(Platform.CodeIdentity.cdhash(atPath: own, architecture: Platform.CodeIdentity.architecture(of: getpid())))
        #expect(Platform.CodeIdentity.runs(token, cdhash: cdhash))
        #expect(Platform.CodeIdentity.runs(token, executable: own))
        var other = cdhash
        other[0] ^= 0xff
        #expect(!Platform.CodeIdentity.runs(token, cdhash: other))
        // Whether this runner is hardened is Apple's or the toolchain's to say: it can be told.
        #expect(Platform.CodeIdentity.isHardened(token) != nil)
    }

    #if canImport(Darwin)
    /// The dynamic status word: valid and hardened, and neither debuggable nor debugged.
    @Test func hardenedIsValidRuntimeAndNotDebuggable() {
        typealias System = Platform.CodeIdentity.System
        let valid = System.validFlag, runtime = System.runtimeFlag
        #expect(System.isHardened(status: valid | runtime))
        #expect(System.isHardened(status: valid | runtime | 0x0000_0200))
        #expect(!System.isHardened(status: runtime), "not valid")
        #expect(!System.isHardened(status: valid), "no Hardened Runtime")
        #expect(!System.isHardened(status: valid | runtime | System.getTaskAllowFlag), "get-task-allow")
        #expect(!System.isHardened(status: valid | runtime | System.debuggedFlag), "debugged")
    }
    #endif
}
