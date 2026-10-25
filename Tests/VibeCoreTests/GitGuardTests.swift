import Foundation
import Testing
@testable import VibeCore

/// 2026-10-25: a worker (or its branch's code in a merge's test run) runs as the user in a worktree that shares
/// `<root>/.git`, so it can write `<common-dir>/hooks` (post-merge, reference-transaction, post-checkout…) and set
/// executable keys in `.git/config` (a filter's smudge, core.fsmonitor, a merge driver). The lead's tool server then ran
/// them as the lead, unattended since auto_advance, in its next fast-forward, cleanup or start_worker. Its git runs only
/// the hooks the lead accepted, from a copy, and none of the repository's own executable config.
struct GitGuardTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo(_ name: String = "guard") throws -> String {
        let url = temp.url(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "1\n2\n3\n4\n5\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// An empty folder the planted programs mark: each touches a file named after itself there when it runs.
    func marks() throws -> String {
        let url = temp.url("marks")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    func marked(_ marks: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: marks)) ?? []).sorted() }

    /// What touches `<marks>/<mark>` and then runs `then`, as a shell command line.
    func touching(_ marks: String, _ mark: String, then: String = "true") -> String { "touch '\(marks)/\(mark)'; \(then)" }

    /// An executable hook `name` in `folder` that marks `mark` (its own name by default).
    func hook(_ name: String, in folder: String, marks: String, as mark: String? = nil) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + name
        try "#!/bin/sh\n\(touching(marks, mark ?? name))\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func commit(_ files: [String: String], in dir: String, _ message: String = "change") throws {
        for (file, text) in files {
            try text.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
            Git.run(["add", file], in: dir)
        }
        #expect(Git.run(["commit", "-q", "-m", message], in: dir).ok)
    }

    /// Every hook the lead's git steps would trigger, planted in `folder`.
    static let hooks = ["post-merge", "reference-transaction", "post-checkout", "pre-commit", "prepare-commit-msg", "commit-msg",
                        "post-commit", "pre-rebase", "post-rewrite", "pre-auto-gc", "pre-merge-commit"]

    /// What a worker plants in the shared git folder: every hook, a filter whose smudge and clean mark (required, so
    /// git can't skip it), the fsmonitor, a merge driver, diff's textconv and external command.
    func plant(root: String, marks: String) throws {
        for name in Self.hooks { try hook(name, in: root + "/.git/hooks", marks: marks) }
        for (key, value) in [("filter.evil.smudge", touching(marks, "smudge", then: "cat")), ("filter.evil.clean", touching(marks, "clean", then: "cat")),
                             ("filter.evil.required", "true"), ("diff.evil.textconv", touching(marks, "textconv", then: "cat")),
                             ("diff.evil.command", touching(marks, "ext-diff")), ("merge.evil.driver", touching(marks, "merge-driver")),
                             ("core.pager", touching(marks, "pager", then: "cat"))] {
            #expect(Git.run(["config", key, value], in: root).ok)
        }
        let fsmonitor = temp.url("fsmonitor").path
        try "#!/bin/sh\n\(touching(marks, "fsmonitor"))\n".write(toFile: fsmonitor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fsmonitor)
        #expect(Git.run(["config", "core.fsmonitor", fsmonitor], in: root).ok)
    }

    static let attributes = "*.txt filter=evil diff=evil merge=evil\n"

    // MARK: The lead's git steps

    /// start_worker's worktree add, merge's scratch worktree, rebase and fast-forward, cleanup's worktree remove and
    /// branch delete, and the reads between them (status, diff, merge-tree) run nothing a worker planted, and still do
    /// their work.
    @Test func whatAWorkerPlantsInTheSharedGitFolderDoesntRunInTheLeadsSteps() throws {
        let root = try repo()
        let marks = try marks()
        let worktree = try Worktrees.create(root: root, slug: "w")
        // Its branch: the attributes that name the planted drivers, a new file, and a change merge-tree has to merge.
        try commit([".gitattributes": Self.attributes, "b.txt": "bee\n", "a.txt": "1\n2\n3\n4\nfive\n"], in: worktree)
        try plant(root: root, marks: marks)
        let head = Git.run(["rev-parse", "agent/w"], in: root).output

        // merge: the branch rebased and tested in a worktree of its own, then main fast-forwarded in the main checkout.
        let check = Worktrees.rebaseAndTest(root: root, commit: head, onto: "main", test: "test -f b.txt", scratch: temp.url("merge"), lock: nil)
        #expect(check == .passed(head), "\(check)")
        #expect(marked(marks).isEmpty, "the merge's scratch worktree and rebase ran \(marked(marks))")
        #expect(try Worktrees.merge(root: root, slug: "w", commit: head) == .merged)
        #expect(marked(marks).isEmpty, "the fast-forward ran \(marked(marks))")
        #expect(try String(contentsOfFile: root + "/b.txt", encoding: .utf8) == "bee\n")

        // The lead's reads: the checkout's status, a branch's diff, the merges an audit and the board try.
        try "1\n2\n3\n4\nfive\nsix\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        let status = Git.run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: root)
        #expect(status.ok && status.output.contains("a.txt"))
        let diff = Git.run(["diff"], in: root)
        // Never an empty comment: Swift Testing's console output crashes on one (an external diff that says nothing).
        #expect(diff.ok && diff.output.contains("+six"), "git diff said: \(diff.output) \(diff.error)")
        #expect(Git.run(["diff", "--stat", "HEAD~1", "HEAD"], in: root).output.contains("b.txt"))
        Git.run(["checkout", "-q", "--", "a.txt"], in: root)
        try commit(["a.txt": "one\n2\n3\n4\nfive\n"], in: root, "main's change")
        try commit(["a.txt": "1\n2\n3\nfour\nfive\n"], in: worktree, "the branch's")
        let merged = Git.run(["merge-tree", "--write-tree", "--name-only", "main", "agent/w"], in: root)
        #expect(merged.ok, "\(merged.output) \(merged.error)")
        let tree = merged.output.split(separator: "\n").first.map(String.init) ?? ""
        #expect(Git.run(["cat-file", "-p", "\(tree):a.txt"], in: root).output == "one\n2\n3\nfour\nfive")
        #expect(marked(marks).isEmpty, "the lead's reads ran \(marked(marks))")

        // start_worker for another task, and cleanup.
        let other = try Worktrees.create(root: root, slug: "x")
        #expect(try String(contentsOfFile: other + "/b.txt", encoding: .utf8) == "bee\n")
        try Worktrees.remove(root: root, slug: "w", force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(!Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/agent/w"], in: root).ok)
        #expect(marked(marks).isEmpty, "start_worker and cleanup ran \(marked(marks))")
    }

    /// A hooks folder of the worker's own, set as core.hooksPath in the repository's config, doesn't run either.
    @Test func aHooksPathTheRepositorysConfigSetsDoesntRun() throws {
        let root = try repo()
        let marks = try marks()
        let worktree = try Worktrees.create(root: root, slug: "w")
        try commit(["b.txt": "bee\n"], in: worktree)
        let planted = temp.url("planted-hooks").path
        for name in Self.hooks { try hook(name, in: planted, marks: marks) }
        #expect(Git.run(["config", "core.hooksPath", planted], in: root).ok)
        #expect(try Worktrees.merge(root: root, slug: "w") == .merged)
        try Worktrees.remove(root: root, slug: "w", force: true)
        try Worktrees.create(root: root, slug: "x")
        #expect(marked(marks).isEmpty, "\(marked(marks))")
    }

    /// A submodule's own config (in `.git/modules/`, or an embedded repository's `.git`) is the worker's to write too:
    /// the lead's `git status` in a checkout with one starts no git inside it, so nothing there runs.
    @Test func aSubmodulesOwnConfigDoesntRunInTheLeadsStatus() throws {
        let root = try repo()
        let marks = try marks()
        let sub = root + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: sub) }
        try commit([".gitattributes": "*.txt filter=subevil\n", "s.txt": "sea\n"], in: sub)
        Git.run(["add", "sub"], in: root)
        #expect(Git.run(["commit", "-q", "-m", "sub"], in: root).ok)
        for (key, value) in [("filter.subevil.clean", touching(marks, "sub-clean", then: "cat")), ("filter.subevil.required", "true")] {
            #expect(Git.run(["config", key, value], in: sub).ok)
        }
        // As long as it was: git reads it through the filter to see whether it changed (another size says so by itself).
        try "see\n".write(toFile: sub + "/s.txt", atomically: true, encoding: .utf8)
        let status = Git.run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: root)
        #expect(status.ok, "git status said: \(status.error)")
        #expect(marked(marks).isEmpty, "\(marked(marks))")
    }

    /// A filter set in a worker's own worktree config (config.worktree) doesn't run in cleanup's `worktree remove`,
    /// whose own `git status` runs in that worktree and reads it; the lead is told of it.
    @Test func aFilterInAWorktreesOwnConfigDoesntRunInCleanup() throws {
        let root = try repo()
        let marks = try marks()
        let worktree = try Worktrees.create(root: root, slug: "w")
        for (key, value) in [("core.repositoryFormatVersion", "1"), ("extensions.worktreeConfig", "true")] {
            #expect(Git.run(["config", key, value], in: root).ok)
        }
        for (key, value) in [("filter.wt.clean", touching(marks, "worktree-clean", then: "cat")), ("filter.wt.required", "true")] {
            #expect(Git.run(["config", "--worktree", key, value], in: worktree).ok)
        }
        try "*.txt filter=wt\n".write(toFile: root + "/.git/info/attributes", atomically: true, encoding: .utf8)
        // Same text, a later time: git reads it through the filter to see whether it changed.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: worktree + "/a.txt")
        let lead = try lead(root, FakeRuntime())
        let status = lead.call("status", [:]).text
        #expect(status.contains("Git config: this repository's own config sets filter.wt.clean, filter.wt.required."), "\(status)")
        try Worktrees.remove(root: root, slug: "w")
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(marked(marks).isEmpty, "\(marked(marks))")
    }

    /// A repository whose own config includes another file runs none of the lead's git, and the lead is told which file
    /// and key: here one included as `~<user>/…`, which git expands and a walk of includes didn't (the filter it sets
    /// ran in start_worker's checkout), and one in a worktree's config.worktree, only on the task's branch.
    @Test func aRepositoryWhoseConfigIncludesAFileRunsNoneOfTheLeadsGit() throws {
        let root = try repo()
        let marks = try marks()
        let included = root + "/.git/included.cfg"
        try "[filter \"inc\"]\n\tsmudge = \"\(touching(marks, "included-smudge", then: "cat"))\"\n\trequired = true\n"
            .write(toFile: included, atomically: true, encoding: .utf8)
        try "*.txt filter=inc\n".write(toFile: root + "/.git/info/attributes", atomically: true, encoding: .utf8)
        let lead = try lead(root, FakeRuntime())
        // git expands `~<user>/` from the password database, whatever HOME is.
        let home = getpwnam(NSUserName()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let up = String(repeating: "../", count: home.split(separator: "/").count)
        #expect(Shell.run(executable: "/usr/bin/git", args: ["config", "include.path", "~\(NSUserName())/\(up)\(included.dropFirst())"], in: root).ok)

        let status = lead.call("status", [:]).text
        #expect(status.contains("doesn't run in this repository") && status.contains("/.git/config sets include.path = ~\(NSUserName())/"), "\(status)")
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]]).isError)
        let started = lead.call("start_worker", ["task": "add-b"])
        #expect(started.isError && started.text.contains("include.path"), "\(started.text)")
        #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "add-b") + "/a.txt"))
        let refused = Git.run(["status"], in: root)
        #expect(!refused.ok && refused.error.contains("include.path"), "\(refused.error)")
        #expect(marked(marks).isEmpty, "\(marked(marks))")

        // Gone from the common config, set in a worktree's own config instead (a worker's, say): still refused.
        #expect(Shell.run(executable: "/usr/bin/git", args: ["config", "--unset", "include.path"], in: root).ok)
        #expect(Git.run(["status"], in: root).ok)
        let worktree = try Worktrees.create(root: root, slug: "w")
        for (key, value) in [("core.repositoryFormatVersion", "1"), ("extensions.worktreeConfig", "true")] {
            #expect(Git.run(["config", key, value], in: root).ok)
        }
        #expect(Shell.run(executable: "/usr/bin/git", args: ["config", "--worktree", "includeIf.onbranch:agent/**.path", included], in: worktree).ok)
        let told = lead.call("status", [:]).text
        #expect(told.contains("/worktrees/w/config.worktree sets includeif.onbranch:agent/**.path = \(included)"), "\(told)")
        #expect(!Git.run(["status"], in: root).ok)
        #expect(throws: (any Error).self) { try Worktrees.create(root: root, slug: "x") }
        #expect(marked(marks).isEmpty, "\(marked(marks))")
    }

    /// A baseline taken from a hooks folder inside the working tree (stakegen's core.hooksPath .githooks) says so.
    @Test func aBaselineFromAHooksFolderInTheWorkingTreeSaysSo() throws {
        let url = temp.url("in-tree")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        let marks = try marks()
        for args in [["init", "-q", "-b", "main"], ["config", "core.hooksPath", ".githooks"]] {
            #expect(Shell.run(executable: "/usr/bin/git", args: args, in: root).ok)
        }
        try hook("pre-commit", in: root + "/.githooks", marks: marks)
        for args in [["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try commit(["a.txt": "one\n"], in: root)
        #expect(marked(marks) == ["pre-commit"])
        let status = try lead(root, FakeRuntime()).call("status", [:]).text
        #expect(status.contains("as the baseline") && status.contains(": pre-commit (") && status.contains("That folder is inside the working tree"), "\(status)")
    }

    /// A worker can't make the guard check one repository's config while git runs another's: its worktree's `.git`
    /// swapped for an empty folder (git walks past it, to the main checkout, whose filter the guard then never saw), or
    /// for a bare repository's files at its top (git takes that folder as its repository, and its config).
    @Test func aWorktreeGitWouldWalkPastOrTakeAsBareRunsNoGit() throws {
        let root = try repo()
        let marks = try marks()
        let worktree = try Worktrees.create(root: root, slug: "w")
        #expect(Shell.run(executable: "/usr/bin/git", args: ["checkout", "-q", "--detach"], in: root).ok)
        #expect(Shell.run(executable: "/usr/bin/git", args: ["switch", "-q", "main"], in: worktree).ok)
        try "*.txt filter=x\n".write(toFile: root + "/.git/info/attributes", atomically: true, encoding: .utf8)
        for (key, value) in [("filter.x.clean", touching(marks, "walked-clean", then: "cat")), ("filter.x.required", "true")] {
            #expect(Shell.run(executable: "/usr/bin/git", args: ["config", key, value], in: root).ok)
        }
        // Same text, a later time: git reads it through the filter to see whether it changed.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: root + "/a.txt")
        try FileManager.default.removeItem(atPath: worktree + "/.git")
        try FileManager.default.createDirectory(atPath: worktree + "/.git", withIntermediateDirectories: false)
        let walked = Git.run(["status", "--porcelain"], in: worktree)
        #expect(!walked.ok && walked.error.contains("can vouch"), "\(walked)")
        #expect(GitGuard.notice(root: worktree)?.contains("can vouch") == true)
        #expect(marked(marks).isEmpty, "\(marked(marks))")

        try FileManager.default.removeItem(atPath: worktree + "/.git")
        for folder in ["objects", "refs"] { try FileManager.default.createDirectory(atPath: worktree + "/" + folder, withIntermediateDirectories: false) }
        try "ref: refs/heads/main\n".write(toFile: worktree + "/HEAD", atomically: true, encoding: .utf8)
        // Git takes the worktree's folder itself as its repository, with whatever config it holds, not the main
        // checkout's the guard found further up.
        let bare = Git.run(["rev-parse", "--absolute-git-dir"], in: worktree)
        #expect(!bare.ok && bare.error.contains("can vouch"), "\(bare)")
        #expect(marked(marks).isEmpty, "\(marked(marks))")
        // The main checkout itself still works.
        #expect(Git.run(["rev-parse", "HEAD"], in: root).ok)
    }

    /// The lead asking before any of its git ran in a repository hears of the hooks it has as the baseline, not as new.
    @Test func aNoticeBeforeAnyGitRanTakesTheBaseline() throws {
        let url = temp.url("asked-first")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        let marks = try marks()
        #expect(Shell.run(executable: "/usr/bin/git", args: ["init", "-q", "-b", "main"], in: root).ok)
        try hook("commit-msg", in: root + "/.git/hooks", marks: marks)
        let told = GitGuard.notice(root: root) ?? ""
        #expect(told.contains("as the baseline") && told.contains(": commit-msg ("), "\(told)")
        #expect(!told.contains("(new)"), "\(told)")
        #expect(GitGuard.notice(root: root) == nil)
    }

    /// An accepted hook that reads a script in a subfolder of the hooks folder (husky's `_/husky.sh`) finds its copy,
    /// and one that looks for a hook in the folder above its own (husky's `h`) doesn't land on a shim and run again.
    @Test func anAcceptedHookFindsItsSubfolderAndNotAShimAboveIt() throws {
        let url = temp.url("husky")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        let marks = try marks()
        #expect(Shell.run(executable: "/usr/bin/git", args: ["init", "-q", "-b", "main"], in: root).ok)
        let hooks = root + "/.git/hooks"
        try hook("lib.sh", in: hooks + "/_", marks: marks, as: "subfolder-lib")
        let runs = marks + "/runs"
        let script = "#!/bin/sh\necho run >> '\(runs)'\nup=\"$(dirname \"$(dirname \"$0\")\")/commit-msg\"\n"
            + "if [ -f \"$up\" ] && [ \"$(wc -l < '\(runs)')\" -lt 5 ]; then sh -e \"$up\" \"$@\"; fi\n. \"$(dirname \"$0\")/_/lib.sh\"\n"
        try script.write(toFile: hooks + "/commit-msg", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks + "/commit-msg")
        for args in [["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try commit(["a.txt": "one\n"], in: root)
        #expect(marked(marks) == ["runs", "subfolder-lib"])
        #expect(try String(contentsOfFile: runs, encoding: .utf8) == "run\n")
    }

    /// The user's own filter, in their global config, still applies where the repository's config sets one of the
    /// same name: the user's value is the one git takes.
    @Test func theUsersGlobalFilterStillAppliesOverTheRepositorys() throws {
        let root = try repo()
        let marks = try marks()
        let global = temp.url("gitconfig").path
        // Quoted: in a config file, a ";" outside quotes starts a comment.
        try "[filter \"keep\"]\n\tsmudge = \"\(touching(marks, "global-smudge", then: "cat"))\"\n".write(toFile: global, atomically: true, encoding: .utf8)
        try commit([".gitattributes": "c.txt filter=keep\n", "c.txt": "sea\n"], in: root)
        #expect(Git.run(["config", "filter.keep.smudge", touching(marks, "planted-smudge", then: "cat")], in: root).ok)
        try FileManager.default.removeItem(atPath: root + "/c.txt")
        #expect(Git.run(["checkout", "--", "c.txt"], in: root, env: ["GIT_CONFIG_GLOBAL": global]).ok)
        #expect(marked(marks) == ["global-smudge"])
        #expect(try String(contentsOfFile: root + "/c.txt", encoding: .utf8) == "sea\n")
    }

    // MARK: The lead's tools

    /// The user's own hook runs once the lead accepts it, from the copy accepted; what a worker plants or changes
    /// after is told to the lead (status, merge) and doesn't run, through a merge, a cleanup and the next start_worker.
    @Test func theLeadIsToldWhatItsGitDoesntRunAndAcceptedHooksRun() throws {
        let root = try repo("lead")
        let marks = try marks()
        let hooks = root + "/.git/hooks"
        try hook("post-merge", in: hooks, marks: marks, as: "user-post-merge")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "test -f b.txt"]).isError)

        // The user's hook, before it's accepted: told, and not run.
        let told = lead.call("status", [:]).text
        // git spells the folder from /private/tmp, Foundation the scratch path from /tmp.
        #expect(told.contains("/.git/hooks isn't as you accepted it: post-merge (new)."), "\(told)")
        #expect(lead.call("accept_git_hooks", ["hooks": ["nope"]]).isError)
        let accepted = lead.call("accept_git_hooks", [:])
        #expect(!accepted.isError && accepted.text.contains("post-merge ("), "\(accepted.text)")
        #expect(!lead.call("status", [:]).text.contains("Git hooks:"))

        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]]).isError)
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit([".gitattributes": Self.attributes, "b.txt": "bee\n"], in: worktree)
        // The worker plants: a new hook, the user's one changed, a filter.
        try hook("reference-transaction", in: hooks, marks: marks)
        try hook("post-checkout", in: hooks, marks: marks)
        try hook("post-merge", in: hooks, marks: marks, as: "planted-post-merge")
        #expect(Git.run(["config", "filter.evil.smudge", touching(marks, "smudge", then: "cat")], in: worktree).ok)
        let report = try seat("worker-add-b", runtime).call("report", doneReport("added"))
        #expect(!report.isError, "\(report.text)")

        let status = lead.call("status", [:]).text
        #expect(status.contains("post-checkout (new), post-merge (changed), reference-transaction (new)"), "\(status)")
        #expect(status.contains("Git config: this repository's own config sets filter.evil.smudge."), "\(status)")
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("post-merge (changed)"), "\(merged.text)")
        #expect(Git.run(["show", "main:b.txt"], in: root).output == "bee")
        #expect(BoardStore(root: root).load().task("add-b")?.status == .done)
        // The accepted copy of the user's post-merge ran on the fast-forward; nothing planted did.
        #expect(marked(marks) == ["user-post-merge"])

        let cleaned = lead.call("cleanup", ["task": "add-b"])
        #expect(!cleaned.isError && cleaned.text.contains("Git hooks:"), "\(cleaned.text)")
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(!lead.call("add_task", ["title": "Add c", "goal": "c.txt exists", "acceptance": ["test -f c.txt"]]).isError)
        let started = lead.call("start_worker", ["task": "add-c"])
        #expect(!started.isError && started.text.contains("Git hooks:"), "\(started.text)")
        #expect(marked(marks) == ["user-post-merge"])
    }

    /// auto_advance's merge and cleanup, with nobody watching, run nothing planted either, and the lead hears of it
    /// in the report of what moved by itself.
    @Test func autoAdvanceRunsNothingPlantedAndTellsTheLead() throws {
        let root = try repo("advance")
        let marks = try marks()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "test -f b.txt"]).isError)
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]]).isError)
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit([".gitattributes": Self.attributes, "b.txt": "bee\n"], in: worktree)
        try plant(root: root, marks: marks)
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        let report = try seat("worker-add-b", runtime).call("report", doneReport("added"))
        #expect(!report.isError, "\(report.text)")
        // Merged, then cleaned up: its worktree is gone.
        #expect(advancing.until { BoardStore(root: root).load().task("add-b")?.status == .done && !FileManager.default.fileExists(atPath: worktree) })
        #expect(Git.run(["show", "main:b.txt"], in: root).output == "bee")
        runtime.calls.lock()
        let reports = runtime.steered.filter { $0.text.hasPrefix("VibeSwitcher moved finished work on by itself") }.map(\.text)
        runtime.calls.unlock()
        #expect(reports.contains { $0.contains("Git hooks:") && $0.contains("reference-transaction (new)") && $0.contains("filter.evil.smudge") }, "\(reports)")
        #expect(marked(marks).isEmpty, "\(marked(marks))")
    }

    /// Trust on first use: the hooks a repository has when the guard first sees it (genswap's commit-msg, which strips
    /// the trailers genswap forbids) are its baseline, and keep running in the lead's git with no accept_git_hooks; the
    /// lead is told once which. A later change runs only once the lead accepts it.
    @Test func theHooksARepositoryHasWhenFirstSeenAreItsBaseline() throws {
        let url = temp.url("first-seen")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        let marks = try marks()
        // Made, and its hook installed, without the guard: as the user's repositories were before it.
        #expect(Shell.run(executable: "/usr/bin/git", args: ["init", "-q", "-b", "main"], in: root).ok)
        let strip = "#!/bin/sh\n\(touching(marks, "user-commit-msg"))\ngrep -v '^Co-Authored-By:' \"$1\" > \"$1.tmp\"; mv \"$1.tmp\" \"$1\"\n"
        let hook = root + "/.git/hooks/commit-msg"
        try strip.write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)

        for args in [["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        #expect(Git.run(["commit", "-q", "-m", "first\n\nCo-Authored-By: Someone <s@s>"], in: root).ok)
        #expect(marked(marks) == ["user-commit-msg"])
        #expect(Git.run(["log", "-1", "--format=%B"], in: root).output == "first")

        // The lead hears of the baseline once.
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let first = lead.call("status", [:]).text
        #expect(first.contains("Git hooks: accepted the existing hooks in ") && first.contains("as the baseline") && first.contains(": commit-msg ("), "\(first)")
        #expect(!first.contains("isn't as you accepted it"), "\(first)")
        #expect(!lead.call("status", [:]).text.contains("Git hooks:"))

        // A worker changes it: told, and the baseline's copy is what runs.
        try "#!/bin/sh\n\(touching(marks, "planted-commit-msg"))\n".write(toFile: hook, atomically: true, encoding: .utf8)
        #expect(lead.call("status", [:]).text.contains("isn't as you accepted it: commit-msg (changed)"))
        try commit(["a.txt": "two\n"], in: root, "second\n\nCo-Authored-By: Someone <s@s>")
        #expect(Git.run(["log", "-1", "--format=%B"], in: root).output == "second")
        #expect(marked(marks) == ["user-commit-msg"])
    }
}
