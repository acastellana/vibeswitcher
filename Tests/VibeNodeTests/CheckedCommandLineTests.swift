import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeNode

/// The node's own command line, as the unit and the LaunchAgent start it (`NodeUnit.execStart`, `NodeAgent`'s
/// `ProgramArguments`), is in a checked node's grammar (`HostImages.CheckedCommandLine`, the re-check's I1): step 5 can
/// start it as it is. Both systems.
struct CheckedCommandLineTests {
    @Test func theUnitsCommandLineIsInTheGrammar() {
        let commit = String(repeating: "a", count: 40)
        let started = NodeUnit.execStart(prefix: "/Users/u/.vibeswitcher/v2/builds", commit: commit)
        guard case .success(let line) = HostImages.CheckedCommandLine.parse(started) else {
            Issue.record("the unit's command line isn't a checked node's: \(started)")
            return
        }
        #expect(line.nodeRoot == "/Users/u/.vibeswitcher/v2/builds/" + commit && line.server == line.nodeRoot + "/bin/vibeswitcher-server" && line.keeper == nil)
    }
}
