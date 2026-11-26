import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// `project.new` (the no-terminal inventory's C1): a new project made by the server (`ProjectMaker.make`) in a scratch
/// projects folder and a scratch home, in this process: the folder named as the app names it, its git repository and
/// first commit as `lead --init` makes them (`LeadInit`), and each refusal said with its reason, nothing made. The kind
/// itself: the user's voice, recorded, acted from a page that acts as `lead` and `session.new` are, refused from one
/// that doesn't. The whole kind on a node (its lead started) is `NewProjectTests`' (Linux only).
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ProjectNewTests {
    private let scratch = Scratch()

    /// A scratch world: a home whose global git config names the user (unless `identity` is false), the node's private
    /// scratch folder, and a projects folder (made unless `made` is false).
    private struct World {
        var home: String
        var projects: String
        var nodeScratch: URL
        var base: String
    }

    private func world(identity: Bool = true, made: Bool = true) throws -> World {
        let base = scratch.url("project-new")
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if identity {
            try "[user]\n\tname = The User\n\temail = user@example.invalid\n".write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        }
        let projects = base.appendingPathComponent("projects")
        if made { try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true) }
        let nodeScratch = base.appendingPathComponent("node-scratch")
        try FileManager.default.createDirectory(at: nodeScratch, withIntermediateDirectories: true)
        return World(home: home.path, projects: projects.path, nodeScratch: nodeScratch, base: base.path)
    }

    private func make(_ world: World, _ name: String, in location: String? = nil) -> Result<ProjectMaker.Made, ProjectMaker.Refusal> {
        ProjectMaker.make(name: name, location: location, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch)
    }

    /// Everything under `path`, as relative names (nothing followed through a link).
    private func listing(_ path: String) -> [String] {
        (FileManager.default.subpaths(atPath: path) ?? []).sorted()
    }

    private func refusal(_ made: Result<ProjectMaker.Made, ProjectMaker.Refusal>) -> ProjectMaker.Refusal? {
        if case .failure(let refusal) = made { return refusal }
        return nil
    }

    // MARK: What it makes

    /// The folder named for the project in the projects folder, its README, and a git repository whose one commit holds
    /// README.md and the .gitignore made, as the user's global identity, with no hook installed.
    @Test func itMakesTheFolderItsRepositoryAndFirstCommit() throws {
        let world = try world()
        let made = try make(world, "My App").get()
        let folder = LeadInit.resolved(world.projects + "/my-app")
        #expect(made.folder == folder && made.name == "My App" && made.files == [".gitignore", "README.md"], "\(made)")
        #expect((try? String(contentsOfFile: folder + "/README.md", encoding: .utf8)) == "# My App\n")
        func git(_ args: [String]) -> String { LeadInit.git(args, in: folder, home: world.home, scratch: world.nodeScratch).trimmed }
        #expect(git(["log", "--format=%s|%an <%ae>"]) == "\(ProjectCreation.commitMessage)|The User <user@example.invalid>")
        #expect(git(["rev-parse", "HEAD"]) == made.commit)
        #expect(git(["ls-files"]).split(separator: "\n").sorted() == [".gitignore", "README.md"])
        #expect(git(["status", "--porcelain"]).isEmpty, "nothing left uncommitted")
        #expect(LeadInit.kind(folder + "/.git/hooks") == nil, "no hooks folder installed")
    }

    /// A real folder inside the projects folder takes it too, named by the path set or the one it resolves to; a
    /// projects folder that isn't there yet is made for the first project.
    @Test func itMakesItInAFolderInsideTheProjectsFolderAndMakesAMissingProjectsFolder() throws {
        let world = try world()
        try FileManager.default.createDirectory(atPath: world.projects + "/clients", withIntermediateDirectories: true)
        let made = try make(world, "Acme Site", in: world.projects + "/clients").get()
        #expect(made.folder == LeadInit.resolved(world.projects + "/clients/acme-site"), "\(made)")
        let resolved = try make(world, "Other", in: LeadInit.resolved(world.projects) + "/clients/").get()
        #expect(resolved.folder == LeadInit.resolved(world.projects + "/clients/other"), "\(resolved)")

        let fresh = try self.world(made: false)
        let first = try make(fresh, "First").get()
        #expect(first.folder == LeadInit.resolved(fresh.projects + "/first"), "\(first)")
    }

    // MARK: What it refuses, with nothing made

    /// A name the app refuses (a separator, hidden, no letter or number), an invisible or control character, a name
    /// too long: refused as `name`, and nothing is made.
    @Test func aBadNameIsRefusedAndNothingIsMade() throws {
        let world = try world()
        for name in ["a/b", "a:b", ".hidden", "!!! ???", "evil\u{202E}txt", "tab\tname", "zero\u{200B}width", String(repeating: "a", count: 101)] {
            let refused = refusal(make(world, name))
            #expect(refused?.reason == .name, "\(name.debugDescription): \(String(describing: refused))")
        }
        #expect(listing(world.projects).isEmpty, "\(listing(world.projects))")
    }

    /// Where outside the projects folder (another folder, its parent, a `..` back out, a relative path, a name that only
    /// starts the same) is refused as `outside`, and nothing is made there or in the projects folder.
    @Test func aPlaceOutsideTheProjectsFolderIsRefused() throws {
        let world = try world()
        let elsewhere = world.base + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: world.projects + "-two", withIntermediateDirectories: true)
        for location in [elsewhere, world.base, world.projects + "/../elsewhere", world.projects + "/./x", "projects", world.projects + "-two", "/"] {
            let refused = refusal(make(world, "Shop", in: location))
            #expect(refused?.reason == .outside, "\(location): \(String(describing: refused))")
        }
        #expect(listing(elsewhere).isEmpty && listing(world.projects).isEmpty && listing(world.projects + "-two").isEmpty)
    }

    /// Something already there by the project's folder name (a folder with files, a file, a link to a folder, a link to
    /// nothing) is refused as `exists`, left as it was, and nothing is followed.
    @Test func anythingThereByItsNameIsRefusedAndLeftAsItWas() throws {
        let world = try world()
        let elsewhere = world.base + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: world.projects + "/shop", withIntermediateDirectories: true)
        try "mine\n".write(toFile: world.projects + "/shop/notes.txt", atomically: true, encoding: .utf8)
        try "a file\n".write(toFile: world.projects + "/cart", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: world.projects + "/till", withDestinationPath: elsewhere)
        try FileManager.default.createSymbolicLink(atPath: world.projects + "/gone", withDestinationPath: elsewhere + "/gone")
        let before = listing(world.projects)
        for name in ["Shop", "Cart", "Till", "Gone"] {
            let refused = refusal(make(world, name))
            #expect(refused?.reason == .exists, "\(name): \(String(describing: refused))")
        }
        #expect(listing(world.projects) == before, "\(listing(world.projects))")
        #expect((try? String(contentsOfFile: world.projects + "/shop/notes.txt", encoding: .utf8)) == "mine\n")
        #expect(listing(elsewhere).isEmpty, "nothing through the links: \(listing(elsewhere))")
    }

    /// A link on the way below the projects folder, to outside or to a folder inside, is refused as `link`, never
    /// followed; a place there that isn't (missing, a file) as `location`.
    @Test func aLinkOnTheWayIsRefusedAndNeverFollowed() throws {
        let world = try world()
        let elsewhere = world.base + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: world.projects + "/real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: world.projects + "/out", withDestinationPath: elsewhere)
        try FileManager.default.createSymbolicLink(atPath: world.projects + "/in", withDestinationPath: world.projects + "/real")
        for location in [world.projects + "/out", world.projects + "/in", world.projects + "/out/deeper"] {
            let refused = refusal(make(world, "Shop", in: location))
            #expect(refused?.reason == .link, "\(location): \(String(describing: refused))")
        }
        #expect(listing(elsewhere).isEmpty && listing(world.projects + "/real").isEmpty)
        try "x\n".write(toFile: world.projects + "/file", atomically: true, encoding: .utf8)
        for location in [world.projects + "/missing", world.projects + "/file"] {
            let refused = refusal(make(world, "Shop", in: location))
            #expect(refused?.reason == .location, "\(location): \(String(describing: refused))")
        }
        #expect(listing(world.projects) == ["file", "in", "out", "real"], "\(listing(world.projects))")
    }

    /// No name and email in the user's global git config: refused as `identity` before anything is made, the projects
    /// folder too.
    @Test func withNoGitIdentityNothingIsMade() throws {
        let world = try world(identity: false, made: false)
        let refused = refusal(make(world, "Shop"))
        #expect(refused?.reason == .identity, "\(String(describing: refused))")
        #expect(LeadInit.kind(world.projects) == nil, "the projects folder isn't made either")
    }

    /// A projects folder inside a git repository: refused as `repository` (a project gets a repository of its own),
    /// nothing made.
    @Test func aProjectsFolderInsideARepositoryIsRefused() throws {
        let world = try world()
        #expect(LeadInit.git(["init", "--quiet", world.projects], in: world.base, home: world.home, scratch: world.nodeScratch).ok)
        let before = listing(world.projects)
        let refused = refusal(make(world, "Shop"))
        #expect(refused?.reason == .repository, "\(String(describing: refused))")
        #expect(listing(world.projects) == before)
    }

    // MARK: The server's work

    /// What `project.new` does with its arguments: with no claude for the lead nothing is made (and no lead asked for);
    /// made, its lead is started in the new folder with the goal, as a new repository (`initialized`), and the result
    /// says both; a refusal starts nothing.
    @Test func theServerMakesItThenStartsItsLeadAndNothingWithoutClaude() async throws {
        let world = try world()
        let asked = Locked<[String]>([])
        func run(_ name: String, goal: String? = nil, claudeMissing: String? = nil,
                 outcome: LeadEngine.StartOutcome = .started(session: UUID(), program: "/bin/claude", notes: [])) async -> WireKinds.ProjectNew.Result? {
            let answered = Locked<WireKinds.ProjectNew.Result?>(nil)
            Requests.makeProject(name: name, location: nil, goal: goal, claudeMissing: claudeMissing, projectsFolder: world.projects, home: world.home,
                                 scratch: world.nodeScratch, note: { _ in },
                                 startLead: { folder, goal, initialized, done in
                                     asked.mutate { $0.append("\(folder)|\(goal ?? "-")|\(initialized)") }
                                     done(outcome)
                                 }) { answered.value = $0 }
            _ = await eventually(timeout: 60) { answered.value != nil }
            return answered.value
        }
        let missing = try #require(await run("Shop", claudeMissing: "claude: no link"))
        #expect(missing.made == false && missing.refused == "noClaude" && missing.said?.contains("claude: no link") == true, "\(missing)")
        #expect(listing(world.projects).isEmpty && asked.value.isEmpty)

        let made = try #require(await run("Shop", goal: "sell things"))
        let folder = LeadInit.resolved(world.projects + "/shop")
        #expect(made.made == true && made.folder == folder && made.lead == "started" && made.commit?.count == 40, "\(made)")
        #expect(asked.value == ["\(folder)|sell things|true"], "\(asked.value)")

        let again = try #require(await run("Shop"))
        #expect(again.made == false && again.refused == "exists" && asked.value.count == 1, "\(again)")

        let noLead = try #require(await run("Till", outcome: .refused("the session host is gone")))
        #expect(noLead.made == true && noLead.lead == "refused" && noLead.notes == ["the session host is gone"], "\(noLead)")
    }

    // MARK: The kind

    /// `project.new` is a user's-voice state change of the same class as `lead` and `session.new` (the kinds that start
    /// something for the user): recorded, never done again, its result kept, a page's that acts; its keys its type's.
    @Test func theKindIsTheUsersAsLeadAndSessionNewAre() throws {
        let spec = try #require(KindSpec.spec("project.new"))
        let lead = try #require(KindSpec.spec("lead"))
        #expect(spec.sender == lead.sender && spec.effect == lead.effect && spec.servedBy == lead.servedBy && spec.page == lead.page)
        let recorded = try #require(spec.recorded)
        #expect(recorded.keepsResult && !recorded.rerun && !recorded.carded && !recorded.batch)
        #expect(RequestArguments.taken["project.new"] == ["name", "location", "goal"])
        #expect(Requests.approvalArguments["project.new"] == ["name", "location", "goal"])
        #expect(NodeWire.taken.contains("project.new") && Requests.recorded.contains("project.new"))
    }

    /// A page that acts sends it as the user's (`pageVoice`, then recorded); one that doesn't is refused by voice, with or
    /// without terminals; a page never sends it as a read.
    @Test func aPageThatDoesntActIsRefused() {
        for terminals in [false, true] {
            #expect(Principal.page([.read, .draft, .act], terminals: terminals).route("project.new") == .pageVoice)
            for rights in [LiveRights.read, [.read, .draft], [.read, .draft, .watch]] {
                let route = Principal.page(rights, terminals: terminals).route("project.new")
                if case .refused(.voice, _) = route {} else { Issue.record("\(rights): \(route)") }
            }
        }
        #expect(!Principal.page([.read, .draft], terminals: false).kinds.contains("project.new"))
        #expect(Principal.page([.read, .draft, .act], terminals: false).kinds.contains("project.new"))
    }

    /// What the result says, in a sentence a person reads: what was made and how its lead's start went, or why nothing
    /// was made.
    @Test func theResultSaysWhatHappened() throws {
        let made = ProjectMaker.Made(name: "My App", folder: "/home/u/dev/my-app", commit: "abc123", files: [".gitignore", "README.md"])
        let session = UUID()
        let started = Requests.projectMade(made, home: "/home/u", .started(session: session, program: "/bin/claude", notes: []))
        #expect(started.made == true && started.lead == "started" && started.session == NodeIds.session(host: session) && started.refused == nil)
        #expect(started.said == "“My App” is made in ~/dev/my-app, with its git repository and first commit; its lead started.")
        let refused = Requests.projectMade(made, home: "/home/u", .refused("no claude"))
        #expect(refused.made == true && refused.lead == "refused" && refused.said?.hasSuffix("but its lead didn't start: no claude") == true && refused.notes == ["no claude"])
        let none = Requests.projectRefused(ProjectMaker.Refusal(.exists, "There's already a folder named “shop” in ~/dev."))
        #expect(none.made == false && none.refused == "exists" && none.folder == nil && none.said == "There's already a folder named “shop” in ~/dev.")
        let line = String(decoding: NodeWire.line(none), as: UTF8.self)
        #expect(line == "{\"commit\":null,\"folder\":null,\"lead\":null,\"made\":false,\"name\":null,\"notes\":[],\"refused\":\"exists\",\"said\":\"There's already a folder named “shop” in ~/dev.\",\"session\":null}\n", "\(line)")
    }
}
