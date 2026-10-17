import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Pictures of the calm Team view, drawn offscreen from `LeadTeamView`: a busy team, a quiet one, a fresh decision,
/// decisions fading and folded, a row opened. Only with `TEAM_SNAPSHOT_DIR=/some/folder swift test --filter TeamSnapshots`.
@MainActor
struct TeamSnapshots {
    static let folder = ProcessInfo.processInfo.environment["TEAM_SNAPSHOT_DIR"]
    /// Whole seconds, so "12m" reads 12m, not 11m from a rounding.
    static let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())

    static func task(_ title: String, _ status: LeadTask.Status, since: TimeInterval?, created: TimeInterval) -> LeadTask {
        let at = now.timeIntervalSince1970
        var task = LeadTask(slug: Slug.make(title, taken: []), title: title,
                            contract: LeadContract(goal: "What must be true when \(title.lowercased()) is done.", acceptance: ["swift test passes"],
                                                   boundaries: [], context: ""), status: status)
        task.createdAt = at - created
        task.since = since.map { at - $0 }
        task.worktree = "/Users/you/dev/vibeswitcher/.vibeswitcher/worktrees/\(task.slug)"
        task.branch = "agent/\(task.slug)"
        if status != .planned {
            task.worker = UUID().uuidString
            task.startedAt = task.createdAt + 60
            task.attempts = 1
        }
        return task
    }

    static func member(working: Bool = true, needsYou: Bool = false, activity: String? = nil, detail: String? = nil, started: TimeInterval = 900) -> MemberSeen {
        MemberSeen(live: true, needsYou: needsYou, working: working, activity: activity, detail: detail, since: now - 60, startedAt: now - started)
    }

    struct Team {
        var board = LeadBoard()
        var seen: [String: MemberSeen] = [:]
        var summaries: [String: String] = [:]
        var decisions: [LeadDecision] = []
    }

    static func busy() -> Team {
        let at = now.timeIntervalSince1970
        var team = Team()
        let asking = task("Menu shortcuts follow the Mac conventions", .running, since: 25 * 60, created: 6_000)
        team.seen[asking.worker!] = member(working: false, needsYou: true, detail: "Should ⌘K open the palette or clear the terminal?")

        var masker = task("Make the credential masker fast on huge inputs, without changing what it masks", .running, since: 12 * 60, created: 5_000)
        masker.checkpoints = [LeadCheckpoint(text: "Rules rewritten without backtracking; 40 KB now takes 3 ms", at: at - 400)]
        team.seen[masker.worker!] = member(activity: "Running swift test --filter Redaction")
        team.summaries[masker.id] = "Checking that a 1 MB log is masked in well under a second"

        var phone = task("Phone input reaches remote sessions", .failed, since: 22 * 60, created: 9_000)
        phone.attempts = 1
        phone.setback = LeadSetback(stage: .review, reason: "Audit: the new test is skipped on CI, so nothing checks the remote path.",
                                    evidence: LeadEvidence(completion: .incomplete, integrity: .suspect, summary: "HostInputTests.remote is skipped on CI.", commit: "4f1c2a9e"),
                                    at: at - 23 * 60)
        team.seen[phone.worker!] = member(activity: "Editing HostInputTests.swift")
        team.summaries[phone.id] = "Making the phone-input test run on every build, not just locally"

        var ended = task("Ended sessions leave the list", .review, since: 3 * 60, created: 7_000)
        ended.verifier = UUID().uuidString
        ended.report = "Ended workers and verifiers of finished tasks are forgotten by the host; swift test passes."
        team.seen[ended.verifier!] = member(activity: "Reading the diff")
        team.summaries[ended.id] = "Double-checking that finished helpers drop out of the session list"

        let queued = [task("Start page shows recent projects", .planned, since: nil, created: 1_800),
                      task("Composer undo keeps the draft", .planned, since: nil, created: 1_200)]
        let merged = (1...4).map { index -> LeadTask in
            var done = task("Merged task \(index)", .done, since: Double(index) * 3_000, created: 20_000)
            done.worktree = nil
            return done
        }
        team.board.tasks = merged + [ended, asking] + queued + [masker, phone]
        team.board.questions = [LeadQuestion(text: "Ship the calm Team view to everyone, or behind a setting first?", options: ["Everyone", "Behind a setting"],
                                             priority: .important, whyNow: "The verifier passed it; the next merge decides.", at: at - 300)]
        team.decisions = [LeadDecision(at: at - 30, text: "Run overlapping tasks in parallel",
                                       why: "Idle worker slots cost hours; a conflict costs one rework round.")] + earlier()
        return team
    }

    static func earlier() -> [LeadDecision] {
        let at = now.timeIntervalSince1970
        return [LeadDecision(at: at - 3_600, text: "Order for the 14 planned tasks: lead tooling first, one at a time", why: "Shared files would conflict on rebase."),
                LeadDecision(at: at - 7_200, text: "Accept the chat fix's memory cost", why: "It removes the hang.")]
    }

    static func quiet() -> Team {
        var team = Team()
        var one = task("Idle CPU and memory stay low with many sessions", .running, since: 40 * 60, created: 3_000)
        one.checkpoints = [LeadCheckpoint(text: "Measured: 0.4% CPU idle with 12 sessions", at: now.timeIntervalSince1970 - 600)]
        team.seen[one.worker!] = member(working: false)
        let merged = (1...9).map { index -> LeadTask in
            var done = task("Merged task \(index)", .done, since: Double(index) * 3_000, created: 30_000)
            done.worktree = nil
            return done
        }
        team.board.tasks = merged + [one]
        team.decisions = earlier()
        return team
    }

    func view(_ team: Team, openRows: Set<String> = [], openDecisions: Set<String> = [], showEarlier: Bool = false, at: Date = now) -> some View {
        LeadTeamView(root: "/Users/you/dev/vibeswitcher", board: team.board, seen: team.seen, open: { _ in }, openRows: openRows,
                     decisions: team.decisions, openDecisions: openDecisions, showEarlier: showEarlier,
                     summary: { team.summaries[$0.task.id] },
                     decisionSummary: { DecisionFeed.needsSummary($0) ? "Run overlapping tasks side by side; conflicts go back to their worker" : nil },
                     clock: at)
            .glance(now: at).padding(14)
    }

    func write<V: View>(_ view: V, name: String, folder: String, width: CGFloat = 380) throws {
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

    @Test(.enabled(if: folder != nil)) func drawCalmTeam() throws {
        let folder = try #require(Self.folder)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let busy = Self.busy()
        try write(view(busy), name: "busy-team", folder: folder)
        try write(view(Self.quiet()), name: "quiet-team", folder: folder)

        // A decision just taken, alone with the tasks' top.
        var fresh = Self.quiet()
        fresh.decisions = [LeadDecision(at: Self.now.timeIntervalSince1970 - 20, text: "Use all 5 worker slots",
                                        why: "The user wants the queue moving; strict one-at-a-time left slots idle for hours."),
                           LeadDecision(at: Self.now.timeIntervalSince1970 - 50,
                                        text: "Overlapping tasks run in parallel when the overlap is small, with call-site-only rules for shared files; a rebase conflict goes back to its worker",
                                        why: "A conflict costs one rework round, while idle slots cost hours.")] + Self.earlier()
        try write(view(fresh, openDecisions: [fresh.decisions[0].id]), name: "fresh-decision", folder: folder)

        // The same decision 2½ minutes on (fading, blurred) beside an older one folded, and the history unfolded.
        var fading = fresh
        fading.decisions.append(LeadDecision(at: Self.now.timeIntervalSince1970 - 100, text: "Verifiers run on the haiku model", why: "Cheap and enough."))
        try write(view(fading, at: Self.now + 135), name: "faded-decisions", folder: folder)
        try write(view(fading, showEarlier: true, at: Self.now + 400), name: "faded-decisions-history", folder: folder)

        // A reworked row opened: why it failed, checkpoints, report, audit, links.
        var opened = busy
        let phone = try #require(opened.board.tasks.firstIndex { $0.title.hasPrefix("Phone") })
        opened.board.tasks[phone].checkpoints = [LeadCheckpoint(text: "Remote path reproduced in a test", at: Self.now.timeIntervalSince1970 - 2_400),
                                                 LeadCheckpoint(text: "Test runs without the skip", at: Self.now.timeIntervalSince1970 - 300)]
        opened.board.tasks[phone].report = "Phone input now reaches remote sessions; HostInputTests pass."
        opened.board.tasks[phone].verifier = UUID().uuidString
        opened.seen[opened.board.tasks[phone].verifier!] = Self.member(working: false)
        try write(view(opened, openRows: [opened.board.tasks[phone].id]), name: "expanded-row", folder: folder)
    }
}
