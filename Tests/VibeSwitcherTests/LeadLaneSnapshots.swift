import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Pictures of the lead's Team view, drawn offscreen from `LeadTeamView` and `LeadLanes`: a task in each state
/// (running, rework, review, needs you, failed, merged, queued), the whole view, a row opened, and each lane alone.
/// Only with `LANE_SNAPSHOT_DIR=/some/folder swift test --filter LeadLaneSnapshots`.
@MainActor
struct LeadLaneSnapshots {
    static let folder = ProcessInfo.processInfo.environment["LANE_SNAPSHOT_DIR"]

    struct Scenario {
        var name: String
        var task: LeadTask
        var seen: [String: LaneSeen]
    }

    static func scenarios(now: Date) -> [Scenario] {
        let at = now.timeIntervalSince1970
        func task(_ title: String, _ status: LeadTask.Status, since: TimeInterval, created: TimeInterval) -> LeadTask {
            var task = LeadTask(slug: Slug.make(title, taken: []), title: title,
                                contract: LeadContract(goal: "What must be true when \(title.lowercased()) is done.",
                                                       acceptance: ["swift build && swift test pass", "Offscreen renders light and dark"],
                                                       boundaries: ["Sources/VibeSwitcher/MainWindow/Lead/*", "tests"], context: ""),
                                status: status)
            task.createdAt = at - created
            task.since = at - since
            task.worktree = "/Users/you/dev/vibeswitcher/.vibeswitcher/worktrees/\(task.slug)"
            task.branch = "agent/\(task.slug)"
            if status != .planned {
                task.worker = UUID().uuidString
                task.startedAt = task.createdAt + 60
                task.attempts = 1
            }
            return task
        }
        func seen(_ task: LeadTask, working: Bool = true, live: Bool = true, needsYou: Bool = false, activity: String? = nil, detail: String? = nil) -> [String: LaneSeen] {
            [task.worker ?? "": LaneSeen(live: live, needsYou: needsYou, working: working, activity: activity, detail: detail, since: now - 120)]
        }

        var running = task("Pipeline lanes in the Team view, with checkpoints and the live stage's activity", .running, since: 42 * 60, created: 5_000)
        running.checkpoints = [LeadCheckpoint(text: "Board fields and the progress tool, with tests", at: at - 1_900),
                               LeadCheckpoint(text: "Lane view model and its tests pass", at: at - 300)]

        var rework = task("Phone input reaches remote sessions", .running, since: 12 * 60, created: 9_000)
        rework.attempts = 3
        rework.setback = LeadSetback(stage: .review, reason: "Audit: the new test is skipped on CI, so nothing checks the remote path.",
                                     evidence: LeadEvidence(completion: .incomplete, integrity: .suspect, summary: "HostInputTests.remote is skipped (XCTSkip) on CI; the change is untested.", commit: "4f1c2a9e"),
                                     at: at - 13 * 60)
        rework.checkpoints = [LeadCheckpoint(text: "Remote path reproduced in a test", at: at - 2_400)]
        rework.report = "Phone input now reaches remote sessions; HostInputTests pass."

        var review = task("Ended sessions leave the list", .review, since: 4 * 60, created: 7_000)
        review.verifier = UUID().uuidString
        review.report = "Ended workers and verifiers of finished tasks are forgotten by the host; swift test passes."
        review.checkpoints = [LeadCheckpoint(text: "Reported done", at: at - 250)]

        let needsYou = task("Menu shortcuts follow the Mac conventions", .running, since: 25 * 60, created: 6_000)

        var failed = task("Hang watchdog restarts a stuck host", .failed, since: 3 * 60, created: 8_000)
        failed.setback = LeadSetback(stage: .merge, reason: "Tests fail rebased onto main: HangWatchdogTests.restartsAfterTimeout", at: at - 180)
        failed.evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: "All checks pass on the branch.", commit: "9b7e0d13")

        var merged = task("Trust prompt is answered for new worktrees", .done, since: 50 * 60, created: 20_000)
        merged.worktree = nil
        merged.merged = LeadMergeRecord(commit: "c0ffee4213ab", tested: true, at: at - 50 * 60)
        merged.evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: "swift test passes; the trust prompt is answered once.", commit: "77aa01bc")
        merged.checkpoints = [LeadCheckpoint(text: "Answered in a scratch worktree", at: at - 4_000)]

        let queued = task("Start page shows recent projects", .planned, since: 30 * 60, created: 1_800)
        let queuedNext = task("Composer undo keeps the draft", .planned, since: 20 * 60, created: 1_200)

        var verifierSeen = seen(review)
        verifierSeen[review.verifier ?? ""] = LaneSeen(live: true, needsYou: false, working: true, activity: "Reading the diff", detail: nil, since: now - 60)
        return [
            Scenario(name: "running", task: running, seen: seen(running, activity: "Running swift test")),
            Scenario(name: "rework", task: rework, seen: seen(rework, activity: "Editing HostInputTests.swift")),
            Scenario(name: "review", task: review, seen: verifierSeen),
            Scenario(name: "needs-you", task: needsYou, seen: seen(needsYou, working: false, needsYou: true,
                                                                  detail: "Asks: should ⌘K open the palette or clear the terminal?")),
            Scenario(name: "failed", task: failed, seen: seen(failed, working: false, live: false)),
            Scenario(name: "merged", task: merged, seen: [:]),
            Scenario(name: "queued", task: queued, seen: [:]),
            Scenario(name: "queued-next", task: queuedNext, seen: [:]),
        ]
    }

    func write<V: View>(_ view: V, width: CGFloat, name: String, folder: String) throws {
        for scheme in [ColorScheme.light, .dark] {
            let framed = view
                .frame(width: width, alignment: .topLeading)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @Test(.enabled(if: folder != nil)) func drawTeamLanes() throws {
        let folder = try #require(Self.folder)
        let scenarios = Self.scenarios(now: Date())
        var board = LeadBoard()
        board.tasks = scenarios.map(\.task)
        let seen = scenarios.reduce(into: [String: LaneSeen]()) { $0.merge($1.seen) { a, _ in a } }
        let width: CGFloat = 360

        // The tab as it opens (finished folded), then with the rework row and the finished ones open.
        try write(LaneList(board: board, seen: seen, open: { _ in }).padding(14), width: width, name: "team-lanes", folder: folder)
        let rework = try #require(scenarios.first { $0.name == "rework" }?.task.id)
        let merged = try #require(scenarios.first { $0.name == "merged" }?.task.id)
        try write(LaneList(board: board, seen: seen, open: { _ in }, openRows: [rework, merged], showFinished: true).padding(14),
                  width: width, name: "team-lanes-expanded", folder: folder)

        // Each state alone.
        for scenario in scenarios where scenario.name != "queued-next" {
            var one = LeadBoard()
            one.tasks = [scenario.task]
            try write(LaneList(board: one, seen: scenario.seen, open: { _ in }, showFinished: true).padding(10), width: width,
                      name: "lane-\(scenario.name)", folder: folder)
        }

        // The live ring: pulsing (its first frame), and still with Reduce Motion.
        let rings = HStack(spacing: 24) {
            ForEach([LeadLanes.LiveRing.pulsing, .still], id: \.self) { ring in
                VStack(spacing: 6) {
                    LaneNode(node: .live, tint: .orange, ring: ring).frame(width: 24, height: 24)
                    Text(ring == .pulsing ? "Pulsing" : "Reduce Motion").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        try write(rings.padding(12), width: 200, name: "lane-live-ring", folder: folder)
    }
}

extension LeadLanes.LiveRing: Hashable {}
