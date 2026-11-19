import Foundation
import Testing
@testable import VibeCore

/// The seal's suite, on Claude Code's skill sync's staging folder (`SkillSyncStaging`, 2026-11-19): an empty
/// `~/.claude/skills/synced/<bucket>/.staging` coming and going while a worker runs holds nothing and changes no hash;
/// a file inside it, or a real skill's file changing, is held as ever. In `ConfigSealTests`' fixture (its scratch home
/// and vault), in a file of v2's own.
extension ConfigSealTests {
    var staging: String { home + "/" + Self.account + ".staging" }

    @Test func anEmptyStagingFolderComingAndGoingHoldsNothing() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam([Self.account + "a/SKILL.md": "a\n"], runtime: runtime)
        let sealed = try #require(ConfigSeal.fingerprint(skills))
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        #expect(ConfigSeal.fingerprint(skills) == sealed)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try FileManager.default.removeItem(atPath: staging)
        #expect(ConfigSeal.fingerprint(skills) == sealed)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        #expect(vault.heldConfig(root: root).isEmpty)
    }

    /// A seal made while the staging folder was there, empty, holds nothing once it's gone.
    @Test func aSealMadeWithAnEmptyStagingFolderHoldsNothingWhenItGoes() throws {
        let runtime = FakeRuntime()
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        let (root, asLead) = try runningTeam([Self.account + "a/SKILL.md": "a\n"], runtime: runtime)
        try FileManager.default.removeItem(atPath: staging)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        #expect(vault.heldConfig(root: root).isEmpty)
    }

    @Test(arguments: ["SKILL.md", "run.sh", "inner/SKILL.md"])
    func aFileInsideTheStagingFolderIsHeld(file: String) throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam([Self.account + "a/SKILL.md": "a\n"], runtime: runtime)
        let sealed = try #require(ConfigSeal.fingerprint(skills))
        try write("echo staged\n", staging + "/" + file)
        #expect(ConfigSeal.fingerprint(skills) != sealed)
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/skills"])
    }

    /// A folder inside it is something in it too: not empty, so walked and held.
    @Test func anEmptyFolderInsideTheStagingFolderIsHeld() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam([Self.account + "a/SKILL.md": "a\n"], runtime: runtime)
        try FileManager.default.createDirectory(atPath: staging + "/inner", withIntermediateDirectories: true)
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/skills"])
    }

    @Test func aRealSkillsFileChangingIsHeldBesideAnEmptyStagingFolder() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam([Self.account + "a/SKILL.md": "a\n"], runtime: runtime)
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        try write("changed\n", home + "/" + Self.account + "a/SKILL.md")
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/skills"])
    }

    /// Only that entry: a link or a file named `.staging` there, and an empty `.staging` at another depth, outside
    /// `synced/`, or under another watched folder, each stay watched.
    @Test(arguments: ["link", "file", ".claude/skills/.staging", ".claude/skills/synced/.staging",
                      ".claude/skills/synced/acct-1/a/.staging", ".claude/skills/other/acct-1/.staging", ".claude/commands/synced/acct-1/.staging"])
    func everyOtherStagingStaysWatched(kind: String) throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam([Self.account + "a/SKILL.md": "a\n", ".claude/commands/c.md": "c\n"], runtime: runtime)
        switch kind {
        case "link": try FileManager.default.createSymbolicLink(atPath: staging, withDestinationPath: "/nowhere")
        case "file": try write("", staging)
        default: try FileManager.default.createDirectory(atPath: home + "/" + kind, withIntermediateDirectories: true)
        }
        let name = kind.hasPrefix(".claude/commands") ? "~/.claude/commands" : "~/.claude/skills"
        #expect(try asLead.checkConfig(root: root).held == [name])
    }
}
