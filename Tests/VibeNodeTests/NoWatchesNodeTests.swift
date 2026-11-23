import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A node whose processes get no inotify instance (the user's 128 all taken: `--test-no-inotify` on its host and
/// server) comes up as one with them does, says so once, and counts its unmade watches in `status --health`.
struct NoWatchesNodeTests {
    private let scratch = Scratch()

    @Test(NodeTraits.linuxOnly)
    func aNodeWithoutWatchesComesUpAndSaysSo() async throws {
        var times: [String] = []
        if ProcessInfo.processInfo.environment["VIBESWITCHER_UP_TIMES"] == "1" {
            for round in 0..<6 {
                let started = MacTime.real.awake()
                let timed = try await ScratchNode(scratch, noInotify: round % 2 == 0)
                times.append("\(round % 2 == 0 ? "without" : "with") \(String(format: "%.2f", MacTime.real.awake() - started))")
                timed.stop()
            }
            print("up times: \(times.joined(separator: ", "))")
        }
        let node = try await ScratchNode(scratch, noInotify: true)
        defer { node.stop() }
        #expect(node.said.contains("a file watch couldn't be made"), "\(node.said)")
        let health = try await node.run(["status", "--health"])
        #expect(health.output.contains("watches couldn't be made: changes are seen at the next housekeeping")
                    || health.output.contains("watch couldn't be made: changes are seen at the next housekeeping"), "\(health.output)")
    }
}
