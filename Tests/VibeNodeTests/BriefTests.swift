import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// Brief me (`BriefRequest.swift`, the app's `Briefing/`): what happened lately and what's asked of you, built by the
/// node from its leads' logs and boards (the app's `Briefing.compose`), the sessions waiting, the other cards and the
/// all-done marks; the template's words with no model, the model's (a fake here, never a real one) while the AI
/// summaries may run, kept a while so asking again asks no model; a read of the user's own or a page's, never a
/// session's. Each test has a scratch host; nothing is slept on.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct BriefTests {
    private let scratch = Scratch()

    /// A lead whose log landed a task an hour ago, with a task running and an all-done mark of the last day.
    private func project(_ world: CardWorld) async throws {
        _ = try await world.world.lead()
        let repo = world.repo
        try await offPool {
            let store = BoardStore(root: repo)
            try store.appendProgress("Merged pricing-copy: the pricing page's copy")
            try store.update { board in
                board.tasks.append(LeadTask(slug: "onboarding", title: "Onboarding steps",
                                            contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""), status: .running))
                var mark = LeadAllDone(id: "m1", at: Date().timeIntervalSince1970 - 600, since: 0,
                                       tasks: [LeadAllDone.Task(slug: "pricing-copy", title: "Pricing copy", outcome: .merged)])
                mark.summary = LeadAllDone.Summary(headline: "The pricing page reads well", bullets: [], byModel: false)
                board.allDone = [mark]
            }
        }
        world.engine.refresh()
        await world.world.drained()
    }

    @Test func theWrittenBriefingSaysWhatHappenedAndWhatWaits() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        try await project(world)
        let reply = try #require(await world.ask("brief", action: nil))
        let result = try #require(reply.result, "\(reply)")
        #expect(WireSchema.check(result, as: "brief.result") == nil)
        let text = try #require(result["text"]?.string)
        #expect(text.contains("In repo,") && text.contains("1 landed") && text.contains("1 running"), "\(text)")
        #expect(text.contains("repo finished all its tasks: The pricing page reads well."), "\(text)")
        #expect(result["byModel"] == .bool(false) && result["notice"] == .null && result["kept"] == .bool(false), "no model meant: no notice")
        let lines = BriefCommandLines.lines(result)
        #expect(lines.first == text && lines.last == "(written from the boards and logs, no model asked)")
        // A project's own briefing.
        let one = try #require(await world.ask("brief", ["folder": .string(world.repo)], action: nil)?.result)
        #expect(one["text"]?.string?.contains("In repo,") == true, "\(one)")
    }

    /// While the AI summaries may run, the model writes it from the app's prompt with the node's notes (the all-done
    /// mark), once: asking again within the kept time gives the same briefing, `kept`.
    @Test func theModelWritesItOnceWhileTheSummariesMayRun() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        try await project(world)
        let prompts = Locked<[String]>([])
        world.queue.sync {
            world.engine.summariesAllowed = true
            world.engine.briefModel = { prompt in prompts.mutate { $0.append(prompt) }; return "One fix landed in repo and the onboarding work is running." }
        }
        let first = try #require(await world.ask("brief", action: nil)?.result)
        #expect(first["byModel"] == .bool(true) && first["text"] == .string("One fix landed in repo and the onboarding work is running."), "\(first)")
        let prompt = try #require(prompts.value.first)
        #expect(prompt.contains("Landed: the pricing page's copy") && prompt.contains("repo: all its tasks finished; The pricing page reads well."), "\(prompt)")
        let again = try #require(await world.ask("brief", action: nil)?.result)
        #expect(again["kept"] == .bool(true) && again["text"] == first["text"] && prompts.value.count == 1)
        // The model gives nothing: the written briefing, saying so.
        world.queue.sync {
            world.engine.briefs = [:]
            world.engine.briefModel = { _ in nil }
        }
        let fallback = try #require(await world.ask("brief", action: nil)?.result)
        #expect(fallback["byModel"] == .bool(false) && fallback["notice"]?.string?.contains("template") == true, "\(fallback)")
    }

    /// A session's process can't ask (it would spend the account's usage); a page's token that reads can.
    @Test func aSessionsProcessIsRefusedAndAPageMayAsk() async throws {
        #expect(NodeWire.kinds["brief"] == .webRead && !NodeWire.changesState("brief"))
        #expect(WebAccess.refusal(for: NodeWire.Request(id: "1", kind: "brief"), rights: [.read]) == nil)
        #expect(WebAccess.refusal(for: NodeWire.Request(id: "2", kind: "brief"), rights: [])?.error?.code == NodeWire.Code.voice.rawValue)
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        var session = CardWorld.user
        session.sessionMarker = true
        let refused = try #require(await world.ask("brief", action: nil, from: session))
        #expect(refused.error?.code == NodeWire.Code.voice.rawValue, "\(refused)")
        let paged = await withCheckedContinuation { done in
            world.requests.queue.async { world.requests.webRead(NodeWire.Request(id: "p", kind: "brief")) { done.resume(returning: $0) } }
        }
        #expect(paged.result?["text"]?.string == "No project lead is running and no session needs you.", "\(paged)")
    }
}
