import Foundation
import Testing
import VibeCore
import VibeNode

/// The node on the Mac's design (docs/superpowers/specs/2026-11-19-v2-node-on-macos.md), step 1: the user's node is
/// built where the service manager is systemd, and refused at once elsewhere (the Mac), before any command reads or
/// runs anything; a scratch node is never refused. The pure arms run on both systems; the Mac's wiring is checked on
/// the hosted Mac by `thisSystemsAnswerIsItsManagers`, and by hand on a real Mac (docs/process/v2-mac-tasks.md).
struct NodeSystemTests {
    @Test func onlyASystemdSystemsUsersNodeIsBuilt() throws {
        #expect(NodeSystem.usersNodeRefusal(manager: .systemd) == nil)
        let mac = try #require(NodeSystem.usersNodeRefusal(manager: .launchd))
        #expect(mac == NodeSystem.macUnbuilt)
        // It says what isn't built, that the app is left alone, what does run, and where the design is.
        for words in ["isn't built for the Mac", "launchd", "~/.vibeswitcher/v2/node", "the app's ~/.vibeswitcher", "your voice", "Mac app is unchanged",
                      "scratch node", "docs/superpowers/specs/2026-11-19-v2-node-on-macos.md"] {
            #expect(mac.contains(words), "\(words)")
        }
        #expect(FileManager.default.fileExists(atPath: ServerLintTests.repo.appendingPathComponent("docs/superpowers/specs/2026-11-19-v2-node-on-macos.md").path))
        #expect(NodeSystem.refusalExitCode == 69)
    }

    @Test func thisSystemsAnswerIsItsManagers() {
        switch Platform.Service.manager {
        case .systemd:
            #expect(NodeSystem.usersNodeRefusal() == nil)
            #expect(!Platform.CodeIdentity.isAvailable)
        case .launchd:
            #expect(NodeSystem.usersNodeRefusal() == NodeSystem.macUnbuilt)
            #expect(Platform.CodeIdentity.isAvailable)
        }
    }

    /// Each command that starts, stops or acknowledges asks first, right after it knows which node it is for, and every
    /// connection to the server asks before it connects: so on the Mac no `/proc/self/exe`, `/run/user/<uid>`,
    /// `systemctl` or socket is read, run or reached for the user's node (the commands aren't run here: on the Mac
    /// that would be the user's node of the machine running the tests).
    @Test func everyCommandAsksBeforeItReadsOrRuns() throws {
        func code(_ file: String) throws -> [String] {
            ServerLintTests.code(try String(contentsOf: ServerLintTests.repo.appendingPathComponent("Sources/vibeswitcher-cli/\(file)"), encoding: .utf8))
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let gate = "if let unbuilt = context.usersNodeRefusal { return Say.unbuilt(unbuilt) }"
        for (file, function) in [("Start.swift", "static func run(_ arguments: [String]) -> Int32 {"),
                                 ("Stop.swift", "static func run(_ arguments: [String]) -> Int32 {"),
                                 ("Status.swift", "static func acknowledge() -> Int32 {")] {
            let lines = try code(file)
            let start = try #require(lines.firstIndex(of: function), "\(file): \(function)")
            let context = try #require(lines[start...].firstIndex(of: "let context = NodeContext.current()"), "\(file)")
            #expect(lines[context + 1] == gate, "\(file): \(lines[context + 1])")
        }
        let client = try code("NodeClient.swift")
        let connect = try #require(client.firstIndex { $0.hasPrefix("static func connect(_ context: NodeContext") })
        #expect(client[connect + 1] == "if let unbuilt = context.usersNodeRefusal { return .failure(.notRunning(unbuilt)) }", "\(client[connect + 1])")
        #expect(client.contains("var usersNodeRefusal: String? { isScratch ? nil : NodeSystem.usersNodeRefusal() }"))
    }
}
