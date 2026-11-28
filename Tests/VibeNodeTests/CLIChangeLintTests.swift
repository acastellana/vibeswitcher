import Foundation
import Testing
@testable import VibeNode

/// One path for a state change in the command line (the architecture review's row 5, 2026-11-22): a state change goes
/// out only through `NodeClient.change`, which takes the token only `TypedWord.said` makes and writes the request's
/// journal entry itself. This keeps the command line's files to it: no journal entry written elsewhere (but a
/// `VibeNode` sequence's own, through its `journal` step, and `status --ack`'s), no state-changing kind sent as a plain
/// `request`, and no read sent through `change`.
@Suite struct CLIChangeLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let cli = "Sources/vibeswitcher-cli"

    /// The journal writes allowed outside `NodeClient.swift`, each a line's text (trimmed) and the file it is in: the
    /// start and stop sequences' own entries (`not-promised-ack`, the fallback's `stop`), asked through their `typed`
    /// step, and `status --ack`'s acknowledgement, which is no request.
    static let allowedJournal: Set<String> = [
        "Start.swift: journal: { context.writeJournal($0) },",
        "Stop.swift: journal: { context.writeJournal($0) },",
        "Status.swift: guard context.writeJournal(JournalAck.entry(action: action)) else {",
    ]

    static func sources() throws -> [(name: String, text: String)] {
        let folder = repo.appendingPathComponent(cli)
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }.sorted().map {
            ($0, try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8))
        }
    }

    /// What breaks the rule in `text` (a file named `name`).
    static func problems(_ name: String, _ text: String) throws -> [String] {
        var found: [String] = []
        let sent = try Regex(#"\.(request|change)\("([^"]+)""#)
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("///") || trimmed.hasPrefix("//") { continue }
            let at = "\(name):\(number + 1)"
            if name != "NodeClient.swift", trimmed.contains("writeJournal("), !allowedJournal.contains("\(name): \(trimmed)") {
                found.append("\(at): a journal entry written outside NodeClient.change: \(trimmed)")
            }
            for match in String(line).matches(of: sent) {
                guard let how = match.output[1].substring, let kind = match.output[2].substring.map(String.init) else { continue }
                let changes = NodeWire.changesState(kind) || Requests.recorded.contains(kind)
                if how == "request", changes { found.append("\(at): \(kind) changes state, sent without the typed code (use NodeClient.change)") }
                if how == "change", !changes { found.append("\(at): \(kind) changes nothing, sent through change (use request)") }
            }
        }
        return found
    }

    @Test func aStateChangeGoesOnlyThroughChange() throws {
        let files = try Self.sources()
        #expect(files.count > 20)
        let found = try files.flatMap { try Self.problems($0.name, $0.text) }
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
        // Every state change the command line sends goes through `change` somewhere.
        let changes = files.reduce(0) { $0 + $1.text.components(separatedBy: ".change(").count - 1 }
        #expect(changes >= 14, "\(changes)")
    }

    /// The lint fires on each thing it forbids.
    @Test func theLintFindsEachBreak() throws {
        let fixture = """
        context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: "tell", epoch: epoch))
        switch client.request("tell", args: args) {
        switch client.change("status", action: action, typed: typed) {
        switch client.request("status") {
        /// client.request("stop") in a comment is no call
        """
        let found = try Self.problems("Tell.swift", fixture)
        #expect(found.count == 3, Comment(rawValue: found.joined(separator: "\n")))
        #expect(try Self.problems("Start.swift", "            journal: { context.writeJournal($0) },").isEmpty)
    }
}
