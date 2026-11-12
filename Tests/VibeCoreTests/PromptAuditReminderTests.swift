import Foundation
import Testing
@testable import VibeCore

/// The reminder to run `/doctor prompt-audit` (`PromptAudit`), on an injected clock: every time below is a date the
/// test gives, never the Mac's.
struct PromptAuditReminderTests {
    let temp = Scratch()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    func at(_ days: Double) -> Date { start.addingTimeInterval(days * day) }

    /// A transcript line as Claude Code writes it.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func userCommand(_ name: String, args: String, at date: Date) -> String {
        let content = "<command-message>\(name.dropFirst())</command-message>\n<command-name>\(name)</command-name>\n<command-args>\(args)</command-args>"
        let object: [String: Any] = ["type": "user", "timestamp": iso(date), "message": ["role": "user", "content": content]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func assistant(_ model: String, at date: Date) -> String {
        let object: [String: Any] = ["type": "assistant", "timestamp": iso(date),
                                     "message": ["role": "assistant", "model": model, "content": [["type": "text", "text": "ok"]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func folder() throws -> URL {
        let url = temp.url("prompt-audit")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func append(_ lines: [String], to file: URL) throws {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: file)
        }
    }

    /// The project as the app keeps it: a look at its transcripts at `now`.
    func look(_ project: PromptAudit.Project?, _ folder: URL, _ now: Date) -> PromptAudit.Project {
        PromptAudit.observe(project, scan: PromptAudit.scan(folder, read: project?.read ?? [:]), now: now)
    }

    @Test func noCardBeforeTheIntervalAndOneAtIt() throws {
        let folder = try folder()
        try append([Self.assistant("claude-opus-5-5", at: at(-1))], to: folder.appendingPathComponent("a.jsonl"))
        let project = look(nil, folder, at(0))
        for days in [0.0, 1, 7, 13, 13.99] { #expect(PromptAudit.due(project, now: at(days)) == nil, "\(days) days") }
        #expect(PromptAudit.due(project, now: at(14)) == .interval(since: at(0), ranBefore: false))
        #expect(PromptAudit.due(project, now: at(20)) != nil)
        // Another interval: the same clock, its own length.
        #expect(PromptAudit.due(project, now: at(6), intervalDays: 7) == nil)
        #expect(PromptAudit.due(project, now: at(7), intervalDays: 7) != nil)
    }

    /// No burst on install: a project first seen now waits a whole interval, even with a run long before in its
    /// transcripts, or a run on another model than the one it answers on now.
    @Test func aProjectFirstSeenGetsItsFirstCardOneIntervalLaterNotAtOnce() throws {
        let folder = try folder()
        try append([Self.userCommand("/doctor", args: "prompt-audit", at: at(-60)), Self.assistant("claude-sonnet-4-5", at: at(-60)),
                    Self.assistant("claude-opus-5-5", at: at(-1))], to: folder.appendingPathComponent("a.jsonl"))
        var project = look(nil, folder, at(0))
        #expect(project.lastRun == at(-60).timeIntervalSince1970)
        #expect(project.models == ["claude-opus-5-5"])
        for days in [0.0, 5, 13.9] {
            project = look(project, folder, at(days))
            #expect(PromptAudit.due(project, now: at(days)) == nil, "\(days) days")
        }
        #expect(PromptAudit.due(project, now: at(14)) == .interval(since: at(0), ranBefore: true))
        // And one with no transcripts at all.
        let empty = look(nil, try self.folder(), at(0))
        #expect(PromptAudit.due(empty, now: at(0)) == nil && PromptAudit.due(empty, now: at(13)) == nil)
        #expect(PromptAudit.due(empty, now: at(14)) != nil)
    }

    @Test func aModelChangeSinceTheLastRunShowsACardAtOnce() throws {
        let folder = try folder()
        let file = folder.appendingPathComponent("lead.jsonl")
        try append([Self.assistant("claude-opus-5-5", at: at(0))], to: file)
        var project = look(nil, folder, at(0))
        try append([Self.userCommand("/doctor", args: "prompt-audit", at: at(1)), Self.assistant("claude-opus-5-5[1m]", at: at(1))], to: file)
        project = look(project, folder, at(1))
        #expect(project.lastRun == at(1).timeIntervalSince1970 && project.models == ["claude-opus-5-5"])
        // The same model, spelled with a context suffix or a date: no change.
        try append([Self.assistant("claude-opus-5-5-20261101", at: at(2))], to: file)
        project = look(project, folder, at(2))
        #expect(PromptAudit.due(project, now: at(2)) == nil)
        // Another model: a card right away, days before the interval.
        try append([Self.assistant("claude-fable-5-2", at: at(3))], to: file)
        project = look(project, folder, at(3))
        #expect(PromptAudit.due(project, now: at(3)) == .modelChanged(from: "claude-opus-5-5", to: "claude-fable-5-2"))
        // A run on the new model settles it, and the clock starts from it.
        try append([Self.userCommand("/doctor", args: "prompt-audit", at: at(4)), Self.assistant("claude-fable-5-2", at: at(4))], to: file)
        project = look(project, folder, at(4))
        #expect(PromptAudit.due(project, now: at(4)) == nil)
        #expect(PromptAudit.due(project, now: at(17.9)) == nil)
        #expect(PromptAudit.due(project, now: at(18)) == .interval(since: at(4), ranBefore: true))
    }

    /// The blind check's case: the lead on one model and your own session in the same folder on another, each
    /// writing last in turn. No card, whatever order the looks fall in; once the lead moves to a third model (and the
    /// one its audit was for goes quiet), the card shows.
    @Test func twoSessionsOnTwoModelsInOneFolderAreNoModelChange() throws {
        let folder = try folder()
        let lead = folder.appendingPathComponent("lead.jsonl"), mine = folder.appendingPathComponent("mine.jsonl")
        try append([Self.assistant("claude-opus-5-5", at: at(0))], to: lead)
        try append([Self.assistant("claude-sonnet-4-5", at: at(0.01))], to: mine)
        var project = look(nil, folder, at(0.02))
        #expect(project.models == ["claude-opus-5-5", "claude-sonnet-4-5"])
        // A run in the lead: the audit is for the lead's model only, though your session answered last.
        try append([Self.userCommand("/doctor", args: "prompt-audit", at: at(1)), Self.assistant("claude-opus-5-5", at: at(1.01))], to: lead)
        try append([Self.assistant("claude-sonnet-4-5", at: at(1.02))], to: mine)
        project = look(project, folder, at(1.03))
        #expect(project.models == ["claude-opus-5-5"])
        for step in 0..<6 {
            let when = 2.0 + Double(step) * 0.1
            try append([Self.assistant(step.isMultiple(of: 2) ? "claude-sonnet-4-5" : "claude-opus-5-5", at: at(when))],
                       to: step.isMultiple(of: 2) ? mine : lead)
            project = look(project, folder, at(when + 0.01))
            #expect(PromptAudit.due(project, now: at(when + 0.01)) == nil, "step \(step)")
        }
        // The lead quiet for a day while your session goes on: still no card.
        try append([Self.assistant("claude-sonnet-4-5", at: at(2.9))], to: mine)
        project = look(project, folder, at(2.95))
        #expect(PromptAudit.due(project, now: at(2.95)) == nil)
        // The lead moves to Fable; your Sonnet session goes on.
        try append([Self.assistant("claude-fable-5-2", at: at(3))], to: lead)
        try append([Self.assistant("claude-sonnet-4-5", at: at(3.1))], to: mine)
        project = look(project, folder, at(3.2))
        #expect(PromptAudit.due(project, now: at(3.2)) == .modelChanged(from: "claude-opus-5-5", to: "claude-fable-5-2"))
    }

    @Test func snoozeMovesTheCardAWeek() throws {
        let folder = try folder()
        var project = look(nil, folder, at(0))
        #expect(PromptAudit.due(project, now: at(14)) != nil)
        project = PromptAudit.snoozed(project, at: at(14))
        for days in [14.0, 15, 20, 20.99] { #expect(PromptAudit.due(project, now: at(days)) == nil, "\(days) days") }
        #expect(PromptAudit.due(project, now: at(21)) != nil)
        // A model change during the week waits for it too.
        project = PromptAudit.snoozed(project, at: at(21))
        project.models = ["claude-opus-5-5"]
        project.sessions = ["lead.jsonl": PromptAudit.Seen(model: "claude-fable-5-2", last: at(23).timeIntervalSince1970)]
        #expect(PromptAudit.due(project, now: at(25)) == nil)
        #expect(PromptAudit.due(project, now: at(28)) == .modelChanged(from: "claude-opus-5-5", to: "claude-fable-5-2"))
    }

    @Test func notForThisProjectStopsItForThatProjectOnly() throws {
        var book = PromptAudit.Book()
        book.projects["/p/one"] = look(nil, try folder(), at(0))
        book.projects["/p/two"] = look(nil, try folder(), at(0))
        book.projects["/p/one"]?.off = true
        let file = temp.url("book").appendingPathComponent("prompt-audit.json")
        try book.save(to: file)
        let kept = PromptAudit.Book.load(from: file)
        #expect(kept == book)
        for days in [14.0, 100, 1_000] {
            #expect(PromptAudit.due(kept.projects["/p/one"]!, now: at(days)) == nil)
            #expect(PromptAudit.due(kept.projects["/p/two"]!, now: at(days)) != nil)
        }
        // A model change doesn't bring it back either.
        var one = kept.projects["/p/one"]!
        one.models = ["a"]
        one.sessions = ["x.jsonl": PromptAudit.Seen(model: "b", last: at(0.5).timeIntervalSince1970)]
        #expect(PromptAudit.due(one, now: at(1)) == nil)
    }

    /// The user runs the audit on their own (in the lead, or any session in the project's folder): found in the
    /// transcripts, no click.
    @Test func aRunFoundInTheTranscriptsResetsTheClock() throws {
        let folder = try folder()
        let file = folder.appendingPathComponent("other-session.jsonl")
        try append([Self.assistant("claude-opus-5-5", at: at(0))], to: file)
        var project = look(nil, folder, at(0))
        #expect(PromptAudit.due(project, now: at(15)) != nil)
        // Lookalikes aren't runs: another command, other arguments, the words in an assistant's text.
        try append([Self.userCommand("/doctor", args: "", at: at(15)), Self.userCommand("/doctor", args: "prompt-auditing", at: at(15)),
                    Self.userCommand("/review", args: "prompt-audit", at: at(15)),
                    #"{"type":"assistant","timestamp":"\#(Self.iso(at(15)))","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"<command-name>/doctor</command-name><command-args>prompt-audit</command-args>"}]}}"#],
                   to: file)
        project = look(project, folder, at(15))
        #expect(project.lastRun == nil)
        #expect(PromptAudit.due(project, now: at(15)) != nil)
        // The real one, snoozed or not: the clock restarts at it.
        project = PromptAudit.snoozed(project, at: at(15))
        try append([Self.userCommand("/doctor", args: "prompt-audit", at: at(16)), Self.assistant("claude-opus-5-5", at: at(16))], to: file)
        project = look(project, folder, at(16))
        #expect(project.lastRun == at(16).timeIntervalSince1970)
        #expect(project.snoozedUntil == nil)
        #expect(PromptAudit.due(project, now: at(29.9)) == nil)
        #expect(PromptAudit.due(project, now: at(30)) == .interval(since: at(16), ranBefore: true))
    }

    /// Each look reads on from where the last stopped: a line half written isn't taken (nor skipped), and a
    /// transcript that got shorter is read again from its start.
    @Test func transcriptsAreReadOnFromWhereTheLastLookStopped() throws {
        let folder = try folder()
        let file = folder.appendingPathComponent("a.jsonl")
        let run = Self.userCommand("/doctor", args: "prompt-audit", at: at(1))
        try append([Self.assistant("claude-opus-5-5", at: at(0))], to: file)
        try (try FileHandle(forWritingTo: file)).then { try $0.seekToEnd(); try $0.write(contentsOf: Data(run.prefix(40).utf8)); try $0.close() }
        let first = PromptAudit.scan(folder)
        #expect(first.runs.isEmpty)
        let size = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber).uint64Value
        #expect(first.read["a.jsonl"] == size - 40)
        try (try FileHandle(forWritingTo: file)).then { try $0.seekToEnd(); try $0.write(contentsOf: Data((run.dropFirst(40) + "\n").utf8)); try $0.close() }
        let second = PromptAudit.scan(folder, read: first.read)
        #expect(second.runs == [PromptAudit.Run(at: at(1).timeIntervalSince1970, file: "a.jsonl")])
        #expect(PromptAudit.scan(folder, read: second.read).runs.isEmpty)
        // Rewritten shorter: from the start.
        try Data((run + "\n").utf8).write(to: file)
        #expect(PromptAudit.scan(folder, read: second.read).runs.count == 1)
    }

    @Test func settingsAreOnWithFourteenDaysUnlessChanged() {
        let defaults = temp.defaults("prompt-audit-settings")
        #expect(PromptAudit.isOn(defaults) && PromptAudit.intervalDays(defaults) == 14)
        defaults.set(false, forKey: PromptAudit.enabledKey)
        defaults.set(30, forKey: PromptAudit.intervalKey)
        #expect(!PromptAudit.isOn(defaults) && PromptAudit.intervalDays(defaults) == 30)
        defaults.set(10_000, forKey: PromptAudit.intervalKey)
        #expect(PromptAudit.intervalDays(defaults) == PromptAudit.intervalRange.upperBound)
    }
}

private extension FileHandle {
    func then(_ body: (FileHandle) throws -> Void) throws { try body(self) }
}
