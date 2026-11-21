import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A held card that holds only Claude Code's versions folder and its link (`ClaudeUpdateHint`) says it looks like
/// Claude Code's own update, naming the version the link now names; the hold stays (it can't be told from a planted
/// file). Anything else held, a link elsewhere or a name that isn't a version, gives no hint. A scratch home only.
struct ClaudeUpdateHintTests {
    private let scratch = Scratch()

    /// A scratch home with a version file; its `claude` link to `link(home)` (nil: no link).
    private func home(link: ((String) -> String)?) throws -> String {
        let home = scratch.url("hint-home").path
        let versions = home + "/.local/share/claude/versions"
        try FileManager.default.createDirectory(atPath: versions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: URL(fileURLWithPath: versions + "/2.1.331"))
        if let link { try FileManager.default.createSymbolicLink(atPath: home + "/.local/bin/claude", withDestinationPath: link(home)) }
        return home
    }

    @Test func onlyTheVersionsAndItsLinkGiveTheHint() throws {
        let home = try home(link: { $0 + "/.local/share/claude/versions/2.1.331" })
        let both = ["~/.local/share/claude/versions", "~/.local/bin"]
        let hint = try #require(ClaudeUpdateHint.hint(names: both, home: home))
        #expect(hint.contains("Claude Code's own update to 2.1.331") && hint.contains("can't tell it from a file a session put there"), "\(hint)")
        #expect(ClaudeUpdateHint.hint(names: ["~/.local/share/claude/versions"], home: home) != nil, "the versions alone")
        #expect(ClaudeUpdateHint.hint(names: both + ["~/.claude/settings.json"], home: home) == nil, "something else held")
        #expect(ClaudeUpdateHint.hint(names: ["~/.local/bin"], home: home) == nil, "the link alone")
    }

    @Test func aLinkElsewhereOrNotAVersionGivesNone() throws {
        #expect(ClaudeUpdateHint.hint(names: ["~/.local/share/claude/versions"], home: try home(link: { _ in "/elsewhere/planted/2.1.331" })) == nil)
        let other = scratch.url("hint-home-2").path
        let versions = other + "/.local/share/claude/versions"
        try FileManager.default.createDirectory(atPath: versions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: other + "/.local/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: other + "/.local/bin/claude", withDestinationPath: versions + "/latest")
        #expect(ClaudeUpdateHint.hint(names: ["~/.local/share/claude/versions"], home: other) == nil, "not a version's name")
        let none = scratch.url("hint-home-3").path
        #expect(ClaudeUpdateHint.hint(names: ["~/.local/share/claude/versions"], home: none) == nil, "no link")
    }
}
