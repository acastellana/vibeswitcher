import Foundation
import Testing
@testable import VibeCore

/// The incident of 2026-11-05 (docs/lead/incidents.md): a verifier stopped on a permission prompt to Read the worker's
/// evidence screenshots (`<root>/.vibeswitcher/evidence/<task>/<report id>/*.png`, outside its worktree, named in its
/// brief), no one answered it, and the audit hung: three times that day, once for 155 minutes. A verifier's settings
/// now let it read the image files in its own task's evidence folder (`LeadLaunch.evidenceReads`), and nothing else.
///
/// The rules are held as Claude Code holds them: `Rules` below is its check of a Read as 2.1.318's bundle has it (not
/// a run of Claude Code): a deny rule that matches any spelling of the file refuses it; otherwise it's read without a
/// prompt only when every spelling (the path as asked with `..` resolved, and where its symlinks land) matches an
/// allow rule; "//" starts a rule's path at the file system's root, "~/" at home, and `*` stays within one name.
struct VerifierEvidenceReadTests {
    let temp = Scratch()

    struct Rules {
        var allow: [String]
        var deny: [String]
        var home: String

        static func patterns(_ rules: [String], home: String) -> [String] {
            rules.compactMap { rule -> String? in
                guard rule.hasPrefix("Read("), rule.hasSuffix(")") else { return nil }
                let content = String(rule.dropFirst(5).dropLast())
                if content.hasPrefix("//") { return String(content.dropFirst()) }
                if content.hasPrefix("~/") { return home + String(content.dropFirst()) }
                return nil
            }
        }

        static func matches(_ pattern: String, _ path: String) -> Bool {
            if pattern.hasSuffix("/**") { return path.hasPrefix(String(pattern.dropLast(2))) }
            return fnmatch(pattern, path, FNM_PATHNAME) == 0
        }

        static func spellings(_ path: String) -> [String] {
            let asked = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let found = realpath(asked, nil) else { return [asked] }
            defer { free(found) }
            let landing = String(cString: found)
            return landing == asked ? [asked] : [asked, landing]
        }

        /// Whether a Read of `path` goes through without a prompt.
        func reads(_ path: String) -> Bool {
            let spellings = Self.spellings(path)
            let refused = Self.patterns(deny, home: home), allowed = Self.patterns(allow, home: home)
            if spellings.contains(where: { spelling in refused.contains { Self.matches($0, spelling) } }) { return false }
            return spellings.allSatisfy { spelling in allowed.contains { Self.matches($0, spelling) } }
        }
    }

    struct Project {
        var root: String
        var home: String
        var evidence: String { root + "/.vibeswitcher/evidence" }

        func write(_ path: String, _ text: String = "x") throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    /// A project with two tasks' kept evidence, the lead's board, an update's image, and a home with the lead's
    /// private files. `root` is spelled as the scratch folder is (through /var, a symlink, on macOS).
    func project(_ name: String = "evidence") throws -> Project {
        let base = temp.url(name).path
        let project = Project(root: base + "/repo", home: base + "/home")
        try project.write(project.evidence + "/audit-me/R1/1-main-light.png")
        try project.write(project.evidence + "/audit-me/R1/2-main-dark.jpeg")
        try project.write(project.evidence + "/audit-me/R1/notes.txt")
        try project.write(project.evidence + "/audit-me/R1/deep/3-deeper.png")
        try project.write(project.evidence + "/audit-me/loose.png")
        try project.write(project.evidence + "/other-task/R9/1-theirs.png")
        try project.write(project.root + "/.vibeswitcher/updates/U1/1-update.png")
        try project.write(project.root + "/.vibeswitcher/board.json", "{}")
        try project.write(project.home + "/.vibeswitcher/lead/seal.json", "{}")
        try project.write(project.home + "/.vibeswitcher/lead/shot.png")
        return project
    }

    func rules(_ role: LeadLaunch.Role, _ project: Project, task: String? = "audit-me") throws -> Rules {
        let launch = try LeadLaunch.prepare(role: role, root: project.root, task: role == .lead ? nil : task, base: "claude", prompt: "p",
                                            start: "Go.", server: "/App/vibeswitcher-mcp", name: "\(role.rawValue)-audit-me",
                                            folder: temp.url("run-\(role.rawValue)-\(UUID().uuidString)"), temporary: temp.url("session-tmp"))
        let settings = try LaunchArguments.json("--settings", in: launch.command)
        let permissions = try #require(settings["permissions"] as? [String: Any])
        return Rules(allow: permissions["allow"] as? [String] ?? [], deny: permissions["deny"] as? [String] ?? [], home: project.home)
    }

    func real(_ path: String) -> String {
        guard let found = realpath(path, nil) else { return path }
        defer { free(found) }
        return String(cString: found)
    }

    /// The incident: the screenshots the verifier's brief names are read without a prompt, by either spelling of the
    /// project's folder.
    @Test func aVerifierReadsItsTasksEvidenceImagesWithoutAPrompt() throws {
        let project = try project()
        let rules = try rules(.verifier, project)
        let folders = Array(Set([project.root, real(project.root)])).sorted().map { $0 + "/.vibeswitcher/evidence/audit-me" }
        let expected = folders.flatMap { folder in ["png", "jpg", "jpeg", "gif", "webp"].map { "Read(/\(folder)/*/*.\($0))" } }
        #expect(rules.allow.filter { $0.hasPrefix("Read(") }.sorted() == expected.sorted(), "\(rules.allow)")
        #expect(rules.allow.filter { !$0.hasPrefix("Read(") } == LeadLaunch.allow(.verifier))
        for root in [project.root, real(project.root)] {
            #expect(rules.reads(root + "/.vibeswitcher/evidence/audit-me/R1/1-main-light.png"), "\(root)")
            #expect(rules.reads(root + "/.vibeswitcher/evidence/audit-me/R1/2-main-dark.jpeg"), "\(root)")
            // A path that climbs and comes back is the same file.
            #expect(rules.reads(root + "/.vibeswitcher/evidence/audit-me/R1/../R1/1-main-light.png"), "\(root)")
        }
    }

    /// Everything else outside its worktree prompts or is refused as before: the lead's private files, another task's
    /// evidence, the rest of `.vibeswitcher`, what isn't an image in a report's folder, and a path that leaves the
    /// folder through `..` or a symlink. Its deny rules are as they were.
    @Test func nothingElseOutsideItsWorktreeBecomesReadable() throws {
        let project = try project()
        let rules = try rules(.verifier, project)
        #expect(rules.deny == LeadLaunch.deny(.verifier))
        let mine = project.evidence + "/audit-me"
        // Links a worker could leave in its evidence folder: to the lead's private files, another task's report,
        // the board; a link of a folder; a link that leads nowhere.
        try FileManager.default.createSymbolicLink(atPath: mine + "/R1/4-seal.png", withDestinationPath: project.home + "/.vibeswitcher/lead/seal.json")
        try FileManager.default.createSymbolicLink(atPath: mine + "/R1/5-private.png", withDestinationPath: project.home + "/.vibeswitcher/lead/shot.png")
        try FileManager.default.createSymbolicLink(atPath: mine + "/R1/6-theirs.png", withDestinationPath: project.evidence + "/other-task/R9/1-theirs.png")
        try FileManager.default.createSymbolicLink(atPath: mine + "/R1/7-board.png", withDestinationPath: project.root + "/.vibeswitcher/board.json")
        try FileManager.default.createSymbolicLink(atPath: mine + "/R2", withDestinationPath: project.evidence + "/other-task/R9")
        try FileManager.default.createSymbolicLink(atPath: mine + "/R1/8-nowhere.png", withDestinationPath: project.root + "/gone.png")
        let refused = [
            project.home + "/.vibeswitcher/lead/seal.json", project.home + "/.vibeswitcher/lead/shot.png",
            project.evidence + "/other-task/R9/1-theirs.png", project.root + "/.vibeswitcher/updates/U1/1-update.png",
            project.root + "/.vibeswitcher/board.json", project.root + "/README.md", "/etc/hosts",
            // Not an image, not in a report's folder, deeper than one.
            mine + "/R1/notes.txt", mine + "/loose.png", mine + "/R1/deep/3-deeper.png", mine + "/R1", mine,
            // Out through `..`.
            mine + "/R1/../../other-task/R9/1-theirs.png", mine + "/../other-task/R9/1-theirs.png", mine + "/R1/../../../board.json",
            mine + "/R1/../../../updates/U1/1-update.png",
            // Out through a symlink.
            mine + "/R1/4-seal.png", mine + "/R1/5-private.png", mine + "/R1/6-theirs.png", mine + "/R1/7-board.png", mine + "/R2/1-theirs.png",
        ]
        for path in refused {
            #expect(!rules.reads(path), "readable: \(path)")
            #expect(!rules.reads(real(project.root) + path.dropFirst(project.root.count)) || !path.hasPrefix(project.root), "readable: \(path)")
        }
        // The link that leads nowhere has no file behind it: only its own spelling, which is in the folder.
        #expect(Rules.spellings(mine + "/R1/8-nowhere.png").count == 1)
        // Another task's verifier reads its own, not this one's.
        let other = try self.rules(.verifier, project, task: "other-task")
        #expect(other.reads(project.evidence + "/other-task/R9/1-theirs.png") && !other.reads(mine + "/R1/1-main-light.png"))
    }

    /// A worker's and the lead's rules are what they were: no Read rule at all.
    @Test func aWorkersAndTheLeadsSettingsAreUnchanged() throws {
        let project = try project()
        for role in [LeadLaunch.Role.worker, .lead] {
            let rules = try rules(role, project)
            #expect(rules.allow == LeadLaunch.allow(role), "\(role): \(rules.allow)")
            #expect(rules.deny == LeadLaunch.deny(role), "\(role)")
            #expect(LeadLaunch.evidenceReads(role, root: project.root, task: "audit-me").isEmpty)
            #expect(!rules.reads(project.evidence + "/audit-me/R1/1-main-light.png"))
        }
    }

    /// Anything unusual gets no rule (the verifier is asked, as before): a task that isn't one plain name, a root that
    /// isn't an absolute folder that's there, characters a rule's pattern reads as its own, and an evidence folder
    /// that isn't where it says (a symlink on the way).
    @Test func anythingUnusualGetsNoRule() throws {
        let project = try project()
        #expect(!LeadLaunch.evidenceReads(.verifier, root: project.root, task: "audit-me").isEmpty)
        #expect(LeadLaunch.evidenceReads(.verifier, root: project.root, task: nil).isEmpty)
        for task in ["", ".", "..", "../other-task", "audit-me/..", "audit-me/R1", "/etc", ".hidden", "a*", "a?b", "[ab]", "{a,b}", "a\\b", "a(b)", "!a", "a\nb"] {
            #expect(LeadLaunch.evidenceReads(.verifier, root: project.root, task: task).isEmpty, "a rule for task \(task.debugDescription)")
        }
        // A task with no evidence kept yet still gets its rule (a later report's is read): nothing there leads elsewhere.
        #expect(LeadLaunch.evidenceReads(.verifier, root: project.root, task: "no-report-yet").count == LeadLaunch.evidenceReads(.verifier, root: project.root, task: "audit-me").count)
        let base = (project.root as NSString).deletingLastPathComponent
        for name in ["star*", "class[1]", "brace{a}", "paren(1)"] {
            try FileManager.default.createDirectory(atPath: base + "/" + name, withIntermediateDirectories: true)
            #expect(LeadLaunch.evidenceReads(.verifier, root: base + "/" + name, task: "audit-me").isEmpty, "a rule under \(name)")
        }
        for root in ["", "repo", "./repo", "/", base + "/not-there"] {
            #expect(LeadLaunch.evidenceReads(.verifier, root: root, task: "audit-me").isEmpty, "a rule for root \(root.debugDescription)")
        }
        // The task's folder, the evidence folder or .vibeswitcher as a link to somewhere else, or to nowhere.
        let elsewhere = base + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere + "/audit-me", withIntermediateDirectories: true)
        for (link, target) in [("/.vibeswitcher/evidence/linked-task", project.evidence + "/other-task"),
                               ("/.vibeswitcher/evidence/dangling-task", base + "/gone")] {
            try FileManager.default.createSymbolicLink(atPath: project.root + link, withDestinationPath: target)
            #expect(LeadLaunch.evidenceReads(.verifier, root: project.root, task: (link as NSString).lastPathComponent).isEmpty, "\(link)")
        }
        for linked in [".vibeswitcher/evidence", ".vibeswitcher"] {
            let root = base + "/linked-" + (linked as NSString).lastPathComponent
            try FileManager.default.createDirectory(atPath: root + "/" + (linked as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: root + "/" + linked, withDestinationPath: elsewhere)
            #expect(LeadLaunch.evidenceReads(.verifier, root: root, task: "audit-me").isEmpty, "a rule through a linked \(linked)")
        }
    }
}
