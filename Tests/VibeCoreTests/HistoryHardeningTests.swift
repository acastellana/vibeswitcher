import Foundation
import Testing
@testable import VibeCore

/// Findings from the history review: symlinked agent folders, non-files named .jsonl, entries without
/// ids, pasted HTML prompts, and odd characters in the scrollback.
struct HistoryHardeningTests {
    func jsonl(_ objects: [[String: Any]]) -> Data {
        Data(objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }.joined().utf8)
    }

    func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vs-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func agentFoldersThatAreSymlinksStillWork() throws {
        // A dotfiles setup: ~/.claude is a link to a folder elsewhere.
        let home = try tempHome()
        let real = try tempHome()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: real) }
        let projects = real.appendingPathComponent("projects/p")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude"), withDestinationURL: real)
        let transcript = projects.appendingPathComponent("s.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let viaHome = home.appendingPathComponent(".claude/projects/p/s.jsonl").path
        #expect(TranscriptReader.checkedURL(viaHome, home: home.path)?.1 == .claude)
        // Still nothing outside the (resolved) folder.
        let outside = real.appendingPathComponent("secret.jsonl")
        try Data("{}\n".utf8).write(to: outside)
        #expect(TranscriptReader.checkedURL(outside.path, home: home.path) == nil)
    }

    @Test func onlyRegularFilesAreRead() throws {
        // A FIFO named .jsonl would block the reading queue forever.
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent(".claude/projects/p")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let fifo = projects.appendingPathComponent("pipe.jsonl")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(TranscriptReader.checkedURL(fifo.path, home: home.path) == nil)
    }

    @Test func entriesWithoutIdsGetTheSameIdOnEveryRead() {
        // Without a stable id, the phone can't tell a re-read entry from a new one.
        let lines: [[String: Any]] = [
            ["type": "user", "timestamp": "2026-10-03T10:00:00.000Z", "message": ["role": "user", "content": "No uuid here"]],
            ["timestamp": "2026-10-03T10:00:01.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "No id either"]]]],
        ]
        let first = TranscriptReader.read(jsonl([lines[0]]), format: .claude).entries
        let again = TranscriptReader.read(jsonl([lines[0]]), format: .claude).entries
        #expect(first.count == 1)
        #expect(first.map(\.id) == again.map(\.id))
        let codex1 = TranscriptReader.read(jsonl([lines[1]]), format: .codex).entries
        let codex2 = TranscriptReader.read(jsonl([lines[1]]), format: .codex).entries
        #expect(codex1.count == 1)
        #expect(codex1.map(\.id) == codex2.map(\.id))
        // Different lines, different ids.
        let other = TranscriptReader.read(jsonl([["type": "user", "timestamp": "2026-10-03T10:00:09.000Z",
                                                  "message": ["role": "user", "content": "Another"]]]), format: .claude).entries
        #expect(other.first?.id != first.first?.id)
    }

    @Test func pastedHtmlIsAPromptButInjectedContextIsNot() {
        let lines: [[String: Any]] = [
            ["type": "user", "uuid": "u1", "message": ["role": "user", "content": "<div class=\"card\">Why is this off-center?</div>"]],
            ["type": "user", "uuid": "u2", "message": ["role": "user", "content": "<!doctype html><html>…</html> fix the title"]],
            ["type": "user", "uuid": "u3", "message": ["role": "user", "content": "<task-notification>done</task-notification>"]],
            ["type": "user", "uuid": "u4", "message": ["role": "user", "content": "<command-name>/clear</command-name>"]],
            ["type": "user", "uuid": "u5", "message": ["role": "user", "content": "<system-reminder>x</system-reminder>"]],
        ]
        let prompts = TranscriptReader.read(jsonl(lines), format: .claude).entries.map(\.text)
        #expect(prompts == ["<div class=\"card\">Why is this off-center?</div>", "<!doctype html><html>…</html> fix the title"])
        let codex: [[String: Any]] = [
            ["type": "response_item", "payload": ["type": "message", "role": "user", "id": "m1",
                                                  "content": [["type": "input_text", "text": "<environment_context>cwd</environment_context>"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "id": "m2",
                                                  "content": [["type": "input_text", "text": "<user_instructions>be brief</user_instructions>"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "id": "m3",
                                                  "content": [["type": "input_text", "text": "<p>Make this bold</p>"]]]],
        ]
        #expect(TranscriptReader.read(jsonl(codex), format: .codex).entries.map(\.text) == ["<p>Make this bold</p>"])
    }

}

struct TranscriptChunkTests {
    let line1 = #"{"type":"user","uuid":"u1","message":{"role":"user","content":"one"}}"# + "\n"
    let line2 = #"{"type":"user","uuid":"u2","message":{"role":"user","content":"two"}}"# + "\n"
    let partial = #"{"type":"user","uuid":"u3","mess"#

    @Test func aFreshTailSkipsThePartialFirstLineAndEndsAtTheFileEnd() {
        let file = Data((line1 + line2).utf8)
        // Start inside line 1: it's cut, so only line 2 counts.
        let plan = TranscriptWindow.Plan(start: 10, fresh: true)
        let chunk = TranscriptWindow.chunk(file.subdata(in: 10..<file.count), plan: plan, fileSize: file.count, format: .claude)
        #expect(chunk.entries.map(\.text) == ["two"])
        #expect(chunk.cursor == file.count)
        #expect(!chunk.pending)
        #expect(chunk.truncatedBefore)
    }

    @Test func aContinuationStartsAtTheCursorAndWaitsForAHalfWrittenLine() {
        let file = Data((line1 + line2 + partial).utf8)
        let after = line1.utf8.count
        let plan = TranscriptWindow.Plan(start: after, fresh: false)
        let chunk = TranscriptWindow.chunk(file.subdata(in: after..<file.count), plan: plan, fileSize: file.count, format: .claude)
        #expect(chunk.entries.map(\.text) == ["two"])
        #expect(chunk.cursor == after + line2.utf8.count)
        #expect(chunk.pending)
        #expect(!chunk.truncatedBefore)
    }

    @Test func aFreshReadFromTheStartReadsEverything() {
        let file = Data((line1 + line2).utf8)
        let chunk = TranscriptWindow.chunk(file, plan: TranscriptWindow.Plan(start: 0, fresh: true), fileSize: file.count, format: .claude)
        #expect(chunk.entries.map(\.text) == ["one", "two"])
        #expect(chunk.cursor == file.count)
        #expect(!chunk.truncatedBefore)
    }
}
