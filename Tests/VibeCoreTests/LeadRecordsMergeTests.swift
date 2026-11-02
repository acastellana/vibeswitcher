import Foundation
import Testing
@testable import VibeCore

/// Two Macs' leads both append to docs/lead/progress.md and docs/lead/decisions.md and commit them to main; the user
/// merges the two mains through GitHub. Twice (2026-10-31, 2026-11-02) that merge stopped on progress.md, both sides
/// having added lines at its end, and once its conflict markers were committed. The repository's .gitattributes gives
/// both files git's built-in union driver, which keeps both sides' lines there instead. These tests merge two such
/// branches in a scratch repository holding this repository's own .gitattributes, with the plain git the user merges
/// with (no global or system config of the Mac's, so nothing there changes the merge).
@Suite struct LeadRecordsMergeTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let records = ["docs/lead/progress.md", "docs/lead/decisions.md"]
    let temp = Scratch()

    /// git in `root`, with no config but the repository's own.
    @discardableResult
    func git(_ args: [String], in root: String) -> Git.Result {
        Shell.run(executable: "/usr/bin/git", args: args, in: root,
                  env: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
                        "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@t"])
    }

    func append(_ lines: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.utf8))
    }

    /// A scratch repository with this repository's .gitattributes (`attributes` in its place, when given; empty when
    /// there is none) and `record` on main, then branches `here` and `other` that each append lines of their own at its
    /// end; `here` checked out. Its root and the record's path in it.
    func diverged(_ record: String, attributes: String? = nil) throws -> (root: String, file: String) {
        let url = temp.url("lead-records")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        #expect(git(["init", "-q", "-b", "main"], in: root).ok)
        let attributes = attributes ?? ((try? String(contentsOf: Self.repo.appendingPathComponent(".gitattributes"), encoding: .utf8)) ?? "")
        try attributes.write(toFile: root + "/.gitattributes", atomically: true, encoding: .utf8)
        let file = root + "/" + record
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "# Lead record\n\n- 2026-11-01 10:00 merged worker-a\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(git(["add", "-A"], in: root).ok)
        #expect(git(["commit", "-q", "-m", "first"], in: root).ok)

        #expect(git(["checkout", "-q", "-b", "other"], in: root).ok)
        try append("- 2026-11-02 09:00 other Mac: merged worker-b\n- 2026-11-02 09:05 other Mac: decided X\n", to: file)
        #expect(git(["commit", "-q", "-am", "Lead: decisions and progress"], in: root).ok)

        #expect(git(["checkout", "-q", "-b", "here", "main"], in: root).ok)
        try append("- 2026-11-02 09:01 this Mac: merged worker-c\n", to: file)
        #expect(git(["commit", "-q", "-am", "Lead: decisions and progress"], in: root).ok)
        return (root, file)
    }

    @Test(arguments: records)
    func appendsOnBothSidesMergeWithBothSidesLines(record: String) throws {
        let (root, file) = try diverged(record)
        let merge = git(["merge", "--no-edit", "other"], in: root)
        #expect(merge.status == 0, "git merge said: \(merge.output) \(merge.error)")
        let text = try String(contentsOfFile: file, encoding: .utf8)
        for marker in ["<<<<<<<", "=======", ">>>>>>>"] { #expect(!text.contains(marker), "\(text)") }
        for line in ["- 2026-11-01 10:00 merged worker-a", "- 2026-11-02 09:01 this Mac: merged worker-c",
                     "- 2026-11-02 09:00 other Mac: merged worker-b", "- 2026-11-02 09:05 other Mac: decided X"] {
            #expect(text.contains(line + "\n"), "\(line) missing from \(text)")
        }
        #expect(git(["status", "--porcelain"], in: root).output.isEmpty, "the merge left the checkout unclean")
    }

    /// The same appends conflict without the union driver: the test above would pass for nothing if they didn't.
    @Test(arguments: records)
    func withoutTheUnionDriverTheSameMergeConflicts(record: String) throws {
        let (root, file) = try diverged(record, attributes: "")
        let merge = git(["merge", "--no-edit", "other"], in: root)
        #expect(merge.status != 0 && merge.output.contains("CONFLICT"), "git merge said: \(merge.output) \(merge.error)")
        #expect(try String(contentsOfFile: file, encoding: .utf8).contains("<<<<<<<"))
        #expect(git(["merge", "--abort"], in: root).ok)
    }
}
