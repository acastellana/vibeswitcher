import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The app's diagnostics in ~/.vibeswitcher (focus-debug.json, sidebar-debug.json) are private: 0600 under umask 022,
/// in the 0700 folder (docs/eval/open-2026-10-19.md, F-F1). The tests' VibeSwitcher folder is a scratch one.
@Suite(.serialized)
struct PrivateDebugFilesTests {
    static func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    @Test func theFocusLogIsPrivate() async throws {
        VibePaths.ensurePrivateDirectories()
        let file = FocusLog.file
        try? FileManager.default.removeItem(at: file)
        let old = umask(0o022)
        defer { umask(old) }
        FocusLog.record(tty: "ttys999", source: "test", steps: ["one"])
        // Written on its own queue.
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(Self.mode(file) == 0o600)
        #expect(Self.mode(VibePaths.root) == 0o700)
    }

    @Test func theSidebarLogIsPrivate() throws {
        VibePaths.ensurePrivateDirectories()
        let file = VibePaths.root.appendingPathComponent("sidebar-debug.json")
        try? FileManager.default.removeItem(at: file)
        let old = umask(0o022)
        defer { umask(old) }
        SidebarController.writeDebug(["updatedAt": "now", "edgeHits": 1])
        #expect(Self.mode(file) == 0o600)
    }
}
