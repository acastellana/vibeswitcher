import Foundation
import Testing
@testable import VibeCore

/// The program a lead's workers and verifiers run (`RoleProgram`, the engine plan's EN-D13): on Linux the lead's
/// resolved `claude` (`VIBESWITCHER_CLAUDE`), whatever a worker-writable setting names; on the Mac today's, from the
/// settings and presets (`RoleProgram` answers nil, and `vibeswitcher-mcp`'s `command(_:root:)` reads them).
struct RoleProgramTests {
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's: the Mac's roles run what its settings name"))
    func aWorkersProgramIsTheLeadsResolvedClaudeNotTheSettings() {
        // The settings and presets a worker could write aren't read at all: `vibeswitcher-mcp` asks this first, and the
        // tool server's own case is `ServerTests.aStopWhileALeadSpawnsStillEndsTheHost` (its worker runs this path).
        let resolved = "/home/someone/.local/share/claude/versions/9.9.9"
        let environment = [RoleProgram.variable: resolved]
        #expect(RoleProgram.claude(for: .claude, environment: environment) == RecentProjects.shellQuote(resolved))
        // A path with a space or quote is one word on the shell's command line.
        #expect(RoleProgram.claude(for: .claude, environment: [RoleProgram.variable: "/a b/it's"]) == #"'/a b/it'\''s'"#)
        // Only Claude's roles, only with an absolute path: otherwise the caller reads its settings, as before.
        #expect(RoleProgram.claude(for: .codex, environment: environment) == nil)
        #expect(RoleProgram.claude(for: .claude, environment: [:]) == nil)
        #expect(RoleProgram.claude(for: .claude, environment: [RoleProgram.variable: "claude"]) == nil)
    }

    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's"))
    func theMacsRoleProgramIsTodays() {
        #expect(RoleProgram.claude(for: .claude, environment: [RoleProgram.variable: "/usr/local/bin/claude"]) == nil)
    }

    /// Either system: switched off (the Mac's form) it answers nil whatever the variable says.
    @Test func switchedOffItReadsNothing() {
        #expect(RoleProgram.claude(for: .claude, environment: [RoleProgram.variable: "/usr/local/bin/claude"], enabled: false) == nil)
    }
}
