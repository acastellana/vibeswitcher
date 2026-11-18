import Foundation
import Testing

/// The session sandbox's relays and porter (its plan's SB4) run before anything in the tool server's and the hook's
/// mains reads a path: inside a box there is no `~/.vibeswitcher`, no host socket and no user settings to read, and a
/// helper the porter started must have its session's connector before any call to the host. So in each main the first
/// statements are those hooks, with only the session sandbox's other first-statement hooks (`BranchRun`, SB6) among
/// them.
struct MCPLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The calls a main's first statements may be, before its own hooks are all in.
    static let firstStatements = ["DoorRelay.runIfConfined(", "Porter.runIfAsked(", "BranchRun.execIfLaunched("]

    /// The first statements of `text` (a main) that aren't imports or comments, up to and with the last of `hooks`;
    /// nil when one of `hooks` isn't among its first statements, or something else comes before the last of them.
    static func problems(_ text: String, hooks: [String]) -> [String] {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") && !$0.hasPrefix("import ") }
        var missing = hooks
        var problems: [String] = []
        for line in lines {
            guard !missing.isEmpty else { break }
            guard let call = firstStatements.first(where: { line.hasPrefix($0) }) else {
                problems.append("before \(missing.joined(separator: ", ")): \(line)")
                break
            }
            missing.removeAll { $0 == call }
        }
        return problems + missing.map { "not among the first statements: \($0)" }
    }

    @Test func theRelayAndThePorterComeBeforeAnythingReadsAPath() throws {
        let mcp = try String(contentsOf: Self.repo.appendingPathComponent("Sources/vibeswitcher-mcp/main.swift"), encoding: .utf8)
        #expect(Self.problems(mcp, hooks: ["DoorRelay.runIfConfined(", "Porter.runIfAsked("]) == [])
        let hook = try String(contentsOf: Self.repo.appendingPathComponent("Sources/vibeswitcher-hook/main.swift"), encoding: .utf8)
        #expect(Self.problems(hook, hooks: ["DoorRelay.runIfConfined("]) == [])
        // And the hook finds its agent from its caller, never from itself alone.
        // (`HookCaller.read` gives the ancestors it read while the caller was held; the main reads none itself.)
        #expect(hook.contains("HookOwner.lineage(caller.ancestors,") && hook.contains("let caller = HookCaller.read(CommandLine.arguments)")
            && !hook.contains("ProcessTable.ancestors(of:") && !hook.contains("ProcessTable.info(pid: caller)"))
    }

    @Test func theRuleKnowsAHookOutOfPlace() {
        let good = "import Foundation\n// a comment\nDoorRelay.runIfConfined(x)\nPorter.runIfAsked(y)\nlet a = VibePaths.root\n"
        #expect(Self.problems(good, hooks: ["DoorRelay.runIfConfined(", "Porter.runIfAsked("]) == [])
        let late = "import Foundation\nlet a = VibePaths.root\nDoorRelay.runIfConfined(x)\nPorter.runIfAsked(y)\n"
        #expect(Self.problems(late, hooks: ["DoorRelay.runIfConfined(", "Porter.runIfAsked("]).first?.hasPrefix("before ") == true)
        let gone = "import Foundation\nDoorRelay.runIfConfined(x)\nlet a = 1\n"
        #expect(Self.problems(gone, hooks: ["DoorRelay.runIfConfined(", "Porter.runIfAsked("]).count == 2)
    }
}
