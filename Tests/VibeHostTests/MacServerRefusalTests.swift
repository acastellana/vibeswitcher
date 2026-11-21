import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// The review of 2026-11-21 (its first HIGH): on the Mac a server child's connections are the app's, so `--server` is
/// refused for the user's host and for any host on the account's own locks (the app's and the node root's, by path or
/// by file), until the Mac's node start is checked (`HostImages.isCheckedMacNode`, never yet); a scratch host on a lock
/// of its own may run one. No Mac host is a node host meanwhile. Linux: never refused here (its child is checked as
/// `HostImages.load` says). Both systems.
struct MacServerRefusalTests {
    let scratch = Scratch()

    @Test func onlyAScratchHostOnTheMacRunsAServerChild() throws {
        let home = scratch.url("mac-server-home")
        let appRoot = home.appendingPathComponent(".vibeswitcher")
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
        let appLock = appRoot.appendingPathComponent("host.lock").path
        FileManager.default.createFile(atPath: appLock, contents: nil)
        let nodeLock = (Platform.Service.nodeRoot(accountHome: home.path) as NSString).appendingPathComponent("host.lock")
        let own = home.appendingPathComponent("scratch-host.lock").path
        FileManager.default.createFile(atPath: own, contents: nil)
        // Another name for the app's lock: a link to it.
        let linked = home.appendingPathComponent("linked.lock").path
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: appLock)
        let refusal = { (lock: String, owns: Bool) in HostImages.macServerRefusal(lockPath: lock, ownsLaunchers: owns, accountHome: home.path) }
        #expect(!HostImages.isCheckedMacNode)
        guard Platform.CodeIdentity.isAvailable else {
            for lock in [appLock, nodeLock, own, linked] { #expect(refusal(lock, true) == nil && refusal(lock, false) == nil, "\(lock)") }
            return
        }
        #expect(refusal(own, true)?.contains("user's host") == true)
        for lock in [appLock, nodeLock, linked, appRoot.path + "/./host.lock"] {
            #expect(refusal(lock, false)?.contains("the account's own") == true, "\(lock)")
        }
        #expect(refusal(own, false) == nil)
        #expect(HostImages.macServerRefusal(lockPath: own, ownsLaunchers: false, accountHome: nil) != nil)
    }
}
