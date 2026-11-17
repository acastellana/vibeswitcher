import Foundation
import Testing
@testable import VibeCore

/// `SandboxPolicy`: a project's `sandbox*` keys of workflow.md, what they may name, and that each is a guard rail
/// (SB-D16): a change is held until the user accepts it, as `test_command`'s is.
struct SandboxPolicyTests {
    let scratch = Scratch()

    func home() throws -> String {
        let home = scratch.url("policy-home").resolvingSymlinksInPath().path
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
}
