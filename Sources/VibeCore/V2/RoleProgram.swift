import Foundation

/// The program a lead's workers and verifiers run (the engine plan's EN-D13), as the lead's tool server picks it. On
/// Linux the node's engine starts each lead by the absolute path `claude` resolved to, and gives the lead's session that
/// path as `VIBESWITCHER_CLAUDE`; the tool server then starts its roles with it and reads neither the settings'
/// `claudeCommand` nor the launch presets, files under `~/.vibeswitcher` any worker can write (which would otherwise pick
/// the program every worker and verifier runs with its role's grant). One hook in `vibeswitcher-mcp`'s
/// `command(_:root:)` asks `claude(for:)` first. The Mac: nil, so the settings and presets pick it, as today.
public enum RoleProgram {
    /// The variable the lead's session carries the program in.
    public static let variable = "VIBESWITCHER_CLAUDE"

    /// The command line (one shell-quoted absolute path) `agent`'s roles start with: on Linux (`enabled`), for Claude,
    /// with `variable` set to an absolute path in `environment`. Nil otherwise: the caller reads its settings.
    public static func claude(for agent: Agent, environment: [String: String] = ProcessInfo.processInfo.environment,
                              enabled: Bool = !Platform.CodeIdentity.isAvailable) -> String? {
        guard enabled, agent == .claude, let path = environment[variable], path.hasPrefix("/") else { return nil }
        return RecentProjects.shellQuote(path)
    }
}
