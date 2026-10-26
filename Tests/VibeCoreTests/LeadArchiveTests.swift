import Foundation
import Testing
@testable import VibeCore

/// archive_decisions: the lead moves decisions that no longer hold from decisions.md to decisions-archive.md, byte for
/// byte, so every lead start reads less; nothing is deleted, and only the lead may. Every repository is a temporary one.
@Suite(.serialized)
struct LeadArchiveTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo(_ name: String = "archive") throws -> String {
        let url = temp.url(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    /// Six entries as decisions.md has them over time: minutes and seconds, a reason over several paragraphs, one with
    /// a `##` subheading of its own and odd spacing, the last without its blank line.
    static let entries = [
        "## 2026-10-17 12:15 Phase 1 is evaluation only\n\nRead-only passes first.\n\n",
        "## 2026-10-17 13:28 Use the test script\n\nOne line.\n\nAnd a second paragraph.\n\n",
        "## 2026-10-18 09:45:03 Merge caps\n\nThree at once.\n## Not a decision: a subheading\nStill this one's.  \n\n\n",
        "## 2026-10-18 09:45:41 Keep the board current\n\nIt's the memory.\n\n",
        "## 2026-10-19 07:45 Battery: no new starts until on AC\n\nThe user asked.\n\n",
        "## 2026-10-20 10:00 Keep it local\n\nThe last one.\n",
    ]

    func decisions(_ root: String) throws -> String {
        let text = "# Decisions\n\n" + Self.entries.joined()
        try BoardStore(root: root).replaceRecord("decisions.md", with: text)
        return text
    }

    @Test func archivingMovesExactlyTheNamedEntriesAndAppends() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try decisions(root)
        let path = root + "/docs/lead/decisions.md", archivePath = root + "/docs/lead/decisions-archive.md"

        // By stamp (seconds), by the whole heading (with its ##), by the stamp alone: in decisions.md's order, whatever the call's.
        let first = lead.call("archive_decisions", ["entries": ["2026-10-19 07:45", "## 2026-10-17 13:28 Use the test script", "2026-10-18 09:45:03"],
                                                    "reason": "superseded by the Mac-wide limits"])
        #expect(!first.isError, "\(first.text)")
        #expect(first.text.contains("Archived 3 entries") && first.text.contains("docs/lead/decisions-archive.md"), "\(first.text)")
        let archive = try #require(read(archivePath))
        let header = LeadRecords.Kind.archive.header
        #expect(archive.hasPrefix(header))
        let batch = String(archive.dropFirst(header.count))
        let line = try #require(batch.components(separatedBy: "\n").first)
        #expect(line.range(of: #"^# Archived \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}: superseded by the Mac-wide limits$"#, options: .regularExpression) != nil, "\(line)")
        #expect(batch == line + "\n\n" + Self.entries[1] + Self.entries[2] + Self.entries[4])
        let pointer = try #require(read(path)?.components(separatedBy: "\n").first { $0.hasPrefix("Archived decisions: ") })
        #expect(pointer.contains("3 entries") && pointer.contains("decisions-archive.md"), "\(pointer)")
        #expect(read(path) == "# Decisions\n\n" + pointer + "\n\n" + Self.entries[0] + Self.entries[3] + Self.entries[5])
        // What every lead reads: the three that stay, nothing of the pointer's.
        #expect(BoardStore(root: root).decisions().map(\.text) == ["Phase 1 is evaluation only", "Keep the board current", "Keep it local"])
        #expect(BoardStore(root: root).decisions().last?.why == "The last one.")

        // A second call appends to the archive (never rewrites it); decisions.md still has one pointer line.
        let second = lead.call("archive_decisions", ["entries": ["2026-10-20 10:00"], "reason": "obsolete: a past state"])
        #expect(!second.isError, "\(second.text)")
        let after = try #require(read(archivePath))
        #expect(after.hasPrefix(archive))
        #expect(String(after.dropFirst(archive.count)).hasSuffix(": obsolete: a past state\n\n" + Self.entries[5]))
        let text = try #require(read(path))
        let pointers = text.components(separatedBy: "\n").filter { $0.hasPrefix("Archived decisions: ") }
        #expect(pointers.count == 1 && pointers[0].contains("4 entries"), "\(pointers)")
        #expect(text == "# Decisions\n\n" + pointers[0] + "\n\n" + Self.entries[0] + Self.entries[3])
        // A decision recorded after goes on as ever.
        #expect(!lead.call("record_decision", ["decision": "Then this", "why": "w"]).isError)
        #expect(BoardStore(root: root).decisions().map(\.text) == ["Phase 1 is evaluation only", "Keep the board current", "Then this"])

        // Committed through the lead's records path, the archive with the rest.
        guard case .committed(let commit) = lead.records.flush(base: "main") else { Issue.record("not committed"); return }
        let files = Git.run(["diff-tree", "--no-commit-id", "--name-only", "-r", commit], in: root).output.split(separator: "\n").map(String.init)
        #expect(Set(files).isSuperset(of: ["docs/lead/decisions-archive.md", "docs/lead/decisions.md"]), "\(files)")
        #expect(files.allSatisfy { $0.hasPrefix("docs/lead/") }, "\(files)")
        #expect(Git.run(["show", "\(commit):docs/lead/decisions-archive.md"], in: root).output + "\n" == after)
        #expect(vault.head(root: root, branch: "main") == commit)
    }

    @Test func anUnknownOrAmbiguousEntryChangesNothing() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let text = try decisions(root)
        // Two entries in one minute: the stamp alone fits both.
        let both = text + "## 2026-10-20 10:00 Keep it local, again\n\nA duplicate.\n\n"
        try BoardStore(root: root).replaceRecord("decisions.md", with: both)
        let path = root + "/docs/lead/decisions.md", archivePath = root + "/docs/lead/decisions-archive.md"
        let refusals: [([String], String, String)] = [
            (["2026-10-17 12:15", "2026-10-21 09:00 Never recorded"], "obsolete", "“2026-10-21 09:00 Never recorded” names no entry"),
            (["2026-10-17 12:1"], "obsolete", "names no entry"),
            (["2026-10-20 10:00"], "duplicate", "names 2 entries"),
            ([], "obsolete", "name the entries"),
            (["2026-10-17 12:15"], " ", "say why"),
        ]
        for (entries, reason, says) in refusals {
            let refused = lead.call("archive_decisions", ["entries": entries, "reason": reason])
            #expect(refused.isError && refused.text.contains("Nothing was archived") && refused.text.contains(says), "\(refused.text)")
            #expect(read(path) == both)
            #expect(!FileManager.default.fileExists(atPath: archivePath))
        }
        // A minute stamp (as docs/process/lead-rules.md names them) fits an entry stamped to the second, and both of a minute's.
        let minute = lead.call("archive_decisions", ["entries": ["2026-10-18 09:45"], "reason": "obsolete"])
        #expect(minute.isError && minute.text.contains("names 2 entries"), "\(minute.text)")
        #expect(read(path) == both)
        // Named by more of its heading, either one goes alone.
        #expect(!lead.call("archive_decisions", ["entries": ["2026-10-20 10:00 Keep it local, again"], "reason": "duplicate"]).isError)
        #expect(BoardStore(root: root).decisions().map(\.text).last == "Keep it local")
        let seconds = lead.call("archive_decisions", ["entries": ["2026-10-18 09:45 Keep the board"], "reason": "obsolete"])
        #expect(!seconds.isError && seconds.text.contains("“2026-10-18 09:45:41 Keep the board current”"), "\(seconds.text)")
        #expect(!(read(path) ?? "").contains("Keep the board current"))
    }

    @Test func onlyTheLeadArchives() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let text = try decisions(root)
        let worker = try issued(.worker, task: "t", root: root, runtime)
        #expect(!worker.tools.contains { $0.name == "archive_decisions" })
        let refused = worker.call("archive_decisions", ["entries": ["2026-10-17 12:15"], "reason": "obsolete"])
        #expect(refused.isError && refused.text.contains("No tool archive_decisions for the worker"), "\(refused.text)")
        #expect(read(root + "/docs/lead/decisions.md") == text)
        #expect(!FileManager.default.fileExists(atPath: root + "/docs/lead/decisions-archive.md"))
        let verifier = try issued(.verifier, task: "t", root: root, runtime)
        #expect(verifier.call("archive_decisions", ["entries": ["2026-10-17 12:15"], "reason": "obsolete"]).isError)
        // The archive is one of the lead's records, as decisions.md is: workers may not edit them, merges take the base's.
        #expect(LeadRecords.paths("docs/lead").contains("docs/lead/decisions-archive.md"))
        let denied = LeadLaunch.deny(.worker, base: "main", records: "docs/lead")
        for rule in ["Edit(docs/lead/**)", "Write(docs/lead/**)", "Bash(git add docs/lead*)"] { #expect(denied.contains(rule), "\(rule)") }
    }

    @Test func statusNudgesOnceAboveTheSizeAndIsSilentBelow() throws {
        let entry = { (index: Int) in String(format: "## 2026-10-17 %02d:%02d Decision %d\n\nBecause.\n\n", index / 60, index % 60, index) }
        let says = "archive_decisions the superseded"
        // At the size: silent.
        let root = try repo()
        let runtime = FakeRuntime()
        try BoardStore(root: root).replaceRecord("decisions.md", with: "# Decisions\n\n" + (0..<LeadRecords.archiveEntries).map(entry).joined())
        let leader = try lead(root, runtime)
        #expect(!leader.call("status", [:]).text.contains(says))
        // Past it, in entries: one line, naming the rules' inventory when the repository has it.
        try FileManager.default.createDirectory(atPath: root + "/docs/process", withIntermediateDirectories: true)
        try "# Rules\n".write(toFile: root + "/docs/process/lead-rules.md", atomically: true, encoding: .utf8)
        try BoardStore(root: root).replaceRecord("decisions.md", with: "# Decisions\n\n" + (0...LeadRecords.archiveEntries).map(entry).joined())
        let status = leader.call("status", [:]).text
        let lines = status.components(separatedBy: "\n").filter { $0.contains(says) }
        #expect(lines.count == 1, "\(status)")
        #expect(lines.first?.contains("decisions.md has \(LeadRecords.archiveEntries + 1) entries") == true, "\(lines)")
        #expect(lines.first?.contains("docs/process/lead-rules.md lists them") == true, "\(lines)")
        // Once a lead start: the next status doesn't repeat it.
        #expect(!leader.call("status", [:]).text.contains(says))

        // Past it in size alone (a few long entries): a new lead's status says it.
        let long = String(repeating: "word ", count: 2_000)
        let other = try repo("long")
        try BoardStore(root: other).replaceRecord("decisions.md", with: "# Decisions\n\n" + (0..<5).map { entry($0) + long + "\n\n" }.joined())
        let next = try lead(other, FakeRuntime())
        #expect(next.call("status", [:]).text.contains("decisions.md has 5 entries"))
        #expect(LeadRecords.archiveNudge(entries: 5, bytes: LeadRecords.archiveBytes, rules: nil) == nil)
        #expect(LeadRecords.archiveNudge(entries: 5, bytes: LeadRecords.archiveBytes + 1, rules: nil)?.contains("lists them") == false)
    }

    @Test func theBriefSaysWhenToArchive() {
        let brief = LeadPrompts.lead(project: "p", root: "/p", workflow: LeadWorkflow())
        #expect(brief.contains("archive_decisions the entries that are superseded, obsolete or now enforced by a check (docs/process/lead-rules.md"))
        #expect(LeadPrompts.tools.contains("archive_decisions"))
    }
}
