import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The card's data (`ConfigHolds`): a held folder's paths and time come from what the vault holds, never from the
/// folder's own modification time (which moves with whatever is written in it).
struct ConfigHoldsTests {
    private let scratch = Scratch()

    /// A vault that answers with `record`, and holds that look inline.
    func holds(answering record: [String: String]) -> ConfigHolds {
        let vault = LeadVault(folder: scratch.url("vault")) { request in
            guard case .guarded = request else { throw LeadVault.Refused("none") }
            return .guarded(record)
        }
        return ConfigHolds(vault: vault, background: { $0() }, main: { $0() })
    }

    @Test func aHeldFoldersPathsAndTimeAreWhatTheVaultHolds() {
        let key = ConfigSeal.keyPrefix + "~/.claude/skills"
        let line = "\(key)\tH\tr\ta/SKILL.md changed, b/run.sh added and 3 more\t1700000500"
        let holds = holds(answering: [ConfigSeal.heldKey: line])
        holds.look(["/r"])
        #expect(holds.held["/r"] == ["~/.claude/skills"])
        #expect(holds.changes["/r"]?["~/.claude/skills"] == "a/SKILL.md changed, b/run.sh added and 3 more")
        #expect(holds.changedAt["/r"]?["~/.claude/skills"] == Date(timeIntervalSince1970: 1_700_000_500))
    }

    /// A folder's own time is never shown: only a file's.
    @Test func changedAtReadsFilesNeverAFoldersOwnTime() throws {
        let home = scratch.url("home").path
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills", withIntermediateDirectories: true)
        try "x\n".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        let times = ConfigHolds.changedAt(["~/.claude/skills", "~/.zshrc"], root: "/r", home: home)
        #expect(times["~/.claude/skills"] == nil)
        #expect(times["~/.zshrc"] != nil)
    }
}
