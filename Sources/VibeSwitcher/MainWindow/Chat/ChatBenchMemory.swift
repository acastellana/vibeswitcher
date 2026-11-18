import AppKit
import Darwin
import Foundation
import VibeCore

extension ChatBench {
    /// VIBESWITCHER_BENCH_MEMORY=1: what opening the conversation (and what streams into it) costs in memory. A thread
    /// of its own samples the footprint (phys_footprint) and malloc's bytes in use every 10 ms, so a peak inside a long
    /// main-thread turn or a read off the main thread is caught too; from just before the open to the run's end. Prints
    /// a line a second and, at the end, `RESULT chat-memory-footprint-mb BEFORE PEAK END` and
    /// `RESULT chat-memory-malloc-mb BEFORE PEAK END` (ChatMemoryTests reads them).
    final class MemoryProbe: @unchecked Sendable {
        struct Reading {
            var footprint: Double
            var malloc: Double
            /// The footprint's graphics ledger (IOSurfaces, Metal: what drawing takes).
            var graphics: Double
        }

        private let lock = NSLock()
        private var before: Reading?
        private var peak = Reading(footprint: 0, malloc: 0, graphics: 0)
        private var secondPeak = Reading(footprint: 0, malloc: 0, graphics: 0)

        static func read() -> Reading {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let ok = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            } == KERN_SUCCESS
            return Reading(footprint: ok ? Double(info.phys_footprint) / 1_048_576 : 0, malloc: Double(stats.size_in_use) / 1_048_576,
                           graphics: ok ? Double(max(0, info.ledger_tag_graphics_footprint)) / 1_048_576 : 0)
        }

        /// The baseline (just before the open), then sampling until the process ends.
        func start() {
            let baseline = Self.read()
            lock.lock()
            before = baseline
            peak = baseline
            secondPeak = baseline
            lock.unlock()
            Thread.detachNewThread { [self] in
                while true {
                    let now = Self.read()
                    lock.lock()
                    peak.footprint = max(peak.footprint, now.footprint)
                    peak.malloc = max(peak.malloc, now.malloc)
                    peak.graphics = max(peak.graphics, now.graphics)
                    secondPeak.graphics = max(secondPeak.graphics, now.graphics)
                    secondPeak.footprint = max(secondPeak.footprint, now.footprint)
                    secondPeak.malloc = max(secondPeak.malloc, now.malloc)
                    lock.unlock()
                    usleep(10_000)
                }
            }
        }

        /// "mem: footprint 182.3 MB (peak this second 190.1) malloc 61.0 MB (peak 70.2)".
        func second() -> String {
            let now = Self.read()
            lock.lock()
            let top = secondPeak
            secondPeak = now
            lock.unlock()
            return String(format: "  mem: footprint %.1f MB (peak this second %.1f) malloc %.1f MB (peak %.1f) graphics %.1f MB (peak %.1f)",
                          now.footprint, top.footprint, now.malloc, top.malloc, now.graphics, top.graphics)
        }

        func results() -> String {
            let now = Self.read()
            lock.lock()
            let before = before ?? now, peak = peak
            lock.unlock()
            return String(format: "RESULT chat-memory-footprint-mb %.1f %.1f %.1f\nRESULT chat-memory-malloc-mb %.1f %.1f %.1f\n"
                          + "RESULT chat-memory-graphics-mb %.1f %.1f %.1f\n"
                          + "  memory: footprint %.1f → peak %.1f (+%.1f) → %.1f MB; malloc in use %.1f → peak %.1f (+%.1f) → %.1f MB",
                          before.footprint, peak.footprint, now.footprint, before.malloc, peak.malloc, now.malloc,
                          before.graphics, peak.graphics, now.graphics,
                          before.footprint, peak.footprint, peak.footprint - before.footprint, now.footprint,
                          before.malloc, peak.malloc, peak.malloc - before.malloc, now.malloc)
        }
    }

    /// VIBESWITCHER_BENCH_LAYERS=1 (with MEMORY): the biggest layers holding a bitmap under `view`, as "WxH px Class (owner)".
    static func biggestLayers(in view: NSView, top: Int = 5) -> String {
        var found: [(pixels: Double, text: String)] = []
        func walk(_ layer: CALayer, depth: Int) {
            let scale = layer.contentsScale
            if layer.contents != nil || layer.drawsAsynchronously {
                let w = layer.bounds.width * scale, h = layer.bounds.height * scale
                let owner = (layer.delegate as? NSView).map { String(describing: type(of: $0)) } ?? "-"
                found.append((w * h, "\(Int(w))x\(Int(h)) \(type(of: layer)) (\(owner)) depth \(depth)"))
            }
            for sub in layer.sublayers ?? [] { walk(sub, depth: depth + 1) }
        }
        if let layer = view.layer { walk(layer, depth: 0) }
        let total = found.reduce(0) { $0 + $1.pixels } * 4 / 1_048_576
        return String(format: "  layers: %d with contents, %.1f MB if 4 B a pixel; biggest: ", found.count, total)
            + found.sorted { $0.pixels > $1.pixels }.prefix(top).map(\.text).joined(separator: "; ")
    }

    /// VIBESWITCHER_BENCH_CENSUS=1 (with STREAM): the heap counted by class (`HeapCensus`) once the stream has started
    /// and at the end; what grew per streamed line, for the classes `watched` names.
    final class StreamCensus {
        static let watched = ["NSKeyValue", "MallocBlock"]
        private var first: (census: HeapCensus.Result, lines: Int)?

        func note(lines: Int) {
            if first == nil, lines > 0 { first = (HeapCensus.take(), lines) }
        }

        func results(lines: Int) -> String {
            guard let first, lines > first.lines else { return "  census: the stream never started" }
            let census = HeapCensus.take(), streamed = lines - first.lines
            var text = "  census over \(streamed) streamed lines; grew:"
            for row in HeapCensus.growth(from: first.census, to: census, top: .max)
            where Self.watched.contains(where: row.name.contains) || row.after.bytes - row.before.bytes > 100_000 {
                let blocks = row.after.blocks - row.before.blocks
                guard blocks != 0 else { continue }
                text += String(format: "\n    %@: %+d blocks (%+.1f a line), %+.1f KB", row.name as NSString, blocks,
                               Double(blocks) / Double(streamed), Double(row.after.bytes - row.before.bytes) / 1024)
            }
            let watched = HeapCensus.growth(from: first.census, to: census, top: .max).filter { Self.watched.contains(where: $0.name.contains) }
            let perLine = Double(watched.reduce(0) { $0 + $1.after.blocks - $1.before.blocks }) / Double(streamed)
            return text + String(format: "\nRESULT chat-stream-watched-blocks-per-line %.1f", perLine)
        }
    }

    /// VIBESWITCHER_BENCH_STREAM=N: a reply streams into the conversation once it's shown: N lines a second appended to
    /// its transcript (a paragraph of the reply, a tool run and its result, in turn), read by the chat's poll as the
    /// window's does. Opened and left alone meanwhile (no resizes, no scrolls).
    final class Stream {
        private let url: URL
        private let perSecond: Int
        private(set) var count = 0

        /// VIBESWITCHER_BENCH_STREAM_LEAD=1: a project lead's conversation instead, as a night of team work fills it: a
        /// VibeSwitcher card (a worker's report, an audit, auto_advance, app health), the lead's status call and its
        /// long result, its reply, in turn.
        private let lead: Bool

        init(path: String, perSecond: Int, lead: Bool = false) {
            url = URL(fileURLWithPath: path)
            self.perSecond = perSecond
            self.lead = lead
        }

        func next() {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            for _ in 0..<perSecond {
                try? handle.write(contentsOf: Data(((lead ? Self.leadLine(count) : Self.line(count)) + "\n").utf8))
                count += 1
            }
        }

        /// A lead's line: a VibeSwitcher card, the lead's status call, its result, its reply.
        static func leadLine(_ index: Int) -> String {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let task = "task-\(index / 4)"
            let message: [String: Any]
            let type: String
            switch index % 4 {
            case 0:
                type = "user"
                let about = ["worker \(task)", "verifier \(task)", "auto_advance", "app health"][(index / 4) % 4]
                let body = "The worker on \(task) says it's done (\(index)): the change is committed and its checks pass.\n\n"
                    + (0..<12).map { "- check \($0) of \(task): `swift test --filter Check\($0)` passed, 42 tests in 3.\($0) s" }.joined(separator: "\n")
                    + "\n\nNext: start its audit, or merge it once the verifier passes it."
                message = ["role": "user", "content": LeadDelivery.typed(body, from: .system(about))]
            case 1:
                type = "assistant"
                message = ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_lead\(index)", "name": "mcp__vibeswitcher__status",
                                                              "input": ["task": task]]]]
            case 2:
                type = "user"
                let status = (0..<30).map { "{\"task\": \"\(task)-\($0)\", \"state\": \"working\", \"checkpoint\": \"step \($0) of \(index)\"}" }
                message = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_lead\(index - 1)",
                                                        "content": "[" + status.joined(separator: ",\n") + "]"]]]
            default:
                type = "assistant"
                message = ["role": "assistant", "content": [["type": "text", "text": "\(task) is done and checked (\(index)); I started its audit. "
                    + "Nothing needs you.\n\n- the merge waits on the verifier\n- two tasks still work"]]]
            }
            let line: [String: Any] = ["type": type, "uuid": "lead\(index)", "timestamp": stamp, "sessionId": "bench-stream", "message": message]
            let data = (try? JSONSerialization.data(withJSONObject: line)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }

        static func line(_ index: Int) -> String {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let message: [String: Any]
            let type: String
            switch index % 3 {
            case 0:
                type = "assistant"
                message = ["role": "assistant", "content": [["type": "text", "text": "Streamed part \(index): the screenshot shows the panel laid out as "
                    + "asked.\n\n- the header keeps its height\n- the list scrolls under it\n\n```swift\nlet panel = Panel(rows: \(index))\n```"]]]
            case 1:
                type = "assistant"
                message = ["role": "assistant", "content": [["type": "tool_use", "id": "toolu_stream\(index)", "name": "Bash",
                                                              "input": ["command": "swift build", "description": "Build step \(index)"]]]]
            default:
                type = "user"
                message = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_stream\(index - 1)",
                                                        "content": "Build complete! (\(index) s)"]]]
            }
            let line: [String: Any] = ["type": type, "uuid": "stream\(index)", "timestamp": stamp, "sessionId": "bench-stream", "message": message]
            let data = (try? JSONSerialization.data(withJSONObject: line)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}
