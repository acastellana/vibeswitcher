import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A build switch parks the workers that only wait on their lead (`SwitchPark`), and decision 6 still refuses it while a
/// worker is mid-turn: on a scratch node with two installed builds, a lead and its worker (the fake Claude, through their
/// own tool servers). Mid-turn, the switch is refused naming the worker and nothing is parked; idle since its report,
/// `status` says the switch would park it, the switch parks it (its session ends, its task marked, its lead told) and
/// hands over, the lead kept.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct SwitchParkTests {
    private let scratch = Scratch()
    static let (a, b) = (String(repeating: "a", count: 40), String(repeating: "b", count: 40))

    @Test func theRuleParksOnlyAnIdleTasksOwnWorkerWithNothingSince() {
        let worker = UUID().uuidString
        var task = LeadTask(slug: "parser", title: "Parser", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""), status: .review)
        task.worker = worker
        task.since = 100
        let idle = LeadActivity.idle(background: nil)
        #expect(SwitchPark.parkable(task: task, worker: worker.lowercased(), activity: idle, held: false))
        #expect(!SwitchPark.parkable(task: task, worker: worker, activity: .working(nil), held: false), "mid-turn")
        #expect(!SwitchPark.parkable(task: task, worker: worker, activity: .needsInput(nil), held: false), "at a prompt")
        #expect(!SwitchPark.parkable(task: task, worker: worker, activity: .idle(background: "npm run dev"), held: false), "on a background command")
        #expect(!SwitchPark.parkable(task: task, worker: worker, activity: nil, held: false), "not read")
        #expect(!SwitchPark.parkable(task: task, worker: worker, activity: idle, held: true), "a message waits for it")
        #expect(!SwitchPark.parkable(task: task, worker: UUID().uuidString, activity: idle, held: false), "another task's")
        var messaged = task
        messaged.messagedAt = 200
        #expect(!SwitchPark.parkable(task: messaged, worker: worker, activity: idle, held: false), "told something since its report")
        var stopped = task
        stopped.stopped = worker
        #expect(!SwitchPark.parkable(task: stopped, worker: worker, activity: idle, held: false), "ended already")
        let told = SwitchPark.told([.init(root: "/r", slug: "parser", session: UUID(), tty: "pts/1", label: "Worker: Parser")], commit: Self.b)
        #expect(told.contains("parser") && told.contains("start_worker continues there") && told.contains(String(Self.b.prefix(12))), "\(told)")
    }

    @Test func aWorkerMidTurnRefusesTheSwitchAndAnIdleOneIsParked() async throws {
        let installs = scratch.url("builds")
        let buildA = try ScratchBuilds.install(commit: Self.a, into: installs)
        _ = try ScratchBuilds.install(commit: Self.b, into: installs)
        let node = try await ScratchNode(scratch, holdFirstLook: true, build: buildA, installRoot: installs)
        defer { node.stop() }
        let repo = try await NodeAcceptanceTests.repository(node)
        let lead = try await NodeAcceptanceTests.startLead(node, repo, goal: "write the parser")
        let worker = try await NodeAcceptanceTests.planAndStart(node, lead, title: "Write the parser")
        let files = node.fake.files(terminal: worker.tty)
        let pid = try #require((EngineEndToEndTests.state(files)["pid"] as? Int).map(Int32.init))
        try files.call("report", ["task": "write-the-parser", "status": "blocked", "summary": "it needs the grammar"])
        try #require(await eventually(timeout: 120) { files.calls().count == 2 }, "\(node.said)")
        let client = try WireClient(node)

        // Mid-turn: refused by name, nothing parked.
        try hook(node, ["hook_event_name": "UserPromptSubmit", "prompt": "go on"], tty: worker.tty, pid: pid)
        let refused = try #require(WireClient.reply(client.request("build.switch", args: ["commit": .string(Self.b)], timeout: SwitchRequest.longestWait)))
        #expect(!refused.ok && (refused.error?.message ?? "").contains("decision 6") && (refused.error?.message ?? "").contains(worker.tty), "\(refused)")
        #expect(try node.sessions().contains { $0.id == worker.id && $0.isLive }, "a worker mid-turn is never parked")

        // Idle since its report: status says the switch parks it, and nothing refuses it up front.
        try hook(node, ["hook_event_name": "Stop"], tty: worker.tty, pid: pid)
        #expect(await node.eventuallyStatus { status in
            ((status["switchParks"] as? [String]) ?? []).contains { $0.contains(worker.tty) } && (status["switchBlockers"] as? [String]) == []
        }, "\(node.said)")
        let handed = try #require(WireClient.reply(client.request("build.switch", args: ["commit": .string(Self.b)], timeout: SwitchRequest.longestWait)),
                                  "\(node.said)")
        #expect(handed.ok && handed.result?["outcome"]?.string == "handed-over", "\(handed)\n\(node.said)")
        #expect((handed.result?["parked"]?.array ?? []).compactMap(\.string).contains { $0.contains(worker.tty) }, "\(handed)")
        #expect(try node.sessions().contains { $0.id == lead.session.id && $0.isLive }, "the lead stays")
        #expect(try !node.sessions().contains { $0.id == worker.id && $0.isLive }, "the worker was parked")
        let board = BoardStore(root: repo.path).load()
        #expect(board.task("write-the-parser")?.stopped?.lowercased() == worker.id.uuidString.lowercased(), "its end is no news")
        #expect(node.said.contains("build.switch: parked write-the-parser in "), "\(node.said)")
        // Its lead is told.
        #expect(await eventually(timeout: 120) { node.inbox(lead.session.tty).contains { $0.text.contains("The user switched VibeSwitcher's build") } },
                "\(node.inbox(lead.session.tty).map(\.text))\n\(node.said)")
    }
}
