import Foundation
import Testing
@testable import VibeCore

/// start_worker's and auto_advance's warning when a task's boundaries name a file other work has (see `LeadOverlap`),
/// through the tools themselves: what the lead reads, on real branches. Waits are on the loop's own passes.
extension LeadAdvanceTests {
    /// A planned task with these boundaries, moved by hand only unless `auto`.
    func plan(_ lead: LeadToolset, _ title: String, _ boundaries: [String], auto: Bool = false) {
        let added = lead.call("add_task", ["title": title, "goal": "g", "acceptance": ["a"], "boundaries": boundaries, "auto_advance": auto])
        #expect(!added.isError, "\(added.text)")
    }

    func committing(_ path: String, in dir: String) throws {
        try FileManager.default.createDirectory(atPath: ((dir + "/" + path) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try commit(path, "code\n", in: dir)
    }

    /// The input path's files on the base, as this repository has them.
    func withInputPath(_ root: String) throws {
        for file in ["Sources/VibeSwitcher/PhoneAccess.swift", "Sources/VibeSwitcher/HostClient.swift", "Sources/VibeSwitcher/RemoteInput.swift", "Sources/VibeHost/InputOrder.swift"] {
            try committing(file, in: root)
        }
    }

    @Test func overlapReplyNamesEachFileTaskAndStateAndSaysNothingWithout() throws {
        let (root, _, lead) = try team(test: nil, ["max_workers": 6])
        plan(lead, "Runs", ["May change Sources/App/Both.swift"])
        #expect(!lead.call("start_worker", ["task": "runs"]).isError)
        try committing("Sources/App/Changed.swift", in: Worktrees.path(root: root, slug: "runs"))
        plan(lead, "Later", ["`Sources/App/Planned.swift` and its tests"])
        plan(lead, "Target", ["Sources/App/Both.swift, Sources/App/Changed.swift and Sources/App/Planned.swift"])

        let reply = lead.call("start_worker", ["task": "target"])
        #expect(!reply.isError, "\(reply.text)")
        #expect(reply.text.contains("Sources/App/Both.swift: runs (running: its boundaries name it)"), "\(reply.text)")
        #expect(reply.text.contains("Sources/App/Changed.swift: runs (running: its branch changes it)"), "\(reply.text)")
        #expect(reply.text.contains("Sources/App/Planned.swift: later (planned: its boundaries name it)"), "\(reply.text)")
        #expect(!reply.text.contains("2026-10-23"), "not on the input path: \(reply.text)")

        plan(lead, "Apart", ["Sources/Other/Alone.swift"])
        let apart = lead.call("start_worker", ["task": "apart"])
        #expect(!apart.isError && !apart.text.contains("Overlap"), "\(apart.text)")
    }

    @Test func overlapOnTheInputPathGetsTheStrongerLine() throws {
        let (root, _, lead) = try team(test: nil, ["max_workers": 6])
        try withInputPath(root)
        plan(lead, "Phone", ["PhoneAccess's send functions and their tests"])
        #expect(!lead.call("start_worker", ["task": "phone"]).isError)
        plan(lead, "Composer", ["HostClient.send"])
        plan(lead, "Next", ["The send path: Sources/VibeSwitcher/PhoneAccess.swift", "HostClient.send, RemoteInput"], auto: false)

        let reply = lead.call("start_worker", ["task": "next"])
        #expect(!reply.isError, "\(reply.text)")
        #expect(reply.text.contains("Sources/VibeSwitcher/PhoneAccess.swift: phone (running: its boundaries name it)"), "\(reply.text)")
        #expect(reply.text.contains("Sources/VibeSwitcher/HostClient.swift: composer (planned: its boundaries name it)"), "\(reply.text)")
        #expect(reply.text.contains("2026-10-23 rule") && reply.text.contains("one after another"), "\(reply.text)")
    }

    @Test func overlapIgnoresDocsRecordsProseProhibitionsAndUnreadableBranches() throws {
        let (root, _, lead) = try team(test: nil, ["max_workers": 8])
        plan(lead, "Holder", ["docs/notes.md, docs/lead/decisions.md, Sources/App/Named.swift", "Sources/App/Other.swift"])
        #expect(!lead.call("start_worker", ["task": "holder"]).isError)
        try committing("docs/guide.swift", in: Worktrees.path(root: root, slug: "holder"))

        plan(lead, "Readers", ["docs/notes.md and docs/lead/decisions.md", "docs/guide.swift", "%%% ??? \u{0}", "", "see e.g. v1.2 of HostClient.send"])
        let readers = lead.call("start_worker", ["task": "readers"])
        #expect(!readers.isError && !readers.text.contains("Overlap"), "\(readers.text)")

        plan(lead, "Keeps out", ["Must not change Sources/App/Named.swift", "Sources/App/Mine.swift but not Sources/App/Other.swift"])
        let kept = lead.call("start_worker", ["task": "keeps-out"])
        #expect(!kept.isError && !kept.text.contains("Overlap"), "\(kept.text)")

        // A branch git can't read says nothing either, and stops nothing.
        try BoardStore(root: root).update { board in
            guard let index = board.taskIndex("holder") else { return }
            board.tasks[index].branch = "agent/no-such-branch"
        }
        plan(lead, "Gone", ["Sources/App/Elsewhere.swift"])
        let gone = lead.call("start_worker", ["task": "gone"])
        #expect(!gone.isError && !gone.text.contains("Overlap"), "\(gone.text)")

        // The same boundaries' real file still counts, so the silence above isn't the warning being off.
        plan(lead, "Control", ["Sources/App/Named.swift"])
        let control = lead.call("start_worker", ["task": "control"])
        #expect(control.text.contains("Sources/App/Named.swift: holder (running: its boundaries name it)"), "\(control.text)")
    }

    @Test func overlapStartsAsBeforeAndTheReportNamesItAndWakesTheLead() async throws {
        let (root, runtime, lead) = try team(test: nil, ["max_workers": 4])
        try withInputPath(root)
        plan(lead, "Earlier", ["Sources/VibeSwitcher/RemoteInput.swift"], auto: true)
        plan(lead, "Second", ["RemoteInput"], auto: true)
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        #expect(await advancing.until { task("earlier", root)?.status == .running && task("second", root)?.status == .running })
        // Started in board order, neither held back; the later one's start carries the warning.
        #expect(await advancing.until { reports(runtime).contains { $0.contains("Overlap for second's start") } })
        let text = try #require(reports(runtime).first { $0.contains("Overlap for second's start") })
        #expect(text.contains("Sources/VibeSwitcher/RemoteInput.swift: earlier (running: its boundaries name it)"), "\(text)")
        #expect(text.contains("2026-10-23 rule"), "\(text)")
        #expect(SteerMessage(text: text, from: .system(LeadAdvance.sender), agentPid: runtime.me.pid).wakes == true, "\(text)")
        let earlier = try #require(task("earlier", root)), second = try #require(task("second", root))
        #expect(try #require(earlier.startedAt) <= (try #require(second.startedAt)))
        #expect(earlier.worker != nil && second.worker != nil)
    }
}
