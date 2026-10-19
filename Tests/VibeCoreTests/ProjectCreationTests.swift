import Foundation
import Testing
@testable import VibeCore

struct ProjectCreationTests {
    let temp = Scratch()
    let home = "/Users/someone"

    func plan(_ name: String, folder: String? = nil, location: String = "~/dev", initializeGit: Bool = true,
              existing: [String: ProjectCreation.Existing] = ["/Users/someone/dev": .folder]) -> Result<ProjectCreation.Plan, ProjectCreation.Problem> {
        ProjectCreation.plan(name: name, folderName: folder ?? ProjectCreation.folderName(for: name), location: location,
                             options: .init(initializeGit: initializeGit), home: home) { existing[$0] ?? .none }
    }

    func message(_ result: Result<ProjectCreation.Plan, ProjectCreation.Problem>) -> String? {
        if case .failure(let problem) = result { return problem.message }
        return nil
    }

    // MARK: The plan

    @Test func theFolderNameIsTheNameTrimmedHyphenatedAndLowercase() {
        #expect(ProjectCreation.folderName(for: "  My New App ") == "my-new-app")
        #expect(ProjectCreation.folderName(for: "Two  Spaces\tand tab") == "two-spaces-and-tab")
        #expect(ProjectCreation.folderName(for: "already-fine") == "already-fine")
        #expect(ProjectCreation.folderName(for: "Ünïcode Café") == "ünïcode-café")
        #expect(ProjectCreation.folderName(for: "   ") == "")
    }

    @Test func badNamesAreRefusedWithWhatTheSheetSays() {
        #expect(message(plan("")) == "Give the project a name.")
        #expect(message(plan("   ")) == "Give the project a name.")
        #expect(message(plan("Name", folder: "")) == "Give the project a name.")
        #expect(message(plan("!!! ---")) == "A project name needs at least one letter or number.")
        #expect(message(plan("a/b")) == "A folder name can't contain “/” or “:”.")
        #expect(message(plan("a:b")) == "A folder name can't contain “/” or “:”.")
        #expect(message(plan(".hidden")) == "A folder name can't start with “.”: the folder would be hidden.")
        #expect(message(plan("App", location: "  ")) == "Choose where to put the project.")
    }

    @Test func aNameThatIsAlreadyThereIsRefused() {
        let taken: [String: ProjectCreation.Existing] = ["/Users/someone/dev": .folder, "/Users/someone/dev/app": .folder,
                                                         "/Users/someone/dev/notes": .file]
        #expect(message(plan("App", existing: taken)) == "There's already a folder named “app” in ~/dev.")
        #expect(message(plan("Notes", existing: taken)) == "There's already a file named “notes” in ~/dev.")
        #expect(message(plan("App", location: "/Users/someone/dev/notes", existing: taken))
                == "~/dev/notes is a file, not a folder.")
        #expect(message(plan("Other", existing: taken)) == nil)
    }

    @Test func theFilesAreTheReadmeAndGitignore() throws {
        let made = try plan("  My App ").get()
        #expect(made.folder == "/Users/someone/dev/my-app")
        #expect(!made.createsLocation)
        #expect(made.files == [.init(name: "README.md", contents: "# My App\n"),
                               .init(name: ".gitignore", contents: ".DS_Store\n.build/\n")])
        #expect(made.gitSteps(branch: "trunk") == [["init", "--quiet", "--initial-branch=trunk"],
                                                   ["add", "--", "README.md", ".gitignore"],
                                                   ["commit", "--quiet", "-m", "Initial commit"]])
    }

    @Test func anEditedFolderNameAndAMissingLocationAndNoGit() throws {
        let made = try plan("My App", folder: "app-2", location: "/Volumes/Work/projects", initializeGit: false).get()
        #expect(made.folder == "/Volumes/Work/projects/app-2")
        #expect(made.createsLocation)
        #expect(made.files.isEmpty)
        #expect(made.gitSteps(branch: "main").isEmpty)
    }

    @Test func theBranchIsGitsDefaultElseMain() {
        #expect(ProjectCreation.branch(fromConfig: .init(status: 0, output: "trunk\n", error: "")) == "trunk")
        #expect(ProjectCreation.branch(fromConfig: .init(status: 1, output: "", error: "")) == "main")  // not set
        #expect(ProjectCreation.branch(fromConfig: .init(status: 0, output: "  ", error: "")) == "main")
        #expect(ProjectCreation.branch(fromConfig: .init(status: -1, output: "", error: "no git")) == "main")
        #expect(ProjectCreation.branch(fromConfig: .init(status: 0, output: "", error: "", timedOut: true)) == "main")
    }

    @Test func pathsShowAndExpandWithATilde() {
        #expect(ProjectCreation.tildePath("/Users/someone/dev", home: home) == "~/dev")
        #expect(ProjectCreation.tildePath("/Users/someoneelse/dev", home: home) == "/Users/someoneelse/dev")
        #expect(ProjectCreation.expand("~/dev/", home: home) == "/Users/someone/dev")
        #expect(ProjectCreation.expand("~", home: home) == "/Users/someone")
        #expect(ProjectCreation.expand("/tmp/x", home: home) == "/tmp/x")
    }

    // MARK: Making it (real git, a scratch HOME and git config)

    /// git as the app runs it, but with a scratch HOME and global config (an identity, maybe a default branch), never
    /// the user's or the system's.
    func scratchGit(branch: String? = nil) throws -> (home: URL, git: ProjectCreation.GitRunner) {
        let home = temp.url("newproject-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent(".gitconfig")
        var text = "[user]\n\tname = Test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n"
        if let branch { text += "[init]\n\tdefaultBranch = \(branch)\n" }
        try text.write(to: config, atomically: true, encoding: .utf8)
        let env = Git.environment.merging(["HOME": home.path, "GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1",
                                           "XDG_CONFIG_HOME": home.path]) { $1 }
        return (home, { args, directory in Shell.run(executable: "/usr/bin/git", args: args, in: directory, env: env) })
    }

    func location() throws -> String {
        let url = temp.url("newproject-dev")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    @Test func aProjectIsMadeWithOneCommitOnTheConfiguredBranch() throws {
        let (_, git) = try scratchGit(branch: "trunk")
        let dev = try location()
        let made = try ProjectCreation.plan(name: "My App", folderName: "my-app", location: dev).get()
        #expect(made.folder == dev + "/my-app")
        #expect(ProjectCreation.create(made, git: git) == nil)

        #expect(ProjectCreation.existing(made.folder) == .folder)
        let log = git(["log", "--oneline"], made.folder)
        #expect(log.ok)
        #expect(log.output.split(separator: "\n").count == 1)
        #expect(log.output.hasSuffix("Initial commit"))
        #expect(git(["rev-parse", "--abbrev-ref", "HEAD"], made.folder).output == "trunk")
        #expect(git(["ls-files"], made.folder).output.split(separator: "\n").sorted() == [".gitignore", "README.md"])
        #expect(git(["status", "--porcelain"], made.folder).output.isEmpty)
        #expect(try String(contentsOfFile: made.folder + "/README.md", encoding: .utf8) == "# My App\n")
        #expect(try String(contentsOfFile: made.folder + "/.gitignore", encoding: .utf8) == ".DS_Store\n.build/\n")
        let mode = try FileManager.default.attributesOfItem(atPath: made.folder)[.posixPermissions] as? Int
        #expect(mode == 0o755)

        // The same name again is refused before anything is written.
        let before = git(["rev-parse", "HEAD"], made.folder).output
        #expect(message(ProjectCreation.plan(name: "My App", folderName: "my-app", location: dev))
                == "There's already a folder named “my-app” in \(ProjectCreation.tildePath(dev)).")
        #expect(ProjectCreation.create(made, git: git) == .exists(folder: "my-app", location: ProjectCreation.tildePath(dev)))
        #expect(git(["rev-parse", "HEAD"], made.folder).output == before)
        #expect(git(["status", "--porcelain"], made.folder).output.isEmpty)
    }

    @Test func withoutAConfiguredBranchItsMain() throws {
        let (_, git) = try scratchGit()
        let made = try ProjectCreation.plan(name: "Plain", folderName: "plain", location: try location()).get()
        #expect(ProjectCreation.create(made, git: git) == nil)
        #expect(git(["rev-parse", "--abbrev-ref", "HEAD"], made.folder).output == "main")
        #expect(git(["log", "--oneline"], made.folder).output.split(separator: "\n").count == 1)
    }

    @Test func aMissingProjectsFolderIsMadeWith0755() throws {
        let (_, git) = try scratchGit()
        let dev = try location() + "/not-yet"
        let made = try ProjectCreation.plan(name: "New", folderName: "new", location: dev).get()
        #expect(made.createsLocation)
        #expect(ProjectCreation.create(made, git: git) == nil)
        #expect(ProjectCreation.existing(dev) == .folder)
        #expect(try FileManager.default.attributesOfItem(atPath: dev)[.posixPermissions] as? Int == 0o755)
    }

    @Test func gitMissingLeavesNoFolderAndSaysWhy() throws {
        let dev = try location()
        let made = try ProjectCreation.plan(name: "No Git", folderName: "no-git", location: dev + "/projects").get()
        let missing: ProjectCreation.GitRunner = { args, directory in
            Shell.run(executable: "/nonexistent/bin/git", args: args, in: directory)
        }
        guard case .failed(let said)? = ProjectCreation.create(made, git: missing) else {
            Issue.record("expected a failure"); return
        }
        #expect(said.hasPrefix("git init failed: "))
        #expect(said.count > "git init failed: ".count)
        #expect(ProjectCreation.existing(made.folder) == .none)
        // The projects folder it made for this goes too; the one that was there stays.
        #expect(ProjectCreation.existing(dev + "/projects") == .none)
        #expect(ProjectCreation.existing(dev) == .folder)
    }

    @Test func aFailingCommitShowsGitsMessageAndLeavesNoFolder() throws {
        let (_, real) = try scratchGit()
        let dev = try location()
        let made = try ProjectCreation.plan(name: "Fails", folderName: "fails", location: dev).get()
        let failing: ProjectCreation.GitRunner = { args, directory in
            args.first == "commit" ? Git.Result(status: 128, output: "", error: "fatal: unable to auto-detect email address")
                                   : real(args, directory)
        }
        #expect(ProjectCreation.create(made, git: failing) == .failed("git commit failed: fatal: unable to auto-detect email address"))
        #expect(ProjectCreation.existing(made.folder) == .none)
        #expect(ProjectCreation.existing(dev) == .folder)
    }

    @Test func aFailureRemovesEveryLevelItMadeAndKeepsTheParentThatWasThere() throws {
        let (_, real) = try scratchGit()
        let parent = try location()
        try "keep\n".write(toFile: parent + "/mine.txt", atomically: true, encoding: .utf8)
        let dev = parent + "/a/b"
        let made = try ProjectCreation.plan(name: "Deep", folderName: "deep", location: dev).get()
        #expect(made.createsLocation)
        let failing: ProjectCreation.GitRunner = { args, directory in
            if args.first == "commit" {
                // Every level was made, each 0755, before git got this far.
                #expect(try! FileManager.default.attributesOfItem(atPath: parent + "/a")[.posixPermissions] as? Int == 0o755)
                #expect(ProjectCreation.existing(dev + "/deep/.git") == .folder)
                return Git.Result(status: 128, output: "", error: "fatal: no")
            }
            return real(args, directory)
        }
        #expect(ProjectCreation.create(made, git: failing) == .failed("git commit failed: fatal: no"))
        #expect(ProjectCreation.existing(parent + "/a") == .none)
        #expect(ProjectCreation.existing(parent) == .folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent) == ["mine.txt"])
    }

    @Test func aFolderThatAppearedAfterThePlanIsLeftAlone() throws {
        let (_, git) = try scratchGit()
        let dev = try location()
        let made = try ProjectCreation.plan(name: "Race", folderName: "race", location: dev).get()
        try FileManager.default.createDirectory(atPath: made.folder, withIntermediateDirectories: false)
        try "mine\n".write(toFile: made.folder + "/notes.txt", atomically: true, encoding: .utf8)
        #expect(ProjectCreation.create(made, git: git) == .exists(folder: "race", location: ProjectCreation.tildePath(dev)))
        #expect(try String(contentsOfFile: made.folder + "/notes.txt", encoding: .utf8) == "mine\n")
        #expect(ProjectCreation.existing(made.folder + "/.git") == .none)
    }

    @Test func withoutGitItsAnEmptyFolder() throws {
        let dev = try location()
        let made = try ProjectCreation.plan(name: "Bare", folderName: "bare", location: dev, options: .init(initializeGit: false)).get()
        #expect(ProjectCreation.create(made, git: { _, _ in Issue.record("git ran"); return .init(status: 1, output: "", error: "") }) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: made.folder).isEmpty)
    }
}
