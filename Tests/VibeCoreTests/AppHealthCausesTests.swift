import Foundation
import Testing
@testable import VibeCore

/// Causes (see `AppHealthCauses.swift`): freezes, error lines and failure notices from fake logs in scratch, grouped by
/// cause, counted by day on an injected clock, and proposed to the lead once, with their evidence and never a secret.
struct AppHealthCausesTests {
    let temp = Scratch()
    let start = Date(timeIntervalSince1970: 1_761_393_730)

    func folders() throws -> AppHealth.Folders {
        let debug = temp.url("debug"), reports = temp.url("reports")
        for url in [debug, reports] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return AppHealth.Folders(debug: debug, reports: reports)
    }

    func writeHang(_ name: String, in folders: AppHealth.Folders, duration: Double, frames: [String]) throws {
        try AppHealthTests.log(duration: duration).write(to: folders.debug.appendingPathComponent(name + ".log"), atomically: true, encoding: .utf8)
        try AppHealthTests.sample(frames).write(to: folders.debug.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    /// Noon (or `hour`) `offset` days from the start, on this Mac's calendar.
    func day(_ offset: Int, hour: Int = 12) -> Date {
        let base = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: start)!
        return Calendar.current.date(byAdding: .day, value: offset, to: base)!
    }

    func name(_ offset: Int) -> String { AppHealth.Watch.day(day(offset)) }

    /// `count` error lines of one cause on day `offset` (each with its own numbers, ids and paths), the day looked at.
    func lines(_ count: Int, on offset: Int, into watch: inout AppHealth.Watch, folders: AppHealth.Folders,
               line: (Int) -> String = { "11:00:0\($0 % 10).000 lead: couldn't bind session \(UUID().uuidString) on ttys00\($0) after \($0 + 3) s: Error Domain=x Code=\($0)" }) {
        watch.saw(lines: (0..<count).map(line), now: day(offset, hour: 11))
        watch.look(now: day(offset), folders: folders, memory: nil)
    }

    func proposals(_ watch: AppHealth.Watch) -> [String] { watch.pending.filter { $0.contains("\nProposed task ") } }

    // MARK: Grouping

    @Test func tenSimilarFreezesAreOneCauseAndTwoDifferentStayApart() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        // Ten with the same top 3 app frames, each called from somewhere else and stuck for a different time.
        for index in 0..<10 {
            try writeHang("hang-20261025-1402\(10 + index)", in: folders, duration: 2 + Double(index),
                          frames: ["Caller\(index).run()", "TeamRowView.header.getter", "TeamRow.spoken.getter", "Text.init(_:)"])
        }
        try writeHang("hang-20261025-140230", in: folders, duration: 3, frames: ["A.one()", "A.two()", "A.three()"])
        try writeHang("hang-20261025-140231", in: folders, duration: 3, frames: ["B.one()", "B.two()", "B.three()"])
        watch.saw(hangs: folders.hangNames(), crashes: [], now: start)
        watch.look(now: start.addingTimeInterval(AppHealth.window), folders: folders, memory: nil)
        let freezes = watch.causes.byKey.filter { $0.value.kind == .freeze }
        #expect(freezes.count == 3, "\(freezes.keys.sorted())")
        let spoken = try #require(freezes["freeze Text.init(_:) < TeamRow.spoken.getter < TeamRowView.header.getter"])
        #expect(spoken.counts == [AppHealth.Watch.day(start): 10])
        #expect(spoken.first == "hang-20261025-140210")
        #expect(spoken.last == "hang-20261025-140219")
        #expect(spoken.title == "Fix the freeze in Text.init(_:) (from TeamRow.spoken.getter)")
        #expect(freezes["freeze A.three() < A.two() < A.one()"]?.counts.values.reduce(0, +) == 1)
        #expect(freezes["freeze B.three() < B.two() < B.one()"]?.counts.values.reduce(0, +) == 1)
    }

    @Test func tenSimilarErrorLinesAreOneCauseAndTwoDifferentStayApart() throws {
        var watch = AppHealth.Watch()
        watch.saw(lines: (0..<10).map { index in
            "14:02:0\(index).000 lead: couldn't bind session \(UUID().uuidString) on ttys00\(index) after \(index * 7) s in /Users/someone/p\(index)/x: Error Domain=x Code=\(index)"
        } + ["14:03:00.000 wallet: couldn't start passage listen: x", "14:03:01.000 spawn failed: no such folder '/Users/someone/secret-project'"], now: start)
        let lines = watch.causes.byKey.filter { $0.value.kind == .line }
        #expect(lines.count == 3, "\(lines.keys.sorted())")
        let bind = try #require(lines["line lead: couldn't bind session <id> on ttys# after # s in <path>: …"])
        #expect(bind.counts == [AppHealth.Watch.day(start): 10])
        #expect(bind.first == AppHealth.Watch.day(start) + " 14:02:00")
        #expect(bind.last == AppHealth.Watch.day(start) + " 14:02:09")
        #expect(lines["line wallet: couldn't start passage listen: …"] != nil)
        #expect(lines["line spawn failed: no such folder '…'"] != nil)
        // A line that's neither an error nor a notice isn't a cause.
        watch.saw(lines: ["14:04:00.000 window: present"], now: start)
        #expect(watch.causes.byKey.count == 3)
    }

    @Test func aWordIsMaskedByWhatItIs() {
        #expect(AppHealth.masked("host: resize 6F1A2B3C to 80×24 (0x1f) in ~/x/y.log, \"quoted words here\" end", limit: 200)
                    == "host: resize <id> to #×# (<id>) in <path>, \"…\" end")
        #expect(AppHealth.pattern("09:00:00.000 composer: couldn't save the outbox: SECRET-MESSAGE-TEXT") == "composer: couldn't save the outbox: …")
    }

    // MARK: Notices

    @Test func failureNoticesTheAppLogsAreCausesToo() {
        let at = "2026-11-08 10:00:00"
        func key(_ line: String) -> String? { AppHealth.cause(ofLine: line, at: at)?.key }
        #expect(key("10:00:00.000 dictation: Claude's ended, in its session, text taken (42 characters), cut short: VibeSwitcher stalled 3.1 s, after 5.2 s, 3 Spaces, level cursor seen; saw a → b")
                == "notice Dictation cut short")
        #expect(key("10:00:00.000 dictation: Claude's ended, no text: The keys didn't reach the session; nothing was dictated., after 1.0 s, 0 Spaces, level cursor none; saw nothing")
                == "notice Dictation: the keys didn't reach the session")
        #expect(key("10:00:00.000 dictation: Claude's ended, no text: no text within 12 s, after 14.0 s, 2 Spaces, level cursor seen; saw nothing")
                == "notice Dictation gave no text: no text within # s")
        #expect(key("10:00:00.000 composer: the host didn't confirm 120 chars") == "notice Message not sent: the session host didn't confirm it")
        #expect(key("10:00:00.000 composer: steer to /dev/ttys004 didn't reach its inbox, back in the box") == "notice Steer didn't reach the agent's inbox")
        #expect(key("10:00:00.000 shell: req-7f3a didn't start: the host refused it") == "notice Run refused: the shell session didn't start")
        #expect(key("10:00:00.000 chat: the host didn't confirm a code block typed at a shell")
                == "notice Run not confirmed: the session host didn't confirm a code block")
        // A notice without an error word is counted all the same; a line that's only news isn't.
        #expect(AppHealth.errorKind("10:00:00.000 composer: refused, no agent in the terminal") == nil)
        #expect(key("10:00:00.000 composer: refused, no agent in the terminal") == "notice Message refused by the composer")
        #expect(key("10:00:00.000 dictation: Claude's ended, text taken (42 characters), after 5.2 s") == nil)
    }

    /// A code block's Run refused in the chat (VibeSwitcher's `RunRefusal.logLine`): one cause per refusal kind, the
    /// session's kind aside.
    @Test func twoRunRefusalsOfAKindAreOneCause() throws {
        var watch = AppHealth.Watch()
        watch.saw(lines: ["10:00:00.000 chat: Run refused (claude session), kind: wayChanged",
                          "10:05:00.000 chat: Run refused (shell session), kind: wayChanged",
                          "10:06:00.000 chat: Run refused (codex session), kind: notWritten"], now: start)
        let notices = watch.causes.byKey.filter { $0.value.kind == .notice }
        #expect(notices.count == 2, "\(notices.keys.sorted())")
        let changed = try #require(notices["notice Code block's Run refused: wayChanged"])
        #expect(changed.counts == [AppHealth.Watch.day(start): 2])
        #expect(changed.first == AppHealth.Watch.day(start) + " 10:00:00")
        #expect(changed.last == AppHealth.Watch.day(start) + " 10:05:00")
        #expect(notices["notice Code block's Run refused: notWritten"]?.counts == [AppHealth.Watch.day(start): 1])
    }

    @Test func aNoticeOnThreeDaysIsProposed() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        for offset in 0..<3 {
            lines(1, on: offset, into: &watch, folders: folders) { _ in "11:00:00.000 composer: the host didn't confirm 42 chars" }
        }
        watch.look(now: day(3, hour: 0), folders: folders, memory: nil)
        let proposal = try #require(proposals(watch).first)
        #expect(proposal.contains("Proposed task 1: Find why the session host doesn't confirm sent messages"), "\(proposal)")
        #expect(proposal.contains("the notice \"Message not sent: the session host didn't confirm it\" (seen on 3 of the 7 days to \(name(2)))"))
        #expect(proposal.contains("Line, masked: composer: the host didn't confirm # chars"))
    }

    // MARK: Proposing

    @Test func aCauseOnThreeDaysIsProposedOnceThenNotForAWeekUnlessItDoubles() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        // Two a day for three days: proposed when the third closes, once, however many lines.
        for offset in 0..<3 {
            #expect(proposals(watch).isEmpty)
            lines(2, on: offset, into: &watch, folders: folders)
        }
        watch.look(now: day(3, hour: 0), folders: folders, memory: nil)
        #expect(proposals(watch).count == 1)
        let proposal = try #require(proposals(watch).first)
        #expect(proposal.components(separatedBy: "Proposed task ").count == 2, "\(proposal)")
        #expect(AppHealth.wakes(proposal))
        #expect(proposal.contains("Proposed task 1: Fix the repeated app.log error: lead: couldn't bind session <id> on ttys# after # s: …"), "\(proposal)")
        #expect(proposal.contains("(seen on 3 of the 7 days to \(name(2)))"))
        let counts = (-4...2).map { "\(name($0).dropFirst(5)) ×\($0 >= 0 ? 2 : 0)" }.joined(separator: ", ")
        #expect(proposal.contains("Counts by day, \(name(-4)) to \(name(2)): \(counts)."), "\(proposal)")
        #expect(proposal.contains("Lines: first at \(name(0)) 11:00:00, last at \(name(2)) 11:00:01 in ~/.vibeswitcher/debug/app.log"), "\(proposal)")
        #expect(proposal.contains("Line, masked: lead: couldn't bind session <id> on ttys# after # s: …"))
        // The same two a day: not proposed again within the week.
        watch.pending = []
        for offset in 3..<6 {
            lines(2, on: offset, into: &watch, folders: folders)
            watch.look(now: day(offset + 1, hour: 0), folders: folders, memory: nil)
        }
        #expect(proposals(watch).isEmpty, "\(proposals(watch))")
        // Twice the count it was proposed at: proposed again, within the week.
        lines(4, on: 6, into: &watch, folders: folders)
        watch.look(now: day(7, hour: 0), folders: folders, memory: nil)
        let again = try #require(proposals(watch).first)
        #expect(proposals(watch).count == 1)
        #expect(again.contains("doubled again since it was proposed for \(name(2)) (2 → 4 a day)"), "\(again)")
        // A week after that, still coming back: proposed again.
        watch.pending = []
        for offset in 7..<13 {
            lines(4, on: offset, into: &watch, folders: folders)
            watch.look(now: day(offset + 1, hour: 0), folders: folders, memory: nil)
        }
        #expect(proposals(watch).isEmpty, "\(proposals(watch))")
        lines(4, on: 13, into: &watch, folders: folders)
        watch.look(now: day(14, hour: 0), folders: folders, memory: nil)
        #expect(proposals(watch).count == 1)
        #expect(proposals(watch).first?.contains("(seen on 7 of the 7 days to \(name(13)))") == true, "\(proposals(watch))")
    }

    @Test func aCauseThatDoublesDayOverDayIsProposed() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        // 1 → 2 is noise.
        lines(1, on: 0, into: &watch, folders: folders)
        lines(2, on: 1, into: &watch, folders: folders)
        watch.look(now: day(2, hour: 0), folders: folders, memory: nil)
        #expect(proposals(watch).isEmpty)
        // 2 → 5 isn't.
        lines(5, on: 2, into: &watch, folders: folders) { "11:00:0\($0).000 wallet: couldn't reach the signer at port 80\($0)" }
        watch.look(now: day(3, hour: 0), folders: folders, memory: nil)
        #expect(proposals(watch).isEmpty, "a new cause isn't a doubling: \(proposals(watch))")
        lines(11, on: 3, into: &watch, folders: folders) { "11:00:0\($0 % 10).000 wallet: couldn't reach the signer at port 80\($0)" }
        watch.look(now: day(4, hour: 0), folders: folders, memory: nil)
        let proposal = try #require(proposals(watch).first)
        #expect(proposal.contains("wallet: couldn't reach the signer at port #\" (doubled day over day (5 → 11))"), "\(proposal)")
    }

    @Test func manyCausesDueTheSameDayAreOneMessageOfAtMostFive() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        let parts = ["lead", "wallet", "vault", "window", "host", "chat", "sandbox"]
        for offset in 0..<3 {
            watch.saw(lines: parts.map { "11:00:00.000 \($0): couldn't do its thing" }, now: day(offset, hour: 11))
            watch.look(now: day(offset), folders: folders, memory: nil)
        }
        watch.look(now: day(3, hour: 0), folders: folders, memory: nil)
        #expect(proposals(watch).count == 1)
        let message = try #require(proposals(watch).first)
        #expect(message.components(separatedBy: "\nProposed task ").count == 1 + AppHealth.proposalsADay)
        #expect(message.contains("2 more causes come back too; proposed at the next day's close if still due."))
        // The two left wait for the next close.
        watch.pending = []
        watch.saw(lines: parts.map { "11:00:00.000 \($0): couldn't do its thing" }, now: day(3, hour: 11))
        watch.look(now: day(4, hour: 0), folders: folders, memory: nil)
        #expect(proposals(watch).first?.components(separatedBy: "\nProposed task ").count == 3, "\(proposals(watch))")
    }

    @Test func aStarvedFreezeIsNoCause() throws {
        var hang = AppHealth.hang(name: "hang-20261025-140210", log: AppHealthTests.log(), sample: AppHealthTests.sample(pcs: 18))
        #expect(hang.verdict == .starved)
        #expect(AppHealth.cause(of: hang) == nil)
        hang = AppHealth.hang(name: "hang-20261025-140210", log: AppHealthTests.log(), sample: nil)
        #expect(AppHealth.cause(of: hang) == nil)
    }

    // MARK: Secrets

    @Test func aTokenInALineNeverReachesTheProposalOrTheState() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        let token = "ghp_" + String(repeating: "aB3dE5fG7h", count: 4).prefix(36)
        let secret = "sk-ant-api03-" + String(repeating: "Zx9Yw8Vu7T", count: 9)
        for offset in 0..<3 {
            lines(1, on: offset, into: &watch, folders: folders) { _ in
                "11:00:00.000 wallet: couldn't reach the signer with \(token) and key=\(secret): unauthorized \(secret)"
            }
            lines(1, on: offset, into: &watch, folders: folders) { _ in "11:00:01.000 dictation: Claude's ended, no text: token \(token) refused, after 1.0 s" }
        }
        watch.look(now: day(3, hour: 0), folders: folders, memory: nil)
        let proposal = try #require(proposals(watch).first)
        #expect(proposal.contains("Proposed task 1:"), "\(proposal)")
        #expect(proposal.contains("Proposed task 2:"), "\(proposal)")
        let state = String(decoding: try JSONEncoder().encode(watch), as: UTF8.self)
        for text in [proposal, state] {
            for shape in [token, String(token.dropFirst(4)), secret, "Zx9Yw8Vu7T", "aB3dE5fG7h"] {
                #expect(!text.contains(shape), "\(shape) in:\n\(text)")
            }
        }
    }

    // MARK: State

    @Test func aStateFileFromBeforeCausesStillDecodes() throws {
        var old = AppHealth.Watch()
        old.seenHangs = ["hang-20261025-140210"]
        old.lookedOn = "2026-11-07"
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["causeLog"] = nil
        let decoded = try JSONDecoder().decode(AppHealth.Watch.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.seenHangs == ["hang-20261025-140210"])
        #expect(decoded.causes.byKey.isEmpty)
    }

    @Test func oldDaysAndQuietCausesArePruned() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        lines(1, on: 0, into: &watch, folders: folders)
        #expect(watch.causes.byKey.count == 1)
        for offset in 1...9 { watch.look(now: day(offset), folders: folders, memory: nil) }
        #expect(watch.causes.byKey.isEmpty)
    }
}
