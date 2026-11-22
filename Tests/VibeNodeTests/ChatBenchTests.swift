import Foundation
import Testing
@testable import VibeNode

/// The chat store on a big transcript (the architecture review's row 13): a synthetic one of screenshot-sized lines,
/// the process's resident memory once its chat is read, and the time each appended line costs the engine's queue.
/// Off unless `VIBESWITCHER_CHAT_BENCH` names the transcript's size in MB (a bench, not a check).
@Suite(.serialized, .enabled(if: ChatBench.megabytes > 0, "a bench: VIBESWITCHER_CHAT_BENCH=<MB>"))
struct ChatBenchTests {
    /// The process's resident memory, in MB (Linux's `/proc/self/status`; 0 elsewhere).
    static func residentMB() -> Double {
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
              let line = status.split(separator: "\n").first(where: { $0.hasPrefix("VmRSS:") }) else { return 0 }
        return (Double(line.split(separator: " ").dropFirst().first ?? "0") ?? 0) / 1024
    }

    @Test func aBigTranscriptsMemoryAndAppendCost() async throws {
        let world = try ChatWorld()
        let shot = ChatBench.screenshot(bytes: 700 * 1024)
        let target = ChatBench.megabytes << 20
        var written = 0, turn = 0
        let handle = try FileHandle(forWritingTo: world.transcript)
        while written < target {
            let lines = ChatBench.turn(turn, shot: shot)
            let data = Data(lines.map { $0 + "\n" }.joined().utf8)
            try handle.write(contentsOf: data)
            written += data.count
            turn += 1
        }
        try handle.close()
        let before = Self.residentMB()
        let opened = Date()
        let stream = try #require(world.queue.sync { world.stream })
        try #require(await eventually(timeout: 600) { world.queue.sync { stream.loaded } })
        let loadSeconds = Date().timeIntervalSince(opened)
        let loaded = Self.residentMB()
        let items = world.queue.sync { stream.items.count }
        world.queue.sync {
            world.chats.resultsTaken = 0
            world.chats.resultsSeconds = 0
        }
        world.chats.readSeconds.set(0)
        // Appended lines, one at a time, each waited for in the stream: small replies, then screenshots.
        for (index, kind) in (Array(repeating: "reply", count: 30) + Array(repeating: "shot", count: 5)).enumerated() {
            let seq = world.queue.sync { stream.seq }
            let lines = kind == "reply" ? [ChatBench.reply("appended-\(index)", text: "an appended line \(index)")]
                : ChatBench.screenshotTurn("appended-\(index)", shot: shot)
            try world.append(lines)
            try #require(await eventually(timeout: 120) { world.queue.sync { stream.seq > seq } }, "append \(index) never reached the stream")
        }
        let (taken, seconds) = world.queue.sync { (world.chats.resultsTaken, world.chats.resultsSeconds) }
        let after = Self.residentMB()
        let readTime = world.chats.readSeconds.get()
        print(String(format: "CHATBENCH transcript %d MB, %d turns, %d items held; load %.1f s; resident %.0f MB before, %.0f MB loaded (+%.0f), %.0f MB after appends; per appended read: engine queue %.2f ms, the read off it %.1f ms (%d reads)",
                     written >> 20, turn, items, loadSeconds, before, loaded, loaded - before, after, taken > 0 ? seconds / Double(taken) * 1000 : 0,
                     taken > 0 ? readTime / Double(taken) * 1000 : 0, taken))
        world.chats.stop()
    }
}

/// The bench's transcript lines (Claude Code's format).
enum ChatBench {
    static let megabytes = Int(ProcessInfo.processInfo.environment["VIBESWITCHER_CHAT_BENCH"] ?? "") ?? 0
    /// Small tool calls (each with a reply) a turn holds beside its screenshot.
    static let smallPerTurn = Int(ProcessInfo.processInfo.environment["VIBESWITCHER_CHAT_BENCH_SMALL"] ?? "") ?? 0

    /// A PNG's signature and `bytes` more, base64.
    static func screenshot(bytes: Int) -> String {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        return data.base64EncodedString()
    }

    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static let at = "2026-11-22T10:00:00.000Z"

    static func reply(_ id: String, text: String) -> String {
        line(["type": "assistant", "uuid": id, "timestamp": at, "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    static func screenshotTurn(_ id: String, shot: String) -> [String] {
        [line(["type": "assistant", "uuid": id + "-call", "timestamp": at,
               "message": ["role": "assistant", "content": [["type": "tool_use", "id": "tool-" + id, "name": "Read", "input": ["file_path": "/work/shot-\(id).png"]]]]]),
         line(["type": "user", "uuid": id + "-result", "timestamp": at,
               "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tool-" + id,
                                                        "content": [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": shot]]]]]]])]
    }

    /// A small tool call and its text result, and a reply after it.
    static func smallTool(_ id: String) -> [String] {
        [line(["type": "assistant", "uuid": id + "-call", "timestamp": at,
               "message": ["role": "assistant", "content": [["type": "tool_use", "id": "tool-" + id, "name": "Bash", "input": ["command": "ls -la src/\(id)"]]]]]),
         line(["type": "user", "uuid": id + "-result", "timestamp": at,
               "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tool-" + id, "content": String(repeating: "file.swift\n", count: 20)]]]]),
         reply(id + "-said", text: "Listed \(id); on to the next.")]
    }

    static func turn(_ index: Int, shot: String) -> [String] {
        [line(["type": "user", "uuid": "prompt-\(index)", "timestamp": at, "message": ["role": "user", "content": "look at screen \(index)"]])]
            + (0..<ChatBench.smallPerTurn).flatMap { smallTool("t\(index)-\($0)") }
            + screenshotTurn("turn-\(index)", shot: shot)
            + [reply("reply-\(index)", text: "Screen \(index) shows the board; the next step is \(index + 1).")]
    }
}
