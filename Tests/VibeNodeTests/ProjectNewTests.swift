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

    // MARK: The independent review's (review-v2-s-new, 2026-11-26)

    /// Invisible characters beyond control and format (a variation selector, a combining grapheme joiner, Hangul fillers,
    /// the braille blank) would make a name that looks like an existing project's: refused as `name`, nothing made beside
    /// it (the review's r03, N1).
    @Test func invisibleLookAlikesOfAProjectAreRefused() throws {
        let world = try world()
        _ = try make(world, "shop").get()
        for name in ["shop\u{FE0F}", "shop\u{034F}", "shop\u{3164}", "shop\u{2800}", "shop\u{115F}", "shop\u{FFA0}", "shop\u{180B}"] {
            let refused = refusal(make(world, name))
            #expect(refused?.reason == .name, "\(name.unicodeScalars.map { String(format: "U+%04X", $0.value) }.last ?? ""): \(String(describing: refused))")
        }
        #expect(listing(world.projects).filter { !$0.hasPrefix("shop/") } == ["shop"], "\(listing(world.projects))")
    }

    /// The location's folder, once the walk has opened it, moved out of the projects folder with a link left in its place
    /// (triggered by the project's folder appearing in it; the window widened by a full node scratch): refused, or made in
    /// the projects folder, and nothing of a repository left outside (the review's r12, I1). The Mac's folder events only.
    @Test func theSameFolderMovedOutAndReachedThroughALinkIsRefused() throws {
        #if canImport(Darwin)
        let world = try world()
        let real = world.projects + "/real"
        let outside = world.base + "/outside"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        for number in 0..<20_000 { mkdir(world.nodeScratch.path + "/lead-init-fill-\(number)", 0o700) }
        let name = "moved"
        let watched = open(real, O_EVTONLY)
        #expect(watched >= 0)
        let swapped = Locked<String?>(nil)
        let queue = DispatchQueue(label: "moved-out")
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watched, eventMask: .write, queue: queue)
        source.setEventHandler {
            guard swapped.value == nil, LeadInit.kind(real + "/" + name) == S_IFDIR else { return }
            let moved = rename(real, outside + "/moved-real") == 0
            let linked = symlink(outside + "/moved-real", real) == 0
            swapped.value = "moved \(moved), linked \(linked)"
            source.cancel()
        }
        source.setCancelHandler { close(watched) }
        source.resume()
        let result = make(world, name, in: real)
        source.cancel()
        let atSwap = queue.sync { swapped.value }
        #expect(atSwap == "moved true, linked true", "the swap didn't happen: \(atSwap ?? "none")")
        switch result {
        case .success(let made):
            #expect(made.folder.hasPrefix(LeadInit.resolved(world.projects) + "/"), "made outside the projects folder, its lead to start there: \(made.folder)")
        case .failure(let refused):
            #expect(LeadInit.kind(outside + "/moved-real/" + name + "/.git") == nil, "refused (\(refused.message)) but a repository left outside: \(listing(outside))")
        }
        #endif
    }

    /// A Where with a hidden folder in it (as `~/.claude/commands` would be with the projects folder at `~`), or a projects
    /// folder set to a hidden one: refused as `hidden`, nothing made.
    @Test func aHiddenFolderOnTheWayIsRefused() throws {
        let world = try world()
        try FileManager.default.createDirectory(atPath: world.projects + "/.claude/commands", withIntermediateDirectories: true)
        for location in [world.projects + "/.claude", world.projects + "/.claude/commands"] {
            let refused = refusal(make(world, "Deploy Now", in: location))
            #expect(refused?.reason == .hidden, "\(location): \(String(describing: refused))")
        }
        let hiddenRoot = world.base + "/.config/projects"
        try FileManager.default.createDirectory(atPath: hiddenRoot, withIntermediateDirectories: true)
        let refused = refusal(ProjectMaker.make(name: "Deploy Now", location: nil, projectsFolder: hiddenRoot, home: world.home, scratch: world.nodeScratch))
        #expect(refused?.reason == .hidden, "\(String(describing: refused))")
        #expect(listing(world.projects) == [".claude", ".claude/commands"] && listing(hiddenRoot).isEmpty)
    }

    /// The projects folder set to a link into a hidden folder (`~/projects-link -> ~/.claude/commands`): Where typed by
    /// the path the link resolves to, or through the link, is refused as `hidden` (the re-check's R1), nothing made.
    @Test func whereTypedByTheResolvedPathOfAHiddenProjectsFolderIsRefused() throws {
        let world = try world()
        let commands = world.home + "/.claude/commands"
        try FileManager.default.createDirectory(atPath: commands + "/sub", withIntermediateDirectories: true)
        #expect(symlink(commands, world.home + "/projects-link") == 0)
        for location in [commands + "/sub", LeadInit.resolved(commands) + "/sub", "~/projects-link/sub"] {
            let refused = refusal(ProjectMaker.make(name: "Ship it", location: location, projectsFolder: "~/projects-link", home: world.home, scratch: world.nodeScratch))
            #expect(refused?.reason == .hidden, "\(location): \(String(describing: refused))")
        }
        #expect(listing(commands) == ["sub"], "\(listing(commands))")
    }

    /// A projects folder not there yet, below a link (to a hidden folder, or to any folder): none of its levels is made
    /// through the link, nothing is made, and the dialog names the folder by the path the link resolves to.
    @Test func aMissingProjectsFolderIsNeverMadeThroughALink() throws {
        let world = try world()
        try FileManager.default.createDirectory(atPath: world.home + "/.claude", withIntermediateDirectories: true)
        #expect(symlink(world.home + "/.claude", world.home + "/hidden-link") == 0)
        let elsewhere = world.base + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        #expect(symlink(elsewhere, world.home + "/elsewhere-link") == 0)
        // The dialog first, while the folders aren't there.
        for (folder, expected) in [("~/elsewhere-link/projects/new", LeadInit.resolved(elsewhere) + "/projects/new/shop"),
                                   ("~/hidden-link/projects", LeadInit.resolved(world.home + "/.claude") + "/projects/shop")] {
            let phrase = Requests.projectNewPhrase(name: "Shop", location: nil, goal: nil, projectsFolder: folder, home: world.home)
            #expect(phrase == "make the project “Shop” in \(expected) and start its lead", "\(phrase)")
        }

        let hidden = refusal(ProjectMaker.make(name: "Deploy now", location: nil, projectsFolder: "~/hidden-link/projects", home: world.home, scratch: world.nodeScratch))
        #expect(hidden?.reason == .hidden, "\(String(describing: hidden))")
        #expect(listing(world.home + "/.claude").isEmpty, "\(listing(world.home + "/.claude"))")
        let linked = refusal(ProjectMaker.make(name: "Shop", location: nil, projectsFolder: "~/elsewhere-link/projects/new", home: world.home, scratch: world.nodeScratch))
        #expect(linked?.reason == .location, "\(String(describing: linked))")
        #expect(listing(elsewhere).isEmpty, "\(listing(elsewhere))")
    }

    /// The lead's start is pinned to what was made: nil while the folder is the one made, holding the commit made, and
    /// (once git found it) the top of its own repository; else why not: another folder by its path (a link to another
    /// repository in its place), another commit, another top (the review's I1 (b)).
    @Test func theLeadStartIsPinnedToTheFolderAndCommitMade() throws {
        let world = try world()
        let made = try make(world, "Shop").get()
        #expect(ProjectMaker.stillMade(made, root: nil, home: world.home, scratch: world.nodeScratch) == nil)
        #expect(ProjectMaker.stillMade(made, root: made.folder, home: world.home, scratch: world.nodeScratch) == nil)
        #expect(ProjectMaker.stillMade(made, root: world.projects, home: world.home, scratch: world.nodeScratch) != nil, "another repository's top")
        // Another commit on top: not the repository made.
        try "more\n".write(toFile: made.folder + "/more.txt", atomically: true, encoding: .utf8)
        #expect(LeadInit.git(["add", "more.txt"], in: made.folder, home: world.home, scratch: world.nodeScratch).ok)
        #expect(LeadInit.git(["commit", "-q", "-m", "more"], in: made.folder, home: world.home, scratch: world.nodeScratch).ok)
        #expect(ProjectMaker.stillMade(made, root: nil, home: world.home, scratch: world.nodeScratch) != nil, "another commit")
        // The folder moved away and a link to another repository left by its name.
        let other = try make(world, "Other").get()
        #expect(rename(made.folder, world.base + "/away") == 0 && symlink(other.folder, made.folder) == 0)
        let why = ProjectMaker.stillMade(made, root: nil, home: world.home, scratch: world.nodeScratch)
        #expect(why?.contains("isn't the folder made") == true, "\(why ?? "nil")")
    }

    /// What the Mac's dialog (and a passkey's phrase) says: the project's name and the folder it will be made in, by its
    /// resolved path, the projects folder named when Where is empty; the goal whole.
    @Test func theApprovalPhraseNamesTheResolvedFolder() throws {
        let world = try world()
        let projects = LeadInit.resolved(world.projects)
        let plain = Requests.projectNewPhrase(name: "Shop", location: nil, goal: nil, projectsFolder: world.projects, home: world.home)
        #expect(plain == "make the project “Shop” in \(projects)/shop and start its lead", "\(plain)")
        try FileManager.default.createDirectory(atPath: world.projects + "/clients", withIntermediateDirectories: true)
        let placed = Requests.projectNewPhrase(name: "Acme Site", location: world.projects + "/clients", goal: "ship it", projectsFolder: world.projects, home: world.home)
        #expect(placed == "make the project “Acme Site” in \(projects)/clients/acme-site and start its lead with the goal “ship it”", "\(placed)")
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
                                 startLead: { folder, goal, initialized, stillMade, done in
                                     #expect(stillMade(nil) == nil && stillMade(folder) == nil, "pinned to the folder just made")
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
