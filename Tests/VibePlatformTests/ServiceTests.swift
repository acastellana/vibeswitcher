import Foundation
import Testing
import VibePlatform

/// `Platform.Service`: each system names its own manager, log and tools, and never the other's (the node on the Mac's
/// design, 2026-11-19). Runs on both systems; the arm for the system it runs on is checked, the Mac's on the hosted
/// Mac (and, for what a real Mac's launchd says, by hand: docs/process/v2-mac-tasks.md). Nothing here runs a tool.
struct ServiceTests {
    @Test func eachSystemNamesItsOwnManagerLogAndToolsOnly() {
        let uid = getuid()
        if Platform.CodeIdentity.isAvailable {
            // The Mac.
            #expect(Platform.Service.manager == .launchd)
            #expect(Platform.Service.log == .unifiedLog)
            #expect(Platform.Service.launchctl == "/bin/launchctl")
            #expect(Platform.Service.unifiedLogTool == "/usr/bin/log")
            #expect(Platform.Service.systemctl == nil && Platform.Service.journalctl == nil)
            #expect(Platform.Service.runtimeFolder(uid: uid) == nil)
        } else {
            // Linux: the paths the node has always run, and the runtime folder from the uid.
            #expect(Platform.Service.manager == .systemd)
            #expect(Platform.Service.log == .journal)
            #expect(Platform.Service.systemctl == "/usr/bin/systemctl")
            #expect(Platform.Service.journalctl == "/usr/bin/journalctl")
            #expect(Platform.Service.launchctl == nil && Platform.Service.unifiedLogTool == nil)
            #expect(Platform.Service.runtimeFolder(uid: uid) == "/run/user/\(uid)")
            #expect(Platform.Service.runtimeFolder(uid: 1234) == "/run/user/1234")
        }
        // The node's root under the account's home: the account's own folder on Linux, a folder of its own beside the
        // app's on the Mac (the node on the Mac's step 2).
        if Platform.CodeIdentity.isAvailable {
            #expect(Platform.Service.nodeRootFolder == ".vibeswitcher/v2/node")
            #expect(!Platform.Service.nodeRootIsTheAccountRoot)
            #expect(Platform.Service.nodeRoot(accountHome: "/Users/someone") == "/Users/someone/.vibeswitcher/v2/node")
        } else {
            #expect(Platform.Service.nodeRootFolder == ".vibeswitcher")
            #expect(Platform.Service.nodeRootIsTheAccountRoot)
            #expect(Platform.Service.nodeRoot(accountHome: "/home/someone") == "/home/someone/.vibeswitcher")
        }
        #expect(Platform.Service.nodeRoot(accountHome: "/home/someone/") == "/home/someone/" + Platform.Service.nodeRootFolder)
        // Every tool named is an absolute path, never a name to look up on PATH.
        let named = [Platform.Service.systemctl, Platform.Service.journalctl, Platform.Service.launchctl, Platform.Service.unifiedLogTool].compactMap { $0 }
        #expect(named.count == 2 && named.allSatisfy { $0.hasPrefix("/") }, "\(named)")
    }
}
