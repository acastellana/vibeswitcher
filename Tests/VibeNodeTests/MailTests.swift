import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// "Between leads" (`MailRequest.swift`, the app's `LeadMailViews.swift`): `mail` gives a project's record of its lead's
/// tell_lead messages, newest first, which way each went and what became of it; only to the user's voice (it's a private
/// record), with no code; `MailText` prints it with every lead's word inert.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct MailTests {
    private let scratch = Scratch()

    @Test func aProjectsMessagesComeNewestFirstEachSaidWhichWay() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let project = LeadMail.project(of: world.repo)
        try LeadMail.append(.init(at: 1_763_600_000, from: project, to: "acme", kind: .question, text: "Which port?", outcome: .delivered,
                                  detail: "Delivered."), root: world.repo)
        try LeadMail.append(.init(at: 1_763_600_060, from: "acme", to: project, kind: .answer, text: "8080\u{1B}[2J", outcome: .waiting,
                                  detail: "Waiting."), root: world.repo)
        try LeadMail.append(.init(at: 1_763_600_120, from: project, to: "acme", kind: nil, text: "x", outcome: .refused,
                                  detail: "Refused, not sent: the kind is question, report or answer"), root: world.repo)

        let reply = try #require(await world.ask("mail", ["folder": .string(world.repo)], action: nil))
        let projects = try #require(reply.result?["projects"]?.array, "\(reply)")
        #expect(projects.count == 1 && projects[0]["total"]?.int == 3 && projects[0]["project"]?.string == project, "\(reply)")
        let messages = projects[0]["messages"]?.array ?? []
        #expect(messages.map { $0["outcome"]?.string } == ["refused", "waiting", "delivered"], "\(messages)")
        #expect(messages.map { $0["received"]?.bool } == [false, true, false], "\(messages)")
        #expect(messages[0]["kind"] == .null && messages[0]["sent"]?.bool == false, "\(messages)")

        let lines = MailText.lines(projects[0])
        #expect(lines.first == "Between leads · \(project) (3 messages)", "\(lines)")
        #expect(lines.contains { $0.contains("from the lead of acme · Answer · waiting in its inbox") }, "\(lines)")
        #expect(lines.contains { $0.contains("to the lead of acme · No kind · refused") }, "\(lines)")
        #expect(lines.contains("      why: Refused, not sent: the kind is question, report or answer"), "\(lines)")
        #expect(!lines.joined().contains("\u{1B}"), "a lead's words reach the terminal inert: \(lines)")
    }

    /// Without a folder, every project with a lead; none here. A relative folder is refused; so is a peer that isn't the
    /// user's voice (a session's process): the record is private.
    @Test func theRecordIsTheUsersAlone() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let none = try #require(await world.ask("mail", action: nil))
        #expect(none.result?["projects"]?.array?.isEmpty == true, "\(none)")
        let relative = try #require(await world.ask("mail", ["folder": .string("repo")], action: nil))
        #expect(relative.error?.code == NodeWire.Code.badArgs.rawValue, "\(relative)")
        var session = CardWorld.user
        session.sessionMarker = true
        let refused = try #require(await world.ask("mail", ["folder": .string(world.repo)], action: nil, from: session))
        #expect(refused.error?.code == NodeWire.Code.voice.rawValue, "\(refused)")
    }

    /// More messages than `mailShown`: the newest shown, the count saying so; `all` gives every one.
    @Test func theNewestAreShownAndAllGivesEveryOne() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        for index in 0..<(Requests.mailShown + 3) {
            try LeadMail.append(.init(at: 1_763_600_000 + Double(index), from: "acme", to: LeadMail.project(of: world.repo), kind: .report,
                                      text: "report \(index)", outcome: .delivered, detail: "Delivered."), root: world.repo)
        }
        let some = try #require(await world.ask("mail", ["folder": .string(world.repo)], action: nil)?.result?["projects"]?.array?.first)
        #expect(some["messages"]?.array?.count == Requests.mailShown && some["messages"]?.array?.first?["text"]?.string == "report \(Requests.mailShown + 2)")
        #expect(MailText.lines(some).first?.contains("the newest \(Requests.mailShown) shown: --all for every one") == true)
        let every = try #require(await world.ask("mail", ["folder": .string(world.repo), "all": .bool(true)], action: nil)?.result?["projects"]?.array?.first)
        #expect(every["messages"]?.array?.count == Requests.mailShown + 3)
    }
}
