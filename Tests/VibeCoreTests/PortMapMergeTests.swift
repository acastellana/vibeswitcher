import Foundation
import Testing
@testable import VibeCore

/// Workers that edit a file shared with main each add a row at the end of docs/process/v2-port-map.md's Non-seam
/// edits table. On 2026-11-19 three branches (sb3-the-launcher-builds twice, leadadvancetests-battery) conflicted with
/// v2 only there, another task's row having landed first: each needed a merge commit, a new audit and the user's
/// approval again for identical code. The repository's .gitattributes gives the file git's union driver, which keeps
/// both rows. These tests take the real file into a scratch repository with this repository's .gitattributes, land one
/// branch's row and then the other's, both through plain git and through the merge queue's own landing
/// (`Worktrees.rebaseAndTest`: rebased, or squashed when the branch holds a merge), and show what a union does to two
/// edits of one row (DocLinksLint's port map check finds it).
@Suite struct PortMapMergeTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let file = "docs/process/v2-port-map.md"
    static let first = "| `Sources/VibeCore/Worktrees.swift` `land` 900-901 (made on `agent/first`, 2026-11-19; kind 4) | one hook | the first task | low: one line |"
    static let second = "| `Sources/VibeCore/LeadVault.swift` `judge` 1500 (made on `agent/second`, 2026-11-19; kind 4) | one hook | the second task | low: one line |"
    let temp = Scratch()

    /// git in `root`, with no config but the repository's own.
    @discardableResult
    func git(_ args: [String], in root: String) -> Git.Result {
        Shell.run(executable: "/usr/bin/git", args: args, in: root,
                  env: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
                        "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@t"])
    }

    func append(_ line: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// The port map's last line replaced by `line`.
    func replaceLast(with line: String, in path: String) throws {
        var lines = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        lines[lines.count - 1] = line
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A scratch repository with this repository's .gitattributes (`attributes` in its place, when given) and its port
    /// map on `main`; branches `agent/first` and `agent/second` off it, each changing the map by its closure (by default
    /// adding a row of its own at the Non-seam table's end) in one commit; `agent/first` landed on `main` (fast-forward),
    /// `main` checked out. Its root and the map's path in it.
    func landedFirst(attributes: String? = nil, first: ((String) throws -> Void)? = nil,
                     second: ((String) throws -> Void)? = nil) throws -> (root: String, file: String) {
        let url = temp.url("port-map")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        #expect(git(["init", "-q", "-b", "main"], in: root).ok)
        // The merge queue's git (`Git.run`) commits with the repository's identity.
        #expect(git(["config", "user.name", "T"], in: root).ok)
        #expect(git(["config", "user.email", "t@t"], in: root).ok)
        let attributes = try attributes ?? String(contentsOf: Self.repo.appendingPathComponent(".gitattributes"), encoding: .utf8)
        try attributes.write(toFile: root + "/.gitattributes", atomically: true, encoding: .utf8)
        let file = root + "/" + Self.file
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: Self.repo.appendingPathComponent(Self.file).path, toPath: file)
        #expect(git(["add", "-A"], in: root).ok)
        #expect(git(["commit", "-q", "-m", "first"], in: root).ok)

        for (branch, change) in [("agent/first", first ?? { try append(Self.first, to: $0) }),
                                 ("agent/second", second ?? { try append(Self.second, to: $0) })] {
            #expect(git(["checkout", "-q", "-b", branch, "main"], in: root).ok)
            try change(file)
            #expect(git(["commit", "-q", "-am", "port map: a Non-seam row"], in: root).ok)
        }
        #expect(git(["checkout", "-q", "main"], in: root).ok)
        #expect(git(["merge", "-q", "--ff-only", "agent/first"], in: root).ok)
        return (root, file)
    }

    func rowsLanded(_ text: String) {
        for marker in ["<<<<<<<", ">>>>>>>"] { #expect(!text.contains(marker), "\(text.suffix(600))") }
        // Both rows at the table's end: in the order they landed, or, after a worker's merge of the base into its
        // branch, its own first (the union driver puts the merge's own side first).
        #expect(text.hasSuffix(Self.first + "\n" + Self.second + "\n") || text.hasSuffix(Self.second + "\n" + Self.first + "\n"),
                "\(text.suffix(600))")
        #expect(DocLinksLintTests.tableProblems(in: text).isEmpty, "\(DocLinksLintTests.tableProblems(in: text))")
    }

    func head(_ ref: String, in root: String) -> String { git(["rev-parse", ref], in: root).output }

    func scratch() -> URL { temp.url("port-map-scratch").appendingPathComponent("merge") }
    var lock: TestLock { TestLock(directory: temp.url("port-map-lock").path) }
    /// The merge's test command: the landed map holds both rows.
    var bothRows: String {
        "grep -qxF '\(Self.first)' \(Self.file) && grep -qxF '\(Self.second)' \(Self.file)"
    }

    // MARK: plain git

    @Test func aPlainMergeOfTheSecondBranchKeepsBothRows() throws {
        let (root, file) = try landedFirst()
        let merge = git(["merge", "--no-edit", "agent/second"], in: root)
        #expect(merge.status == 0, "git merge said: \(merge.output) \(merge.error)")
        rowsLanded(try String(contentsOfFile: file, encoding: .utf8))
        #expect(git(["status", "--porcelain"], in: root).output.isEmpty)
    }

    /// Without the union driver the same merge conflicts: the test above would pass for nothing if it didn't.
    @Test func withoutTheUnionDriverThePlainMergeConflicts() throws {
        let (root, file) = try landedFirst(attributes: "")
        let merge = git(["merge", "--no-edit", "agent/second"], in: root)
        #expect(merge.status != 0 && merge.output.contains("CONFLICT"), "git merge said: \(merge.output) \(merge.error)")
        #expect(try String(contentsOfFile: file, encoding: .utf8).contains("<<<<<<<"))
        #expect(git(["merge", "--abort"], in: root).ok)
    }

    // MARK: the merge queue's landing

    /// The merge queue rebases a branch without merges onto the base (`Worktrees.place`), in a detached worktree of
    /// the base's commit, whose .gitattributes the rebase's picks read.
    @Test func theMergeQueuesRebaseKeepsBothRows() throws {
        let (root, _) = try landedFirst()
        let checked = Worktrees.rebaseAndTest(root: root, commit: head("agent/second", in: root), onto: head("main", in: root),
                                              test: bothRows, scratch: scratch(), lock: lock, records: "docs/lead")
        guard case .passed(let landed) = checked else { Issue.record("\(checked)"); return }
        rowsLanded(git(["show", "\(landed):\(Self.file)"], in: root).output + "\n")
        #expect(git(["rev-parse", "\(landed)^"], in: root).output == head("main", in: root), "landed on main's tip")
    }

    @Test func withoutTheUnionDriverTheMergeQueuesRebaseConflicts() throws {
        let (root, _) = try landedFirst(attributes: "")
        let checked = Worktrees.rebaseAndTest(root: root, commit: head("agent/second", in: root), onto: head("main", in: root),
                                              test: bothRows, scratch: scratch(), lock: lock, records: "docs/lead")
        #expect(checked == .conflict, "\(checked)")
    }

    /// A worker brings its branch up to date by merging the base in: with the union driver that merge is clean (it
    /// stopped on the map before), and the merge queue squashes the branch, merge and all, onto the base.
    @Test func aWorkersMergeOfTheBaseIsCleanAndTheSquashKeepsBothRows() throws {
        let (root, file) = try landedFirst()
        #expect(git(["checkout", "-q", "agent/second"], in: root).ok)
        let merge = git(["merge", "--no-edit", "main"], in: root)
        #expect(merge.status == 0, "git merge said: \(merge.output) \(merge.error)")
        rowsLanded(try String(contentsOfFile: file, encoding: .utf8))
        #expect(git(["checkout", "-q", "main"], in: root).ok)
        let checked = Worktrees.rebaseAndTest(root: root, commit: head("agent/second", in: root), onto: head("main", in: root),
                                              test: bothRows, scratch: scratch(), lock: lock, records: "docs/lead")
        guard case .passed(let landed) = checked else { Issue.record("\(checked)"); return }
        rowsLanded(git(["show", "\(landed):\(Self.file)"], in: root).output + "\n")
        // Squashed: one commit on main's tip, not the worker's merge.
        #expect(git(["rev-list", "--count", "\(head("main", in: root))..\(landed)"], in: root).output == "1")
    }

    // MARK: two edits of one row

    /// Two branches that edit the same row each differently don't conflict either: the union keeps both versions of
    /// the row, one after the other. DocLinksLint's port map check (`DocLinksLintTests.tableProblems`) finds the two rows with one first cell,
    /// so a merge that lands it fails its lint run instead of leaving the table wrong unseen.
    @Test func twoEditsOfOneRowLeaveBothVersionsAndTheLintFindsThem() throws {
        let original = try String(contentsOf: Self.repo.appendingPathComponent(Self.file), encoding: .utf8)
        let last = try #require(original.components(separatedBy: "\n").last { !$0.isEmpty })
        let cells = DocLinksLintTests.tableCells(last)
        try #require(cells.count == 4)
        let edited = { (cost: String) in "| " + cells[0] + " | " + cells[1] + " | " + cells[2] + " | " + cost + " |" }
        let (root, file) = try landedFirst(first: { try replaceLast(with: edited("low: edited by the first"), in: $0) },
                                           second: { try replaceLast(with: edited("low: edited by the second"), in: $0) })
        let merge = git(["merge", "--no-edit", "agent/second"], in: root)
        #expect(merge.status == 0, "git merge said: \(merge.output) \(merge.error)")
        let text = try String(contentsOfFile: file, encoding: .utf8)
        #expect(text.hasSuffix(edited("low: edited by the first") + "\n" + edited("low: edited by the second") + "\n"), "\(text.suffix(600))")
        let problems = DocLinksLintTests.tableProblems(in: text)
        #expect(problems.count == 1 && problems.first?.contains("the same row name") == true, "\(problems)")
    }
}
