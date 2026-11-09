import Foundation
import Testing

/// scripts/verifier-eval.sh's two offline parts on made-up files, no model and no clone: `--summary FOLDER` sums an
/// --all run's score.json files, `--score FOLDER CASE` scores a case folder's stream.jsonl. A run that ended with an
/// error gets no score: it's in no total and the summary exits 2, as for a case that couldn't run.
struct VerifierEvalScriptTests {
    static let repo = KeychainLintTests.repo
    static let script = repo.appendingPathComponent("scripts/verifier-eval.sh")
    let temp = Scratch()

    func eval(_ arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // The run read to its end and waited for on a thread of its own, not the cooperative pool.
        let output = await offPool { () -> String in
            let read = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            waitForEnd(process)
            return read
        }
        return (process.terminationStatus, output)
    }

    /// The script's cases as (name, clean), from its `cases` block.
    static func cases() throws -> [(name: String, clean: Bool)] {
        try String(contentsOf: script, encoding: .utf8).split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ")
            guard words.count > 3, words[1].count == 40, words[1].allSatisfy(\.isHexDigit) else { return nil }
            return (String(words[0]), words[2] == "expect-no-Important")
        }
    }

    /// An --all run's folder where every bug case found its one bug and every clean case is clean, at 1000 tokens,
    /// $1 and 1 minute a case; `change` edits a case's score.
    func runFolder(_ change: (String, inout [String: Any]) -> Void = { _, _ in }) throws -> URL {
        let run = temp.url("all-auto")
        for (name, clean) in try Self.cases() {
            var score: [String: Any] = ["name": name, "kind": clean ? "clean" : "bug", "expected": clean ? 0 : 1, "found": clean ? 0 : 1,
                                        "found_important": clean ? 0 : 1, "important": 0, "findings": 1, "tokens": 1000, "cost": 1.0,
                                        "minutes": 1.0, "error": false, "denials": 0, "claude_version": "2.1.319"]
            change(name, &score)
            let folder = run.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: score).write(to: folder.appendingPathComponent("score.json"))
        }
        return run
    }

    @Test func aRunThatErroredIsNotScored() async throws {
        let cases = try Self.cases()
        let bugs = cases.filter { !$0.clean }.count, cleans = cases.count - bugs
        let run = try runFolder { name, score in
            guard ["the-phone-shows-needs", "steadier-merge-gate"].contains(name) else { return }
            // What an errored run could otherwise add: a false alarm, a miss, and its tokens, cost and minutes.
            score["error"] = true
            score["important"] = name == "the-phone-shows-needs" ? 3 : 0
            score["found"] = 0
            score["found_important"] = 0
            score["tokens"] = 5000
            score["cost"] = 20.0
            score["minutes"] = 30.0
        }
        let (status, output) = try await eval(["--summary", run.path])
        #expect(status == 2, "\(output)")
        #expect(output.contains("the-phone-shows-needs: not scored"), "\(output)")
        #expect(output.contains("steadier-merge-gate: not scored"), "\(output)")
        #expect(output.contains("bugs found: \(bugs - 1) of \(bugs - 1) (\(bugs - 1) as Important) in \(bugs - 1) bug cases"), "\(output)")
        #expect(output.contains("false alarms: 0 Important finding(s) on \(cleans - 1) clean cases"), "\(output)")
        let counted = cases.count - 2
        #expect(output.contains("tokens: \(counted * 1000); cost: $\(counted).00; \(counted) min"), "\(output)")
    }

    @Test func aRunWithoutErrorsStillExitsZero() async throws {
        let (status, output) = try await eval(["--summary", try runFolder().path])
        #expect(status == 0, "\(output)")
        #expect(!output.contains("not scored"), "\(output)")
    }

    @Test func theSummaryNamesTheVersionThatRan() async throws {
        let (_, known) = try await eval(["--summary", try runFolder().path])
        #expect(known.split(separator: "\n").first?.contains("Claude Code 2.1.319") == true, "\(known)")
    }

    @Test func theSummarySaysUnknownWithoutAVersion() async throws {
        let (_, unknown) = try await eval(["--summary", try runFolder { _, score in score["claude_version"] = nil }.path])
        #expect(unknown.split(separator: "\n").first?.contains("Claude Code unknown") == true, "\(unknown)")
    }

    @Test func theSummaryPrintsDenialsAndDoesNotRejectThem() async throws {
        let run = try runFolder { name, score in if name == "the-lead-s-rules" { score["denials"] = 4 } }
        let (status, output) = try await eval(["--summary", run.path])
        #expect(status == 0, "\(output)")
        #expect(output.contains("4 permission denial(s)"), "\(output)")
    }

    /// A case folder with `result` as its stream's last event, after an init event (no version: an older CLI).
    func caseFolder(result: [String: Any], version: String? = "2.1.319") throws -> URL {
        let folder = temp.url("case")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var initEvent: [String: Any] = ["type": "system", "subtype": "init"]
        initEvent["claude_code_version"] = version
        let events: [[String: Any]] = [initEvent, result.merging(["type": "result"]) { first, _ in first }]
        let text = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try (text + "\n").write(to: folder.appendingPathComponent("stream.jsonl"), atomically: true, encoding: .utf8)
        return folder
    }

    func score(_ folder: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent("score.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func anErroredCaseExitsTwoAsNotScored() async throws {
        let folder = try caseFolder(result: ["subtype": "error_max_budget_usd", "is_error": true, "total_cost_usd": 20.5,
                                             "terminal_reason": "budget_exhausted"])
        let (status, output) = try await eval(["--score", folder.path, "the-phone-shows-needs"])
        #expect(status == 2, "\(output)")
        #expect(output.contains("not scored"), "\(output)")
        #expect(output.contains("budget_exhausted"), "\(output)")
        #expect(!output.contains("no false alarm"), "\(output)")
        #expect(try score(folder)["error"] as? Bool == true)
    }

    @Test func anErrorSubtypeCountsEvenWithoutTheFlag() async throws {
        let folder = try caseFolder(result: ["subtype": "error_max_turns", "is_error": false, "total_cost_usd": 1.0])
        let (status, output) = try await eval(["--score", folder.path, "the-phone-shows-needs"])
        #expect(status == 2, "\(output)")
        #expect(try score(folder)["error"] as? Bool == true)
    }

    @Test func aCasePrintsItsDenialsAndIsNotRejectedForThem() async throws {
        let denials: [[String: Any]] = [["tool_name": "Edit"], ["tool_name": "Write"]]
        let folder = try caseFolder(result: ["subtype": "success", "is_error": false, "total_cost_usd": 1.0, "permission_denials": denials])
        let (status, output) = try await eval(["--score", folder.path, "the-phone-shows-needs"])
        #expect(status == 0, "\(output)")
        #expect(output.contains("permission denials: 2"), "\(output)")
        let saved = try score(folder)
        #expect(saved["denials"] as? Int == 2)
        #expect(saved["claude_version"] as? String == "2.1.319")
    }

    @Test func aCaseWithoutAnInitVersionSavesUnknown() async throws {
        let folder = try caseFolder(result: ["subtype": "success", "is_error": false, "total_cost_usd": 1.0], version: nil)
        let (status, output) = try await eval(["--score", folder.path, "the-phone-shows-needs"])
        #expect(status == 0, "\(output)")
        #expect(try score(folder)["claude_version"] as? String == "unknown")
    }
}
