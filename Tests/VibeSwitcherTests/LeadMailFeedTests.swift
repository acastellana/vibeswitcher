import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The Team tab's Between leads (`LeadMailFeed`): every message in the project's lead-mail record, sent and received,
/// newest first, a refused one with why; read with the boards (`LeadFiles.mail`); and Settings' switch for the channel.
struct LeadMailFeedTests {
    private func newRoot() throws -> String {
        let root = scratchRoot.appendingPathComponent("lead-mail-feed-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    @Test func itListsTheRecordsMessagesNewestFirstWithTheRefusedReason() throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let me = LeadMail.project(of: root)
        let records = [
            LeadMail.Record(at: 1_000, from: me, to: "api", kind: .question, text: "Is the id a string?", outcome: .delivered,
                            detail: "Delivered: typed in as the lead of api's next prompt."),
            LeadMail.Record(at: 2_000, from: "api", to: me, kind: .answer, text: "Yes.", outcome: .delivered,
                            detail: "Delivered to the lead of \(me) while it works: it gets it at its next step."),
            LeadMail.Record(at: 3_000, from: me, to: "api", kind: .report, text: "The token: [masked]", outcome: .refused,
                            detail: "Refused, not sent: the text holds something shaped like a credential (API key): never send one to another lead; leave it out."),
            LeadMail.Record(at: 4_000, from: me, to: "docs", kind: nil, text: "Hello", outcome: .refused,
                            detail: "Refused, not sent: kind is question, report or answer, not \"hi\"."),
        ]
        // Through the record as tell_lead keeps it, and read as the boards are.
        for record in records { try LeadMail.append(record, root: root) }
        var files = LeadFiles()
        let feed = LeadMailFeed(files.mail(root), project: me)

        #expect(feed.items.map(\.at) == [4_000, 3_000, 2_000, 1_000])
        #expect(feed.items.map(\.text) == ["Hello", "The token: [masked]", "Yes.", "Is the id a string?"])
        #expect(feed.items.map(\.kind) == ["No kind", "Report", "Answer", "Question"])
        #expect(feed.items.map(\.received) == [false, false, true, false])
        #expect(feed.items.map(\.from) == [me, me, "api", me])
        #expect(feed.items.map(\.to) == ["docs", "api", me, "api"])

        let refused = feed.items[1]
        #expect(refused.refused && refused.outcomeLabel == "Refused")
        #expect(refused.reason == "The text holds something shaped like a credential (API key): never send one to another lead; leave it out.")
        #expect(feed.items[0].reason == "Kind is question, report or answer, not \"hi\".")
        // A delivered one has no reason, only what became of it.
        #expect(feed.items[2].reason == nil && !feed.items[2].refused && feed.items[2].outcomeLabel == "Delivered")
        // VoiceOver hears the refusal too.
        #expect(LeadMailList.spoken(refused).hasSuffix("Refused: The text holds something shaped like a credential (API key): never send one to another lead; leave it out."))
    }

    @Test func twoAtTheSameTimeShowTheLaterLineFirst() {
        let records = ["first", "second"].map {
            LeadMail.Record(at: 5, from: "a", to: "b", kind: .report, text: $0, outcome: .waiting, detail: "Sent.")
        }
        #expect(LeadMailFeed(records, project: "a").items.map(\.text) == ["second", "first"])
    }

    @Test func theRecordIsReadAgainOnlyWhenItChanged() throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var files = LeadFiles()
        #expect(files.mail(root).isEmpty)
        #expect(files.fileReads == 0)
        let record = LeadMail.Record(at: 1, from: "a", to: "b", kind: .report, text: "one", outcome: .delivered, detail: "Delivered.")
        try LeadMail.append(record, root: root)
        #expect(files.mail(root).map(\.text) == ["one"])
        _ = files.mail(root)
        #expect(files.fileReads == 1)
        var second = record
        second.text = "two"
        try LeadMail.append(second, root: root)
        #expect(files.mail(root).map(\.text) == ["one", "two"])
        #expect(files.fileReads == 2)
    }

    @Test func settingsSwitchIsOnAtFirstAndTurnsTheChannelOff() throws {
        let temp = Scratch()
        let defaults = temp.defaults("lead-mail")
        let presets = temp.url("lead-mail-presets")
        let preferences = Preferences(defaults: defaults, presetsFile: presets)
        #expect(preferences.leadMail)
        #expect(LeadMail.isOn(defaults))
        preferences.leadMail = false
        // The key the tool server reads (`LeadMail.isOn`): off.
        #expect(!LeadMail.isOn(defaults))
        #expect(!Preferences(defaults: defaults, presetsFile: presets).leadMail)
        preferences.leadMail = true
        #expect(LeadMail.isOn(defaults))
    }
}
