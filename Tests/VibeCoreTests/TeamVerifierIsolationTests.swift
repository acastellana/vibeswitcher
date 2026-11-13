import Foundation
import Testing
@testable import VibeCore

/// T10 of docs/process/reviews/team-on-one-task-design.md (section 4, "Verifiers never read the wall"): a team task's
/// verifier gets no post text in its prompt or tools, and its Read is denied the members' Claude Code transcript
/// folders, where delivered posts sit; a plain task's verifier keeps today's rules.
extension LeadFindingsToolTests {
    /// The settings file the last session started as `name` was given.
    func settings(of name: String, _ runtime: FakeRuntime) throws -> [String: Any] {
        let spawn = try #require(runtime.spawned.last { $0.command.contains("--name '\(name)'") })
        let range = try #require(spawn.command.range(of: #"--settings '([^']+)'"#, options: .regularExpression))
        let path = String(spawn.command[range].dropFirst("--settings '".count).dropLast())
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }

    static let posts = ["the picker hands back a closure named onPickZebra, not a delegate",
                        "store answers: I renamed QuokkaCache to PlainCache, pull before you build"]

    @Test func aTeamTasksVerifierGetsNoPostTextNoWallToolAndNoMembersTranscripts() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        // add-b becomes a team task whose members talked on its wall.
        let team = try LeadTeam.make(slug: "add-b", root: root, parts: [("lead", "glue"), ("ui", "the picker"), ("store", "the cache")])
        try BoardStore(root: root).update { board in
            let index = try #require(board.tasks.firstIndex { $0.slug == "add-b" })
            board.tasks[index].team = team
        }
        let wall = try LeadWall(root: root, slug: "add-b", folder: vault.folder)
        try wall.post(Self.posts[0], by: "ui", to: ["lead"])
        try wall.post(Self.posts[1], by: "store", to: [LeadWall.everyone], needsAnswer: true)
        #expect(wall.posts().map(\.text) == Self.posts)

        let audit = call(lead, "audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")

        // Its prompt and its tools hold no post's text, and no wall tool.
        let prompt = try verifierPrompt(runtime)
        let verifier = try seat("verify-add-b", runtime)
        let tools = verifier.tools
        #expect(tools.map(\.name) == ["submit_audit"])
        let toolText = String(decoding: try JSONSerialization.data(withJSONObject: tools.map(\.json), options: [.sortedKeys]), as: UTF8.self)
        for post in Self.posts {
            for words in [post, "onPickZebra", "QuokkaCache"] {
                #expect(!prompt.contains(words), "\(words) in the verifier's prompt")
                #expect(!toolText.contains(words), "\(words) in the verifier's tools")
            }
        }
        #expect(!tools.contains { $0.name.localizedCaseInsensitiveContains("wall") || $0.name.localizedCaseInsensitiveContains("post") })

        // Its Read is denied each member's transcript folder, on top of every rule a verifier has.
        let deny = try #require((try settings(of: "verify-add-b", runtime)["permissions"] as? [String: Any])?["deny"] as? [String])
        let workflow = LeadWorkflow.load(from: (root as NSString).appendingPathComponent(".vibeswitcher/workflow.md"))
        let base = LeadLaunch.deny(.verifier, base: "main", records: workflow.recordsDir)
        #expect(Array(deny.prefix(base.count)) == base)
        for member in team.dropFirst() {
            let folder = LeadLaunch.claudeProjectFolder(member.worktree, home: "~")
            #expect(folder.hasPrefix("~/.claude/projects/-"))
            #expect(deny.contains("Read(\(folder)/**)"), "\(member.name): \(deny.suffix(8))")
            #expect(deny.contains("Read(\(folder))"))
        }
        // The integrator's folder is the verifier's own too (it starts in the task's worktree): its transcripts are
        // denied, not the folder whole, where its own large tool results are kept for it to read.
        let own = LeadLaunch.claudeProjectFolder(team[0].worktree, home: "~")
        #expect(deny.contains("Read(\(own)/*.jsonl)"), "\(deny.suffix(8))")
        #expect(!deny.contains("Read(\(own)/**)") && !deny.contains("Read(\(own))"))
    }

    @Test func aPlainTasksVerifierKeepsTodaysRules() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        #expect(!call(lead, "audit", ["task": "add-b"]).isError)
        let deny = try #require((try settings(of: "verify-add-b", runtime)["permissions"] as? [String: Any])?["deny"] as? [String])
        let workflow = LeadWorkflow.load(from: (root as NSString).appendingPathComponent(".vibeswitcher/workflow.md"))
        #expect(deny == LeadLaunch.deny(.verifier, base: "main", records: workflow.recordsDir))
        #expect(!deny.contains { $0.contains(".claude/projects") })
    }
}

struct TeamVerifierLaunchTests {
    let temp = Scratch()

    func root() throws -> String {
        let url = temp.url("repo")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    func deny(_ launch: LeadLaunch.Prepared) throws -> [String] {
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
        return try #require((settings?["permissions"] as? [String: Any])?["deny"] as? [String])
    }

    func prepare(_ role: LeadLaunch.Role, root: String, task: String) throws -> LeadLaunch.Prepared {
        try LeadLaunch.prepare(role: role, root: root, task: task, base: "claude", prompt: "p", start: "Check.", server: "/App/vibeswitcher-mcp",
                               name: "\(role.rawValue)-\(task)", records: "docs/lead", folder: temp.url("run-\(role.rawValue)-\(task)"),
                               temporary: temp.url("tmp"))
    }

    @Test func onlyATeamTasksVerifierIsDeniedItsMembersTranscriptFolders() throws {
        let root = try root()
        let team = try LeadTeam.make(slug: "journeys", root: root, parts: [("lead", "glue"), ("ui", "views"), ("store", "model"), ("tests", "checks")])
        try BoardStore(root: root).update { board in
            var task = LeadTask(slug: "journeys", title: "Journeys", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))
            task.team = team
            board.tasks.append(task)
            board.tasks.append(LeadTask(slug: "plain", title: "Plain", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: "")))
        }
        let today = LeadLaunch.deny(.verifier, records: "docs/lead")
        let folders = team.map { LeadLaunch.claudeProjectFolder($0.worktree, home: "~") }
        // One folder per member, each as Claude Code names it (`claudeProjectFolder`; a long path's is hashed).
        #expect(Set(folders).count == team.count && folders.allSatisfy { $0.hasPrefix("~/.claude/projects/-") })

        let verifier = try deny(try prepare(.verifier, root: root, task: "journeys"))
        #expect(Array(verifier.prefix(today.count)) == today)
        // Its cwd is the task's worktree, the integrator's: that folder's transcripts, the others' folders whole.
        let own = folders[0]
        #expect(Set(verifier.dropFirst(today.count))
                == Set(folders.dropFirst().flatMap { ["Read(\($0))", "Read(\($0)/**)"] }
                       + ["Read(\(own)/*.jsonl)", "Read(\(own)/memory*)", "Read(\(own)/memory*/**)"]))

        // A plain task's verifier, and a team task's worker, keep today's rules exactly.
        #expect(try deny(try prepare(.verifier, root: root, task: "plain")) == today)
        #expect(try deny(try prepare(.verifier, root: root, task: "not-on-the-board")) == today)
        #expect(try deny(try prepare(.worker, root: root, task: "journeys")) == LeadLaunch.deny(.worker, records: "docs/lead"))
    }

    @Test func aWorktreeReachedThroughALinkIsDeniedByBothSpellings() throws {
        let real = try root()
        let link = temp.url("linked").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let team = try LeadTeam.make(slug: "journeys", root: link, parts: [("lead", "glue"), ("ui", "views")])
        try FileManager.default.createDirectory(atPath: team[1].worktree, withIntermediateDirectories: true)
        let rules = LeadLaunch.memberTranscripts(root: link, slug: "journeys", team: team)
        for path in [team[1].worktree, LeadTeam.worktree(root: real, slug: "journeys", member: "ui", index: 1)] {
            #expect(rules.contains("Read(\(LeadLaunch.claudeProjectFolder(path, home: "~"))/**)"), "\(path): \(rules)")
        }
    }

    /// The verifier's own folder (its cwd's, the integrator's): every transcript and every entry there at its launch
    /// is denied, so a session folder made after it (the verifier's own, with its saved tool results) stays readable.
    @Test func inItsOwnFolderTheVerifierIsDeniedEveryEarlierSessionButNotItsOwn() throws {
        let root = try root()
        let home = temp.url("home").path
        let team = try LeadTeam.make(slug: "journeys", root: root, parts: [("lead", "glue"), ("ui", "views")])
        let name = (LeadLaunch.claudeProjectFolder(team[0].worktree, home: home) as NSString).lastPathComponent
        let folder = (home as NSString).appendingPathComponent(".claude/projects/\(name)")
        let integrator = "0d3e2d68-d467-49bc-b4db-9f13858722ab"
        try FileManager.default.createDirectory(atPath: folder + "/\(integrator)/tool-results", withIntermediateDirectories: true)
        try "{}".write(toFile: folder + "/\(integrator).jsonl", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: folder + "/memory", withIntermediateDirectories: true)

        let rule = "~/.claude/projects/\(name)"
        let rules = LeadLaunch.memberTranscripts(root: root, slug: "journeys", team: team, cwd: team[0].worktree, home: home)
        let mine = rules.filter { $0.hasPrefix("Read(\(rule)") && !$0.hasPrefix("Read(\(rule)--") }
        #expect(Set(mine) == ["Read(\(rule)/*.jsonl)", "Read(\(rule)/memory*)", "Read(\(rule)/memory*/**)",
                              "Read(\(rule)/\(integrator))", "Read(\(rule)/\(integrator)/**)",
                              "Read(\(rule)/\(integrator).jsonl)", "Read(\(rule)/\(integrator).jsonl/**)",
                              "Read(\(rule)/memory)", "Read(\(rule)/memory/**)"], "\(mine)")
        // The other member's folder, where the verifier never starts, whole.
        let other = LeadLaunch.claudeProjectFolder(team[1].worktree, home: "~")
        #expect(rules.contains("Read(\(other))") && rules.contains("Read(\(other)/**)"))

        // An entry a rule can't hold as it's named: the folder is denied whole.
        try FileManager.default.createDirectory(atPath: folder + "/a b)", withIntermediateDirectories: true)
        let whole = LeadLaunch.memberTranscripts(root: root, slug: "journeys", team: team, cwd: team[0].worktree, home: home)
        #expect(whole.contains("Read(\(rule))") && whole.contains("Read(\(rule)/**)") && !whole.contains { $0.contains("a b") })
    }

    /// The verifier's own folder can't be listed (here it can't be read; any failure but its not being there): which
    /// earlier sessions it holds is unknown, so it's denied whole. Not there yet, it holds none: its transcripts only.
    @Test func itsOwnFolderThatCantBeListedIsDeniedWhole() throws {
        let root = try root()
        let home = temp.url("home").path
        let team = try LeadTeam.make(slug: "journeys", root: root, parts: [("lead", "glue"), ("ui", "views")])
        let name = (LeadLaunch.claudeProjectFolder(team[0].worktree, home: home) as NSString).lastPathComponent
        let folder = (home as NSString).appendingPathComponent(".claude/projects/\(name)")
        let rule = "~/.claude/projects/\(name)"
        func mine() -> Set<String> {
            Set(LeadLaunch.memberTranscripts(root: root, slug: "journeys", team: team, cwd: team[0].worktree, home: home)
                .filter { $0.hasPrefix("Read(\(rule)") && !$0.hasPrefix("Read(\(rule)--") })
        }
        #expect(mine() == ["Read(\(rule)/*.jsonl)", "Read(\(rule)/memory*)", "Read(\(rule)/memory*/**)"])

        try FileManager.default.createDirectory(atPath: folder + "/0d3e2d68-d467-49bc-b4db-9f13858722ab/tool-results",
                                                withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder)) == nil, "the folder still lists")
        #expect(mine() == ["Read(\(rule))", "Read(\(rule)/**)"])
    }

    @Test func aBoardThatCantBeReadStartsNoVerifier() throws {
        let root = try root()
        let store = BoardStore(root: root)
        try FileManager.default.createDirectory(atPath: store.folder, withIntermediateDirectories: true)
        try "not a board".write(toFile: (store.folder as NSString).appendingPathComponent("board.json"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try prepare(.verifier, root: root, task: "journeys") }
    }
}
