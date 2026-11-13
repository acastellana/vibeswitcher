import Foundation
import Testing
@testable import VibeCore

/// The team-task model (`LeadTeam`, `LeadTask.team`): boards from before it, members through the board's JSON, the
/// rules on names and sizes, and each member's branch and worktree.
struct LeadTeamTests {
    let temp = Scratch()
    let root = "/repo"

    func repo() throws -> URL {
        let url = temp.url("board")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".vibeswitcher"), withIntermediateDirectories: true)
        return url
    }

    /// A board as builds before team tasks wrote it: no `team` on any task.
    static let oldBoard = """
    {
      "baseBranch" : "main",
      "questions" : [

      ],
      "tasks" : [
        {
          "attempts" : 1,
          "branch" : "agent\\/add-login",
          "contract" : {
            "acceptance" : [
              "test passes"
            ],
            "boundaries" : [
              "only auth\\/"
            ],
            "context" : "",
            "goal" : "Users can log in"
          },
          "createdAt" : 1700000000,
          "id" : "T-1",
          "mainRedTold" : [
            "FooTests\\/bar"
          ],
          "since" : 1700000100,
          "slug" : "add-login",
          "status" : "running",
          "title" : "Add login",
          "worker" : "session-1",
          "worktree" : "\\/repo\\/.vibeswitcher\\/worktrees\\/add-login"
        },
        {
          "contract" : {
            "acceptance" : [

            ],
            "boundaries" : [

            ],
            "context" : "",
            "goal" : "Later"
          },
          "createdAt" : 1700000200,
          "id" : "T-2",
          "slug" : "later",
          "status" : "planned",
          "title" : "Later"
        }
      ],
      "updates" : [

      ]
    }
    """

    @Test func aBoardFromBeforeTeamsLoadsUnchangedAndSavesWithoutNoise() throws {
        let store = BoardStore(root: try repo().path)
        let file = URL(fileURLWithPath: store.file)
        try Data(Self.oldBoard.utf8).write(to: file)

        let board = try store.read()
        #expect(board.tasks.map(\.slug) == ["add-login", "later"])
        #expect(board.tasks.allSatisfy { $0.team == nil && !$0.isTeam && $0.integrator == nil })
        #expect(board.tasks[0].worker == "session-1")
        #expect(board.tasks[0].mainRedTold == ["FooTests/bar"])
        #expect(board.tasks[0].members == ["session-1"])

        try store.write(board)
        let saved = try Data(contentsOf: file)
        #expect(!String(decoding: saved, as: UTF8.self).contains("\"team\""))
        let before = try JSONSerialization.jsonObject(with: Data(Self.oldBoard.utf8)) as? NSDictionary
        let after = try JSONSerialization.jsonObject(with: saved) as? NSDictionary
        #expect(before != nil && before == after)
    }

    @Test(arguments: [2, 3, 4]) func aTeamRoundTripsThroughTheBoardsFile(size: Int) throws {
        let store = BoardStore(root: try repo().path)
        let names = ["lead", "ui", "store", "tests"].prefix(size)
        var team = try LeadTeam.make(slug: "journeys", root: store.root, parts: names.map { ($0, "the \($0) part") })
        team[0].worker = "session-a"
        team[0].mainRedTold = ["A/b"]
        team[size - 1].wallSeen = 7
        team[size - 1].mainRedTold = []
        let id = try store.update { board -> String in
            var task = LeadTask(slug: "journeys", title: "Sandbox UI journeys",
                                contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))
            task.team = team
            board.tasks.append(task)
            return task.id
        }

        let loaded = try #require(try store.read().task(id))
        #expect(loaded.team == team)
        #expect(loaded.isTeam)
        #expect(loaded.integrator?.name == "lead")
        #expect(loaded.teamMember(names.last!)?.wallSeen == 7)
        #expect(loaded.teamMember("nobody") == nil)
        // The task's own mainRedTold stays its own; members keep theirs.
        #expect(loaded.mainRedTold == nil)
        #expect(LeadTeam.problem(try #require(loaded.team), slug: "journeys", root: store.root) == nil)
    }

    @Test func eachMemberHasItsBranchAndWorktree() throws {
        let team = try LeadTeam.make(slug: "journeys", root: root, parts: [("lead", "glue"), ("ui", "views"), ("store", "model")])
        #expect(team.map(\.branch) == ["agent/journeys", "agent/journeys--ui", "agent/journeys--store"])
        #expect(team.map(\.worktree) == ["/repo/.vibeswitcher/worktrees/journeys",
                                         "/repo/.vibeswitcher/worktrees/journeys--ui",
                                         "/repo/.vibeswitcher/worktrees/journeys--store"])
        #expect(team.map(\.part) == ["glue", "views", "model"])
        #expect(team.allSatisfy { $0.worker == nil && $0.wallSeen == nil && $0.mainRedTold == nil })
        // The integrator is on the task's own branch and worktree, as a plain task's worker is.
        #expect(team[0].branch == Worktrees.branch("journeys"))
        #expect(team[0].worktree == Worktrees.path(root: root, slug: "journeys"))
        #expect(LeadTeam.branch(slug: "journeys", member: "ui", index: 1) == "agent/journeys--ui")
        #expect(LeadTeam.worktree(root: root, slug: "journeys", member: "ui", index: 1) == "/repo/.vibeswitcher/worktrees/journeys--ui")
    }

    @Test func aTeamHasTwoToFourMembers() {
        let names = ["a", "b", "c", "d", "e"]
        for count in 0...5 {
            let parts = names.prefix(count).map { ($0, "part") }
            let made = Result { try LeadTeam.make(slug: "s", root: root, parts: parts) }
            if (2...4).contains(count) {
                #expect((try? made.get())?.count == count)
            } else {
                #expect(throws: LeadTeam.Refusal.self) { try made.get() }
            }
        }
    }

    @Test(arguments: ["ui", "store2", "a", "sandbox-hooks", "abcdefghijklmnop"])
    func safeNamesAreTaken(name: String) {
        #expect(LeadTeam.nameProblem(name) == nil)
    }

    @Test(arguments: ["", "ui--store", "UI", "ui/store", "ui.lock", "..", ".ui", "ui store", "ui-", "-ui", "2ui", "ui@{1}",
                      "ui~1", "ui^", "ui:x", "ui\\x", "ui*", "ui?", "ui[", "üi", "ui\n", "abcdefghijklmnopq"])
    func unsafeNamesAreRefused(name: String) {
        #expect(LeadTeam.nameProblem(name) != nil)
        #expect(throws: LeadTeam.Refusal.self) {
            try LeadTeam.make(slug: "s", root: root, parts: [("lead", "glue"), (name, "part")])
        }
    }

    @Test func aNameIsUsedOnceInATeam() throws {
        #expect(throws: LeadTeam.Refusal(text: "member name \"ui\" is used twice")) {
            try LeadTeam.make(slug: "s", root: root, parts: [("lead", "glue"), ("ui", "one"), ("ui", "two")])
        }
        #expect(throws: LeadTeam.Refusal.self) {
            try LeadTeam.make(slug: "s", root: root, parts: [("ui", "glue"), ("ui", "views")])
        }
    }

    @Test func membersMustSitWhereTheirPlaceSays() throws {
        let team = try LeadTeam.make(slug: "s", root: root, parts: [("lead", "glue"), ("ui", "views")])
        #expect(LeadTeam.problem(team, slug: "s", root: root) == nil)
        // The integrator moved off the task's branch, or the members swapped: refused.
        #expect(LeadTeam.problem(Array(team.reversed()), slug: "s", root: root) != nil)
        var offBranch = team
        offBranch[0].branch = "agent/s--lead"
        #expect(LeadTeam.problem(offBranch, slug: "s", root: root) != nil)
        var elsewhere = team
        elsewhere[1].worktree = "/elsewhere"
        #expect(LeadTeam.problem(elsewhere, slug: "s", root: root) != nil)
        // Another slug's team isn't this task's.
        #expect(LeadTeam.problem(team, slug: "t", root: root) != nil)
    }

    @Test func aMembersBranchIsNeverAnotherTasksSlug() {
        // Slug.make joins words with one hyphen, so no slug holds the joiner a member's branch has.
        for title in ["journeys ui", "journeys--ui", "journeys - - ui", "a -- b"] {
            #expect(!Slug.make(title, taken: []).contains(LeadTeam.joiner))
        }
    }
}
