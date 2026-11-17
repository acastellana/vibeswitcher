import AppKit
import Darwin
import Foundation

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

    /// VIBESWITCHER_BENCH_STREAM=N: a reply streams into the conversation once it's shown: N lines a second appended to
    /// its transcript (a paragraph of the reply, a tool run and its result, in turn), read by the chat's poll as the
    /// window's does. Opened and left alone meanwhile (no resizes, no scrolls).
    final class Stream {
        private let url: URL
        private let perSecond: Int
        private var count = 0

        init(path: String, perSecond: Int) {
            url = URL(fileURLWithPath: path)
            self.perSecond = perSecond
        }

        func next() {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            for _ in 0..<perSecond {
                try? handle.write(contentsOf: Data((Self.line(count) + "\n").utf8))
                count += 1
            }
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
