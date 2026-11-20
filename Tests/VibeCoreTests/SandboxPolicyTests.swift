import Foundation
import Testing
@testable import VibeCore

/// `SandboxPolicy`: a project's `sandbox*` keys of workflow.md, what they may name, and that each is a guard rail
/// (SB-D16): a change is held until the user accepts it, as `test_command`'s is.
struct SandboxPolicyTests {
    let scratch = Scratch()

    func home() throws -> String {
        // Made, then resolved by realpath: the Mac's `resolvingSymlinksInPath` gives /private/tmp back as /tmp, which
        // isn't the path the policy resolves to.
        let made = scratch.url("policy-home").path
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        let home = SandboxPolicy.resolved(made)
        for folder in [".ssh", ".config/gh", ".gnupg", ".vibeswitcher/state", ".cache/sdk", "sdk", "projects/app", "projects/other"] {
            try FileManager.default.createDirectory(atPath: home + "/" + folder, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(atPath: home + "/projects/other/.git", withIntermediateDirectories: true)
        return home
    }

    static func workflow(_ settings: String) -> LeadWorkflow { LeadWorkflow.parse("---\n\(settings)\n---\n") }

    @Test func aPathUnderAHiddenFolderIsRefusedNamingIt() throws {
        let home = try home()
        for (key, value, named) in [("sandbox_read", "~/.ssh", ".ssh"), ("sandbox_read", "~/.config/gh/hosts.yml", ".config"),
                                    ("sandbox_private", "~/.gnupg", ".gnupg"), ("sandbox_read", "~/.vibeswitcher/state", ".vibeswitcher"),
                                    ("sandbox_read", "\(home)/.claude/.credentials.json", ".claude"), ("sandbox_read", "/run/user/1000", "/run"),
                                    ("sandbox_read", "/mnt/c/Users", "/mnt"), ("sandbox_read", "/proc/1", "/proc"),
                                    ("sandbox_read", "~/projects/other", "another repository")] {
            let result = SandboxPolicy.read(Self.workflow("\(key): ~/sdk, \(value)"), home: home, root: home + "/projects/app")
            guard case .failure(let refusal) = result else {
                Issue.record("\(key): \(value) was taken: \(result)")
                continue
            }
            #expect(refusal.key == key && refusal.value == value && refusal.description.contains(named), "\(refusal)")
        }
        // What may be named is taken, resolved.
        let taken = try SandboxPolicy.read(Self.workflow("sandbox_read: ~/sdk, /usr/share/doc\nsandbox_private: ~/.cache/sdk"),
                                           home: home, root: home + "/projects/app").get()
        #expect(taken.read == [home + "/sdk", SandboxPolicy.resolved("/usr/share/doc")] && taken.privateFolders == [home + "/.cache/sdk"])
    }

    /// Whichever way round: a path that holds a hidden folder is refused as one under it is.
    @Test func aPathThatHoldsAHiddenFolderIsRefused() throws {
        let home = try home()
        try FileManager.default.createDirectory(atPath: home + "/.local/share/keyrings", withIntermediateDirectories: true)
        for (value, named) in [("~", "home"), ("~/.config/..", "home"), ("~/.local", ".local/share/keyrings"), ("~/.local/share", ".local/share/keyrings"),
                               ("/var", "/var/run"), ("/", "home")] {
            let result = SandboxPolicy.read(Self.workflow("sandbox_read: \(value)"), home: home, root: home + "/projects/app")
            guard case .failure(let refusal) = result else {
                Issue.record("\(value) was taken: \(result)")
                continue
            }
            #expect(refusal.description.contains(named), "\(value): \(refusal)")
        }
    }

    /// A path that holds another repository is refused, naming it; one too big to look through is refused too.
    @Test func aFolderHoldingAnotherRepositoryIsRefused() throws {
        let home = try home()
        try FileManager.default.createDirectory(atPath: home + "/projects/app/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/work/deep/down/second", withIntermediateDirectories: true)
        try "gitdir: /elsewhere\n".write(toFile: home + "/work/deep/down/second/.git", atomically: true, encoding: .utf8)
        for value in ["~/projects", "~/work"] {
            let result = SandboxPolicy.read(Self.workflow("sandbox_read: \(value)"), home: home, root: home + "/projects/app")
            guard case .failure(let refusal) = result else {
                Issue.record("\(value) was taken: \(result)")
                continue
            }
            #expect(refusal.description.contains("another repository"), "\(refusal)")
        }
        // The project's own repository under it is no other's.
        #expect(SandboxPolicy.repositories(home + "/projects/app", home + "/projects/app") == .none)
        #expect(SandboxPolicy.repositories(home + "/projects", home + "/projects/app") == .found(home + "/projects/other"))
        // Past the limit, refused rather than passed.
        #expect(SandboxPolicy.repositories(home + "/work", nil, limit: 2) == .tooBig)
        #expect(SandboxPolicy.repositories(home + "/sdk", nil) == .none)
    }

    /// A path is tidied by its spelling alone: `.`, `..` and empty components out, `/private/…` kept as it is (the
    /// Mac's `standardizedFileURL` drops `/private`, which no longer matches a home resolved by realpath).
    @Test func aPathIsTidiedByItsSpellingAlone() {
        #expect(SandboxPolicy.lexical("/private/var/a/./b//c/../d/") == "/private/var/a/b/d")
        #expect(SandboxPolicy.lexical("/a/..") == "/" && SandboxPolicy.lexical("/..") == "/" && SandboxPolicy.lexical("/") == "/")
        #expect(SandboxPolicy.lexical("relative/../x") == "relative/../x")
    }

    @Test func aLinkIsResolvedBeforeItIsJudged() throws {
        let home = try home()
        // A harmless-looking name whose link leads into a hidden folder.
        try FileManager.default.createSymbolicLink(atPath: home + "/sdk-link", withDestinationPath: home + "/.ssh")
        let result = SandboxPolicy.read(Self.workflow("sandbox_read: ~/sdk-link"), home: home, root: home + "/projects/app")
        guard case .failure(let refusal) = result else {
            Issue.record("taken: \(result)")
            return
        }
        #expect(refusal.description.contains(".ssh"), "\(refusal)")
        // And one leading somewhere allowed is taken as where it leads.
        try FileManager.default.createSymbolicLink(atPath: home + "/fine-link", withDestinationPath: home + "/sdk")
        #expect(try SandboxPolicy.read(Self.workflow("sandbox_read: ~/fine-link"), home: home).get().read == [home + "/sdk"])
    }

    @Test func aRelativeOrHomelessPathIsRefused() throws {
        let home = try home()
        for value in ["sdk", "./sdk", "../sdk", "~", "~other/sdk", "/", home, (home as NSString).deletingLastPathComponent, "~/sdk/../.."] {
            let result = SandboxPolicy.read(Self.workflow("sandbox_read: \(value)"), home: home)
            guard case .failure(let refusal) = result else {
                Issue.record("\(value) was taken: \(result)")
                continue
            }
            #expect(refusal.key == "sandbox_read", "\(refusal)")
        }
        // A setting that isn't on or off, refused; none at all, the defaults.
        #expect(throws: SandboxRefusal.self) { try SandboxPolicy.read(Self.workflow("sandbox_nesting: perhaps"), home: home).get() }
        #expect(try SandboxPolicy.read(Self.workflow("max_workers: 2"), home: home).get() == .standard)
        let off = try SandboxPolicy.read(Self.workflow("sandbox: off\nsandbox_nesting: on"), home: home).get()
        #expect(!off.enabled && off.nesting)
    }

    @Test func aHostWithASchemeAPathOrAnAddressIsRefused() throws {
        let home = try home()
        for value in ["https://api.example.com", "api.example.com/v1", "user@api.example.com", "127.0.0.1", "10.0.0.1:443",
                      "[::1]", "fd7a::1", "localhost", "-bad.example.com", "api.example.com:99999", "exa mple.com"] {
            let result = SandboxPolicy.read(Self.workflow("sandbox_hosts: \(value)"), home: home)
            guard case .failure(let refusal) = result else {
                Issue.record("\(value) was taken: \(result)")
                continue
            }
            #expect(refusal.key == "sandbox_hosts" && refusal.value == value, "\(refusal)")
        }
        let taken = try SandboxPolicy.read(Self.workflow("sandbox_hosts: API.example.com, *.npmjs.org, git.example.com:8443\nsandbox_run_hosts: registry.npmjs.org"),
                                           home: home).get()
        #expect(taken.hosts == ["api.example.com", "*.npmjs.org", "git.example.com:8443"] && taken.runHosts == ["registry.npmjs.org"])
    }

    @Test func theSandboxKeysAreGuarded() throws {
        #expect(Set(SandboxPolicy.keys).isSubset(of: Set(LeadVault.guardedKeys)))
        // Read as written, and a change to one is a change of the guard rails' hashes, held until accepted as
        // test_command's is (`LeadVault.changedSettings`).
        let before = Self.workflow("test_command: make test\nsandbox_read: ~/sdk\nsandbox_nesting: off")
        let after = Self.workflow("test_command: make test\nsandbox_read: ~/.ssh\nsandbox_nesting: off")
        #expect(LeadVault.guardedValue("sandbox_read", in: after) == "~/.ssh")
        let changed = LeadVault.guardedHashes(before).filter { LeadVault.guardedHashes(after)[$0.key] != $0.value }.map(\.key)
        #expect(changed == ["sandbox_read"])

        // Through a vault: recorded as the lead set it, then a worker's edit is held, naming the key.
        let book = LeadVault.Book(restoring: nil)
        book.configHome = scratch.url("vault-config-home").path
        let folder = scratch.url("vault")
        let app = book.vault(folder: folder, as: { .app })
        let lead = book.vault(folder: folder, as: { .session("lead-session") })
        let root = scratch.url("vault-repo").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"],
                          ["commit", "-q", "--allow-empty", "-m", "first"]] { #expect(Git.run(arguments, in: root).ok) }
        let grant = try app.startLead(root: root, branch: "main", floor: nil)
        try app.bind(grant, root: root, session: "lead-session")
        #expect(try lead.changedSettings(before, root: root).isEmpty)
        let held = try lead.changedSettings(after, root: root)
        #expect(held.map(\.key) == ["sandbox_read"] && held.first?.value == "~/.ssh", "\(held)")
    }

    /// A vault whose rails were recorded before the `sandbox*` keys were guarded takes each at its default, not as the
    /// file says now: a `sandbox: off` written since is held for the user's accept, never recorded on first sight. A
    /// vault with nothing recorded yet records them as it does every rail.
    @Test func aSandboxKeyAddedAfterTheVaultsBaselineIsHeld() throws {
        let book = LeadVault.Book(restoring: nil)
        book.configHome = scratch.url("baseline-config-home").path
        let folder = scratch.url("baseline-vault")
        let app = book.vault(folder: folder, as: { .app })
        let lead = book.vault(folder: folder, as: { .session("lead-session") })
        let root = scratch.url("baseline-repo").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"],
                          ["commit", "-q", "--allow-empty", "-m", "first"]] { #expect(Git.run(arguments, in: root).ok) }
        let grant = try app.startLead(root: root, branch: "main", floor: nil)
        try app.bind(grant, root: root, session: "lead-session")
        // The baseline of a build before the keys: every other rail, recorded as the lead set it.
        let old = Self.workflow("test_command: make test")
        try app.setGuardedSettings(LeadVault.guardedHashes(old).filter { !SandboxPolicy.keys.contains($0.key) }, root: root)
        // Then a worker writes `sandbox: off` and widens what its box reads.
        let widened = Self.workflow("test_command: make test\nsandbox: off\nsandbox_nesting: on")
        let held = try lead.changedSettings(widened, root: root)
        #expect(Set(held.map(\.key)) == ["sandbox", "sandbox_nesting"], "\(held)")
        #expect(held.first { $0.key == "sandbox" }?.value == "off")
        // Held again on the next call: nothing recorded it.
        #expect(Set(try lead.changedSettings(widened, root: root).map(\.key)) == ["sandbox", "sandbox_nesting"])
        // A file that leaves them unset is what was recorded: nothing held.
        #expect(try lead.changedSettings(old, root: root).isEmpty)
    }

    /// `sandbox_env`: the variables a run is given for the tools it uses from the account, any tool: `~` is the
    /// account's home, `PATH` names folders put first, and nothing at or under a hidden place, nor a name of the run's
    /// own machinery, is taken. Guarded as every `sandbox*` key is: a worker's edit of it is held, naming it.
    @Test func sandboxEnvGivesAnyToolItsVariablesAndRefusesTheRunsOwnNamesAndHiddenPlaces() throws {
        let home = try home()
        let taken = try SandboxPolicy.read(Self.workflow("sandbox_env: MADE_UP_HOME=~/sdk, MADE_UP_PATH=~/sdk:lib:/usr/share, PYTHONUSERBASE=~/.local, PATH=~/sdk/bin:/opt/tool/bin, FLAG=1"),
                                           home: home, root: home + "/projects/app").get()
        #expect(taken.environment == ["MADE_UP_HOME": home + "/sdk", "MADE_UP_PATH": home + "/sdk:lib:/usr/share", "PYTHONUSERBASE": home + "/.local", "FLAG": "1"],
                "\(taken.environment)")
        #expect(taken.path == [home + "/sdk/bin", "/opt/tool/bin"])
        // A value is passed on as written but for `~`: a URL's `//`, a trailing `/`.
        let written = try SandboxPolicy.read(Self.workflow("sandbox_env: REGISTRY=https://registry.example.com:8080/simple/, DIR=~/sdk/"), home: home,
                                             root: home + "/projects/app").get()
        #expect(written.environment == ["REGISTRY": "https://registry.example.com:8080/simple/", "DIR": home + "/sdk/"], "\(written.environment)")
        for (value, said) in [("KEY=~/.ssh/id_ed25519", ".ssh"), ("CFG=~/.config", ".config"), ("NODE=~/.vibeswitcher/state", ".vibeswitcher"),
                              ("SOCK=/run/user/1000/bus", "/run"), ("MIXED=~/sdk:~/.gnupg", ".gnupg"), ("PATH=~/.claude/bin", ".claude"),
                              ("PATH=bin", "from / or from ~/"), ("OTHER=~root/x", "isn't this user's"),
                              ("LD_PRELOAD=/x.so", "the run's own"), ("HOME=~/sdk", "the run's own"), ("BASH_ENV=~/sdk/rc", "the run's own"),
                              ("VIBESWITCHER_TEST_LOCK=/x", "the run's own"), ("GIT_DIR=~/sdk", "the run's own"), ("VS_HEAVY_CORES=64", "the run's own"),
                              ("1BAD=x", "not a variable's name"), ("NOEQUALS", "not NAME=value"), ("A=1, A=2", "twice")] {
            let result = SandboxPolicy.read(Self.workflow("sandbox_env: \(value)"), home: home, root: home + "/projects/app")
            guard case .failure(let refusal) = result else {
                Issue.record("sandbox_env: \(value) was taken: \(result)")
                continue
            }
            #expect(refusal.key == "sandbox_env" && refusal.description.contains(said), "\(value): \(refusal)")
        }
        // Guarded as the others: a change to it is a change of the guard rails' hashes.
        #expect(LeadVault.guardedKeys.contains("sandbox_env"))
        let before = Self.workflow("sandbox_env: MADE_UP_HOME=~/sdk"), after = Self.workflow("sandbox_env: MADE_UP_HOME=~/sdk, EXTRA=~/sdk")
        #expect(LeadVault.guardedHashes(before).filter { LeadVault.guardedHashes(after)[$0.key] != $0.value }.map(\.key) == ["sandbox_env"])
        // And as accepted only: an edit not recorded reads as unset.
        let accepted = LeadVault.acceptedSandbox(after, recorded: LeadVault.guardedHashes(before))
        #expect(accepted.settings["sandbox_env"] == nil)
        #expect(LeadVault.acceptedSandbox(after, recorded: LeadVault.guardedHashes(after)).settings["sandbox_env"] == "MADE_UP_HOME=~/sdk, EXTRA=~/sdk")
    }
}
