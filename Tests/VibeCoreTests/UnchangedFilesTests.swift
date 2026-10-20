import Foundation
import Testing
@testable import VibeCore

/// A transcript's end is parsed again only once the file changed (`UnchangedFiles`): the witness looks at every team
/// member's every 3 s, and most haven't written since. What it says is always what the file says now: an append, a
/// rewrite in place or one renamed over it is read.
struct UnchangedFilesTests {
    let scratch = Scratch()

    static let call = """
    {"isSidechain":false,"type":"assistant","timestamp":"2026-10-17T15:00:00Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}

    """
    static let interrupted = """
    {"isSidechain":false,"type":"user","timestamp":"2026-10-17T15:00:09Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}

    """

    @Test func aTranscriptIsParsedAgainOnlyOnceItChanged() throws {
        let url = scratch.url("transcript")
        try Data(Self.call.utf8).write(to: url)
        let reads = TranscriptTail.tails.reads
        #expect(TranscriptTail.read(url: url)?.state == .toolCall)
        #expect(TranscriptTail.read(url: url)?.state == .toolCall)
        #expect(TranscriptTail.tails.reads == reads + 1)
        // Appended: read again, and it says what the file says now.
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(Self.interrupted.utf8))
        try handle.close()
        #expect(TranscriptTail.read(url: url)?.state == .turnOver(apiError: nil))
        #expect(TranscriptTail.tails.reads == reads + 2)
        // Replaced by another file (a rename over it): read again.
        let other = scratch.url("transcript-new")
        try Data(Self.call.utf8).write(to: other)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: other)
        #expect(TranscriptTail.read(url: url)?.state == .toolCall)
        #expect(TranscriptTail.tails.reads == reads + 3)
    }

    @Test func itsProgressToo() throws {
        let url = scratch.url("progress")
        try Data(Self.call.utf8).write(to: url)
        let reads = TranscriptProgress.mains.reads
        let first = TranscriptProgress.read(url: url)
        #expect(first?.lastWritten == ISO8601DateFormatter().date(from: "2026-10-17T15:00:00Z")?.timeIntervalSince1970)
        #expect(TranscriptProgress.read(url: url) == first)
        #expect(TranscriptProgress.mains.reads == reads + 1)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(Self.interrupted.utf8))
        try handle.close()
        #expect(TranscriptProgress.read(url: url)?.lastWritten == ISO8601DateFormatter().date(from: "2026-10-17T15:00:09Z")?.timeIntervalSince1970)
        #expect(TranscriptProgress.mains.reads == reads + 2)
    }

    /// The same size and the same inode, rewritten in place: its modification time tells.
    @Test func aRewriteOfTheSameSizeIsReadAgain() throws {
        let cache = UnchangedFiles<String>()
        let url = scratch.url("same-size")
        try Data("aaaa".utf8).write(to: url)
        let read = { String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self) }
        #expect(cache.value(at: url.path, read: read) == "aaaa")
        let handle = try FileHandle(forWritingTo: url)
        handle.write(Data("bbbb".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(cache.value(at: url.path, read: read) == "bbbb")
        #expect(cache.value(at: url.path, read: read) == "bbbb")
        #expect(cache.reads == 2)
        // A file that isn't there is asked each time.
        #expect(cache.value(at: url.path + "-gone", read: { "none" }) == "none")
        #expect(cache.reads == 2)
    }

    /// The witness's line split is `split(separator:)`'s, empty lines left out, on a slice too (a tail starts mid-file).
    @Test func linesAreSplitAsSplitDoes() {
        let cases = ["", "\n", "a", "a\n", "\n\na\n\nbb\n", "a\nb", "first\nsecond\nthird", "\n\n\n"]
        for text in cases {
            let data = Data(text.utf8)
            #expect(TranscriptReader.lines(data) == data.split(separator: 0x0A), "\(text.debugDescription)")
            let padded = Data(("xx\n" + text).utf8)
            let slice = padded[(padded.startIndex + 3)...]
            #expect(TranscriptReader.lines(slice) == slice.split(separator: 0x0A), "a slice of \(text.debugDescription)")
            #expect(TranscriptReader.lines(slice).map(\.startIndex) == slice.split(separator: 0x0A).map(\.startIndex))
        }
    }
}
