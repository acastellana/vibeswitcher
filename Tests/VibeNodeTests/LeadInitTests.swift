import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// `lead --init`'s plan and make (`LeadInit`, the independent review of 2026-11-22), in this process on a scratch folder
/// and a scratch home: nothing of the folder's git runs and no hooks baseline is taken; exactly the files shown are
/// committed, a change during the prompt refuses with nothing left; a repository config that could run anything is
/// refused; the secrets are named and left out; the author is the home's global identity; the folder is checked again.
/// The end to end runs are `NewProjectTests`'.
@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(5)))
struct LeadInitTests {
    private let scratch = Scratch()

    /// A home whose global git config names the user.
    private func home(identity: Bool = true) throws -> String {
        let home = scratch.url("home-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if identity {
            try "[user]\n\tname = The User\n\temail = user@example.invalid\n".write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        }
        return home.path
    }

    /// A folder with `files` (name: contents).
    private func folder(_ files: [String: String] = ["a.txt": "a\n"]) throws -> String {
        let url = scratch.url("project-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, text) in files {
            let file = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return url.resolvingSymlinksInPath().path
    }

    private var probes: URL { scratch.url("probes") }

    private func plan(_ folder: String, home: String) throws -> LeadInit.Plan {
        switch LeadInit.plan(folder, home: home, scratch: probes) {
        case .failure(let refusal): throw refusal
        case .success(let plan): return try #require(plan)
        }
    }

    private func refusal(_ folder: String, home: String) -> String? {
        if case .failure(let refusal) = LeadInit.plan(folder, home: home, scratch: probes) { return refusal.message }
        return nil
    }

    private func tree(_ folder: String) -> [String] {
        LeadInit.repo(["ls-tree", "-r", "-z", "--name-only", "HEAD"], folder).output.split(separator: "\0").map(String.init).sorted()
    }

    /// An agent's `git init` and executable hooks: none runs at the plan or the commit, and nothing records a baseline
    /// of them (`Git.run` would take the hooks a first-seen repository has as accepted).
    @Test func aPlantedHookDoesntRunAndNoBaselineIsTaken() throws {
        let home = try home()
        let folder = try folder()
        #expect(LeadInit.git(["init", "-q"], in: folder).ok)
        let marker = scratch.url("hook-ran").path
        for hook in ["pre-commit", "commit-msg", "post-commit", "reference-transaction", "post-index-change"] {
            try writeClosedOnExec("#!/bin/sh\necho \(hook) >> '\(marker)'\n", to: URL(fileURLWithPath: folder + "/.git/hooks/" + hook))
        }
        let planned = try plan(folder, home: home)
        #expect(planned.inRepository && planned.files == [".gitignore", "a.txt"], "\(planned)")
        let made = LeadInit.make(planned, home: home)
        #expect(made == .success([".gitignore", "a.txt"]), "\(made)")
        #expect(!FileManager.default.fileExists(atPath: marker), "a hook ran: \((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "")")
        let common = folder + "/.git"
        #expect(GitGuard.accepted(commonDir: common) == nil && !FileManager.default.fileExists(atPath: GitGuard.store(commonDir: common).path),
                "no baseline of the folder's hooks")
    }

    /// The commit holds exactly the planned files: a file come during the prompt isn't added; one gone, or one staged by
    /// someone else meanwhile, refuses with nothing left (a new repository removed, an existing one's index put back).
    @Test func aChangeDuringThePromptIsntCommittedOrRefuses() throws {
        let home = try home()
        let added = try folder(["a.txt": "a\n"])
        let planned = try plan(added, home: home)
        try "b\n".write(toFile: added + "/b.txt", atomically: true, encoding: .utf8)
        #expect(LeadInit.make(planned, home: home) == .success([".gitignore", "a.txt"]))
        #expect(tree(added) == [".gitignore", "a.txt"], "b.txt came after the code was asked: not committed")

        let gone = try folder(["a.txt": "a\n", "c.txt": "c\n"])
        let shown = try plan(gone, home: home)
        try FileManager.default.removeItem(atPath: gone + "/c.txt")
        guard case .failure(let refused) = LeadInit.make(shown, home: home) else { Issue.record("made with a shown file gone"); return }
        #expect(refused.message.contains("c.txt"), "\(refused)")
        #expect(!FileManager.default.fileExists(atPath: gone + "/.git") && !FileManager.default.fileExists(atPath: gone + "/.gitignore"), "nothing left")

        let staged = try folder(["a.txt": "a\n"])
        #expect(LeadInit.git(["init", "-q"], in: staged).ok)
        let asked = try plan(staged, home: home)
        try "x\n".write(toFile: staged + "/x.txt", atomically: true, encoding: .utf8)
        #expect(LeadInit.repo(["add", "x.txt"], staged).ok)
        let indexBefore = FileManager.default.contents(atPath: staged + "/.git/index")
        guard case .failure(let refusedStaged) = LeadInit.make(asked, home: home) else { Issue.record("made with a file staged meanwhile"); return }
        #expect(refusedStaged.message.contains("staged and not shown: x.txt"), "\(refusedStaged)")
        #expect(FileManager.default.contents(atPath: staged + "/.git/index") == indexBefore, "the index put back")
        #expect(!LeadInit.repo(["rev-parse", "--verify", "--quiet", "HEAD"], staged).ok)
    }

    /// A repository whose config sets core.worktree, a filter or a hooks path, whose .git is a file, or which is a
    /// linked worktree's is refused at the plan, naming why.
    @Test func aRepositoryConfigThatCouldRunAnythingIsRefused() throws {
        let home = try home()
        for (key, value) in [("core.worktree", "/elsewhere"), ("filter.evil.clean", "sh -c 'touch x'"), ("core.hooksPath", "hooks"), ("include.path", "../x")] {
            let folder = try folder()
            #expect(LeadInit.git(["init", "-q"], in: folder).ok)
            #expect(LeadInit.git(["config", "--file", folder + "/.git/config", key, value], in: "/").ok)
            let why = refusal(folder, home: home) ?? ""
            #expect(why.contains(key == "core.worktree" ? "core.worktree" : key.lowercased()) || why.contains(key), "\(key): \(why)")
        }
        let linked = try folder()
        let elsewhere = try folder()
        #expect(LeadInit.git(["init", "-q"], in: elsewhere).ok)
        try "gitdir: \(elsewhere)/.git\n".write(toFile: linked + "/.git", atomically: true, encoding: .utf8)
        #expect(refusal(linked, home: home)?.contains("isn't a folder of its own") == true, "\(refusal(linked, home: home) ?? "")")
        // A plain clone's keys are taken.
        let plain = try folder()
        #expect(LeadInit.git(["init", "-q"], in: plain).ok)
        #expect(LeadInit.git(["config", "--file", plain + "/.git/config", "remote.origin.url", "https://example.invalid/r.git"], in: "/").ok)
        #expect(refusal(plain, home: home) == nil)
    }

    @Test func theSecretNamesAreMatchedWithoutCaseNamedAndLeftOut() throws {
        for name in [".NPMRC", "prod.env", ".ENV", ".env.local", "Terraform.tfstate.backup", "id_dsa.pub", "x.keystore", "a/b/credentials.json",
                     ".netrc", ".git-credentials", ".pypirc", ".envrc", "c.PFX", "k.jks", "vars.tfvars", "server.KEY"] {
            #expect(LeadInit.looksSecret(name), "\(name)")
        }
        for name in ["README.md", "environment.ts", "keys.md", "src/env.swift"] { #expect(!LeadInit.looksSecret(name), "\(name)") }
        let home = try home()
        let folder = try folder(["a.txt": "a\n", ".npmrc": "token\n", "Prod.ENV": "K=1\n", ".gitignore": "*.log\n"])
        let planned = try plan(folder, home: home)
        #expect(planned.leftOut == [".npmrc", "Prod.ENV"] && planned.files == [".gitignore", "a.txt"], "\(planned)")
        let words = LeadInit.words(planned)
        #expect(words.contains("Left out, as they look like secrets: .npmrc, Prod.ENV") && words.contains("Committed: .gitignore, a.txt"), "\(words)")
        #expect(LeadInit.make(planned, home: home) == .success([".gitignore", "a.txt"]))
        let exclude = try String(contentsOfFile: folder + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.contains("/.npmrc\n") && exclude.contains("/Prod.ENV\n"), "kept out of later commits: \(exclude)")
    }

    /// The prompt names the files, the first `shownNames`, and counts the rest.
    @Test func thePromptNamesTheFilesAndCountsTheRest() throws {
        let home = try home()
        var files: [String: String] = [".gitignore": "x\n"]
        for index in 0..<24 { files[String(format: "f%02d.txt", index)] = "\(index)\n" }
        let planned = try plan(try folder(files), home: home)
        let words = LeadInit.words(planned)
        #expect(words.contains("Committed: .gitignore, f00.txt") && words.contains("f18.txt and 5 more"), "\(words)")
        #expect(words.contains("as The User <user@example.invalid>"), "\(words)")
    }

    /// The author is the home's global identity, never the folder's own config's; none there refuses, saying how.
    @Test func theAuthorIsTheUsersGlobalIdentity() throws {
        let home = try home()
        let folder = try folder()
        #expect(LeadInit.git(["init", "-q"], in: folder).ok)
        #expect(LeadInit.git(["config", "--file", folder + "/.git/config", "user.name", "An Agent"], in: "/").ok)
        #expect(LeadInit.git(["config", "--file", folder + "/.git/config", "user.email", "agent@example.invalid"], in: "/").ok)
        let planned = try plan(folder, home: home)
        #expect(LeadInit.make(planned, home: home) == .success([".gitignore", "a.txt"]))
        let author = LeadInit.repo(["log", "-1", "--format=%an <%ae> / %cn <%ce>"], folder).output
        #expect(author == "The User <user@example.invalid> / The User <user@example.invalid>", "\(author)")
        let nobody = try self.home(identity: false)
        #expect(refusal(try self.folder(), home: nobody)?.contains("git config --global user.name") == true)
    }

    /// The folder checked again after the code: replaced by a link meanwhile, nothing is made; the home folder and `/`
    /// are refused by their resolved paths.
    @Test func theFolderIsCheckedAgainAndHomeIsRefused() throws {
        let home = try home()
        let folder = try folder()
        let planned = try plan(folder, home: home)
        let other = try self.folder(["z.txt": "z\n"])
        try FileManager.default.removeItem(atPath: folder)
        try FileManager.default.createSymbolicLink(atPath: folder, withDestinationPath: other)
        guard case .failure(let refused) = LeadInit.make(planned, home: home) else { Issue.record("made through a link"); return }
        #expect(refused.message.contains("isn't a folder"), "\(refused)")
        #expect(!FileManager.default.fileExists(atPath: other + "/.git"))
        let linkToHome = scratch.url("to-home").path
        try FileManager.default.createSymbolicLink(atPath: linkToHome, withDestinationPath: home)
        #expect(refusal(home, home: home)?.contains("a folder of its own") == true)
        #expect(refusal("/", home: home)?.contains("a folder of its own") == true)
        #expect(refusal(linkToHome, home: home) != nil, "a link to the home folder")
    }
}
