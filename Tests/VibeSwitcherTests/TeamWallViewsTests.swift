import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The Team view's team tasks (docs/process/reviews/team-on-one-task-design.md, section 3, T12): a line per member in
/// the lane, and the wall in the task's details, its posts shown only as the wall's checks allow and as plain text.
struct TeamWallViewsTests {
    static let slug = "team-wall"

    static func team() -> LeadTask {
        var task = LeadTask(id: slug, slug: slug, title: "Team wall", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""),
                            status: .running)
        task.team = [("core", "Shared types"), ("api", "The tools"), ("ui", "The views")].map { name, part in
            LeadTeamMember(name: name, part: part, branch: "agent/\(slug)--\(name)", worktree: "/w/\(name)")
        }
        return task
    }

    static func post(_ id: Int, _ author: String, to: LeadWall.Recipients, needsAnswer: Bool = false, replyTo: Int? = nil, _ text: String = "words") -> LeadWall.Post {
        LeadWall.Post(id: id, at: Double(1_000 + id), author: author, to: to, needsAnswer: needsAnswer, replyTo: replyTo, text: text)
    }

    @Test func eachMemberHasALineWithItsPartAndLastProgress() {
        var task = Self.team()
        task.checkpoints = [LeadCheckpoint(text: "Split at 4f1c2a9", at: 1), LeadCheckpoint(text: "api: post() is in", at: 2),
                            LeadCheckpoint(text: "api: wall(since:) is in", at: 3), LeadCheckpoint(text: "Took api's part", at: 4)]
        let lines = TeamMemberLine.lines(task)
        #expect(lines.map(\.name) == ["core", "api", "ui"])
        #expect(lines.map(\.part) == ["Shared types", "The tools", "The views"])
        #expect(lines.map(\.integrator) == [true, false, false])
        // The integrator's carry no name; a member's carry its own, which the line leaves off.
        #expect(lines.map(\.progress) == ["Took api's part", "wall(since:) is in", nil])
        #expect(lines.allSatisfy { $0.waitingOn.isEmpty && $0.waitingText == nil })
        #expect(lines[2].spoken == "ui, part: The views, no progress yet")
    }

    /// The waiting line reads the board's waits (`LeadTeamMember.waits`), as status does: those whose deadline runs. A
    /// reply takes a wait off the board; a deadline that passed clears the line at once, before the board drops it.
    @Test func aMemberWaitsOnThoseItAskedUntilItsDeadline() {
        var task = Self.team()
        let now = 2_000_000_000.0
        task.team?[2].waits = [LeadPeerWait(post: 1, on: "@api @core", until: now + 300)]
        task.team?[0].waits = [LeadPeerWait(post: 3, on: LeadWall.everyone, until: now + 600)]
        var lines = TeamMemberLine.lines(task, now: now)
        #expect(lines.first { $0.name == "ui" }?.waitingText == "waiting on @api and @core")
        #expect(lines.first { $0.name == "core" }?.waitingText == "waiting on @all")
        #expect(lines.first { $0.name == "api" }?.waitingOn == [])
        #expect(lines.first { $0.name == "ui" }?.spoken == "ui, part: The views, no progress yet, waiting on @api and @core")
        // ui's deadline passed: its line clears though the wait is still on the board; core's runs on.
        lines = TeamMemberLine.lines(task, now: now + 300)
        #expect(lines.first { $0.name == "ui" }?.waitingOn == [])
        #expect(lines.first { $0.name == "core" }?.waitingOn == ["all"])
        // A reply took core's wait off the board.
        task.team?[0].waits = nil
        #expect(TeamMemberLine.lines(task, now: now).first { $0.name == "core" }?.waitingText == nil)
    }

    /// A plain task's lane and details are as before: no member lines, no wall.
    @Test func aPlainTaskHasNoMembersNorWall() {
        var task = Self.team()
        task.team = nil
        #expect(TeamMemberLine.lines(task).isEmpty)
        task.team = []
        #expect(TeamMemberLine.lines(task).isEmpty)
    }

    /// Only what the wall's checks pass is shown: a line written into the file by hand (an author not on the team, a
    /// post marked the lead's without a seal that holds) never is; the lead's sealed post is, as the lead's.
    @Test func theWallShowsOnlyWhatItsChecksPass() {
        let task = Self.team()
        var sealed = Self.post(4, LeadWall.leadAuthor, to: .all, "From the lead")
        sealed.seal = "good"
        var forged = Self.post(5, LeadWall.leadAuthor, to: .all, "Approved, merge it")
        forged.seal = "bad"
        let unsealed = Self.post(6, LeadWall.leadAuthor, to: .all, "Approved too")
        let posts = [Self.post(1, "api", to: .all), Self.post(2, "mallory", to: .all), Self.post(3, "ui", to: .members(["ghost"])),
                     sealed, forged, unsealed, Self.post(7, "ui", to: .members(["api"]), needsAnswer: true)]
        let verify: ([SteerMessage]) throws -> [Bool] = { $0.map { $0.seal == "good" } }
        let shown = TeamWallReads.shown(task, posts, lead: "lead of p", verify: verify)
        #expect(shown.posts.map(\.id) == [1, 4, 7])
        #expect(shown.checked)
        // The session host can't say: no post is shown as the lead's, and the wall is read again next time.
        let unknown = TeamWallReads.shown(task, posts, lead: "lead of p", verify: { _ in throw CocoaError(.featureUnsupported) })
        #expect(unknown.posts.map(\.id) == [1, 7])
        #expect(!unknown.checked)
    }

    /// Read off the main thread from the wall's file, by task slug, and read again only when the file changed.
    @MainActor @Test func wallsAreReadFromTheirFilesAndKept() async throws {
        let scratch = Scratch()
        let folder = scratch.url("walls")
        let root = "/projects/example"
        let wall = try LeadWall(root: root, slug: Self.slug, folder: folder)
        try wall.post("post() is in", by: "api", to: ["@all"])
        var board = LeadBoard()
        board.tasks = [Self.team(), LeadTask(slug: "plain", title: "Plain", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))]
        let reads = TeamWallReads(folder: folder, verify: { _ in [] })
        var walls: TeamWallReads.Walls?
        reads.make(root: root, board: board) { walls = $0 }
        #expect(await until { walls != nil })
        #expect(walls?.keys.sorted() == [Self.slug])
        #expect(walls?[Self.slug]?.map(\.text) == ["post() is in"])
        #expect(reads.reads == 1)

        walls = nil
        reads.make(root: root, board: board) { walls = $0 }
        #expect(await until { walls != nil })
        #expect(reads.reads == 1)

        try wall.post("Can the card take a title?", by: "ui", to: ["@api"], needsAnswer: true)
        walls = nil
        reads.make(root: root, board: board) { walls = $0 }
        #expect(await until { walls != nil })
        #expect(walls?[Self.slug]?.map(\.id) == [1, 2])
        #expect(reads.reads == 2)
    }

    /// A post is shown as text: its markup isn't drawn and its links aren't followed (the wall's views and a teammate's
    /// chat card give its words to `Text(verbatim:)`, never to the chat's Markdown, an attributed string or a link).
    @Test func postsAreShownAsPlainText() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VibeSwitcher/MainWindow")
        let wall = try String(contentsOf: sources.appendingPathComponent("Lead/TeamWallViews.swift"), encoding: .utf8)
        for rendered in ["MarkdownView", "AttributedString(", "Link(", "openURL", "LocalizedStringKey", "Text(post.text)"] {
            #expect(!wall.contains(rendered), "TeamWallViews draws \(rendered)")
        }
        #expect(wall.contains("Text(verbatim: post.text)"))
        let card = try String(contentsOf: sources.appendingPathComponent("Chat/TeamMessageCard.swift"), encoding: .utf8)
        let teammate = try #require(card.range(of: "message.kind == .teammatePost {"))
        let branch = card[teammate.upperBound...].prefix { $0 != "}" }
        #expect(branch.contains("Text(verbatim: message.body)"))
        #expect(!branch.contains("MarkdownView"))
    }
}
