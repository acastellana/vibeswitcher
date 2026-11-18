import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The prompt audit reminder in the app (`PromptAuditDesk`): its card's buttons, on an injected clock, and Run now
/// into a lead session that is a fake Claude Code on a scratch pty (`FakeClaude`, through a scratch session host:
/// never a real session).
@MainActor
@Suite(.serialized)
struct PromptAuditDeskTests {
    let temp = Scratch()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    /// A made-up project folder: only its name is used (its transcripts are in the scratch home).
    let root = "/Users/someone/dev/prompt-audit-project"

    final class Clock { var now: Date; init(_ now: Date) { self.now = now } }

    /// A desk on a scratch home and record, its projects `[root]`, at `clock`'s time; looked at once.
    func desk(_ clock: Clock) async throws -> PromptAuditDesk {
        let home = temp.url("prompt-audit-home")
        try FileManager.default.createDirectory(at: PromptAudit.transcripts(root: root, home: home.path), withIntermediateDirectories: true)
        let desk = PromptAuditDesk(file: home.appendingPathComponent("prompt-audit.json"), home: home.path, clock: { clock.now })
        desk.roots = { [root] in [root] }
        await refresh(desk)
        return desk
    }

    func refresh(_ desk: PromptAuditDesk) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in desk.refresh { done.resume() } }
    }

    @Test func theCardsButtonsAndNothingSentWithoutTheClick() async throws {
        let clock = Clock(start)
        let desk = try await desk(clock)
        defer { desk.close() }  // its writes land before the scratch home goes
        var sent: [String] = []
        let send: (String) -> Bool = { sent.append($0); return true }
        #expect(desk.due.isEmpty)
        clock.now = start.addingTimeInterval(13 * 86_400)
        await refresh(desk)
        #expect(desk.due.isEmpty)
        clock.now = start.addingTimeInterval(14 * 86_400)
        await refresh(desk)
        #expect(desk.due[root] == .interval(since: start, ranBefore: false))
        // Looks, recomputes, a snooze and its end: nothing typed anywhere.
        desk.snooze(root)
        #expect(desk.due.isEmpty)
        clock.now = start.addingTimeInterval(21 * 86_400)
        await refresh(desk)
        #expect(desk.due[root] != nil)
        // Settings › Project lead off: no card; on again: back.
        desk.enabled = false
        #expect(desk.due.isEmpty)
        desk.enabled = true
        #expect(desk.due[root] != nil)
        #expect(sent.isEmpty)
        // A session that couldn't take it: the card stays, saying so; the clock doesn't restart.
        #expect(!desk.runNow(root, send: { _ in false }))
        #expect(desk.due[root] != nil && desk.refused[root] != nil)
        // Run now: exactly the command, once, and the card goes for a whole interval.
        #expect(desk.runNow(root, send: send))
        #expect(sent == [PromptAudit.command])
        #expect(desk.due.isEmpty && desk.refused[root] == nil)
        clock.now = start.addingTimeInterval(34.9 * 86_400)
        await refresh(desk)
        #expect(desk.due.isEmpty)
        clock.now = start.addingTimeInterval(35 * 86_400)
        await refresh(desk)
        #expect(desk.due[root] != nil)
        // Not for this project: gone for good, kept across a new desk on the same record.
        desk.turnOff(root)
        #expect(desk.due.isEmpty)
        desk.close()  // its write landed
        let again = PromptAuditDesk(file: desk.file, home: desk.home, clock: { clock.now })
        again.roots = { [root] in [root] }
        defer { again.close() }
        clock.now = start.addingTimeInterval(400 * 86_400)
        await refresh(again)
        #expect(again.due.isEmpty)
        #expect(sent == [PromptAudit.command])
        // With no card, Run now sends nothing.
        #expect(!again.runNow(root, send: send))
        #expect(sent == [PromptAudit.command])
    }

    /// Run now types `/doctor prompt-audit` into the lead's session as the composer's message: here a fake Claude
    /// Code, whose transcript then holds it as the user's prompt, once.
    @Test func runNowSendsTheCommandIntoTheLeadSessionOnlyOnTheClick() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let clock = Clock(start)
        let desk = try await desk(clock)
        defer { desk.close() }
        clock.now = start.addingTimeInterval(14 * 86_400)
        await refresh(desk)
        #expect(desk.due[root] != nil)
        // The card shown, nothing clicked: the session gets nothing.
        try await h.quiet()
        let before = try String(contentsOf: h.transcript, encoding: .utf8)
        #expect(!before.contains(PromptAudit.command))

        #expect(desk.runNow(root, send: { h.sync.type($0) }))
        try await h.waitFor { (try? String(contentsOf: h.transcript, encoding: .utf8))?.contains("Got: \(PromptAudit.command)") == true }
        let lines = try String(contentsOf: h.transcript, encoding: .utf8).split(separator: "\n")
        let prompts = lines.compactMap { line -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["type"] as? String == "user" else { return nil }
            return (object["message"] as? [String: Any])?["content"] as? String
        }
        #expect(prompts.filter { $0 == PromptAudit.command }.count == 1, "\(prompts)")
        #expect(desk.due.isEmpty)
    }
}

extension PromptAuditDeskTests {
    /// The record file is read by the first look (off the main thread), not when the desk is made, and nothing set
    /// before that look writes over the projects the file holds.
    @Test func theRecordIsReadByTheFirstLookAndNotWrittenOverBeforeIt() async throws {
        let home = temp.url("prompt-audit-record-home")
        let other = "/Users/someone/dev/another-project"
        try FileManager.default.createDirectory(at: PromptAudit.transcripts(root: root, home: home.path), withIntermediateDirectories: true)
        let file = home.appendingPathComponent("prompt-audit.json")
        var kept = PromptAudit.Book()
        var off = PromptAudit.Project(firstSeen: start)
        off.off = true
        kept.projects[other] = off
        try kept.save(to: file)
        let clock = Clock(start)
        let desk = PromptAuditDesk(file: file, home: home.path, clock: { clock.now })
        desk.roots = { [root] in [root] }
        #expect(desk.book.projects.isEmpty)
        // Set before the first look: shown, kept, and laid over the file's projects rather than written over them.
        desk.set(root, PromptAudit.Project(firstSeen: start.addingTimeInterval(-15 * 86_400)))
        #expect(desk.due[root] != nil)
        await refresh(desk)
        desk.close()
        #expect(desk.book.projects[other]?.off == true)
        #expect(desk.due[root] != nil)
        let written = PromptAudit.Book.load(from: file)
        #expect(written.projects[other]?.off == true && written.projects[root] != nil)
    }
}
