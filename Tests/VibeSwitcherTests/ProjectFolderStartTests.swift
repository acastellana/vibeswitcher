import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A new session with no folder (Home's Choose Folder…, ⌘N with nothing selected, ⊕ › Other Folder… › Project Lead):
/// the folder you pick starts its project lead, or, when it's in no git repository, you choose between making it one
/// (and starting the lead) and a plain session. A preset you asked for still starts that preset. Git runs with a scratch
/// HOME and config, in scratch folders only.
@MainActor
struct ProjectFolderStartTests {
    let temp = Scratch()

    /// What the flow did, in order.
    final class Calls {
        var prompts: [String] = []
        var leads: [String] = []
        var sessions: [(preset: String?, folder: String)] = []
        var asked: [FolderRepository.Plan] = []
        var failures: [String] = []
    }

    /// git with a scratch HOME and config, never on the main thread.
    func scratchGit() throws -> ProjectCreation.GitRunner {
        let home = temp.url("pfs-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent(".gitconfig")
        try "[user]\n\tname = Test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n"
            .write(to: config, atomically: true, encoding: .utf8)
        let env = Git.environment.merging(["HOME": home.path, "GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1",
                                           "XDG_CONFIG_HOME": home.path]) { $1 }
        return { args, directory in
            #expect(!Thread.isMainThread, "git ran on the main thread")
            return Shell.run(executable: "/usr/bin/git", args: args, in: directory, env: env)
        }
    }

    /// A scratch folder holding `files` (relative path: contents).
    func folder(_ files: [String: String]) throws -> String {
        let url = temp.url("pfs-folder")
        let path = url.resolvingSymlinksInPath().path
        for (name, contents) in files {
            let file = URL(fileURLWithPath: path).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// The flow with fakes: the panel answers `chosen`, the alert `button`.
    func start(_ calls: Calls, chosen: String?, button: Int = 2, git: @escaping ProjectCreation.GitRunner) -> ProjectFolderStart {
        let scratch = temp.url("pfs-scratch")
        return ProjectFolderStart(chooseFolder: { calls.prompts.append($0); return chosen }, git: git, scratch: scratch,
                                  ask: { calls.asked.append($0); return button },
                                  startLead: { calls.leads.append($0) },
                                  startSession: { calls.sessions.append(($0?.name, $1)) },
                                  failed: { title, _ in calls.failures.append(title) })
    }

    @Test func noFolderMeansChooseOneForTheLeadAndAPresetChosenFirstKeepsIt() {
        let shell = LaunchPreset(name: "Shell", kind: .shell, command: "")
        #expect(ProjectFolderStart.plan(preset: nil, folder: nil) == .chooseForLead)
        #expect(ProjectFolderStart.prompt(for: .chooseForLead) == "Start Lead Here")
        #expect(ProjectFolderStart.plan(preset: shell, folder: nil) == .chooseForSession(shell))
        #expect(ProjectFolderStart.prompt(for: .chooseForSession(shell)) == "Start Shell Here")
        // A known folder: the preset asked for (nil: its first), as before, with no panel and no lead.
        #expect(ProjectFolderStart.plan(preset: shell, folder: "/p") == .session(shell, in: "/p"))
        #expect(ProjectFolderStart.plan(preset: nil, folder: "/p") == .session(nil, in: "/p"))
    }

    @Test func explicitPresetsStartAsBeforeWithNoLead() throws {
        let calls = Calls()
        let git = try scratchGit()
        let flow = start(calls, chosen: "/chosen", git: git)
        let shell = LaunchPreset(name: "Shell", kind: .shell, command: "")
        flow.run(preset: shell, folder: "/known")
        flow.run(preset: nil, folder: "/known")
        #expect(calls.prompts.isEmpty)
        flow.run(preset: shell, folder: nil)
        #expect(calls.prompts == ["Start Shell Here"])
        #expect(calls.sessions.map(\.preset) == ["Shell", nil, "Shell"])
        #expect(calls.sessions.map(\.folder) == ["/known", "/known", "/chosen"])
        #expect(calls.leads.isEmpty && calls.asked.isEmpty)
    }

    @Test func aChosenRepositoryOrAFolderInOneStartsTheLead() async throws {
        let git = try scratchGit()
        let repo = try folder(["a.txt": "one\n", "sub/b.txt": "two\n"])
        let made = try await Task.detached { [repo] in
            [git(["init", "-q", "-b", "main"], repo), git(["add", "-A"], repo), git(["commit", "-q", "-m", "first"], repo)].allSatisfy(\.ok)
        }.value
        #expect(made)
        for chosen in [repo, repo + "/sub"] {
            let calls = Calls()
            start(calls, chosen: chosen, git: git).run(preset: nil, folder: nil)
            #expect(calls.prompts == ["Start Lead Here"])
            #expect(await until { calls.leads == [chosen] })
            #expect(calls.sessions.isEmpty && calls.asked.isEmpty && calls.failures.isEmpty)
        }
        // Cancelled in the panel: nothing.
        let calls = Calls()
        start(calls, chosen: nil, git: git).run(preset: nil, folder: nil)
        #expect(calls.prompts == ["Start Lead Here"] && calls.leads.isEmpty && calls.sessions.isEmpty)
    }

    @Test func aFolderInNoRepositoryAsksAndCancelOrAPlainSessionLeaveItAsItWas() async throws {
        let git = try scratchGit()
        let chosen = try folder(["main.py": "print(1)\n"])
        let cancelled = Calls()
        start(cancelled, chosen: chosen, button: 2, git: git).run(preset: nil, folder: nil)
        #expect(await until { cancelled.asked.count == 1 })
        #expect(cancelled.leads.isEmpty && cancelled.sessions.isEmpty)

        let plain = Calls()
        start(plain, chosen: chosen, button: 1, git: git).run(preset: nil, folder: nil)
        #expect(await until { plain.sessions.count == 1 })
        #expect(plain.sessions.first?.preset == nil && plain.sessions.first?.folder == chosen)  // the folder's first preset
        #expect(plain.leads.isEmpty)
        #expect(ProjectCreation.existing(chosen + "/.git") == .none)
        #expect(ProjectCreation.existing(chosen + "/.gitignore") == .none)

        let question = ProjectFolderStart.notRepositoryQuestion(try #require(plain.asked.first))
        #expect(question.text.contains("2 files"))  // main.py and the .gitignore to come
        #expect(question.text.contains("nothing is pushed"))
        #expect(ProjectFolderStart.notRepositoryButtons == ["Make it a git repository and start the lead", "Start a plain Claude session", "Cancel"])
    }

    @Test func makingItARepositoryCommitsItsFilesButSecretsAndStartsTheLead() async throws {
        let git = try scratchGit()
        let chosen = try folder(["main.py": "print(1)\n", "src/app.js": "x\n", ".env": "TOKEN=1\n", "config/.env.local": "A=1\n",
                                 "certs/server.pem": "-\n", "node_modules/dep/index.js": "y\n", "build/out.o": "z\n"])
        let calls = Calls()
        start(calls, chosen: chosen, button: 0, git: git).run(preset: nil, folder: nil)
        #expect(await until { calls.leads == [chosen] || !calls.failures.isEmpty })
        #expect(calls.failures.isEmpty)
        let plan = try #require(calls.asked.first)
        #expect(plan.addsGitignore)
        #expect(plan.files == [".gitignore", "main.py", "src/app.js"])
        #expect(plan.leftOut.isEmpty)  // the new .gitignore covers the secret-named ones and the build output
        let committed = try await Task.detached { [chosen] in git(["ls-files"], chosen).output }.value
        #expect(committed.split(separator: "\n").map(String.init) == [".gitignore", "main.py", "src/app.js"])
        let log = try await Task.detached { [chosen] in git(["log", "--format=%s"], chosen).output }.value
        #expect(log.trimmingCharacters(in: .whitespacesAndNewlines) == ProjectCreation.commitMessage)
        #expect(try String(contentsOfFile: chosen + "/.gitignore", encoding: .utf8) == FolderRepository.gitignore)
    }

    @Test func secretNamedFilesItsOwnGitignoreMissesAreLeftOutAndKeptOut() async throws {
        let git = try scratchGit()
        // Its own .gitignore stays as it is, and doesn't name the secrets.
        let chosen = try folder([".gitignore": "*.log\n", "main.py": "print(1)\n", ".env": "TOKEN=1\n", "keys/id_rsa": "k\n",
                                 "deploy.key": "k\n", "debug.log": "x\n"])
        let calls = Calls()
        start(calls, chosen: chosen, button: 0, git: git).run(preset: nil, folder: nil)
        #expect(await until { calls.leads == [chosen] || !calls.failures.isEmpty })
        #expect(calls.failures.isEmpty)
        let plan = try #require(calls.asked.first)
        #expect(!plan.addsGitignore)
        #expect(plan.files == [".gitignore", "main.py"])
        #expect(plan.leftOut == [".env", "deploy.key", "keys/id_rsa"])
        let question = ProjectFolderStart.notRepositoryQuestion(plan)
        #expect(question.text.contains("Left out, as they look like secrets: .env, deploy.key, keys/id_rsa."))
        #expect(try String(contentsOfFile: chosen + "/.gitignore", encoding: .utf8) == "*.log\n")
        let committed = try await Task.detached { [chosen] in git(["ls-files"], chosen).output }.value
        #expect(committed.split(separator: "\n").map(String.init) == [".gitignore", "main.py"])
        // A later `git add -A` (a worker's) doesn't take them either.
        let status = try await Task.detached { [chosen] in git(["status", "--porcelain", "--untracked-files=all"], chosen).output }.value
        #expect(status.isEmpty, "\(status)")
    }

    /// The files `git ls-files` lists in `folder` (what's committed or staged).
    func tracked(_ folder: String, git: @escaping ProjectCreation.GitRunner) async -> [String] {
        await Task.detached { git(["ls-files"], folder).output.split(separator: "\n").map(String.init) }.value
    }

    /// F1: a .gitignore that un-ignores a secret (`!.env`) wins over .git/info/exclude; the index is checked anyway.
    @Test func aSecretTheFoldersGitignoreUnignoresIsStillLeftOut() async throws {
        let git = try scratchGit()
        let chosen = try folder([".gitignore": "!.env\n!*.pem\n", "main.py": "print(1)\n", ".env": "TOKEN=1\n", "a/server.pem": "-\n"])
        let plan = try await Task.detached { [chosen, scratch = temp.url("pfs-scratch")] in
            try FolderRepository.plan(for: chosen, scratch: scratch, git: git).get()
        }.value
        #expect(plan.leftOut == [".env", "a/server.pem"])
        let problem = await Task.detached { FolderRepository.make(plan, git: git) }.value
        #expect(problem == nil, "\(problem?.message ?? "")")
        #expect(await tracked(chosen, git: git) == [".gitignore", "main.py"])
    }

    /// F6: a secret-named file that came after the question is left out too.
    @Test func aSecretThatCameSinceThePlanIsLeftOut() async throws {
        let git = try scratchGit()
        let chosen = try folder([".gitignore": "*.log\n", "main.py": "print(1)\n"])
        let plan = try await Task.detached { [chosen, scratch = temp.url("pfs-scratch")] in
            try FolderRepository.plan(for: chosen, scratch: scratch, git: git).get()
        }.value
        #expect(plan.leftOut.isEmpty)
        try "k\n".write(toFile: chosen + "/deploy.key", atomically: true, encoding: .utf8)
        let problem = await Task.detached { FolderRepository.make(plan, git: git) }.value
        #expect(problem == nil, "\(problem?.message ?? "")")
        #expect(await tracked(chosen, git: git) == [".gitignore", "main.py"])
        #expect(try String(contentsOfFile: chosen + "/.git/info/exclude", encoding: .utf8).contains("/deploy.key\n"))
    }

    /// F3: a folder holding a repository of its own is named in the question.
    @Test func aNestedRepositoryIsNamedInTheQuestion() async throws {
        let git = try scratchGit()
        let chosen = try folder(["main.py": "print(1)\n", "vendor/lib/a.txt": "a\n"])
        let lib = chosen + "/vendor/lib"
        let made = await Task.detached {
            [git(["init", "-q", "-b", "main"], lib), git(["add", "-A"], lib), git(["commit", "-q", "-m", "x"], lib)].allSatisfy(\.ok)
        }.value
        #expect(made)
        let plan = try await Task.detached { [chosen, scratch = temp.url("pfs-scratch")] in
            try FolderRepository.plan(for: chosen, scratch: scratch, git: git).get()
        }.value
        #expect(plan.nested == ["vendor/lib"])
        #expect(ProjectFolderStart.notRepositoryQuestion(plan).text
            .contains("A repository of its own, committed as a reference (its files aren't included): vendor/lib."))
    }

    @Test func theIgnoreListCoversSecretsAndBuildOutput() {
        for name in [".env", ".env.*", "*.pem", "*.key", "id_rsa*", ".DS_Store", "node_modules/", ".build/", "build/", "dist/",
                     "target/", ".venv/", "__pycache__/"] {
            #expect(FolderRepository.gitignore.split(separator: "\n").contains(Substring(name)), "\(name)")
        }
        for path in [".env", "a/.env.production", "server.pem", "x/deploy.key", "id_rsa", "id_rsa.pub", "ssh/id_ed25519"] {
            #expect(FolderRepository.looksSecret(path), "\(path)")
        }
        for path in ["main.py", "environment.md", "keys.txt", "pem/readme", "my.env.example.md"] {
            #expect(!FolderRepository.looksSecret(path), "\(path)")
        }
    }

    @Test func aFailedCommitLeavesTheFolderAsItWas() async throws {
        let real = try scratchGit()
        let git: ProjectCreation.GitRunner = { args, directory in
            args.first == "commit" ? Git.Result(status: 1, output: "", error: "no identity") : real(args, directory)
        }
        let chosen = try folder(["main.py": "print(1)\n"])
        let calls = Calls()
        start(calls, chosen: chosen, button: 0, git: git).run(preset: nil, folder: nil)
        #expect(await until { !calls.failures.isEmpty })
        #expect(calls.leads.isEmpty)
        #expect(ProjectCreation.existing(chosen + "/.git") == .none)
        #expect(ProjectCreation.existing(chosen + "/.gitignore") == .none)
        #expect(ProjectCreation.existing(chosen + "/main.py") == .file)
    }
}

extension LeadRelaunchTests {
    /// A folder you pick inside a repository whose lead runs: that lead is shown, and no second one starts.
    @Test func choosingAFolderOfAProjectWhoseLeadRunsShowsThatLead() async throws {
        let world = try world()
        defer { world.stop() }
        let (lead, _) = try await leadStarted(in: world)
        let (host, controller) = relaunched(world)
        var asked: [String] = []
        var selected: [UUID] = []
        controller.confirm = { title, _, _ in asked.append(title); return 0 }
        controller.select = { selected.append($0) }
        host.connectIfRunning()
        #expect(await until { controller.keptLeads[world.root] == lead.id })
        let sub = world.root + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)

        var prompts: [String] = []
        let flow = ProjectFolderStart(chooseFolder: { prompts.append($0); return sub },
                                      startLead: { controller.startLead(in: $0) },
                                      startSession: { _, _ in Issue.record("started a plain session") },
                                      failed: { title, _ in Issue.record("failed: \(title)") })
        flow.run(preset: nil, folder: nil)
        #expect(prompts == ["Start Lead Here"])
        // A second lead would be selected under its own session's id.
        #expect(await until { !selected.isEmpty })
        #expect(selected == [lead.id])
        #expect(host.sessions.map(\.id) == [lead.id])
        #expect(asked.isEmpty)
    }
}

/// A repository with no commits yet: the first commit a folder in no repository gets, without the git init.
extension ProjectFolderStartTests {
    /// An empty repository in a scratch folder holding `files`, `staged` added to its index.
    func emptyRepository(_ files: [String: String], staged: [String] = [], git: @escaping ProjectCreation.GitRunner) async throws -> String {
        let chosen = try folder(files)
        let made = await Task.detached {
            git(["init", "-q", "-b", "main"], chosen).ok && (staged.isEmpty || git(["add", "--"] + staged, chosen).ok)
        }.value
        #expect(made)
        return chosen
    }

    @Test func anEmptyRepositoryGetsAFirstCommitOfItsFilesButSecretsStagedOnesToo() async throws {
        let git = try scratchGit()
        let chosen = try await emptyRepository([".gitignore": "*.log\n!.env\n", "main.py": "print(1)\n", "staged.txt": "s\n",
                                                ".env": "TOKEN=1\n", "debug.log": "x\n"],
                                               staged: ["staged.txt", ".env"], git: git)
        let plan = try await Task.detached { [chosen, scratch = temp.url("pfs-scratch")] in
            try FolderRepository.plan(for: chosen, scratch: scratch, git: git).get()
        }.value
        #expect(plan.inRepository && !plan.addsGitignore)
        #expect(plan.files == [".gitignore", "main.py", "staged.txt"])
        #expect(plan.leftOut == [".env"])
        let question = ProjectFolderStart.emptyRepositoryQuestion(plan)
        #expect(question.title == "“\((chosen as NSString).lastPathComponent)” has no commits yet.")
        #expect(question.text.contains("in \(ProjectCreation.tildePath(chosen)), a first commit of its 3 files"))
        #expect(question.text.contains("nothing is pushed"))
        #expect(question.text.contains("Left out, as they look like secrets: .env."))

        let problem = await Task.detached { FolderRepository.make(plan, git: git) }.value
        #expect(problem == nil, "\(problem?.message ?? "")")
        #expect(await tracked(chosen, git: git) == [".gitignore", "main.py", "staged.txt"])
        let count = await Task.detached { git(["rev-list", "--count", "HEAD"], chosen).output }.value
        #expect(count.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        #expect(try String(contentsOfFile: chosen + "/.git/info/exclude", encoding: .utf8).contains("/.env\n"))
        // Made once: a second make finds the commit and does nothing.
        let again = await Task.detached { FolderRepository.make(plan, git: git) }.value
        #expect(again?.message.contains("has a commit already") == true)
    }

    @Test func aFailedFirstCommitInAnEmptyRepositoryPutsItsIndexBack() async throws {
        let real = try scratchGit()
        let git: ProjectCreation.GitRunner = { args, directory in
            args.first == "commit" ? Git.Result(status: 1, output: "", error: "no identity") : real(args, directory)
        }
        let chosen = try await emptyRepository(["main.py": "print(1)\n", "staged.txt": "s\n", "id_rsa": "k\n"], staged: ["staged.txt"], git: real)
        let excludeBefore = try String(contentsOfFile: chosen + "/.git/info/exclude", encoding: .utf8)
        let plan = try await Task.detached { [chosen, scratch = temp.url("pfs-scratch")] in
            try FolderRepository.plan(for: chosen, scratch: scratch, git: git).get()
        }.value
        #expect(plan.addsGitignore)
        let problem = await Task.detached { FolderRepository.make(plan, git: git) }.value
        #expect(problem?.message.contains("no identity") == true)
        #expect(ProjectCreation.existing(chosen + "/.git") == .folder)
        #expect(ProjectCreation.existing(chosen + "/.gitignore") == .none)
        #expect(await tracked(chosen, git: real) == ["staged.txt"])
        #expect(try String(contentsOfFile: chosen + "/.git/info/exclude", encoding: .utf8) == excludeBefore)
    }

    /// An exclude file edited without a last newline: its last pattern and the first left out stay two lines.
    @Test func anExcludeWithoutALastNewlineKeepsItsPatterns() async throws {
        let git = try scratchGit()
        let chosen = try await emptyRepository([".gitignore": "*.tmp\n", "main.py": "print(1)\n", ".env": "TOKEN=1\n"], git: git)
        try "*.log".write(toFile: chosen + "/.git/info/exclude", atomically: true, encoding: .utf8)
        let plan = try await Task.detached { [chosen, scratch = temp.url("pfs-scratch")] in
            try FolderRepository.plan(for: chosen, scratch: scratch, git: git).get()
        }.value
        let problem = await Task.detached { FolderRepository.make(plan, git: git) }.value
        #expect(problem == nil, "\(problem?.message ?? "")")
        #expect(try String(contentsOfFile: chosen + "/.git/info/exclude", encoding: .utf8) == "*.log\n/.env\n")
        let status = await Task.detached { git(["status", "--porcelain", "--untracked-files=all"], chosen).output }.value
        #expect(status.isEmpty, "\(status)")
    }

    /// F1 (audit): a .git the app didn't make whose info folder or exclude file is a symbolic link to somewhere else:
    /// nothing is written through it, and the repository is left as it was.
    @Test func aSymlinkedExcludeInAnEmptyRepositoryIsRefused() async throws {
        let git = try scratchGit()
        for linked in ["info", "info/exclude"] {
            let chosen = try await emptyRepository([".gitignore": "*.tmp\n", "main.py": "print(1)\n", ".env": "TOKEN=1\n"],
                                                   staged: ["main.py"], git: git)
            let elsewhere = temp.url("pfs-elsewhere").resolvingSymlinksInPath().path
            try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
            try "outside\n".write(toFile: elsewhere + "/exclude", atomically: true, encoding: .utf8)
            let link = chosen + "/.git/" + linked
            try FileManager.default.removeItem(atPath: link)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: linked == "info" ? elsewhere : elsewhere + "/exclude")
            let plan = try await Task.detached { [chosen, scratch = temp.url("pfs-scratch")] in
                try FolderRepository.plan(for: chosen, scratch: scratch, git: git).get()
            }.value
            #expect(plan.leftOut == [".env"])
            let problem = await Task.detached { FolderRepository.make(plan, git: git) }.value
            #expect(problem?.message.contains("is a symbolic link") == true, "\(linked): \(problem?.message ?? "made")")
            #expect(try String(contentsOfFile: elsewhere + "/exclude", encoding: .utf8) == "outside\n", "\(linked)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere) == ["exclude"], "\(linked)")
            let empty = await Task.detached { FolderRepository.isEmptyRepository(chosen, git: git) }.value
            #expect(empty, "\(linked)")
            #expect(await tracked(chosen, git: git) == ["main.py"], "\(linked)")
        }
    }

    /// A repository whose HEAD is unborn but has commits elsewhere (an orphan branch) isn't an empty one.
    @Test func anOrphanBranchIsNoEmptyRepository() async throws {
        let git = try scratchGit()
        let chosen = try await emptyRepository(["main.py": "print(1)\n"], staged: ["main.py"], git: git)
        let empty = await Task.detached { FolderRepository.isEmptyRepository(chosen, git: git) }.value
        #expect(empty)
        let plan = try await Task.detached { [chosen, scratch = temp.url("pfs-scratch")] in
            try FolderRepository.plan(for: chosen, scratch: scratch, git: git).get()
        }.value
        let orphaned = await Task.detached {
            [git(["commit", "-q", "-m", "first"], chosen), git(["checkout", "-q", "--orphan", "pages"], chosen)].allSatisfy(\.ok)
        }.value
        #expect(orphaned)
        let still = await Task.detached { FolderRepository.isEmptyRepository(chosen, git: git) }.value
        #expect(!still)
        let problem = await Task.detached { FolderRepository.make(plan, git: git) }.value
        #expect(problem?.message.contains("has a commit already") == true)
        let count = await Task.detached { git(["rev-list", "--count", "--all"], chosen).output }.value
        #expect(count.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    /// `git rm --cached` refuses an entry that differs from both HEAD (none yet) and the work tree, without -f: a
    /// repository of its own named like a secret, with a change of its own.
    @Test func aNestedRepositoryNamedLikeASecretIsLeftOut() async throws {
        let git = try scratchGit()
        let chosen = try folder([".gitignore": "*.log\n", "main.py": "print(1)\n", "vendor/.env/a.txt": "a\n"])
        let nested = chosen + "/vendor/.env"
        let made = await Task.detached {
            [git(["init", "-q", "-b", "main"], nested), git(["add", "-A"], nested), git(["commit", "-q", "-m", "x"], nested)].allSatisfy(\.ok)
        }.value
        #expect(made)
        try "b\n".write(toFile: nested + "/b.txt", atomically: true, encoding: .utf8)
        let plan = try await Task.detached { [chosen, scratch = temp.url("pfs-scratch")] in
            try FolderRepository.plan(for: chosen, scratch: scratch, git: git).get()
        }.value
        let problem = await Task.detached { FolderRepository.make(plan, git: git) }.value
        #expect(problem == nil, "\(problem?.message ?? "")")
        #expect(await tracked(chosen, git: git) == [".gitignore", "main.py"])
        #expect(ProjectCreation.existing(nested + "/b.txt") == .file)
    }

    /// The same for a secret file rewritten between the add and the rm.
    @Test func aSecretRewrittenSinceTheAddIsLeftOut() async throws {
        let real = try scratchGit()
        let git: ProjectCreation.GitRunner = { args, directory in
            if args.first == "rm" { try? "TOKEN=2\n".write(toFile: directory + "/.env", atomically: true, encoding: .utf8) }
            return real(args, directory)
        }
        let chosen = try folder([".gitignore": "!.env\n", "main.py": "print(1)\n", ".env": "TOKEN=1\n"])
        let plan = try await Task.detached { [chosen, scratch = temp.url("pfs-scratch")] in
            try FolderRepository.plan(for: chosen, scratch: scratch, git: git).get()
        }.value
        let problem = await Task.detached { FolderRepository.make(plan, git: git) }.value
        #expect(problem == nil, "\(problem?.message ?? "")")
        #expect(await tracked(chosen, git: real) == [".gitignore", "main.py"])
        #expect(try String(contentsOfFile: chosen + "/.env", encoding: .utf8) == "TOKEN=2\n")
    }

    /// The empty sidebar's New Session menu: Project Lead… asks for a folder, as Home's Choose Folder… does.
    @Test func theEmptySidebarsMenuOffersALeadInAFolderYouChoose() {
        var newSessions: [(preset: String?, folder: String?)] = []
        var leads: [String] = []
        let actions = WindowActions(
            newSession: { newSessions.append(($0?.name, $1)) }, endSession: { _ in }, resume: { _ in }, remove: { _ in }, rename: { _ in },
            pause: { _, _ in }, resumePaused: { _ in }, openInTerminal: { _ in }, presets: { _ in [] }, isLive: { _ in false },
            canResume: { _ in false }, resumeCommand: { _ in nil }, settings: {}, moveToWindow: { _ in }, startLead: { leads.append($0) })
        let empty = NewSessionMenu.leadItem(folder: nil, actions: actions)
        #expect(empty.title == "Project Lead…")
        empty.action()
        actions.chooseFolderForLead()  // Home's Choose Folder…
        #expect(newSessions.count == 2 && newSessions.allSatisfy { $0.preset == nil && $0.folder == nil })
        #expect(ProjectFolderStart.plan(preset: nil, folder: nil) == .chooseForLead)
        #expect(leads.isEmpty)
        // A project's ⊕: its lead, with no panel.
        let project = NewSessionMenu.leadItem(folder: "/p", actions: actions)
        #expect(project.title == "Project Lead")
        project.action()
        #expect(leads == ["/p"] && newSessions.count == 2)
    }
}

extension LeadRelaunchTests {
    /// A scratch repository with no commits yet (its own identity, as `world()`'s), holding a file and a secret.
    func emptyRepository() throws -> String {
        let url = temp.url("empty")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try "TOKEN=1\n".write(toFile: root + "/deploy.key", atomically: true, encoding: .utf8)
        return root
    }

    @Test func anEmptyRepositoryIsOfferedAFirstCommitAndItsLeadStarts() async throws {
        let world = try world()
        defer { world.stop() }
        let root = try emptyRepository()
        let (host, controller) = relaunched(world)
        var asked: [(title: String, buttons: [String])] = []
        var selected: [UUID] = []
        controller.confirm = { title, _, buttons in asked.append((title, buttons)); return 0 }
        controller.select = { selected.append($0) }
        host.connectIfRunning()
        #expect(await until { host.state == .connected })

        controller.startLead(in: root)
        #expect(await until { !selected.isEmpty })
        let name = (root as NSString).lastPathComponent
        #expect(asked.map(\.title) == ["“\(name)” has no commits yet."])
        #expect(asked.first?.buttons == ["Make a first commit and start the lead", "Cancel"])
        #expect(Git.run(["rev-list", "--count", "HEAD"], in: root).output == "1")
        #expect(Git.run(["ls-files"], in: root).output.split(separator: "\n") == [".gitignore", "a.txt"])
        let lead = try #require(host.sessions.first { $0.id == selected.first })
        #expect(lead.label == "Lead · \(name)" && lead.cwd == root)
    }

    @Test func decliningTheFirstCommitChangesNothing() async throws {
        let world = try world()
        defer { world.stop() }
        let root = try emptyRepository()
        let (host, controller) = relaunched(world)
        var asked: [String] = []
        controller.confirm = { title, _, buttons in asked.append(title); return buttons.count - 1 }
        controller.select = { _ in Issue.record("a lead was shown") }
        host.connectIfRunning()
        #expect(await until { host.state == .connected })
        let before = try FileManager.default.contentsOfDirectory(atPath: root + "/.git").sorted()

        controller.startLead(in: root)
        #expect(await until { asked.count == 1 })
        #expect(asked == ["“\((root as NSString).lastPathComponent)” has no commits yet."])
        // A start from outside the app (anything can post it) offers no commit: it's told how, as before.
        controller.startLead(in: root, askAboutMovedHead: false)
        #expect(await until { asked.count == 2 })
        #expect(asked.last == "The repository has no commits yet.")
        // A folder inside it (the repository could be a stray git init in a parent, your home): its whole tree isn't
        // offered for a commit either.
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        controller.startLead(in: root + "/sub")
        #expect(await until { asked.count == 3 })
        #expect(asked.last == "The repository has no commits yet.")

        #expect(!Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).ok)
        #expect(Git.run(["ls-files"], in: root).output.isEmpty)
        #expect(ProjectCreation.existing(root + "/.gitignore") == .none)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root + "/.git").sorted() == before)
        #expect(host.sessions.isEmpty)
    }
}
