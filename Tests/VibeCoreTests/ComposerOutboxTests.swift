import Foundation
import Testing
@testable import VibeCore

struct ComposerOutboxTests {
    let key = "host:6D824633-4242-4E59-B4B2-5F2A95AE034D"
    let sent = Date(timeIntervalSince1970: 1_792_258_000)

    func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
    }

    /// The composer's message for this text and these images: the text, then the quoted paths.
    func message(_ text: String, _ images: [String]) -> String {
        let paths = images.map(RecentProjects.shellQuote).joined(separator: " ")
        return [text, paths].filter { !$0.isEmpty }.joined(separator: text.isEmpty ? "" : "\n\n")
    }

    func entry(_ text: String, images: [String] = [], at: Date? = nil) -> OutboxEntry {
        OutboxEntry(key: key, message: message(text, images), text: text, attachments: images, sentAt: at ?? sent, expectsSoon: true)
    }

    // 19:25: sent with a pasted screenshot; Claude Code replaced the path with an image block and wrote
    // "[Image #19]" before the text. The chat kept calling it undelivered.
    @Test func aMessageWithAPastedImageMatchesItsImageBlock() {
        let image = "/Users/albert/.vibeswitcher/attachments/pasted-2026-10-17-192531-5E66.png"
        let text = "How are things going? Can you check against your memory to see if this is still the plan or what's going on?"
        let prompt = SentMatch.Prompt(text: "[Image #19]" + text, images: 1, at: sent.addingTimeInterval(1))
        #expect(SentMatch.matches(message(text, [image]), attachments: [image], prompt: prompt))

        var outbox = Outbox()
        outbox.add(entry(text, images: [image]))
        outbox.confirm(key: key, message: message(text, [image]), ok: true)
        #expect(outbox.delivered(key: key, prompts: [prompt]).count == 1)
        #expect(outbox.entries.isEmpty)

        let pending = PendingMessage(text: message(text, [image]), afterPrompts: 0, expectsSoon: true, sentAt: sent, attachments: [image])
        #expect(PendingMessage.remaining([pending], prompts: [prompt]).isEmpty)
    }

    @Test func imagesHaveToArriveToo() {
        let image = "/tmp/a.png"
        // The same words without the image: not this message.
        #expect(!SentMatch.matches(message("look", [image]), attachments: [image], prompt: SentMatch.Prompt(text: "look")))
        // The agent kept the path as text instead of an image block: it still arrived.
        #expect(SentMatch.matches(message("look", [image]), attachments: [image], prompt: SentMatch.Prompt(text: "look\n\n/tmp/a.png")))
        // Only an image.
        #expect(SentMatch.matches(message("", [image]), attachments: [image], prompt: SentMatch.Prompt(text: "[Image #3]", images: 1)))
        // Other words: never.
        #expect(!SentMatch.matches(message("look", [image]), attachments: [image], prompt: SentMatch.Prompt(text: "[Image #3] look again", images: 1)))
        // Whitespace the agent changed doesn't matter.
        #expect(SentMatch.matches("one\n\ntwo  three", attachments: [], prompt: SentMatch.Prompt(text: "one\ntwo three")))
    }

    @Test func pendingToDelivered() {
        var outbox = Outbox()
        let first = entry("hello")
        outbox.add(first)
        #expect(outbox.onTheirWay(key: key).map(\.id) == [first.id])
        #expect(outbox.confirm(key: key, message: "hello", ok: true) == first.id)
        #expect(outbox.entry(first.id)?.state == .typed)
        // An earlier "hello" (before it was sent) isn't it; nor is another session's.
        #expect(outbox.delivered(key: key, prompts: [SentMatch.Prompt(text: "hello", at: sent.addingTimeInterval(-60))]).isEmpty)
        #expect(outbox.delivered(key: "host:other", prompts: [SentMatch.Prompt(text: "hello", at: sent.addingTimeInterval(1))]).isEmpty)
        #expect(outbox.entries.count == 1)
        #expect(outbox.delivered(key: key, prompts: [SentMatch.Prompt(text: "hello", at: sent.addingTimeInterval(1))]) == [first.id])
        #expect(outbox.entries.isEmpty)
    }

    @Test func onePromptAnswersOneEntry() {
        var outbox = Outbox()
        let a = entry("yes"), b = entry("yes", at: sent.addingTimeInterval(5))
        outbox.add(a)
        outbox.add(b)
        #expect(outbox.delivered(key: key, prompts: [SentMatch.Prompt(text: "yes", at: sent.addingTimeInterval(1))]) == [a.id])
        #expect(outbox.entries.map(\.id) == [b.id])
    }

    @Test func aSlashCommandIsDoneWhenTheHostTakesIt() {
        var outbox = Outbox()
        outbox.add(OutboxEntry(key: key, message: "/compact", text: "/compact"))
        outbox.confirm(key: key, message: "/compact", ok: true)
        #expect(outbox.entries.isEmpty)
    }

    @Test func deliveryFailureIsKept() throws {
        var outbox = Outbox()
        let failed = entry("are you there?")
        outbox.add(failed)
        #expect(outbox.confirm(key: key, message: "are you there?", ok: false) == failed.id)
        #expect(outbox.entry(failed.id)?.state == .failed)
        #expect(outbox.onTheirWay(key: key).isEmpty)
        #expect(outbox.needsYou(key: key).map(\.id) == [failed.id])
        // Kept on disk too.
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        try OutboxStore.save(outbox.entries, to: url)
        #expect(OutboxStore.load(url).map(\.state) == [.failed])
        // Send now: on its way again, from now.
        let now = sent.addingTimeInterval(120)
        #expect(outbox.resend(failed.id, at: now)?.state == .sending)
        #expect(outbox.entry(failed.id)?.sentAt == now)
        #expect(outbox.needsYou(key: key).isEmpty)
        // It can still show up later: then it's delivered, whatever its state.
        outbox.confirm(key: key, message: "are you there?", ok: false)
        #expect(outbox.delivered(key: key, prompts: [SentMatch.Prompt(text: "are you there?", at: now)]) == [failed.id])
    }

    // 16:47: the app hung while sending and was relaunched; the message must come back, not vanish.
    @Test func pendingThenRestartIsRestored() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        var outbox = Outbox()
        let image = "/Users/albert/.vibeswitcher/attachments/pasted-2026-10-17-164759-3B80.png"
        let stuck = entry("look at this", images: [image])
        let typed = entry("and this", at: sent.addingTimeInterval(3))
        outbox.add(stuck)
        outbox.add(typed)
        outbox.confirm(key: key, message: "and this", ok: true)
        try OutboxStore.save(outbox.entries, to: url)

        // Relaunch.
        var restored = Outbox(restoring: OutboxStore.load(url))
        #expect(restored.entries == outbox.entries)
        #expect(restored.entry(stuck.id)?.attachments == [image])
        #expect(restored.entry(stuck.id)?.state == .sending)
        #expect(restored.onTheirWay(key: key).isEmpty)                         // never sent again by itself
        #expect(Set(restored.needsYou(key: key).map(\.id)) == [stuck.id, typed.id])
        // The same words sent again this launch are a new entry: the host's answer for those doesn't touch it.
        #expect(restored.confirm(key: key, message: message("look at this", [image]), ok: true) == nil)
        #expect(restored.entry(stuck.id)?.state == .sending)
        // The one that made it is dropped once the conversation shows it.
        #expect(restored.delivered(key: key, prompts: [SentMatch.Prompt(text: "and this", at: sent.addingTimeInterval(4))]) == [typed.id])
        #expect(restored.needsYou(key: key).map(\.id) == [stuck.id])
        // Discard.
        #expect(restored.remove(stuck.id)?.text == "look at this")
        #expect(restored.entries.isEmpty && restored.restored.isEmpty)
    }

    @Test func handedToTheSteerInboxLeavesTheOutbox() {
        var outbox = Outbox()
        outbox.add(entry("steer this"))
        #expect(outbox.handedOff(key: key, message: "steer this") != nil)
        #expect(outbox.entries.isEmpty)
    }

    @Test func aMissingOrBrokenFileIsAnEmptyOutbox() throws {
        let url = file()
        #expect(OutboxStore.load(url).isEmpty)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(OutboxStore.load(url).isEmpty)
    }

    /// ~/.vibeswitcher/outbox.json kept restoring "go on" for a lead lost with a replaced host, on every launch.
    @Test func messagesToASessionTheHostNoLongerHasAreDropped() {
        let gone = UUID(), here = UUID()
        var outbox = Outbox(restoring: [OutboxEntry(key: "host:\(gone)", message: "go on", text: "go on", state: .typed),
                                        OutboxEntry(key: "host:\(here)", message: "hi", text: "hi"),
                                        OutboxEntry(key: "agent:abc", message: "terminal", text: "terminal")])
        let dropped = outbox.dropGone(known: [here])
        #expect(dropped.map(\.message) == ["go on"])
        #expect(outbox.entries.map(\.message) == ["hi", "terminal"])
        #expect(!outbox.restored.contains(dropped[0].id))
        // Once only: nothing left to drop.
        #expect(outbox.dropGone(known: [here]).isEmpty)
    }
}
