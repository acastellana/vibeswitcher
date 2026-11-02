import Foundation
import Testing
@testable import VibeCore

/// The everyday git reads other projects' workers and verifiers named after the git-read lockdown (85f3e417, 2026-11-01):
/// `git merge-tree`, `git log <range> --stat`, `git show <sha> --cc -- <file>`, `git grep -n <pattern> <rev> -- <path>`,
/// `git diff <range> --stat -- <path>`, the reads a replay of that day's transcripts found still prompting, and a worker's
/// `git diff <a> <b> -- <files> | git apply -R` proof. Each runs unasked for every role that may run it, judged by the
/// role's settings as `prepare` writes them (deny rules, allow rules, then its hook); the refusals still hold for them.
struct ReadOnlyGitFormsTests {
    let temp = Scratch()

    /// A repository with `main`, a branch `other` off it, and links committed inside that point outside it.
    func repository() throws -> (repo: String, privateDir: String, base: String) {
        let scratch = temp.url("forms").resolvingSymlinksInPath().path
        let privateDir = scratch + "/private", repo = scratch + "/repo"
        try FileManager.default.createDirectory(atPath: privateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Data("SECRET-SEAL-VALUE(\n".utf8).write(to: URL(fileURLWithPath: privateDir + "/seal"))
        let setup = "git init -q -b main && mkdir sub && echo a > a && echo b > sub/b && echo build > .gitignore"
            + " && ln -s ../private/seal inner && ln -s \(privateDir) linkdir && git add -A && git commit -qm one"
            + " && git checkout -qb other && echo c >> sub/b && git commit -qam two && git checkout -q main"
            + " && echo d >> a && git commit -qam three"
        let out = try LeadLaunchOutsideReadsTests.shell(setup, in: repo)
        #expect(!out.contains("fatal"), "\(out)")
        let base = try LeadLaunchOutsideReadsTests.shell("git rev-parse HEAD~1", in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        return (repo, privateDir, base)
    }

    func roles(_ repo: String) throws -> [LeadLaunchOutsideReadsTests.Role] {
        try [LeadLaunch.Role.lead, .worker, .verifier].map { try LeadLaunchOutsideReadsTests.Role($0, root: repo, temp: temp) }
    }

    /// The table: each listed form, and each read the replay found, runs unasked for every role, and is a form git takes
    /// (run here, it prints no usage or error); a worker's patch on its input runs unasked for it alone; each refusal
    /// (a path outside, a global option, `--stdin`, an abbreviation, a symlink out) holds for every role.
    @Test func everydayGitFormsRunUnaskedPerRoleAndTheRefusalsHold() throws {
        let (repo, privateDir, base) = try repository()
        let reads = [
            // merge-tree's trial merges.
            "git merge-tree --write-tree main other", "git merge-tree main other", "git merge-tree --write-tree --name-only --no-messages main other",
            "git merge-tree --write-tree -z --messages main other", "git merge-tree \(base) main other",
            "git merge-tree --trivial-merge \(base) main other",
            // log with a range and its summaries.
            "git log main..other --stat", "git log main..other --name-only", "git log main..other --name-status", "git log main..other --oneline",
            "git log other..main --stat -- a", "git log --oneline main..other --stat",
            // show with combined diffs, grep in a revision, diff summaries of a path.
            "git show \(base) --cc -- a", "git show HEAD --cc", "git grep -n b other -- sub", "git grep -n 'b' \(base) -- sub",
            "git grep -n -e a -e b main -- sub a", "git grep -l a HEAD", "git grep -c -i A", "git grep -n -E 'a|b' -- sub",
            "git grep -nw -C2 a HEAD -- a", "git grep --name-only b other", "git grep -q a", "git grep -n a HEAD:sub",
            "git diff main...other --stat -- sub", "git diff main...other --stat", "git diff main..other --name-only -- sub",
            // What the replay of 2026-11-01's transcripts still found prompting, all reads.
            "git ls-tree -r --name-only HEAD", "git ls-tree HEAD sub/", "git ls-tree -r HEAD -- sub",
            "git check-ignore -q build", "git check-ignore -v build", "git rev-list --count main..other",
            "git rev-list --reverse --no-merges main..other", "git diff-tree --cc -p HEAD", "git log --oneline other --not main",
        ]
        let roles = try roles(repo)
        for command in reads {
            let out = try LeadLaunchOutsideReadsTests.shell(command, in: repo)
            #expect(!out.contains("usage:") && !out.contains("fatal:") && !out.contains("error:"), "not a git form: \(command): \(out)")
            for role in roles { #expect(role.runsUnasked(command, cwd: repo), "\(role.role): \(command)") }
        }
        // `git stash list` (the stash is the repository's, shared by every worktree): the parser takes it for every
        // role, but the lead's and the verifier's deny rules (`LeadLaunch.gitWrites`, `git stash:*`) refuse it first.
        #expect(ReadOnlyCommand.allows("git stash list", in: .init(root: repo, cwd: repo)))
        for role in roles { #expect(role.runsUnasked("git stash list", cwd: repo) == (role.role == .worker), "\(role.role)") }
        // A worker's regression proof: the fix out and back in, the patch from git on its input (and its dry runs).
        let writes = ["git diff \(base) HEAD -- a | git apply -R", "git diff \(base) HEAD -- a | git apply",
                      "git diff \(base) HEAD -- a sub/b | git apply -R --check", "git diff \(base) HEAD -- a | git apply --check",
                      "git diff \(base) HEAD -- \(repo)/a | git apply -R"]
        for role in roles {
            for command in writes {
                #expect(role.runsUnasked(command, cwd: repo) == (role.role == .worker), "\(role.role): \(command)")
            }
        }
        let refused = [
            // A path outside the worktree.
            "git grep -n x HEAD -- ../private", "git grep x -- /etc", "git grep x HEAD:../x", "git grep -f ../private/seal HEAD",
            "git grep -f/etc/x HEAD", "git grep x ~/x", "git log main..other --stat -- ../private/seal", "git show HEAD --cc -- /etc/hosts",
            "git diff main...other --stat -- ~/x", "git diff main...other --stat -- ../private", "git merge-tree main ../x",
            "git ls-tree HEAD ../x", "git check-ignore ../private/seal", "git check-ignore \(privateDir)/seal",
            "git rev-list main -- /etc/hosts", "git diff-tree -p HEAD -- ../x",
            // A global option before the command.
            "git -C ../private grep x", "git -c core.pager=x grep x", "git --no-pager merge-tree main other", "git -P log main..other --stat",
            "git --git-dir=../x merge-tree main other", "git --literal-pathspecs grep x", "git -C .. ls-tree HEAD",
            // Input read from stdin.
            "git merge-tree --stdin", "git merge-tree --write-tree --stdin", "git log --stdin --stat", "git show --stdin --cc",
            "git diff-tree --stdin", "git rev-list --stdin", "git check-ignore --stdin", "git grep -f - HEAD",
            // Abbreviations of listed flags (git would take them, and of unlisted ones).
            "git merge-tree --write main other", "git merge-tree --trivial \(base) main other", "git merge-tree --name main other",
            "git grep --open x", "git grep --no-ind x", "git grep --line x", "git log main..other --sta", "git ls-tree --name-o HEAD",
            "git check-ignore --verb build", "git rev-list --cou main", "git stash li",
            // A symlink committed inside that points outside.
            "git grep x HEAD -- inner", "git grep -n x -- linkdir/seal", "git grep -f inner HEAD", "git check-ignore inner",
            "git ls-tree HEAD linkdir/seal", "git log --stat -- inner", "git diff main...other --stat -- linkdir",
            "git show HEAD --cc -- inner",
            // A short flag's value attached (the blind check's): `-finner` reads the link's target as -f's file, and git
            // prints a line of it in a regex error. Every program's short flags, ahead of their values too.
            "git grep -E -finner", "git grep -P -finner HEAD", "git grep -nfinner HEAD", "git diff-tree -Oinner -p HEAD",
            "git log -Oinner -p", "git diff -Oinner main other", "grep -finner a", "grep -f.. a", "rg -finner a",
            // Everything else stash and apply do.
            "git stash", "git stash pop", "git stash list -p", "git stash show",
        ]
        for role in roles {
            for command in refused + writes.map({ $0 + " -v" }) + ["git apply -R one.patch", "git diff HEAD | git apply --unsafe-paths -R",
                                                                  "git diff HEAD | git apply -R --directory=../x", "git diff HEAD | git apply -R -R",
                                                                  "git diff HEAD | git apply --reverse", "git diff HEAD | git apply -R --check && head inner"] {
                #expect(!role.runsUnasked(command, cwd: repo), "\(role.role): \(command)")
            }
        }
    }

    /// `git merge-tree` forms beyond a trial merge (a merge per line of its input, strategy options, a commit too many
    /// or too few for the form, the mode flags mixed, a ref move after it), and git grep's pager and searches of files
    /// git doesn't track, prompt for every role.
    @Test func mergeTreeBeyondATrialAndGrepsPagerPrompt() throws {
        let (repo, _, base) = try repository()
        let refused = [
            "git merge-tree --stdin", "git merge-tree --stdin main other", "git merge-tree -X ours main other",
            "git merge-tree --strategy-option=ours main other", "git merge-tree main", "git merge-tree a b c d",
            "git merge-tree --write-tree \(base) main other", "git merge-tree --trivial-merge main other",
            "git merge-tree --trivial-merge --name-only \(base) main other", "git merge-tree --write-tree --trivial-merge main other",
            "git merge-tree --name-only \(base) main other", "git merge-tree --merge-base= main other", "git merge-tree -- main other",
            "git merge-tree -zX main other", "git merge-tree --write-tree main other && git update-ref refs/heads/x HEAD",
            "git merge-tree --write-tree main other | git commit-tree -m x", "git merge-tree --write-tree main other | git read-tree",
            // git grep's pager (a program it runs), any spelling, and its searches outside what git tracks.
            "git grep --open-files-in-pager x", "git grep --open-files-in-pager=less x", "git grep -O x", "git grep -Oless x",
            "git grep -nO x", "git grep -O less x", "git grep --open-files x", "git grep --no-index x", "git grep --untracked x",
            "git grep --textconv x", "git grep --recurse-submodules x", "git grep --ext-grep x", "git grep --threads 2 x",
        ]
        for role in try roles(repo) {
            for command in refused { #expect(!role.runsUnasked(command, cwd: repo), "\(role.role): \(command)") }
        }
        // The parser alone, for a role without a worktree too.
        for command in refused { #expect(!ReadOnlyCommand.allows(command), "\(command)") }
        #expect(ReadOnlyCommand.allows("git merge-tree --write-tree --merge-base=\(base) main other"))
    }

    /// From a subfolder of the worktree (the audit's F1, F2): git grep opens `-f`'s file from the top of the work tree,
    /// not the shell's folder the path check judges it from, so in `sub`, `git grep -E -f ../private/seal` looked inside
    /// (sub/../private) and read outside (repo/../private), printing the seal in its regex error. `-f` prompts in every
    /// spelling, as does `-f -` (its input) and ls-tree's `--full-tree` (paths from the top); the listed forms still run.
    @Test func fromASubfolderGitOpensFilesWhereThePathCheckLooks() throws {
        let (repo, _, _) = try repository()
        let sub = repo + "/sub"
        #expect(try LeadLaunchOutsideReadsTests.shell("git grep -E -f ../private/seal", in: sub).contains("SECRET-SEAL-VALUE"), "not a leak")
        let refused = ["git grep -E -f ../private/seal", "git grep -E -f ../private/seal HEAD", "git grep -f b HEAD", "git grep -fb HEAD",
                       "git grep -nfb", "git grep -f - HEAD", "git grep -e x -f b", "git ls-tree --full-tree HEAD a",
                       "git ls-tree --full-tree -r HEAD"]
        let reads = ["git grep -n b HEAD -- .", "git grep -n b other -- b", "git grep -n -e b -e c other", "git log main..other --stat -- b",
                     "git diff main...other --stat -- b", "git show HEAD --cc -- ../a", "git ls-tree HEAD b", "git ls-tree -r --name-only HEAD",
                     "git check-ignore -q ../build", "git merge-tree --write-tree main other", "git diff -Ob main other --stat",
                     "git rev-list --count main..other -- b", "git diff-tree -r --cc HEAD -- ../a"]
        let roles = try roles(repo)
        for command in reads {
            let out = try LeadLaunchOutsideReadsTests.shell(command, in: sub)
            #expect(!out.contains("usage:") && !out.contains("fatal:") && !out.contains("error:"), "not a git form: \(command): \(out)")
        }
        for role in roles {
            for command in refused { #expect(!role.runsUnasked(command, cwd: sub), "\(role.role): \(command)") }
            for command in reads { #expect(role.runsUnasked(command, cwd: sub), "\(role.role): \(command)") }
        }
    }
}
