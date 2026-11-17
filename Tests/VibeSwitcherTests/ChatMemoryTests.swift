import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import VibeCore
@testable import VibeSwitcher

/// The chat's memory peaks (2026-11-17, the app's largest one-minute footprint steps): an image-heavy chat opened while
/// its reply streams in, and a long chat (460 entries) loaded. The chat bench (`--chat-bench` with
/// VIBESWITCHER_BENCH_MEMORY, see `ChatBench.MemoryProbe`) in a process of its own on a scratch home, on a made-up
/// transcript: how far the footprint and malloc's bytes in use rise from just before the open, sampled every 10 ms.
/// Benches (`Tag.perf`): run by `scripts/test.sh --perf --filter ChatMemoryTests`.
@Suite(.serialized, .tags(.perf), .enabled(if: perfRun, perfOnly))
struct ChatMemoryTests {
    let scratch = Scratch()

    /// Screenshot-sized PNGs (retina, 2880x1800), each about 1 MB: blocks of colour and some noise, as a UI screenshot
    /// compresses.
    static func screenshot(seed: Int, width: Int = 2880, height: Int = 1800) -> Data {
        var generator = SeededGenerator(seed: UInt64(seed + 1))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<300 {
            context.setFillColor(CGColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                         blue: .random(in: 0...1, using: &generator), alpha: 1))
            context.fill(CGRect(x: .random(in: 0..<width, using: &generator), y: .random(in: 0..<height, using: &generator),
                                width: .random(in: 20...600, using: &generator), height: .random(in: 10...200, using: &generator)))
        }
        // Noise in a band (photos, gradients, antialiased text): what makes a screenshot's PNG a megabyte.
        if let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            let rows = height / 12, start = (seed * 97) % (height - rows)
            for row in start..<(start + rows) {
                for byte in 0..<(width * 4) where byte % 4 != 3 { pixels[row * context.bytesPerRow + byte] = .random(in: 0...255, using: &generator) }
            }
        }
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state ^ (state >> 33)
        }
    }

    static func line(_ type: String, _ uuid: String, _ content: Any) -> String {
        let line: [String: Any] = ["type": type, "uuid": uuid, "timestamp": "2026-11-17T08:00:00.000Z", "sessionId": "memory-fixture",
                                   "message": ["role": type, "content": content]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self)
    }

    /// An image-heavy chat: `exchanges` prompts, each with two screenshots attached from the composer (files, quoted
    /// paths: 20 different ones), a tool run and a reply; the last few have a screenshot pasted into the prompt or
    /// returned by a tool (in the transcript, base64).
    static func imageChat(in folder: URL, exchanges: Int = 40) throws -> String {
        let images = folder.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let files = try (0..<20).map { index -> String in
            let url = images.appendingPathComponent("pasted-\(index).png")
            try screenshot(seed: index).write(to: url)
            return url.path
        }
        var lines: [String] = []
        for step in 0..<exchanges {
            let attached = "'\(files[(2 * step) % files.count])' '\(files[(2 * step + 1) % files.count])'"
            let inline = step >= exchanges - 3
            if inline {
                let pasted = screenshot(seed: 100 + step, width: 1440, height: 900).base64EncodedString()
                lines.append(line("user", "u\(step)", [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": pasted]],
                                                       ["type": "text", "text": "Step \(step): \(attached) the panel looks off here, fix it."]]))
            } else {
                lines.append(line("user", "u\(step)", "Step \(step): \(attached) the panel looks off here, fix it."))
            }
            lines.append(line("assistant", "t\(step)", [["type": "tool_use", "id": "toolu_shot\(step)", "name": "mcp__browser__screenshot", "input": [:]]]))
            var result: [[String: Any]] = [["type": "text", "text": "Took a screenshot."]]
            if inline {
                result.append(["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                                           "data": screenshot(seed: 200 + step, width: 1440, height: 900).base64EncodedString()]])
            }
            lines.append(line("user", "r\(step)", [["type": "tool_result", "tool_use_id": "toolu_shot\(step)", "content": result]]))
            lines.append(line("assistant", "a\(step)", [["type": "text", "text": "Step \(step) done: the header keeps its height and the list "
                + "scrolls under it.\n\n- `Panel.swift`: the inset\n- nothing else moved\n\n```swift\npanel.inset = 12\n```"]]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A long chat: `entries` entries of prompts, tool runs and replies of a few paragraphs (a lead's working day).
    static func longChat(entries: Int = 460) -> String {
        var lines: [String] = []
        var step = 0
        // A prompt, a tool run (its result in it) and a reply a step.
        while step * 3 < entries {
            lines.append(line("user", "u\(step)", "Step \(step): check the widget module and tell me what changed, then run the tests."))
            lines.append(line("assistant", "t\(step)", [["type": "tool_use", "id": "toolu_\(step)", "name": "Bash",
                                                        "input": ["command": "swift test --filter Widget\(step)", "description": "Run tests"]]]))
            lines.append(line("user", "r\(step)", [["type": "tool_result", "tool_use_id": "toolu_\(step)",
                                                    "content": (0..<40).map { "Test Case 'Widget\(step)Tests.test\($0)' passed (0.0\($0 % 10) seconds)." }.joined(separator: "\n")]]))
            lines.append(line("assistant", "a\(step)", [["type": "text", "text": (0..<4).map { paragraph in
                "Step \(step), part \(paragraph): the parser reads each line once and keeps a cursor so the next read starts where this one "
                    + "ended; **nothing else** moved, and `Widget\(step).swift` has 3 uses.\n\n- one\n- two\n\n```swift\nlet widget = Widget(id: \(step))\n```"
            }.joined(separator: "\n\n")]]))
            step += 1
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Runs the bench on `transcript` in a scratch home with `settings`; the footprint's and malloc's before, peak and end.
    func bench(_ transcript: String, _ settings: [String: String], name: String) async throws
        -> (status: Int32, output: String, footprint: [Double], malloc: [Double]) {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        let home = scratch.url("chat-memory")
        let projects = home.appendingPathComponent(".claude/projects/bench")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let path = projects.appendingPathComponent("\(name).jsonl")
        try transcript.write(to: path, atomically: true, encoding: .utf8)
        let output = scratch.url("chat-memory-output")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = app
        process.arguments = ["--chat-bench", path.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["VIBESWITCHER_HOME"] = nil
        environment["VIBESWITCHER_BENCH_MEMORY"] = "1"
        environment["VIBESWITCHER_BENCH_LAYERS"] = "1"
        for (key, value) in settings { environment[key] = value }
        process.environment = environment
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if await offPool({ ended.wait(timeout: .now() + hangGuard) }) == .timedOut {
            process.terminate()
            Issue.record("the bench hung")
            return (-1, (try? String(contentsOf: output, encoding: .utf8)) ?? "", [], [])
        }
        let text = try String(contentsOf: output, encoding: .utf8)
        let results = FootprintBenchTests.results(text)
        return (process.terminationStatus, text, (results["chat-memory-footprint-mb"] ?? []).compactMap(Double.init),
                (results["chat-memory-malloc-mb"] ?? []).compactMap(Double.init))
    }

    /// The top peak: an image-heavy chat opened while its reply streams in (two lines a second), left alone.
    @Test
    func anImageHeavyChatOpenedWhileItsReplyStreamsStaysSmall() async throws {
        let transcript = try Self.imageChat(in: scratch.url("images"))
        let run = try await bench(transcript, ["VIBESWITCHER_BENCH_STREAM": "2", "VIBESWITCHER_BENCH_SECONDS": "12",
                                               "VIBESWITCHER_BENCH_SIZE": "1020x748"], name: "image-chat")
        print("image-heavy chat, streaming: status \(run.status)\n\(run.output)")
        try #require(run.footprint.count == 3 && run.malloc.count == 3, "\(run.output)")
        // Every entry shown and the streamed ones added (40 exchanges of 3 entries; the stream's lines after them).
        #expect((Self.entries(run.output) ?? 0) > 120, "\(run.output)")
        let footprint = run.footprint[1] - run.footprint[0], malloc = run.malloc[1] - run.malloc[0]
        print("image-heavy chat, streaming: footprint +\(footprint) MB, malloc +\(malloc) MB at the peak")
        #expect(footprint < Self.imageFootprintLimit, "footprint rose \(footprint) MB")
        #expect(malloc < Self.imageMallocLimit, "malloc rose \(malloc) MB")
    }

    /// A long chat (460 entries) loaded.
    @Test
    func aLongChatsLoadStaysSmall() async throws {
        let run = try await bench(Self.longChat(), ["VIBESWITCHER_BENCH_SECONDS": "8", "VIBESWITCHER_BENCH_SIZE": "1020x748",
                                                    "VIBESWITCHER_BENCH_OPEN": "bottom"], name: "long-chat")
        print("long chat: status \(run.status)\n\(run.output)")
        try #require(run.footprint.count == 3 && run.malloc.count == 3, "\(run.output)")
        #expect((Self.entries(run.output) ?? 0) >= 460, "\(run.output)")
        let footprint = run.footprint[1] - run.footprint[0], malloc = run.malloc[1] - run.malloc[0]
        print("long chat: footprint +\(footprint) MB, malloc +\(malloc) MB at the peak")
        #expect(footprint < Self.longFootprintLimit, "footprint rose \(footprint) MB")
        #expect(malloc < Self.longMallocLimit, "malloc rose \(malloc) MB")
    }

    /// A reply streaming into a shown chat: what the heap grew by per streamed line, of the classes that grew about 85
    /// blocks a streamed cycle in the app (NSKeyValueDependency, __NSMallocBlock__; counted by `HeapCensus`, in-process).
    @Test
    func streamedLinesLeaveNoObservationsBehind() async throws {
        let run = try await bench(Self.longChat(entries: 120), ["VIBESWITCHER_BENCH_STREAM": "3", "VIBESWITCHER_BENCH_SECONDS": "20",
                                                                 "VIBESWITCHER_BENCH_SIZE": "1020x748", "VIBESWITCHER_BENCH_CENSUS": "1"],
                                  name: "stream-chat")
        print("streamed chat: status \(run.status)\n\(run.output)")
        let perLine = FootprintBenchTests.results(run.output)["chat-stream-watched-blocks-per-line"]?.first.flatMap(Double.init)
        try #require(perLine != nil, "\(run.output)")
        print("streamed chat: \(perLine!) watched blocks a streamed line")
        // The chat's own streaming doesn't make them (2026-11-17: -73.5 a line, the open's own going): the app's growth
        // is elsewhere. Kept so it stays so.
        #expect(perLine! < 1, "\(perLine!) a streamed line")
    }

    /// How far the footprint may rise at the peak (MB). About 110 MB of it is the system's drawing memory for a window
    /// redraw (the graphics ledger: there a moment after each redraw, gone a second later), the same for any content.
    /// Drawn from the files at full size, the image-heavy chat's attachments took a gigabyte (+1012 MB, 2026-11-17);
    /// decoded at their size on screen, +178.
    static let imageFootprintLimit = 300.0
    /// Malloc's bytes in use at the peak: the transcript's 4 MB tail read and parsed, its screenshots decoded for their
    /// thumbnails (each whole first: 20 MB a screenshot). +81 MB with the files drawn at full size, +51 with thumbnails
    /// decoded a core each at once, +33 two at a time (`ImageCache`).
    static let imageMallocLimit = 60.0
    /// The long chat: +184 MB (110 of it the redraw's), malloc +25.
    static let longFootprintLimit = 300.0
    static let longMallocLimit = 60.0

    static func entries(_ output: String) -> Int? {
        output.split(separator: "\n").last { $0.hasPrefix("t=") }.flatMap { $0.firstMatch(of: #/entries=(\d+)/#).flatMap { Int($0.1) } }
    }
}
private final class Anchor {}
