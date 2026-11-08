import Foundation
import Testing
@testable import VibeCore

/// The product inventory (backlog A5): `scripts/product-inventory.sh` on this repository lists what VibeSwitcher already
/// does, the same bytes each time; and the lead's records commit after a merge makes it again from the merged code
/// when what it's made from changed, never failing on it. The merge tests use temporary repositories and a stand-in
/// script.
@Suite(.serialized)
struct ProductInventoryTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path

    // MARK: The script, on this repository

    func inventory() -> String {
        let run = Shell.run(executable: "/bin/bash", args: [Self.repository + "/" + ProductInventory.script], in: Self.repository)
        #expect(run.ok, "\(run.error)")
        return run.output
    }

    @Test func theScriptListsWhatTheAppDoesTheSameEachTime() throws {
        let text = inventory()
        #expect(text == inventory(), "two runs on the same code differ")
        let menu = "`Sources/VibeSwitcher/MainWindow/MainMenu.swift`"
        for line in ["- Edit › Find › Find… ⌘F — \(menu)", "- Session › Export Chat… ⇧⌘E — \(menu)",
                     "- View › Focus Terminal ⇧⌘↩ — \(menu)", "- File › End Session… ⇧⌘⌫ — \(menu)",
                     "- Chat: Copy as Markdown — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`"] {
            #expect(text.contains(line + "\n"), "missing: \(line)")
        }
        // The chat's and the terminal's features the lead once proposed anew, each with its file.
        for feature in ["- Search the conversation", "- Export Chat…", "- Latest button", "- Code block header: the language, Copy",
                        "- Code block Run", "- Tool calls folded into groups", "- Selection survives output", "- Option-drag selects"] {
            #expect(text.split(separator: "\n").contains { $0.hasPrefix(feature) && $0.hasSuffix(".swift`") }, "missing: \(feature)")
        }
        // Every menu bar item in MainMenu.swift, and every Settings tab, by name.
        let source = try String(contentsOfFile: Self.repository + "/Sources/VibeSwitcher/MainWindow/MainMenu.swift", encoding: .utf8)
        let titles = source.matches(of: #/item\("([^"]+)"/#).map { String($0.output.1) }.filter { $0 != "Services" && !$0.hasPrefix("Session ") }
        #expect(titles.count > 40)
        for title in titles { #expect(text.contains(" › \(title)"), "menu item \(title) missing") }
        for tab in ["General", "Agents", "Phone", "Launch", "Terminal", "Wallet"] { #expect(text.contains("\n### \(tab)\n- Settings › \(tab) tab")) }
        #expect(text.contains("\n## Sandbox (`scripts/sandbox-app.sh`)\n") && text.contains("- `sheet NAME`"))
        // Each entry names its source file, and every curated feature's code was found.
        let entries = text.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(entries.count > 200)
        for entry in entries { #expect(entry.contains(" — `Sources/VibeSwitcher/") && entry.hasSuffix(".swift`"), "\(entry)") }
        #expect(!text.contains("not found"))
    }

    @Test func theScriptSaysWhatItReads() throws {
        let run = Shell.run(executable: "/bin/bash", args: [Self.repository + "/" + ProductInventory.script, "--inputs"], in: Self.repository)
        #expect(run.output == "Sources/VibeSwitcher")
        let text = try String(contentsOfFile: Self.repository + "/" + ProductInventory.script, encoding: .utf8)
        #expect(text.contains("\n# inputs: Sources/VibeSwitcher\n"))
    }

    // MARK: Made again with the records after a merge

    /// A repository whose stand-in script lists `src`'s files, appending a line to `runs` each time it runs (`fail`:
    /// it fails instead).
    func repo(fail: Bool = false) throws -> (root: String, runs: String) {
        let url = temp.url("inventory")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        let runs = temp.url("runs.txt").path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/src/a.txt", atomically: true, encoding: .utf8)
        try "other\n".write(toFile: root + "/c.txt", atomically: true, encoding: .utf8)
        let script = """
        #!/bin/bash
        # inputs: src
        set -euo pipefail
        echo run >> \(RecentProjects.shellQuote(runs))
        \(fail ? "exit 1" : "")
        [[ $1 == --root && $3 == --write ]]
        mkdir -p "$2/docs/process"
        { echo "# Inventory"; ls "$2/src" | LC_ALL=C sort; } > "$2/\(ProductInventory.output)"

        """
        try script.write(toFile: root + "/" + ProductInventory.script, atomically: true, encoding: .utf8)
        Git.run(["add", "-A"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return (root, runs)
    }

    func runs(_ path: String) -> Int {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func files(of commit: String, _ root: String) -> [String] {
        Git.run(["diff-tree", "--no-commit-id", "--name-only", "-r", commit], in: root).output.split(separator: "\n").map(String.init).sorted()
    }

    /// `slug`'s worker adds `file`, and its audit is clean: ready to merge.
    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, slug: String, file: String) throws {
        _ = lead.call("add_task", ["title": slug, "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": slug])
        let worktree = Worktrees.path(root: root, slug: slug)
        try "\(slug)\n".write(toFile: worktree + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: worktree)
        Git.run(["commit", "-q", "-m", "add \(file)"], in: worktree)
        _ = try seat("worker-\(slug)", runtime).call("report", doneReport("added"))
        _ = lead.call("audit", ["task": slug])
        _ = try seat("verify-\(slug)", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked"])
    }

    func merge(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, slug: String, file: String) throws {
        try audited(lead, runtime, root: root, slug: slug, file: file)
        let merged = lead.call("merge", ["task": slug])
        #expect(!merged.isError, "\(merged.text)")
        _ = lead.call("cleanup", ["task": slug])
    }

    @Test func aMergeThatChangesTheCodeCommitsTheInventoryWithTheRecords() throws {
        let (root, runsFile) = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try merge(lead, runtime, root: root, slug: "add-b", file: "src/b.txt")
        let records = Git.run(["rev-parse", "main"], in: root).output
        #expect(Git.run(["log", "-1", "--format=%s", records], in: root).output == LeadRecords.subject)
        #expect(files(of: records, root) == ["docs/lead/progress.md", ProductInventory.output])
        #expect(Git.run(["log", "-1", "--format=%B", records], in: root).output == LeadRecords.message("docs/lead", inventory: true))
        // Made from the merged code, and the checkout holds what was committed.
        #expect(Git.run(["show", "main:\(ProductInventory.output)"], in: root).output == "# Inventory\na.txt\nb.txt")
        let status = Git.run(["status", "--porcelain", "--", "docs"], in: root).output
        #expect(status.isEmpty, "\(status)")
        #expect(vault.head(root: root, branch: "main") == records)
        #expect(runs(runsFile) == 1)

        // Records alone, and a merge outside the inputs: the script isn't run again, and nothing else goes in.
        #expect(!lead.call("record_decision", ["decision": "Keep src small", "why": "test"]).isError)
        guard case .committed(let next) = lead.records.flush(base: "main") else { Issue.record("not committed"); return }
        #expect(files(of: next, root) == ["docs/lead/decisions.md"])
        try merge(lead, runtime, root: root, slug: "add-d", file: "d.txt")
        #expect(files(of: Git.run(["rev-parse", "main"], in: root).output, root) == ["docs/lead/progress.md"])
        #expect(runs(runsFile) == 1)

        // Another change to the code: made again, with that merge's records.
        try merge(lead, runtime, root: root, slug: "add-e", file: "src/e.txt")
        let shown = Git.run(["show", "main:\(ProductInventory.output)"], in: root).output
        #expect(shown == "# Inventory\na.txt\nb.txt\ne.txt", "\(shown)")
        #expect(files(of: Git.run(["rev-parse", "main"], in: root).output, root) == ["docs/lead/progress.md", ProductInventory.output])
        #expect(runs(runsFile) == 2)
    }

    @Test func aFailingScriptNeverStopsAMergeOrItsRecords() throws {
        let (root, runsFile) = try repo(fail: true)
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try merge(lead, runtime, root: root, slug: "add-b", file: "src/b.txt")
        let records = Git.run(["rev-parse", "main"], in: root).output
        #expect(Git.run(["log", "-1", "--format=%s", records], in: root).output == LeadRecords.subject)
        #expect(files(of: records, root) == ["docs/lead/progress.md"])
        #expect(Git.run(["show", "main:src/b.txt"], in: root).output == "add-b")
        #expect(!FileManager.default.fileExists(atPath: root + "/" + ProductInventory.output))
        // Not run again for the same code at the next flush.
        #expect(!lead.call("record_decision", ["decision": "One", "why": "test"]).isError)
        #expect(lead.records.flush(base: "main") != .unchanged)
        #expect(runs(runsFile) == 1)
    }

    @Test func theUsersOwnEditOfTheInventoryStays() throws {
        let (root, _) = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try merge(lead, runtime, root: root, slug: "add-b", file: "src/b.txt")
        let path = root + "/" + ProductInventory.output
        try "# Mine\n".write(toFile: path, atomically: true, encoding: .utf8)
        try merge(lead, runtime, root: root, slug: "add-e", file: "src/e.txt")
        #expect(files(of: Git.run(["rev-parse", "main"], in: root).output, root) == ["docs/lead/progress.md"])
        #expect((try? String(contentsOfFile: path, encoding: .utf8)) == "# Mine\n")
        #expect(Git.run(["show", "main:\(ProductInventory.output)"], in: root).output == "# Inventory\na.txt\nb.txt")
    }
}
