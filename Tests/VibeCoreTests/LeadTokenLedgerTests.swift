import Foundation
import Testing
@testable import VibeCore

/// A project lead's own tokens per day (`LeadTokenLedger`), from stand-in transcripts written as Claude Code writes
/// them (LeadReceiptTests' fixtures) in a scratch home: only the lead's sessions, each response once, only what came
/// since the ledger began, and only numbers kept.
struct LeadTokenLedgerTests {
    let temp = Scratch()

    /// A project with a board, and the scratch home's Claude folder for it.
    func project() throws -> (root: String, home: String, claude: URL) {
        let url = temp.url("proj")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".vibeswitcher"), withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        try "{}".write(toFile: root + "/.vibeswitcher/board.json", atomically: true, encoding: .utf8)
        let home = temp.url("home").path
        let claude = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects").appendingPathComponent(RecentProjects.claudeSlug(for: root))
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        return (root, home, claude)
    }

    func write(_ lines: [String], to file: URL, ending: String = "\n") throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + ending).write(to: file, atomically: true, encoding: .utf8)
    }

    func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// Dates `file`'s making back to `at`, as if it had been written since then (its responses are older than now).
    func backdate(_ file: URL, to at: Double) throws {
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: at)], ofItemAtPath: file.path)
        #expect(abs((LeadTokenLedger.born(file) ?? 0) - at) < 1)
    }

    static func response(_ id: String, input: Int, output: Int, at: Double, model: String = "claude-opus-5-5", block: Int = 0) -> String {
        LeadReceiptTests.response(id, model, input: input, output: output, at: at, block: block)
    }

    @Test func theLeadsTokensAreTalliedPerDayFromItsOwnTranscriptsOnly() throws {
        let (root, home, claude) = try project()
        let name = LeadTokenLedger.leadName(root: root)
        #expect(name == "lead-" + Slug.make((root as NSString).lastPathComponent, taken: []) && name.hasPrefix("lead-proj"))
        // The ledger begins an hour ago; the lead's transcript was there already, its earlier response not counted.
        let begun = Date().timeIntervalSince1970 - 3600
        let lead = claude.appendingPathComponent("l-a.jsonl")
        try write(LeadReceiptTests.named(name, session: "l-a") + [Self.response("m0", input: 999, output: 999, at: begun - 60)], to: lead)
        try backdate(lead, to: begun - 120)
        let made = try #require(try LeadTokenLedger.tally(root: root, home: home, now: Date(timeIntervalSince1970: begun)))
        #expect(made.since == begun && made.days.isEmpty && made.files["\(claude.lastPathComponent)/l-a.jsonl"]?.lead == true)

        // Since: a response written twice (two content blocks), one two days on, and half a line still being written.
        let first = Self.response("m1", input: 10, output: 100, at: begun + 10)
        // Two days on: never the day of `begun + 3590` (m3, a resumed lead's), which is the next day when this runs in
        // the hour after midnight.
        let tomorrow = begun + 2 * 86_400
        try append([first, Self.response("m1", input: 10, output: 100, at: begun + 10, block: 1),
                    Self.response("m2", input: 20, output: 200, at: tomorrow, model: "claude-sonnet-5-5")].joined(separator: "\n") + "\n", to: lead)
        let partial = Self.response("m4", input: 40, output: 400, at: begun + 30)
        try append(String(partial.prefix(40)), to: lead)
        // Its subagent's transcript: the lead's too.
        try write([Self.response("s1", input: 1, output: 2, at: begun + 20, model: "claude-haiku-4-5")],
                  to: claude.appendingPathComponent("l-a/subagents/agent-x.jsonl"))
        try backdate(claude.appendingPathComponent("l-a/subagents/agent-x.jsonl"), to: begun + 15)
        // A resumed lead's new transcript: its copy of an earlier response (from before it was made) isn't counted again.
        try write(LeadReceiptTests.named(name, session: "l-b") + [first, Self.response("m3", input: 30, output: 300, at: begun + 3590)],
                  to: claude.appendingPathComponent("l-b.jsonl"))
        // The user's own session in the project's folder, and a worker's: never counted.
        try write(LeadReceiptTests.named("my-own-look", session: "u") + [Self.response("u1", input: 5_000_000, output: 5, at: begun + 40)],
                  to: claude.appendingPathComponent("u.jsonl"))
        try write(LeadReceiptTests.named("worker-x", session: "w") + [Self.response("w1", input: 7_000_000, output: 5, at: begun + 40)],
                  to: claude.appendingPathComponent("w.jsonl"))

        let now = Date()
        var ledger = try #require(try LeadTokenLedger.tally(root: root, home: home, now: now))
        let today = LoadStats.day(Date(timeIntervalSince1970: begun + 10)), next = LoadStats.day(Date(timeIntervalSince1970: tomorrow))
        let todays = try #require(ledger.days[today])
        let late = LoadStats.day(Date(timeIntervalSince1970: begun + 3590))
        // m1 + s1 (+ m3 when it falls on the same day).
        let sameDay = late == today
        #expect(todays.input == 11 + (sameDay ? 30 : 0) && todays.output == 102 + (sameDay ? 300 : 0), "\(todays)")
        #expect(Set(todays.models.keys) == Set(["claude-opus-5-5", "claude-haiku-4-5"]) && todays.unpriced == nil)
        #expect(todays.sessions.count == (sameDay ? 3 : 2))
        let tomorrows = try #require(ledger.days[next])
        #expect(tomorrows.input == 20 && tomorrows.output == 200 && tomorrows.models == ["claude-sonnet-5-5": 220])
        // Opus 5.5 m1: 10 × $4 + 100 × $20; Haiku 4.5 s1: 1 × $1 + 2 × $5 (per million).
        let opus: Double = 10 * 4 + 100 * 20, haiku: Double = 1 * 1 + 2 * 5, resumed: Double = sameDay ? 30 * 4 + 300 * 20 : 0
        let expected = (opus + haiku + resumed) / 1_000_000
        #expect(abs(todays.cost - expected) < 1e-12 && todays.tokens.cost != nil)
        let total = ledger.days.values.reduce(0) { $0 + $1.total }
        #expect(total == 11 + 102 + 220 + 330, "\(ledger.days)")

        // Nothing new: nothing counted twice. The half line, once finished, counts once.
        ledger = try #require(try LeadTokenLedger.tally(root: root, home: home, now: now))
        #expect(ledger.days.values.reduce(0) { $0 + $1.total } == total)
        try append(String(partial.dropFirst(40)) + "\n", to: lead)
        ledger = try #require(try LeadTokenLedger.tally(root: root, home: home, now: now))
        #expect(ledger.days.values.reduce(0) { $0 + $1.total } == total + 440)
        #expect(LeadTokenLedger.load(root: root) == ledger)

        // Kept private, numbers only.
        let file = LeadTokenLedger.file(root: root)
        let mode = ((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("SECRET") && !saved.contains("my-own-look"))
    }

    @Test func aProjectWithoutABoardIsPassedOverAndAnUnpricedModelLeavesItsDaysCostUnknown() throws {
        let (root, home, claude) = try project()
        let elsewhere = temp.url("no-board").path
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        #expect(try LeadTokenLedger.tally(root: elsewhere, home: home) == nil)
        #expect(!FileManager.default.fileExists(atPath: LeadTokenLedger.file(root: elsewhere).path))

        let begun = Date().timeIntervalSince1970 - 600
        try LeadTokenLedger.tally(root: root, home: home, now: Date(timeIntervalSince1970: begun))
        // A transcript that appears after the ledger began counts from its start.
        try write(LeadReceiptTests.named(LeadTokenLedger.leadName(root: root), session: "l") + [Self.response("n1", input: 5, output: 5, at: begun + 5, model: "claude-new-9")],
                  to: claude.appendingPathComponent("l.jsonl"))
        try backdate(claude.appendingPathComponent("l.jsonl"), to: begun + 1)
        let ledger = try #require(try LeadTokenLedger.tally(root: root, home: home))
        let day = try #require(ledger.days[LoadStats.day(Date(timeIntervalSince1970: begun + 5))])
        #expect(day.total == 10 && day.unpriced == ["claude-new-9"] && day.tokens.cost == nil)
    }
}
