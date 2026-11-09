import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// An install's write of the hook binary (`HookBinary.atLaunch`), against the real vault: the 2026-11-08 13:34 install
/// launched, wrote the binary before the app had read its Keychain key, and the host refused the seal; a lead's look in
/// the 84 s the Keychain took held the new binary and refused a passing merge.
struct HookBinaryLaunchTests {
    private let scratch = Scratch()

    /// Whether the app's key has been read, which is what makes the host take its connection for the app's.
    final class Key: @unchecked Sendable {
        private let lock = NSLock()
        private var read = false
        func markRead() { lock.withLock { read = true } }
        var caller: LeadVault.Caller { lock.withLock { read ? .app : .unknown } }
    }

    struct Install {
        let home: String
        let root: String
        let target: URL
        let source: URL
        let key: Key
        let app: LeadVault
        let lead: LeadVault
    }

    /// A Mac with the old binary sealed and a lead running, and a new build's binary ready to go in.
    func install() throws -> Install {
        let home = scratch.url("home").path
        let root = scratch.url("repo").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let target = URL(fileURLWithPath: home + "/.vibeswitcher/bin/vibeswitcher-hook")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old build".utf8).write(to: target)
        let source = scratch.url("bundled-hook")
        try Data("new build".utf8).write(to: source)

        let book = LeadVault.Book()
        book.configHome = home
        let key = Key()
        let folder = scratch.url("vault")
        let app = book.vault(folder: folder, as: { key.caller })
        let lead = book.vault(folder: folder, as: { .session("LEAD") })
        // Started by an earlier launch, whose key was read: another folder, so its writes are its own.
        let earlier = book.vault(folder: scratch.url("earlier"), as: { .app })
        try earlier.bind(try earlier.startLead(root: root, branch: "main"), root: root, session: "LEAD")
        #expect(try lead.checkConfig(root: root) == LeadVault.ConfigCheck())
        return Install(home: home, root: root, target: target, source: source, key: key, app: app, lead: lead)
    }

    func launch(_ mac: Install, whileTheKeyIsRead: () -> Void = {}) {
        HookBinary.atLaunch(connect: {
            whileTheKeyIsRead()
            mac.key.markRead()
        }, background: { $0() }, replace: {
            HookBinary.sync(vault: mac.app, home: mac.home, source: mac.source, target: mac.target)
            mac.app.sealAppWrites()
        })
    }

    @Test func aLookRightAfterTheLaunchHoldsNothing() throws {
        let mac = try install()
        launch(mac)
        #expect(try Data(contentsOf: mac.target) == Data("new build".utf8))
        #expect(try mac.lead.checkConfig(root: mac.root) == LeadVault.ConfigCheck())
        #expect(mac.lead.heldConfig(root: mac.root).isEmpty)
    }

    /// The Keychain's wait: the look that held the 13:34 install's merge.
    @Test func aLookWhileTheKeyIsBeingReadHoldsNothing() throws {
        let mac = try install()
        var during: LeadVault.ConfigCheck?
        launch(mac) { during = try? mac.lead.checkConfig(root: mac.root) }
        #expect(during == LeadVault.ConfigCheck())
        #expect(try mac.lead.checkConfig(root: mac.root) == LeadVault.ConfigCheck())
    }

    /// Nothing is left beside the binary in the sealed folder, and the temporary file goes too.
    @Test func theWriteLeavesOnlyTheBinary() throws {
        let mac = try install()
        launch(mac)
        let folder = mac.target.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["vibeswitcher-hook"])
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent(".vibeswitcher-hook.tmp").path))
    }
}
