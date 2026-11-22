import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// `lead --init`'s plan and make (`LeadInit`, narrowed by the whole-feature review of 2026-11-22), in this process on a
/// scratch folder and a scratch home: only a folder in no repository; the repository built privately and installed
/// through the folder's descriptor (a `.git` pre-placed or appearing during the prompt, as a folder or a link, refuses
/// with nothing written); files read through descriptors (a file or a parent swapped for a link pulls nothing in, a hard
/// link, an oversized file or too much in all refuses); no filter or hook of anyone's runs; every committed name in the
/// prompt; the secrets named and left out; the author the home's global identity; the folder checked again; git given
/// nothing of this process's environment. The end to end runs are `NewProjectTests`'.
@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(5)))
struct LeadInitTests {
    private let scratch = Scratch()

    /// A home whose global git config names the user (and `extra`, more of its config).
    private func home(identity: Bool = true, extra: String = "") throws -> String {
        let home = scratch.url("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let user = identity ? "[user]\n\tname = The User\n\temail = user@example.invalid\n" : ""
        try (user + extra).write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        return home.path
    }

    /// A folder with `files` (name: contents).
    private func folder(_ files: [String: String] = ["a.txt": "a\n"]) throws -> String {
        let url = scratch.url("project")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, text) in files {
            let file = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return url.resolvingSymlinksInPath().path
    }

    private var probes: URL {
        let url = scratch.url("probes")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// git as `LeadInit` runs it, in `folder`, for the test's own looks.
    private func git(_ args: [String], _ folder: String, home: String) -> LeadInit.Ran {
        LeadInit.git(args, in: folder, home: home, scratch: probes)
    }

    private func plan(_ folder: String, home: String) throws -> LeadInit.Plan {
        try LeadInit.plan(folder, home: home, scratch: probes).get()
    }

    private func refusal(_ folder: String, home: String) -> String? {
        if case .failure(let refusal) = LeadInit.plan(folder, home: home, scratch: probes) { return refusal.message }
        return nil
    }

    private func made(_ plan: LeadInit.Plan, home: String, maxFile: Int64 = LeadInit.maxFileBytes, maxTotal: Int64 = LeadInit.maxTotalBytes)
        -> Result<[String], LeadInit.Refusal> {
        LeadInit.make(plan, home: home, scratch: probes, maxFile: maxFile, maxTotal: maxTotal).map(\.files)
    }

    private func tree(_ folder: String, home: String) -> [String] {
        git(["ls-tree", "-r", "-z", "--name-only", "HEAD"], folder, home: home).output.split(separator: "\0").map(String.init).sorted()
    }

    /// Nothing was made: no .git (unless `kept`, one that was there), no .gitignore of ours.
    private func nothingMade(_ folder: String, gitignore: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!FileManager.default.fileExists(atPath: folder + "/.git"), sourceLocation: sourceLocation)
        let partial = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix(".git.vs-init") }
        #expect(partial.isEmpty, "a partial install left: \(partial)", sourceLocation: sourceLocation)
        if gitignore { #expect(!FileManager.default.fileExists(atPath: folder + "/.gitignore"), sourceLocation: sourceLocation) }
    }

    @Test func theRepositoryIsMadeSoundWithNoHooksAndTheFolderUntouchedBeyondIt() throws {
        let home = try home()
        let folder = try folder(["a.txt": "a\n", "src/b.txt": "b\n", ".npmrc": "token\n"])
        let planned = try plan(folder, home: home)
        #expect(planned.files == [".gitignore", "a.txt", "src/b.txt"] && planned.leftOut == [".npmrc"] && planned.branch == "main", "\(planned)")
        let result = LeadInit.make(planned, home: home, scratch: probes)
        guard case .success(let made) = result else { Issue.record("\(result)"); return }
        #expect(git(["rev-parse", "HEAD"], folder, home: home).trimmed == made.commit)
        #expect(git(["symbolic-ref", "HEAD"], folder, home: home).trimmed == "refs/heads/main")
        #expect(tree(folder, home: home) == [".gitignore", "a.txt", "src/b.txt"])
        #expect(git(["status", "--porcelain"], folder, home: home).output.isEmpty, "a clean work tree: \(git(["status", "--porcelain"], folder, home: home).output)")
        #expect(git(["fsck", "--strict"], folder, home: home).ok)
        #expect(git(["config", "--bool", "core.bare"], folder, home: home).trimmed == "false")
        #expect(git(["log", "-g", "--format=%gs", "main"], folder, home: home).trimmed.hasPrefix("commit (initial)"), "its reflog")
        #expect(!FileManager.default.fileExists(atPath: folder + "/.git/hooks"), "no hooks folder: the lead's first look accepts none")
        let exclude = try String(contentsOfFile: folder + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude == "/.npmrc\n", "\(exclude)")
        #expect(try String(contentsOfFile: folder + "/.gitignore", encoding: .utf8) == LeadInit.gitignore)
    }

    /// Only a folder in no repository: a .git of any kind there (a folder, a file, a link), inside a repository, inside a
    /// git folder or a bare repository: refused at the plan, saying why.
    @Test func onlyAFolderInNoRepository() throws {
        let home = try home()
        let withFolder = try folder()
        try FileManager.default.createDirectory(atPath: withFolder + "/.git", withIntermediateDirectories: false)
        #expect(refusal(withFolder, home: home)?.contains("has a .git already") == true)
        let withFile = try folder()
        try "gitdir: /elsewhere\n".write(toFile: withFile + "/.git", atomically: true, encoding: .utf8)
        #expect(refusal(withFile, home: home)?.contains("has a .git already") == true)
        let withLink = try folder()
        let target = try folder([:])
        try FileManager.default.createSymbolicLink(atPath: withLink + "/.git", withDestinationPath: target)
        #expect(refusal(withLink, home: home)?.contains("has a .git already") == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: target)) ?? ["?"]).isEmpty, "nothing written through the link")

        let repository = try folder(["inner/x.txt": "x\n"])
        #expect(git(["init", "-q"], repository, home: home).ok)
        #expect(refusal(repository + "/inner", home: home)?.contains("is inside the repository") == true)
        try FileManager.default.createDirectory(atPath: repository + "/.git/sub", withIntermediateDirectories: false)
        #expect(refusal(repository + "/.git/sub", home: home)?.contains("git couldn't say it is in no repository") == true, "\(refusal(repository + "/.git/sub", home: home) ?? "")")
        let bare = try folder([:])
        #expect(git(["init", "-q", "--bare"], bare, home: home).ok)
        try FileManager.default.createDirectory(atPath: bare + "/refs/x", withIntermediateDirectories: true)
        #expect(refusal(bare + "/refs/x", home: home) != nil)
        // A bare repository's files in the folder itself, a config whose words could mimic git's: refused as one.
        let lookalike = try folder(["HEAD": "ref: refs/heads/main\n", "config": "[extensions \"not a git repository\"]\n", "objects/x": "", "refs/x": ""])
        #expect(refusal(lookalike, home: home)?.contains("as a bare repository does") == true, "\(refusal(lookalike, home: home) ?? "")")
    }

    /// A `.git` appearing during the prompt, a folder or a link to one elsewhere: refused with nothing written, its
    /// contents (or the link's target) untouched.
    @Test func aGitAppearingDuringThePromptIsRefusedAndUntouched() throws {
        let home = try home()
        let planted = try folder()
        let asked = try plan(planted, home: home)
        try FileManager.default.createDirectory(atPath: planted + "/.git", withIntermediateDirectories: false)
        guard case .failure(let refused) = made(asked, home: home) else { Issue.record("made over a planted .git"); return }
        #expect(refused.message.contains(".git"), "\(refused)")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: planted + "/.git")) ?? ["?"]).isEmpty, "the planted .git untouched")
        #expect(!FileManager.default.fileExists(atPath: planted + "/.gitignore"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: planted)) ?? []).sorted() == [".git", "a.txt"], "no partial install left")

        let linked = try folder()
        let shown = try plan(linked, home: home)
        let outside = try folder([:])
        try FileManager.default.createSymbolicLink(atPath: linked + "/.git", withDestinationPath: outside)
        guard case .failure = made(shown, home: home) else { Issue.record("made through a .git link"); return }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: outside)) ?? ["?"]).isEmpty, "nothing written through the link")
    }

    /// A filter a .gitattributes names (defined in the user's own global config here, so git would run it on a plain
    /// add) never runs: the bytes are hashed with no filter, in the private repository.
    @Test func aFilterNeverRuns() throws {
        let marker = scratch.url("filter-ran").path
        let home = try home(extra: "[filter \"evil\"]\n\tclean = sh -c 'echo ran >> \(marker); cat'\n\trequired = true\n")
        let folder = try folder(["a.txt": "raw\n", ".gitattributes": "* filter=evil\n"])
        let planned = try plan(folder, home: home)
        #expect(made(planned, home: home) == .success([".gitattributes", ".gitignore", "a.txt"]))
        #expect(!FileManager.default.fileExists(atPath: marker), "the filter ran")
        #expect(git(["cat-file", "blob", "HEAD:a.txt"], folder, home: home).output == "raw\n")
    }

    /// The commit holds exactly the planned files as read: one come during the prompt isn't added; one gone refuses with
    /// nothing left.
    @Test func aChangeDuringThePromptIsntCommittedOrRefuses() throws {
        let home = try home()
        let added = try folder(["a.txt": "a\n"])
        let planned = try plan(added, home: home)
        try "b\n".write(toFile: added + "/b.txt", atomically: true, encoding: .utf8)
        #expect(made(planned, home: home) == .success([".gitignore", "a.txt"]))
        #expect(tree(added, home: home) == [".gitignore", "a.txt"], "b.txt came after the code was asked: not committed")

        let gone = try folder(["a.txt": "a\n", "c.txt": "c\n"])
        let shown = try plan(gone, home: home)
        try FileManager.default.removeItem(atPath: gone + "/c.txt")
        guard case .failure(let refused) = made(shown, home: home) else { Issue.record("made with a shown file gone"); return }
        #expect(refused.message.contains("c.txt"), "\(refused)")
        nothingMade(gone)
    }

    /// Nothing from outside the folder is pulled in, and nothing but what the code was typed for: a planned file swapped
    /// for a link to a file outside refuses (it isn't what the plan read); a folder on a planned file's way swapped for a
    /// link refuses.
    @Test func aFileOrAParentSwappedForALinkPullsNothingFromOutside() throws {
        let home = try home()
        let outside = try folder(["secret.txt": "outside bytes\n", "sub/b.txt": "outside b\n"])
        let swappedFile = try folder(["a.txt": "a\n"])
        let planned = try plan(swappedFile, home: home)
        try FileManager.default.removeItem(atPath: swappedFile + "/a.txt")
        try FileManager.default.createSymbolicLink(atPath: swappedFile + "/a.txt", withDestinationPath: outside + "/secret.txt")
        guard case .failure(let swapped) = made(planned, home: home) else { Issue.record("made with a file swapped for a link"); return }
        #expect(swapped.message.contains("a.txt isn't what it was"), "\(swapped)")
        nothingMade(swappedFile)

        let swappedParent = try folder(["sub/b.txt": "inside b\n"])
        let shown = try plan(swappedParent, home: home)
        try FileManager.default.removeItem(atPath: swappedParent + "/sub")
        try FileManager.default.createSymbolicLink(atPath: swappedParent + "/sub", withDestinationPath: outside + "/sub")
        guard case .failure(let refused) = made(shown, home: home) else { Issue.record("made through a linked parent"); return }
        #expect(refused.message.contains("sub/b.txt"), "\(refused)")
        nothingMade(swappedParent)
    }

    /// A file with another hard link, one bigger than the cap, or all of them past the total: refused, naming the file.
    @Test func aHardLinkOrTooMuchIsRefused() throws {
        let home = try home()
        let outside = try folder(["elsewhere.txt": "shared\n"])
        let linked = try folder(["a.txt": "a\n"])
        #expect(link(outside + "/elsewhere.txt", linked + "/b.txt") == 0)
        #expect(refusal(linked, home: home)?.contains("b.txt has 2 hard links") == true, "\(refusal(linked, home: home) ?? "")")
        nothingMade(linked)

        let big = try folder(["a.txt": "a\n", "big.bin": String(repeating: "x", count: 4096)])
        guard case .failure(let tooBig) = made(try plan(big, home: home), home: home, maxFile: 1024) else { Issue.record("made past the file cap"); return }
        #expect(tooBig.message.contains("big.bin is 4096 bytes"), "\(tooBig)")
        nothingMade(big)

        let many = try folder(["a.txt": String(repeating: "a", count: 800), "b.txt": String(repeating: "b", count: 800)])
        guard case .failure(let tooMuch) = made(try plan(many, home: home), home: home, maxTotal: 1000) else { Issue.record("made past the total"); return }
        #expect(tooMuch.message.contains("at b.txt"), "\(tooMuch)")
        nothingMade(many)
    }

    /// The install is made under a temporary name and put in place last: one that fails before (a .gitignore come
    /// meanwhile) leaves no `.git`, no partial one, and the .gitignore that came as it was.
    @Test func aFailedInstallLeavesNoPartialGit() throws {
        let home = try home()
        let folder = try folder(["a.txt": "a\n"])
        let planned = try plan(folder, home: home)
        try "theirs\n".write(toFile: folder + "/.gitignore", atomically: true, encoding: .utf8)
        guard case .failure(let refused) = made(planned, home: home) else { Issue.record("made over a .gitignore come meanwhile"); return }
        #expect(refused.message.contains(".gitignore") && refused.message.contains("nothing was left"), "\(refused)")
        nothingMade(folder, gitignore: false)
        #expect(try String(contentsOfFile: folder + "/.gitignore", encoding: .utf8) == "theirs\n")
    }

    /// Bytes changed during the prompt, with the same size and name: not what the code was typed for, refused.
    @Test func changedBytesRefuse() throws {
        let home = try home()
        let folder = try folder(["a.txt": "good\n"])
        let planned = try plan(folder, home: home)
        try "evil\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        guard case .failure(let refused) = made(planned, home: home) else { Issue.record("made with changed bytes"); return }
        #expect(refused.message.contains("a.txt isn't what it was"), "\(refused)")
        nothingMade(folder)
    }

    /// A secret the folder's own .gitignore takes back in (`!.env`) couldn't be kept out of later commits: refused.
    @Test func aSecretTheFoldersGitignoreTakesBackInIsRefused() throws {
        let home = try home()
        let folder = try folder(["a.txt": "a\n", ".env": "K=1\n", ".gitignore": "*.log\n!.env\n"])
        #expect(refusal(folder, home: home)?.contains(".env looks like a secret, and the folder's own .gitignore takes it back in") == true,
                "\(refusal(folder, home: home) ?? "")")
    }

    /// Two names that differ only in their Unicode form (one would hide the other): refused, naming them.
    @Test func namesDifferingOnlyInUnicodeFormAreRefused() throws {
        let home = try home()
        let folder = try folder(["a.txt": "a\n"])
        // Not a dictionary: the two names are equal Strings. Made byte for byte.
        for (name, text) in [("caf\u{E9}.txt", "one\n"), ("cafe\u{301}.txt", "two\n")] {
            let fd = open(folder + "/" + name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            try #require(fd >= 0)
            _ = text.withCString { write(fd, $0, strlen($0)) }
            close(fd)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).count == 3, "two files on disk")
        #expect(refusal(folder, home: home)?.contains("differ only in their Unicode form") == true, "\(refusal(folder, home: home) ?? "")")
    }

    /// A name with a control character (a newline would add a line to the exclude file), or a repository of its own
    /// inside: refused at the plan.
    @Test func aControlCharacterOrANestedRepositoryIsRefused() throws {
        let home = try home()
        let odd = try folder(["a.txt": "a\n", "two\nlines.txt": "x\n"])
        #expect(refusal(odd, home: home)?.contains("control character") == true, "\(refusal(odd, home: home) ?? "")")
        let nested = try folder(["a.txt": "a\n", "inner/x.txt": "x\n"])
        #expect(git(["init", "-q"], nested + "/inner", home: home).ok)
        #expect(refusal(nested, home: home)?.contains("is a repository of its own") == true, "\(refusal(nested, home: home) ?? "")")
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
        #expect(words.contains("Left out, as they look like secrets:\n  .npmrc\n  Prod.ENV") && words.contains("Committed:\n  .gitignore\n  a.txt"), "\(words)")
        #expect(made(planned, home: home) == .success([".gitignore", "a.txt"]))
        let exclude = try String(contentsOfFile: folder + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude == "/.npmrc\n/Prod.ENV\n", "kept out of later commits: \(exclude)")
    }

    /// The prompt names every committed file, however many (up to the cap), never "and N more".
    @Test func thePromptNamesEveryFile() throws {
        let home = try home()
        var files: [String: String] = [".gitignore": "x\n"]
        for index in 0..<40 { files[String(format: "f%02d.txt", index)] = "\(index)\n" }
        let words = LeadInit.words(try plan(try folder(files), home: home))
        for index in 0..<40 { #expect(words.contains(String(format: "\n  f%02d.txt", index))) }
        #expect(!words.contains("more") && words.contains("as The User <user@example.invalid>"), "\(words)")
    }

    /// The author is the home's global identity; none there refuses, saying how.
    @Test func theAuthorIsTheUsersGlobalIdentity() throws {
        let home = try home()
        let folder = try folder()
        #expect(made(try plan(folder, home: home), home: home) == .success([".gitignore", "a.txt"]))
        let author = git(["log", "-1", "--format=%an <%ae> / %cn <%ce>"], folder, home: home).output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(author == "The User <user@example.invalid> / The User <user@example.invalid>", "\(author)")
        let nobody = try self.home(identity: false)
        #expect(refusal(try self.folder(), home: nobody)?.contains("git config --global user.name") == true)
    }

    /// The folder checked again after the code: a link in its place, another folder at its path; the home folder, `/`
    /// and a link to the home folder refused at the plan.
    @Test func theFolderIsCheckedAgainAndHomeIsRefused() throws {
        let home = try home()
        let folder = try folder()
        let planned = try plan(folder, home: home)
        let other = try self.folder(["z.txt": "z\n"])
        try FileManager.default.removeItem(atPath: folder)
        try FileManager.default.createSymbolicLink(atPath: folder, withDestinationPath: other)
        guard case .failure(let refused) = made(planned, home: home) else { Issue.record("made through a link"); return }
        #expect(refused.message.contains("isn't a folder"), "\(refused)")
        #expect(!FileManager.default.fileExists(atPath: other + "/.git"))
        let swapped = try self.folder()
        let swappedPlan = try plan(swapped, home: home)
        try FileManager.default.moveItem(atPath: swapped, toPath: scratch.url("moved").path)
        try FileManager.default.createDirectory(atPath: swapped, withIntermediateDirectories: false)
        guard case .failure(let replaced) = made(swappedPlan, home: home) else { Issue.record("made in a replaced folder"); return }
        #expect(replaced.message.contains("isn't the folder it was"), "\(replaced)")
        let linkToHome = scratch.url("to-home").path
        try FileManager.default.createSymbolicLink(atPath: linkToHome, withDestinationPath: home)
        #expect(refusal(home, home: home)?.contains("a folder of its own") == true)
        #expect(refusal("/", home: home)?.contains("a folder of its own") == true)
        #expect(refusal(linkToHome, home: home) != nil, "a link to the home folder")
    }

    /// A link is committed as git commits one, an executable as one.
    @Test func aLinkAndAnExecutableAreCommittedAsGitWould() throws {
        let home = try home()
        let folder = try folder(["a.txt": "a\n"])
        try FileManager.default.createSymbolicLink(atPath: folder + "/l", withDestinationPath: "a.txt")
        try writeClosedOnExec("#!/bin/sh\nexit 0\n", to: URL(fileURLWithPath: folder + "/run.sh"))
        #expect(made(try plan(folder, home: home), home: home) == .success([".gitignore", "a.txt", "l", "run.sh"]))
        #expect(git(["ls-tree", "HEAD", "l"], folder, home: home).output.hasPrefix("120000 "))
        #expect(git(["cat-file", "blob", "HEAD:l"], folder, home: home).output == "a.txt")
        #expect(git(["ls-tree", "HEAD", "run.sh"], folder, home: home).output.hasPrefix("100755 "))
    }

    /// What an interrupted run left in the scratch folder, an hour old, goes at the next plan; a fresh one stays.
    @Test func whatAnInterruptedRunLeftIsTidied() throws {
        let scratchFolder = probes
        let old = scratchFolder.appendingPathComponent("lead-init-old"), fresh = scratchFolder.appendingPathComponent("lead-init-fresh")
        for url in [old, fresh] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        LeadInit.tidy(scratchFolder)
        #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: fresh.path))
    }

    /// git gets a fixed environment, none of this process's: no `GIT_*` but the ones `LeadInit` sets.
    @Test func gitGetsNothingOfThisProcesssEnvironment() {
        let environment = LeadInit.environment(home: "/home/u")
        let ours: Set<String> = ["GIT_CONFIG_NOSYSTEM", "GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS", "GIT_LITERAL_PATHSPECS", "GIT_ATTR_NOSYSTEM",
                                 "GIT_PAGER", "GIT_EDITOR", "GIT_ASKPASS"]
        #expect(Set(environment.keys.filter { $0.hasPrefix("GIT_") }) == ours)
        #expect(Set(environment.keys) == ours.union(["PATH", "HOME", "XDG_CONFIG_HOME", "LC_ALL", "LANG"]))
    }
}
