import Foundation
import Testing
@testable import VibeCore

/// The update check's list of what the build reads, against build-app.sh itself (in a file of its own: it reads this
/// checkout's script, and AppUpdateTests clones scratch repositories, which AgentExportLint allows only in a file that
/// doesn't locate the checkout).
struct AppUpdateBuildPathsTests {
    /// The list is build-app.sh's own `source_state` list, kept as one.
    @Test func theBuildPathsAreBuildAppShSourceState() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: repo.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.contains("git ls-tree HEAD --") })
        let listed = line.components(separatedBy: "HEAD --").last!.components(separatedBy: " 2>").first!.split(separator: " ").map(String.init)
        #expect(listed == AppUpdate.buildPaths)
    }
}
