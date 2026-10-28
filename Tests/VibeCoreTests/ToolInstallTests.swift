import Foundation
import Testing
@testable import VibeCore

/// What one click installs of what `LaunchPreflight` finds missing (`ToolInstall`): the commands, fixed in code, and
/// what each fixes. Nothing here runs anything.
struct ToolInstallTests {
    static let noClaude = LaunchPreflight.Missing.agent(program: "claude", shell: "/bin/zsh")

    @Test func theCommandsAreFixedAndOnlyTheOfficialHTTPSURL() {
        #expect(ToolInstall.commandLineToolsCommand == ["/usr/bin/xcode-select", "--install"])
        #expect(ToolInstall.claudeCodeURL == "https://claude.ai/install.sh")
        #expect(ToolInstall.claudeCodeCommand == "curl -fsSL https://claude.ai/install.sh | bash")
        #expect(ToolInstall.claudeCodeSession == "Install Claude Code")
        // What's shown is exactly what runs.
        #expect(ToolInstall.commandLineTools.shown == "/usr/bin/xcode-select --install")
        #expect(ToolInstall.claudeCode.shown == ToolInstall.claudeCodeCommand)
        // One URL, https, and nothing after bash: no flags or arguments for it.
        let urls = ToolInstall.claudeCodeCommand.split(separator: " ").filter { $0.contains("://") }
        #expect(urls == ["https://claude.ai/install.sh"])
        #expect(ToolInstall.claudeCodeCommand.hasSuffix("| bash"))
    }

    @Test func eachMissingPieceIsOfferedTheInstallThatFixesItOrNone() {
        typealias Problem = LaunchPreflight.Problem
        #expect(ToolInstall.offer(for: Problem(missing: [.commandLineTools])) == .commandLineTools)
        #expect(ToolInstall.offer(for: Problem(missing: [.gitStub(developer: "/Library/Developer/CommandLineTools")])) == .commandLineTools)
        #expect(ToolInstall.offer(for: Problem(missing: [Self.noClaude])) == .claudeCode)
        // A new Mac without both: Apple's tools first; the start offers Claude Code once they're there.
        #expect(ToolInstall.offer(for: Problem(missing: [Self.noClaude, .commandLineTools])) == .commandLineTools)
        // Only explained: a helper, a shell, git that fails or isn't at its path, Codex, a claude the preset names by path.
        for missing: LaunchPreflight.Missing in [.helper(name: "vibeswitcher-mcp", path: "/App/vibeswitcher-mcp"), .shell("/bin/nosh"),
                                                 .gitFails("license"), .git("/usr/bin/git"), .agent(program: "codex", shell: "/bin/zsh"),
                                                 .agent(program: "/opt/claude/bin/claude", shell: "/bin/zsh")] {
            #expect(ToolInstall.offer(for: Problem(missing: [missing])) == nil, "\(missing)")
        }
        // Done: none of what it fixes is missing, whatever else is.
        #expect(ToolInstall.commandLineTools.done(nil))
        #expect(ToolInstall.commandLineTools.done(Problem(missing: [Self.noClaude])))
        #expect(!ToolInstall.commandLineTools.done(Problem(missing: [.commandLineTools])))
        #expect(!ToolInstall.claudeCode.done(Problem(missing: [Self.noClaude])))
    }

    @Test func theOfferShowsTheExactCommandAndWhereItComesFrom() {
        let tools = ToolInstall.commandLineTools.offer(LaunchPreflight.Problem(missing: [.commandLineTools]))
        #expect(tools.title == "git needs Apple's Command Line Tools.")
        #expect(tools.text.hasPrefix("The lead wasn't started. They aren't installed on this Mac (xcode-select -p names no developer folder).\n\n"))
        #expect(tools.text.contains("\n\n/usr/bin/xcode-select --install\n\n"))
        #expect(tools.text.contains("Apple's own installer"))
        #expect(!tools.text.contains("in Terminal"))

        let claude = ToolInstall.claudeCode.offer(LaunchPreflight.Problem(missing: [Self.noClaude, .helper(name: "h", path: "/x/h")]))
        #expect(claude.title == "Claude Code isn't installed.")
        #expect(claude.text.contains("\n\ncurl -fsSL https://claude.ai/install.sh | bash\n\n"))
        #expect(claude.text.contains("Anthropic's official installer, from https://claude.ai/install.sh"))
        #expect(claude.text.contains("“Install Claude Code”"))
        // What it doesn't fix is still said.
        #expect(claude.text.contains("Also missing: VibeSwitcher is missing its h."))
        #expect(ToolInstall.buttons == ["Install", "Cancel"])
    }
}
