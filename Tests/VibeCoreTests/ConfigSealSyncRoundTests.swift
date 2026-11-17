import Foundation
import Testing
@testable import VibeCore

/// Claude Code's own skill sync (2026-11-17): a round it finished inside `~/.claude/skills/synced/<bucket>/` is
/// accepted by itself and holds nothing; every other change to the skills, or to the rest of the seal, is held as ever.
/// The bucket's ids are made up.
extension ConfigSealTests {
    /// A bucket's name as Claude Code spells it: "<org id>_<account id>", made up here.
    static let bucket = "0e3a52b8-1111-4222-8333-944455556666_7f1b2c3d-aaaa-4bbb-8ccc-ddddeeeeffff"
    static var synced: String { ".claude/skills/synced/" }
    static var inBucket: String { synced + bucket + "/" }

    /// A round's marker as Claude Code writes it: a token and the kinds it listed the round for.
    static func marker(_ token: String) -> String { token + " skills" }

    /// A synced bucket with its marker, manifest, round marker and one skill (docx, with a script).
    var syncedFiles: [String: String] {
        [Self.synced + ".bucket-" + Self.bucket: "", Self.inBucket + "manifest.json": #"{"skills":[{"name":"docx"}]}"#,
         Self.inBucket + ".last-complete-round": Self.marker("11111111-2222-4333-8444-555555555555"),
         Self.inBucket + "docx/SKILL.md": "docx v1\n", Self.inBucket + "docx/scripts/run.py": "print(1)\n"]
    }

    /// One of the sync's rounds: the skill rewritten (a file changed, one added), then the manifest and the round
    /// marker, the marker last. `marker`/`manifest` false leave that one as it was; `skill` false touches no skill.
    /// `idle`: a round with nothing new, as Claude Code runs one: the manifest only touched, the marker restamped.
    func claudeSyncRound(marker: Bool = true, manifest: Bool = true, skill: Bool = true, idle: Bool = false,
                         token: String = "99999999-8888-4777-8666-555555555555") throws {
        let bucket = home + "/" + Self.inBucket
        if skill {
            try write("docx v2\n", bucket + "docx/SKILL.md")
            try write("print(2)\n", bucket + "docx/scripts/new.py")
            try setTime(1_900_000_000, bucket + "docx/SKILL.md")
            try setTime(1_900_000_000, bucket + "docx/scripts/new.py")
        }
        if manifest {
            if !idle { try write(#"{"skills":[{"name":"docx","updatedAt":"2"}]}"#, bucket + "manifest.json") }
            try setTime(1_900_000_001, bucket + "manifest.json")
        }
        if marker {
            try write(Self.marker(token), bucket + ".last-complete-round")
            try setTime(1_900_000_002, bucket + ".last-complete-round")
        }
    }

    /// Red first: a finished sync round that rewrote a skill, with a worker running, held the team until the user's
    /// Accept. Now it's accepted by itself: nothing is held, and the next look finds it sealed.
    @Test func aFinishedSyncRoundHoldsNothing() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(syncedFiles, runtime: runtime)
        try claudeSyncRound()
        #expect(try asLead.checkConfig(root: root).held.isEmpty)
        #expect(vault.heldConfig(root: root).isEmpty)
        #expect(try asLead.checkConfig(root: root).held.isEmpty)
    }

    /// The round as the vault notes it: its paths, the bucket's folder never named (the lead's log says only counts).
    static let roundSaid = ["synced/<account>/docx/SKILL.md changed", "synced/<account>/docx/scripts/new.py added"]

    /// The round accepted by itself is recorded as the sync's (not a change of the user's sealed), and the lead's
    /// look leaves a line in the progress log: no card, nothing held, and the next worker starts.
    @Test func anAcceptedRoundIsRecordedAndLoggedNotShown() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for (file, text) in syncedFiles { try write(text, home + "/" + file) }
        #expect(try vault(for: runtime).checkConfig(root: root) == LeadVault.ConfigCheck())
        let first = try add(lead, "First")
        let started = lead.call("start_worker", ["task": first])
        #expect(!started.isError, "\(started.text)")

        try claudeSyncRound()
        let second = try add(lead, "Second")
        let next = lead.call("start_worker", ["task": second])
        #expect(!next.isError, "\(next.text)")
        #expect(vault.heldConfig(root: root).isEmpty)
        let record = try vault.guardedRecord(root: root)
        #expect(ConfigSeal.syncRound(in: record) == Self.roundSaid)
        #expect(ConfigSeal.held(in: record).isEmpty)
        let progress = (try? String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)) ?? ""
        #expect(progress.contains("in ~/.claude/skills/synced, accepted by itself (nothing held): 1 changed, 1 added"), "\(progress)")
        #expect(!progress.contains("sealed as they are"), "\(progress)")
        // Counts only: the log may be public, and a synced skill's name an organisation's own.
        #expect(!progress.contains("docx"), "\(progress)")
        #expect(!progress.contains(Self.bucket), "\(progress)")
        // Noted once: the next look finds it noted.
        let third = try add(lead, "Third")
        #expect(!lead.call("start_worker", ["task": third]).isError)
        let again = (try? String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)) ?? ""
        #expect(again.components(separatedBy: "Claude Code's skill sync finished a round").count == 2, "\(again)")
    }

    /// A round another look accepted (the app's, here) is noted in the lead's log at its next look.
    @Test func aRoundAnotherLookAcceptedIsLoggedAtTheLeadsNextLook() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for (file, text) in syncedFiles { try write(text, home + "/" + file) }
        let first = try add(lead, "First")
        #expect(!lead.call("start_worker", ["task": first]).isError)
        try claudeSyncRound()
        #expect(try vault.checkConfig(root: root).syncAccepted == Self.roundSaid)
        let second = try add(lead, "Second")
        #expect(!lead.call("start_worker", ["task": second]).isError)
        let progress = (try? String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)) ?? ""
        #expect(progress.contains("accepted by itself (nothing held): 1 changed, 1 added"), "\(progress)")
    }

    /// The look that accepts it says so to whoever asked, and nothing as resealed.
    @Test func theLookThatAcceptsARoundSaysSo() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(syncedFiles, runtime: runtime)
        try claudeSyncRound()
        let found = try asLead.checkConfig(root: root)
        #expect(found.syncAccepted == Self.roundSaid && found.held.isEmpty && found.resealed.isEmpty, "\(found)")
        #expect(found.lastSyncRound?.files == Self.roundSaid)
        let next = try asLead.checkConfig(root: root)
        #expect(next.syncAccepted.isEmpty && next.held.isEmpty && next.resealed.isEmpty, "\(next)")
        #expect(next.lastSyncRound == found.lastSyncRound)
    }

    /// Beside a finished round, anything else is held as ever: a file straight in the skills folder or in a skill of
    /// the user's, one straight in `synced/` or in a bucket's dot folder, and the rest of the seal (settings, hooks,
    /// agents, commands), the round itself accepted.
    @Test(arguments: [".claude/skills/evil.sh", ".claude/skills/mine/SKILL.md", ".claude/skills/synced/evil.sh",
                      ".claude/skills/synced/\(bucket)/.staging/x/SKILL.md", ".claude/skills/synced/\(bucket).bak/x/SKILL.md",
                      ".claude/settings.json", ".claude/hooks/x.sh", ".claude/agents/a.md", ".claude/commands/c.md"])
    func anythingBesideARoundIsStillHeld(file: String) throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(syncedFiles, runtime: runtime)
        try write("planted\n", home + "/" + file)
        try claudeSyncRound()
        let name = "~/" + file.split(separator: "/").prefix(2).joined(separator: "/")
        #expect(try asLead.checkConfig(root: root).held == [name])
        #expect(vault.heldConfig(root: root) == [name])
    }

    /// A change under `synced/` that isn't a finished round is held, named as ever (the card's text is today's): the
    /// marker or the manifest not rewritten with it, or neither.
    @Test(arguments: [(false, true), (true, false), (false, false)])
    func aRoundWithoutItsMarkerOrManifestIsHeld(marker: Bool, manifest: Bool) throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(syncedFiles, runtime: runtime)
        try claudeSyncRound(marker: marker, manifest: manifest)
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/skills"])
        let at = "synced/\(Self.bucket)/docx/"
        #expect(ConfigSeal.heldChanges(in: try vault.guardedRecord(root: root)) == ["~/.claude/skills": "\(at)SKILL.md changed, \(at)scripts/new.py added"])
        #expect(ConfigSeal.syncRound(in: try vault.guardedRecord(root: root)).isEmpty)
    }

    /// A round that touched only the bookkeeping holds nothing, and moves the baseline: a skill written after it,
    /// with no round of its own, is held.
    @Test func aSkillWrittenAfterABookkeepingOnlyRoundIsHeld() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(syncedFiles, runtime: runtime)
        try claudeSyncRound(skill: false)
        #expect(try asLead.checkConfig(root: root).held.isEmpty)
        try write("docx v3\n", home + "/" + Self.inBucket + "docx/SKILL.md")
        try setTime(1_800_000_000, home + "/" + Self.inBucket + "docx/SKILL.md")
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/skills"])
    }

    /// Not a round as Claude Code writes one: a skill file newer than the round's marker (written after the round),
    /// a marker or a manifest not shaped as it writes them, a link planted in a synced skill.
    @Test(arguments: ["newer than the marker", "marker misshaped", "manifest misshaped", "link"])
    func notARoundAsClaudeCodeWritesOneIsHeld(how: String) throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(syncedFiles, runtime: runtime)
        let bucket = home + "/" + Self.inBucket
        switch how {
        case "marker misshaped": try claudeSyncRound(token: "round 2")
        case "manifest misshaped":
            try claudeSyncRound()
            try write(#"{"plugins":[]}"#, bucket + "manifest.json")
            try setTime(1_900_000_001, bucket + "manifest.json")
        case "link":
            try claudeSyncRound()
            try FileManager.default.createSymbolicLink(atPath: bucket + "docx/scripts/x.py", withDestinationPath: "/bin/sh")
        default:
            try claudeSyncRound()
            try setTime(1_900_000_010, bucket + "docx/scripts/new.py")
        }
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/skills"])
    }

    /// A bucket folder that wasn't sealed with its `.bucket-` marker is no round's: one with no marker, or one whose
    /// marker comes with it.
    @Test(arguments: [false, true])
    func aNewBucketIsHeld(marked: Bool) throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(syncedFiles, runtime: runtime)
        let other = "1a2b3c4d-1111-4222-8333-944455556666_unbound"
        let folder = home + "/" + Self.synced + other + "/"
        if marked { try write("", home + "/" + Self.synced + ".bucket-" + other) }
        try write("new\n", folder + "evil/SKILL.md")
        try write(#"{"skills":[{"name":"evil"}]}"#, folder + "manifest.json")
        try write(Self.marker("22222222-2222-4333-8444-555555555555"), folder + ".last-complete-round")
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/skills"])
    }

    /// What a look held stays held for the user's click, whatever round follows: it may be no round's, and its card
    /// may be up.
    @Test func aHeldChangeStaysHeldThroughALaterRound() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(syncedFiles, runtime: runtime)
        try claudeSyncRound(marker: false)
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/skills"])
        try claudeSyncRound(manifest: false, skill: false)
        let found = try asLead.checkConfig(root: root)
        #expect(found.held == ["~/.claude/skills"] && found.syncAccepted.isEmpty, "\(found)")
        #expect(vault.heldConfig(root: root) == ["~/.claude/skills"])
    }

    /// A skill written into a synced skill, followed by one of the sync's idle rounds (nothing new: the manifest only
    /// touched, the marker restamped), is held: an idle round takes nothing in.
    @Test func aSkillFollowedByAnIdleRoundIsHeld() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(syncedFiles, runtime: runtime)
        let bucket = home + "/" + Self.inBucket
        try write("planted\n", bucket + "docx/scripts/x.py")
        try setTime(1_900_000_000, bucket + "docx/scripts/x.py")
        try claudeSyncRound(skill: false, idle: true)
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/skills"])
    }
}
