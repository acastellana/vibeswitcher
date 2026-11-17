import Foundation
import Testing
@testable import VibeCore

/// A team task's member worktrees (`Worktrees.createMember`, docs/process/reviews/team-on-one-task-design.md "The
/// unit"), on scratch repositories only: each member's folder and sub-branch from a commit of the team branch, and the
/// task's cleanup taking them with its own.
struct MemberWorktreesTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    /// A repository on `main` with one commit.
    func repo() throws -> String {
        let url = temp.url("team")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try commit("a.txt", "one\n", in: root)
        return root
    }

    /// Commits `file` with `text` in `dir`; the new head.
    @discardableResult
    func commit(_ file: String, _ text: String, in dir: String) throws -> String {
        try text.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        Git.run(["commit", "-q", "-m", "change \(file)"], in: dir)
        return head(in: dir)
    }

    func head(_ ref: String = "HEAD", in dir: String) -> String { Git.run(["rev-parse", ref], in: dir).output }
    func hasBranch(_ name: String, _ root: String) -> Bool { Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: root).ok }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// The team branch `agent/one` in its worktree, two commits past main: the interface, then more of it. Its worktree
    /// and the interface commit.
    func team(_ root: String) throws -> (worktree: String, interface: String) {
        let worktree = try Worktrees.create(root: root, slug: "one")
        let interface = try commit("api.txt", "interface\n", in: worktree)
        try commit("api.txt", "interface, more\n", in: worktree)
        return (worktree, interface)
    }

    @Test func aMemberGetsItsFolderAndSubBranchFromTheNamedCommit() throws {
        let root = try repo()
        let (_, interface) = try team(root)
        let path = try Worktrees.createMember(root: root, slug: "one", member: "lexer", from: String(interface.prefix(10)))
        #expect(path == root + "/.vibeswitcher/worktrees/one--lexer")
        #expect(path == LeadTeam.worktree(root: root, slug: "one", member: "lexer", index: 1))
        #expect(Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path).output == "agent/one--lexer")
        #expect(LeadTeam.branch(slug: "one", member: "lexer", index: 1) == "agent/one--lexer")
        // The named commit, not the team branch's tip.
        #expect(head(in: path) == interface)
        #expect(Worktrees.isWorktree(root: root, slug: "one--lexer"))
        #expect(Worktrees.members(root: root, slug: "one") == ["lexer"])
        // The main checkout doesn't list it as a change.
        #expect(Git.run(["status", "--porcelain"], in: root).output.isEmpty)
    }

    /// Creating it again is idempotent: the same worktree, its branch where it is, the member's commits kept; also when
    /// its folder had gone. A later commit of the team branch the member's branch lacks is refused, not reset to.
    @Test func creatingAMemberTwiceKeepsItsWork() throws {
        let root = try repo()
        let (worktree, interface) = try team(root)
        let path = try Worktrees.createMember(root: root, slug: "one", member: "lexer", from: interface)
        let own = try commit("lexer.txt", "lexing\n", in: path)
        #expect(try Worktrees.createMember(root: root, slug: "one", member: "lexer", from: interface) == path)
        #expect(head(in: path) == own)
        #expect(head("refs/heads/agent/one--lexer", in: root) == own)

        // Its folder gone, its branch kept: the worktree comes back on that branch.
        #expect(Git.run(["worktree", "remove", path], in: root).ok)
        #expect(!exists(path))
        #expect(try Worktrees.createMember(root: root, slug: "one", member: "lexer", from: interface) == path)
        #expect(head(in: path) == own)

        // The team branch's tip, which the member's branch doesn't hold: refused, nothing moved.
        let tip = head(in: worktree)
        #expect(throws: Worktrees.Failure.self) { try Worktrees.createMember(root: root, slug: "one", member: "lexer", from: tip) }
        #expect(head("refs/heads/agent/one--lexer", in: root) == own)
    }

    @Test func aMemberIsRefusedOffTheTeamBranchOrWithABadName() throws {
        let root = try repo()
        let (_, interface) = try team(root)
        // A commit main has and the team branch doesn't.
        let onMain = try commit("b.txt", "main only\n", in: root)
        for (name, commit) in [("lexer", onMain), ("lexer", "no-such-commit"), ("Lexer", interface), ("lex--er", interface), ("lexer/x", interface)] {
            #expect(throws: Worktrees.Failure.self, "\(name) \(commit)") {
                try Worktrees.createMember(root: root, slug: "one", member: name, from: commit)
            }
        }
        // No team branch at all.
        #expect(throws: Worktrees.Failure.self) { try Worktrees.createMember(root: root, slug: "two", member: "lexer", from: interface) }
        // A folder that isn't its worktree is left alone.
        let stray = Worktrees.path(root: root, slug: "one--parser")
        try FileManager.default.createDirectory(atPath: stray, withIntermediateDirectories: true)
        #expect(throws: Worktrees.Failure.self) { try Worktrees.createMember(root: root, slug: "one", member: "parser", from: interface) }
        #expect(!hasBranch("agent/one--parser", root))
        #expect(!hasBranch("agent/one--lexer", root))
    }

    /// Only the task's own: another task whose slug starts with this one's isn't a member.
    @Test func membersAreTheTasksOwn() throws {
        let root = try repo()
        let (_, interface) = try team(root)
        try Worktrees.createMember(root: root, slug: "one", member: "lexer", from: interface)
        Git.run(["branch", "agent/one--parser", interface], in: root)
        try Worktrees.create(root: root, slug: "one-b")
        Git.run(["branch", "agent/one-b--x", interface], in: root)
        #expect(Worktrees.members(root: root, slug: "one") == ["lexer", "parser"])
        #expect(Worktrees.members(root: root, slug: "one-b") == ["x"])
        #expect(Worktrees.members(root: root, slug: "two").isEmpty)
    }

    // MARK: Cleanup

    /// The task `one` with a worker started, made a team of an integrator, lexer and parser, branched from its
    /// interface commit; `status` set, merged at the team branch's head when done.
    func teamTask(_ root: String, _ lead: LeadToolset, status: LeadTask.Status) throws -> (lexer: String, parser: String) {
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "one"])
        let worktree = Worktrees.path(root: root, slug: "one")
        let interface = try commit("api.txt", "interface\n", in: worktree)
        let lexer = try Worktrees.createMember(root: root, slug: "one", member: "lexer", from: interface)
        let parser = try Worktrees.createMember(root: root, slug: "one", member: "parser", from: interface)
        // Lexer's part, taken into the team branch.
        try commit("lexer.txt", "lexing\n", in: lexer)
        #expect(Git.run(["merge", "-q", "--no-edit", "agent/one--lexer"], in: worktree).ok)
        let members = try LeadTeam.make(slug: "one", root: root, parts: [("lead", "the interface"), ("lexer", "lexing"), ("parser", "parsing")])
        let branchHead = head(in: worktree)
        try BoardStore(root: root).update { board in
            guard let index = board.taskIndex("one") else { return }
            board.tasks[index].team = members
            board.tasks[index].status = status
            if status == .done { board.tasks[index].merged = LeadMergeRecord(commit: branchHead, tested: true, branchHead: branchHead) }
        }
        return (lexer, parser)
    }

    @Test func cleanupRemovesEveryMembersWorktreeAndSubBranchWithTheTasks() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let (lexer, parser) = try teamTask(root, lead, status: .done)
        let cleaned = lead.call("cleanup", ["task": "one"])
        #expect(!cleaned.isError, "\(cleaned.text)")
        #expect(cleaned.text.contains("members' worktrees and branches (2)"))
        for path in [lexer, parser, Worktrees.path(root: root, slug: "one")] { #expect(!exists(path), "\(path)") }
        for branch in ["agent/one", "agent/one--lexer", "agent/one--parser"] { #expect(!hasBranch(branch, root), "\(branch)") }
        #expect(Worktrees.members(root: root, slug: "one").isEmpty)
    }

    /// A plain task's cleanup is as before, and leaves another task's branches alone, one whose slug starts with its own
    /// included.
    @Test func cleanupOfAPlainTaskIsUnchanged() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "one"])
        Git.run(["branch", "agent/one-b"], in: root)
        Git.run(["branch", "agent/one-b--x"], in: root)
        let cleaned = lead.call("cleanup", ["task": "one", "force": true])
        #expect(!cleaned.isError, "\(cleaned.text)")
        #expect(!cleaned.text.contains("members"))
        #expect(!exists(Worktrees.path(root: root, slug: "one")))
        #expect(!hasBranch("agent/one", root))
        #expect(hasBranch("agent/one-b", root) && hasBranch("agent/one-b--x", root))
    }

    /// A member's uncommitted files are named and cleanup refused, nothing removed; force drops them, and says so.
    @Test func aMembersUncommittedWorkIsReportedNotDeleted() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let (lexer, parser) = try teamTask(root, lead, status: .done)
        try "half done\n".write(toFile: parser + "/parser.txt", atomically: true, encoding: .utf8)
        let refused = lead.call("cleanup", ["task": "one"])
        #expect(refused.isError)
        #expect(refused.text.contains("parser (agent/one--parser): uncommitted parser.txt (untracked)"), "\(refused.text)")
        #expect(!refused.text.contains("lexer ("))
        for path in [lexer, parser, Worktrees.path(root: root, slug: "one")] { #expect(exists(path), "\(path)") }
        for branch in ["agent/one", "agent/one--lexer", "agent/one--parser"] { #expect(hasBranch(branch, root), "\(branch)") }
        #expect(exists(parser + "/parser.txt"))

        let forced = lead.call("cleanup", ["task": "one", "force": true])
        #expect(!forced.isError, "\(forced.text)")
        #expect(forced.text.contains("Dropped, as force said: parser (agent/one--parser): uncommitted parser.txt (untracked)"), "\(forced.text)")
        for path in [lexer, parser] { #expect(!exists(path), "\(path)") }
        #expect(!hasBranch("agent/one--parser", root))
    }

    /// A done task's member commits the integrator didn't take are refused, as the task's own unmerged commits are;
    /// an abandoned task's go with it, as its own do.
    @Test func aMembersUntakenCommitsCountAsTheTasksOwnDo() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let (_, parser) = try teamTask(root, lead, status: .done)
        let untaken = try commit("parser.txt", "parsing\n", in: parser)
        let refused = lead.call("cleanup", ["task": "one"])
        #expect(refused.isError)
        #expect(refused.text.contains("parser (agent/one--parser): 1 commit not taken: \(untaken.prefix(8))"), "\(refused.text)")
        #expect(hasBranch("agent/one--parser", root) && exists(parser))

        try BoardStore(root: root).update { board in
            guard let index = board.taskIndex("one") else { return }
            board.tasks[index].status = .abandoned
        }
        let cleaned = lead.call("cleanup", ["task": "one"])
        #expect(!cleaned.isError, "\(cleaned.text)")
        #expect(!hasBranch("agent/one--parser", root) && !exists(parser))
    }
}
