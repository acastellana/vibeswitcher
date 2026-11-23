import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The prompt-audit reminder on a node (`PromptAuditWatch.swift`, the app's `PromptAuditDesk`): a project a lead runs in
/// gets a `status` notice once the interval passed since the node first saw it, or since its last run found in its
/// transcripts; `prompt-audit` (the user's voice, recorded) snoozes it a week, turns it off, or back on. The engine's
/// clock is a test's (`promptAuditNow`), so no test waits two weeks.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct PromptAuditWatchTests {
    private let scratch = Scratch()

    private func look(_ world: CardWorld, at now: Date) async {
        let done = Locked(false)
        world.queue.async {
            world.engine.promptAudit.now = { now }
            world.engine.lookAtPromptAudits { done.value = true }
        }
        _ = await eventually(timeout: 60) { done.value }
    }

    private func notices(_ world: CardWorld) -> [String] { world.queue.sync { world.engine.promptAuditNotices } }

    /// A line of Claude's transcript at `at`: an answer on `model`, or the user's `/doctor prompt-audit`.
    private func transcript(_ world: CardWorld, _ lines: [(at: Date, model: String?)]) throws {
        let folder = URL(fileURLWithPath: LeadLaunch.claudeProjectFolder(world.repo, home: world.host.home.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = lines.map { line -> String in
            let at = NodeWire.dateText(line.at)
            guard let model = line.model else {
                return #"{"type":"user","timestamp":"\#(at)","message":{"content":"<command-name>/doctor</command-name><command-args>prompt-audit</command-args>"}}"#
            }
            return #"{"type":"assistant","timestamp":"\#(at)","message":{"model":"\#(model)","content":[]}}"#
        }.joined(separator: "\n") + "\n"
        let file = folder.appendingPathComponent("lead.jsonl")
        if let handle = try? FileHandle(forWritingTo: file) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    @Test func aProjectIsRemindedAfterTheIntervalAndASnoozeOrOffQuietsIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.sleepingLead()
        let start = Date()
        try transcript(world, [(start, "claude-opus-5-5")])
        try #require(await eventually(timeout: 60) { world.queue.sync { world.engine.leadRoots.isEmpty == false } })

        // First sight: no reminder at once, none a day later.
        await look(world, at: start)
        #expect(notices(world).isEmpty)
        await look(world, at: start + 86_400)
        #expect(notices(world).isEmpty)
        // The interval past: the notice says why and what to type, never typed here.
        await look(world, at: start + 15 * 86_400)
        let notice = try #require(notices(world).first, "\(notices(world))")
        #expect(notice.contains("time for a prompt audit in repo") && notice.contains("`/doctor prompt-audit`")
                && notice.contains("No prompt audit seen here in the 15 days"), "\(notice)")

        // Snoozed: quiet for a week; the reply says until when.
        let action = UUID().uuidString.lowercased()
        let snoozed = try #require(await world.ask("prompt-audit", ["folder": .string(world.repo), "do": .string("snooze")], action: action))
        #expect(snoozed.ok && snoozed.result?["until"] != .null, "\(snoozed)")
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["prompt-audit"])
        #expect(notices(world).isEmpty)
        await look(world, at: start + 23 * 86_400)
        #expect(notices(world).count == 1, "a week on, it's due again")

        // Off, then on again.
        let off = try #require(await world.ask("prompt-audit", ["folder": .string(world.repo), "do": .string("off")]))
        #expect(off.ok && notices(world).isEmpty, "\(off)")
        let on = try #require(await world.ask("prompt-audit", ["folder": .string(world.repo), "do": .string("on")]))
        #expect(on.ok && notices(world).count == 1, "\(on)")

        // A run the user typed resets the clock.
        try transcript(world, [(start + 23 * 86_400, nil), (start + 23 * 86_400 + 5, "claude-opus-5-5")])
        await look(world, at: start + 23 * 86_400 + 60)
        #expect(notices(world).isEmpty, "\(notices(world))")
    }

    @Test func aBadChangeIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let relative = try #require(await world.ask("prompt-audit", ["folder": .string("repo"), "do": .string("off")]))
        #expect(relative.error?.code == NodeWire.Code.badArgs.rawValue, "\(relative)")
        let word = try #require(await world.ask("prompt-audit", ["folder": .string(world.repo), "do": .string("never")]))
        #expect(word.error?.code == NodeWire.Code.badArgs.rawValue && word.error?.message.contains("snooze, off or on") == true, "\(word)")
    }

    /// Settings' reminder (`prompt_audit`, `prompt_audit_days`, the app's keys): its days say when a project is due, and
    /// off it says none, whatever the project's record.
    @Test func settingsDaysAndOffDecideTheReminder() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.sleepingLead()
        let start = Date()
        try transcript(world, [(start, "claude-opus-5-5")])
        try #require(await eventually(timeout: 60) { world.queue.sync { world.engine.leadRoots.isEmpty == false } })
        let files = NodeSettings.Files(root: world.host.root)
        _ = try NodeSettings.setNode(try #require(NodeSettings.setting("prompt_audit_days")), to: "3", files: files)
        await look(world, at: start)
        await look(world, at: start + 4 * 86_400)
        #expect(notices(world).count == 1, "3 days, not 14: \(notices(world))")
        _ = try NodeSettings.setNode(try #require(NodeSettings.setting("prompt_audit")), to: "off", files: files)
        await look(world, at: start + 5 * 86_400)
        #expect(notices(world).isEmpty)
    }
}
