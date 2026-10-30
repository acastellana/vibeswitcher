import Foundation

/// What one click can install of what `LaunchPreflight` finds missing, and the exact command it runs: Apple's Command
/// Line Tools (which bring git) through Apple's own installer, and Claude Code through Anthropic's official one. Each
/// command is fixed here, whole: nothing in it comes from the Mac, a preset or a message, and it's shown before it runs.
/// The rest (a missing shell, a helper, Codex, a git that fails) can only be explained.
public enum ToolInstall: Equatable, Sendable {
    case commandLineTools
    case claudeCode

    /// What the Command Line Tools' install runs, without a shell: it opens Apple's installer dialog and returns.
    public static let commandLineToolsCommand = ["/usr/bin/xcode-select", "--install"]
    /// Anthropic's official installer for Claude Code, over https only.
    public static let claudeCodeURL = "https://claude.ai/install.sh"
    /// What Claude Code's install session runs (in the login shell, as a session's command is).
    public static let claudeCodeCommand = "curl -fsSL \(claudeCodeURL) | bash"
    /// The session it runs in.
    public static let claudeCodeSession = "Install Claude Code"

    /// The install to offer for `problem`: the first missing piece one can fix (the Command Line Tools first: git is
    /// looked at last, but Claude Code's installer needs no git). A start that's still missing something after it asks again.
    public static func offer(for problem: LaunchPreflight.Problem) -> ToolInstall? {
        if problem.missing.contains(where: { ToolInstall.commandLineTools.fixes($0) }) { return .commandLineTools }
        if problem.missing.contains(where: { ToolInstall.claudeCode.fixes($0) }) { return .claudeCode }
        return nil
    }

    /// Whether this install is what `missing` needs.
    public func fixes(_ missing: LaunchPreflight.Missing) -> Bool {
        switch (self, missing) {
        // A developer folder without git is fixed by the same installer; a missing /usr/bin/git (part of macOS) isn't.
        case (.commandLineTools, .commandLineTools), (.commandLineTools, .gitStub): return true
        // Only the bare command: one the preset names by a path is where the preset says, not where the installer puts it.
        case (.claudeCode, .agent(let program, _)): return program == "claude"
        default: return false
        }
    }

    /// Whether a look after the install finds none of what it fixes missing (nil: nothing is).
    public func done(_ problem: LaunchPreflight.Problem?) -> Bool {
        !(problem?.missing.contains(where: fixes) ?? false)
    }

    /// The command, exactly as it runs.
    public var shown: String {
        switch self {
        case .commandLineTools: return Self.commandLineToolsCommand.joined(separator: " ")
        case .claudeCode: return Self.claudeCodeCommand
        }
    }

    /// What's being installed.
    public var name: String {
        switch self {
        case .commandLineTools: return "Apple's Command Line Tools"
        case .claudeCode: return "Claude Code"
        }
    }

    /// The alert offering it: what's missing, then the command it runs and where it comes from. `what`: what waits on
    /// it ("the lead").
    public func offer(_ problem: LaunchPreflight.Problem, what: String = "the lead") -> (title: String, text: String) {
        let how: String
        switch self {
        case .commandLineTools:
            how = "Install runs\n\n\(shown)\n\nwhich opens Apple's own installer (the tools come from Apple's software update). "
                + "VibeSwitcher waits for it to finish, then starts \(what)."
        case .claudeCode:
            how = "Install runs Anthropic's official installer, from \(Self.claudeCodeURL), in a new session, “\(Self.claudeCodeSession)”, "
                + "where you see its output:\n\n\(shown)\n\nWhen it's done, VibeSwitcher starts \(what)."
        }
        let mine = problem.missing.filter(fixes), rest = problem.missing.filter { !fixes($0) }
        let said = mine.map(LaunchPreflight.text).first ?? ""
        var text = "\(what.prefix(1).uppercased() + what.dropFirst()) wasn't started. \(Self.unprompted(said))\n\n\(how)"
        if !rest.isEmpty {
            text += "\n\nAlso missing: " + rest.map { LaunchPreflight.title($0) + " " + LaunchPreflight.text($0) }.joined(separator: "\n\n")
        }
        return (mine.first.map(LaunchPreflight.title) ?? problem.title, text)
    }

    /// A miss's text without its "run this in Terminal" advice: Install does that here.
    static func unprompted(_ text: String) -> String {
        for advice in [" Run xcode-select --install in Terminal", " Install Claude Code (claude.com/claude-code)"] {
            if let range = text.range(of: advice) { return String(text[..<range.lowerBound]) }
        }
        return text
    }

    public static let buttons = ["Install", "Cancel"]
}
