import Foundation

/// VibeSwitcher's own health, as its logs show it, for the lead of the project that builds it (`watch_app_logs:` in
/// that project's workflow.md; no other lead gets it). The app watches its hang reports (`HangWatchdog`'s
/// `~/.vibeswitcher/debug/hang-*.log` and `.txt`), the crash reports macOS writes for its programs
/// (`~/Library/Logs/DiagnosticReports`) and its app.log's error lines, and tells what's new in a short digest, made here
/// without a model: for a freeze its length, the app's state (the selected session's kind, chat or terminal shown,
/// window key), footprint and the top app frames; for a crash its exception and top frames; for error lines their
/// kinds and counts. Never what a message, a transcript or an attachment says: only those fields, each from a fixed
/// shape (names, numbers, function names), and the whole through `Redaction`. Once a day, if anything happened, a trend.
/// 2026-10-25: a one-off review of these logs found four real bugs (freezes, 392-row terminals, memory growth,
/// duplicate verifiers) no one had been told about.
public enum AppHealth {
    /// Who the lead's told it's from: "VibeSwitcher (not the user) reports (app health)".
    public static let sender = "app health"
    /// Events within this long of the first are told together, in one digest.
    public static let window: TimeInterval = 10 * 60
    /// The same freeze (or crash) seen again this soon after it was told is counted, not told again.
    public static let repeatWithin: TimeInterval = 24 * 3600
    /// The programs whose crash reports are VibeSwitcher's.
    public static let programs = ["VibeSwitcher", "vibeswitcher-host", "vibeswitcher-mcp"]
    /// Memory growing at least this fast (MB an hour), over at least `growthAfter` since launch, is worth a trend line
    /// on a day with nothing else.
    public static let worryingGrowth: Double = 25
    public static let growthAfter: TimeInterval = 2 * 3600

    // MARK: Freezes

    /// The line `HangWatchdog` starts a hang's .log with: when the main thread got stuck, and once it answered again,
    /// how long that took ("vibeswitcher-hang: since=1761400000.123 duration=12.3").
    /// `sampleInside`: how much of the sample (.txt) was taken while it was still stuck, 0 to 1 ("sample-inside=0.00":
    /// none of it, the sample began after it answered). `load`: the 1-minute load average when it got stuck, on `cpus`
    /// cores. `spread`: the sample's main thread (see `Spread`), with its `verdict`.
    public static func hangHeader(since: Date, duration: TimeInterval?, sampleInside: Double? = nil, load: Double? = nil, cpus: Int? = nil,
                                  spread: Spread? = nil, verdict: Verdict? = nil) -> String {
        "vibeswitcher-hang: since=\(String(format: "%.3f", since.timeIntervalSince1970))"
            + (duration.map { " duration=\(String(format: "%.1f", $0))" } ?? "")
            + (sampleInside.map { " sample-inside=\(String(format: "%.2f", $0))" } ?? "")
            + (load.map { " load=\(String(format: "%.2f", $0))" } ?? "")
            + (cpus.map { " cpus=\($0)" } ?? "")
            + (spread.map { " samples=\($0.samples) pcs=\($0.pcs) top-share=\(String(format: "%.2f", $0.topShare))" } ?? "")
            + (verdict.map { " verdict=\($0.rawValue)" } ?? "")
    }

    /// How long `sample` samples a hang for (its `HangWatchdog` call).
    public static let sampleSeconds: TimeInterval = 3

    /// When a `sample` report's sampling began, its "Date/Time:" line ("2026-10-26 11:19:20.374 +0100").
    public static func sampleStart(_ sample: String) -> Date? {
        guard let line = sample.components(separatedBy: "\n").prefix(40).first(where: { $0.hasPrefix("Date/Time:") }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        return formatter.date(from: line.dropFirst("Date/Time:".count).trimmingCharacters(in: .whitespaces))
    }

    /// The part of a sample begun at `start` (lasting `sampleSeconds`) taken before the main thread answered at `end`
    /// (nil: it never did), 0 to 1. 2026-10-26: `sample` took 3 to 6 s to begin, so both reports that day sampled only
    /// the idle main thread after its stall.
    public static func sampleInside(start: Date, end: Date?) -> Double {
        guard let end else { return 1 }
        return min(max(end.timeIntervalSince(start) / sampleSeconds, 0), 1)
    }

    /// One frame of a stack caught on the stuck main thread.
    public struct StackFrame: Equatable, Hashable, Sendable {
        /// The function (demangled), or "???" when it can't be named.
        public var name: String
        /// Its image's file name ("VibeSwitcher", "AppKit").
        public var image: String
        /// The return address's offset in the function, and the address.
        public var offset: UInt
        public var address: UInt

        public init(name: String, image: String, offset: UInt, address: UInt) {
            self.name = name
            self.image = image
            self.offset = offset
            self.address = address
        }
    }

    /// The line that opens the caught stacks' section of a hang's .log.
    public static let caughtTitle = "Main thread while stuck"

    /// The main thread's stacks caught while it was stuck (each outermost frame first; `at`, how far into the stall
    /// each was taken), as a call graph in `sample`'s shape under a title line: what `busiestPath` reads, and a
    /// person can, as in a sample.
    public static func caughtGraph(_ stacks: [(at: TimeInterval, frames: [StackFrame])]) -> String {
        guard let first = stacks.first, let last = stacks.last else { return "" }
        final class Node {
            var count = 0
            var children: [StackFrame: Node] = [:]
            var order: [StackFrame] = []
        }
        let root = Node()
        for stack in stacks {
            root.count += 1
            var node = root
            for frame in stack.frames {
                if node.children[frame] == nil {
                    node.children[frame] = Node()
                    node.order.append(frame)
                }
                node = node.children[frame]!
                node.count += 1
            }
        }
        var lines = [String(format: "\(caughtTitle): %d stacks, from %.1f s to %.1f s into the stall", stacks.count, first.at, last.at),
                     "Call graph:", "    \(stacks.count) Thread_main   DispatchQueue_1: com.apple.main-thread  (caught while stuck)"]
        func emit(_ node: Node, level: Int) {
            for frame in node.order.sorted(by: { node.children[$0]!.count > node.children[$1]!.count }) {
                let child = node.children[frame]!
                lines.append("    + " + String(repeating: "  ", count: level) + "\(child.count) \(frame.name)  (in \(frame.image)) + \(frame.offset)  ["
                             + "0x" + String(frame.address, radix: 16) + "]")
                emit(child, level: level + 1)
            }
        }
        emit(root, level: 0)
        return lines.joined(separator: "\n")
    }

    /// One freeze, from its report's two files.
    public struct Hang: Equatable, Sendable {
        /// "hang-20261025-140210", its files' name.
        public var name: String
        public var since: Date?
        /// How long the main thread was stuck; nil when no answer was recorded (still stuck, or ended stuck).
        public var duration: TimeInterval?
        /// The selected session's kind (lead, worker, verifier, agent, shell, none), as the app's state said.
        public var session: String?
        /// "chat", "terminal" or "nothing"; "window never opened".
        public var shown: String?
        public var key: Bool?
        /// The app's footprint when it was sampled, and its peak, in MB.
        public var footprint: Double?
        public var peak: Double?
        /// The app's main-thread frames on the busiest path of its sample, the top of the stack first.
        public var frames: [String] = []
        /// Whether its sample (.txt) was there to read.
        public var sampled = false
        /// Whether `frames` (or `systemFrames`) are from stacks caught while it was stuck (the .log's), not the sample.
        public var caught = false
        /// How much of the sample was taken while it was still stuck, 0 to 1 (nil: not known).
        public var sampleInside: Double?
        /// The 1-minute load average when it got stuck, and the Mac's cores (nil: a report from before they were kept).
        public var load: Double?
        public var cpus: Int?
        /// How its sample's main-thread samples spread (nil without a sample).
        public var spread: Spread?

        /// Whether its sample says it was starvation, real work or a wait.
        public var verdict: Verdict? { AppHealth.verdict(spread, sampleInside: sampleInside) }

        public init(name: String) { self.name = name }

        /// What makes two freezes the same: their top 3 app frames.
        /// With none, the busiest path's top 3 frames whatever their image (see `AppHealth.systemFrames`).
        public var systemFrames: [String] = []

        /// What makes two freezes the same: their top 3 app frames, else their top 3 frames; nil without a sample
        /// (nothing to tell it by: it's never taken for another).
        public var signature: String? {
            if !frames.isEmpty { return frames.prefix(3).joined(separator: " < ") }
            return systemFrames.isEmpty ? nil : "no app frames: " + systemFrames.joined(separator: " < ")
        }
    }

    /// A freeze from its .log (`log`, the header and state) and its sample (`sample`), either missing.
    public static func hang(name: String, log: String?, sample: String?) -> Hang {
        var hang = Hang(name: name)
        if let log {
            let lines = log.components(separatedBy: "\n")
            if let header = lines.first, header.hasPrefix("vibeswitcher-hang:") {
                let fields = values(header)
                hang.since = fields["since"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
                hang.duration = fields["duration"].flatMap(Double.init)
                hang.sampleInside = fields["sample-inside"].flatMap(Double.init)
                hang.load = fields["load"].flatMap(Double.init)
                hang.cpus = fields["cpus"].flatMap { Int($0) }
            }
            for line in lines {
                if line.hasPrefix("window never opened") { hang.shown = "window never opened" }
                if line.hasPrefix("window visible=") { hang.key = values(line)["key"].map { $0 == "true" } }
                if line.hasPrefix("selected=") {
                    let fields = values(line)
                    hang.session = fields["selected"] == "none" ? "none" : word(fields["kind"]) ?? "unknown"
                    hang.shown = fields["chatShown"] == "true" ? "chat" : fields["terminalHidden"] == "false" ? "terminal" : "nothing"
                }
            }
        }
        if hang.since == nil { hang.since = nameDate(name) }
        if let sample {
            hang.sampled = true
            hang.footprint = sampleMegabytes(sample, "Physical footprint:")
            hang.peak = sampleMegabytes(sample, "Physical footprint (peak):")
            hang.spread = spread(sample: sample)
            hang.frames = appFrames(sample: sample, image: "VibeSwitcher")
            if hang.frames.isEmpty { hang.systemFrames = systemFrames(sample: sample) }
        }
        // The stacks caught while it was stuck say what blocked it; the sample may have begun after it answered.
        if let log, log.contains("\n" + caughtTitle) {
            let frames = appFrames(sample: log, image: "VibeSwitcher"), system = frames.isEmpty ? systemFrames(sample: log) : []
            if !frames.isEmpty || !system.isEmpty {
                hang.caught = true
                hang.frames = frames
                hang.systemFrames = system
            }
        }
        return hang
    }

    /// `key=value` words of a line (a value up to the next space).
    static func values(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        for word in line.split(separator: " ") {
            guard let equals = word.firstIndex(of: "=") else { continue }
            result[String(word[..<equals])] = String(word[word.index(after: equals)...])
        }
        return result
    }

    /// A value that's one plain word (letters, digits, - and _), or nil.
    static func word(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 24,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return value
    }

    /// When "hang-20261025-140210" began, in this Mac's time zone (as `HangWatchdog` names them).
    public static func nameDate(_ name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(name.dropFirst("hang-".count)))
    }

    /// A `sample` header's size ("Physical footprint:  512.3M"), in MB.
    static func sampleMegabytes(_ sample: String, _ label: String) -> Double? {
        guard let line = sample.components(separatedBy: "\n").prefix(60).first(where: { $0.hasPrefix(label) }) else { return nil }
        let value = line.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
        guard let unit = value.last, let number = Double(value.dropLast()) else { return Double(value).map { $0 / 1_048_576 } }
        switch unit {
        case "K": return number / 1024
        case "M": return number
        case "G": return number * 1024
        default: return Double(value).map { $0 / 1_048_576 }
        }
    }

    /// Frames that only pass a call on (a thunk, the program's entry) and say nothing of what ran.
    static let wrapperPrefixes = ["thunk for ", "reabstraction thunk", "partial apply for ", "@objc ", "protocol witness for ", "outlined "]
    static let entryPoints: Set<String> = ["main", "static AppDelegate.$main()", "$main", "VibeSwitcher_main"]

    /// The main thread's busiest path in a `sample` report's call graph, as its frames in `image` (by function name),
    /// the top of the stack first, at most 5.
    public static func appFrames(sample: String, image: String) -> [String] {
        frames(busiestPath(sample: sample).filter { $0.image == image }.map(\.name))
    }

    /// With no app frame on that path (a SwiftUI or AttributeGraph stall): its top 3 frames whatever their image,
    /// "name (image)", the top first.
    public static func systemFrames(sample: String) -> [String] {
        Array(frames(busiestPath(sample: sample).map { "\($0.name) (\($0.image))" }).prefix(3))
    }

    /// `names` (outermost first) without wrappers and repeats, the top of the stack first, at most 5.
    static func frames(_ names: [String]) -> [String] {
        var result: [String] = []
        for name in names.reversed() where !entryPoints.contains(name) && !wrapperPrefixes.contains(where: name.hasPrefix) && result.last != name {
            result.append(name)
        }
        return Array(result.prefix(5))
    }

    /// The main thread's busiest path (at each frame, the callee with the most samples), outermost first: each frame's
    /// function name and image.
    static func busiestPath(sample: String) -> [(name: String, image: String)] {
        guard let (_, nodes, children) = mainThreadGraph(sample: sample) else { return [] }
        let roots = nodes.indices.filter { nodes[$0].parent == nil }
        guard var current = roots.max(by: { nodes[$0].count < nodes[$1].count }) else { return [] }
        var path = [current]
        while let next = children[current].max(by: { nodes[$0].count < nodes[$1].count }) {
            path.append(next)
            current = next
        }
        return path.compactMap { index in
            // "name  (in Image) + 12  [0x…]  File.swift:3"
            let text = nodes[index].text
            guard let open = text.range(of: "  (in "), let close = text[open.upperBound...].firstIndex(of: ")") else { return nil }
            var name = String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            for prefix in ["specialized ", "merged "] where name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
            guard !name.isEmpty else { return nil }
            return (String(name.prefix(120)), String(text[open.upperBound..<close].prefix(60)))
        }
    }

    /// The main thread's block of a `sample` report's call graph: its sample count (its thread line's), and each frame
    /// line under it (outermost first) with its parent and children, as indices.
    static func mainThreadGraph(sample: String) -> (samples: Int, nodes: [(depth: Int, count: Int, text: String, parent: Int?)], children: [[Int]])? {
        let lines = sample.components(separatedBy: "\n")
        guard let graph = lines.firstIndex(where: { $0.hasPrefix("Call graph:") }) else { return nil }
        // The main thread's block: its line, then every line indented deeper.
        var thread: (depth: Int, count: Int)?
        var nodes: [(depth: Int, count: Int, text: String, parent: Int?)] = []
        var children: [[Int]] = []
        var stack: [Int] = []
        for line in lines[(graph + 1)...] {
            guard let (depth, count, text) = graphLine(line) else {
                if thread != nil { break }
                continue
            }
            if let top = thread?.depth {
                if depth <= top { break }
                while let last = stack.last, nodes[last].depth >= depth { stack.removeLast() }
                nodes.append((depth, count, text, stack.last))
                children.append([])
                if let parent = stack.last { children[parent].append(nodes.count - 1) }
                stack.append(nodes.count - 1)
            } else if text.hasPrefix("Thread_") {
                // The first thread is the main one (sample lists it first, as "com.apple.main-thread").
                thread = (depth, count)
            }
        }
        guard let thread else { return nil }
        return (thread.count, nodes, children)
    }

    // MARK: Starvation or work

    /// How the main thread's samples spread over the instructions they caught it at (its top-of-stack PCs). Running
    /// code, sampled every millisecond for 3 s, is caught at hundreds of them; a thread that barely runs (a loaded Mac,
    /// or its pages coming back in after hours idle) sits on the same few for hundreds of samples each. 2026-10-30 and
    /// 31, three fix tasks (7-s-freeze-measuring, accessibility-graph, 9-s-swiftui-layout) found their freeze was that:
    /// hang-20261031-001452, 2298 samples on 18 PCs.
    public struct Spread: Equatable, Sendable {
        /// The main thread's samples, and the distinct addresses at the top of their stacks.
        public var samples: Int
        public var pcs: Int
        /// The busiest of those PCs: its function, and its share of the samples, 0 to 1.
        public var top: String
        public var topShare: Double
        /// The share of samples in a kernel wait (`waits`): the thread blocked, not running.
        public var waiting: Double

        public init(samples: Int, pcs: Int, top: String, topShare: Double, waiting: Double) {
            self.samples = samples
            self.pcs = pcs
            self.top = top
            self.topShare = topShare
            self.waiting = waiting
        }
    }

    /// What a freeze's main-thread sample says it was.
    public enum Verdict: String, Sendable {
        /// Few PCs, many samples each: the thread barely ran (the Mac loaded or paging), nothing of the app's to fix.
        case starved
        /// Spread over many PCs: the app's own work, as a freeze was always told.
        case work
        /// Most samples in a kernel wait while it was stuck: a blocking call (a lock, a synchronous message).
        case waiting
    }

    /// At least this many samples on average a PC is starvation. Chosen from the 101 reports in ~/.vibeswitcher/debug
    /// on 2026-10-31 whose sample wasn't mostly in a wait: 54 clustered ones had 2 to 58 PCs over 1799-2493 samples (at
    /// least 39 samples a PC; hang-20261031-001452's 18 over 2298), the spread ones 71 to 441 (at most 33 a PC; the
    /// accessibility work of 2026-10-30 09:57-10:08, 148-282 PCs). No report fell between 33 and 39.
    public static let starvedSamplesPerPC = 35
    /// Fewer samples than this say nothing either way (`sample` itself starved: hang-20261028-070849 got 10 in 3 s).
    public static let verdictSamples = 200
    /// At least this share in a kernel wait is a wait, not starvation: the 10-30 11:40 and 11:51 freezes had 91% and
    /// 95% of theirs in mach_msg2_trap (every stack caught while stuck there too); no clustered sample had over 39%.
    public static let waitingShare = 0.5
    /// The kernel calls a blocked thread sits in.
    static let waits: Set<String> = ["mach_msg2_trap", "mach_msg_trap", "mach_msg_overwrite_trap", "semaphore_wait_trap", "semaphore_timedwait_trap",
                                     "__psynch_cvwait", "__psynch_mutexwait", "__psynch_rw_rdlock", "__psynch_rw_wrlock", "__ulock_wait",
                                     "__ulock_wait2", "__semwait_signal", "kevent", "kevent_id", "kevent_qos", "__select", "__workq_kernreturn",
                                     "__wait4", "poll"]

    /// The main thread's spread in a `sample` report: each frame's samples not in a callee were taken at its address.
    public static func spread(sample: String) -> Spread? {
        guard let (samples, nodes, children) = mainThreadGraph(sample: sample), samples > 0 else { return nil }
        var atPC: [String: (count: Int, name: String)] = [:]
        for (index, node) in nodes.enumerated() {
            let own = node.count - children[index].reduce(0) { $0 + nodes[$1].count }
            guard own > 0 else { continue }
            let text = node.text
            // "name  (in Image) + 12  [0x19b2ad380]  File.swift:3"
            let pc = text.range(of: "[0x").flatMap { open in text[open.lowerBound...].firstIndex(of: "]").map { String(text[open.lowerBound...$0]) } } ?? text
            let name = text.range(of: "  (in ").map { String(text[..<$0.lowerBound]).trimmingCharacters(in: .whitespaces) } ?? text
            atPC[pc, default: (0, name)].count += own
        }
        guard let top = atPC.values.max(by: { $0.count < $1.count }) else { return nil }
        let waiting = atPC.values.filter { waits.contains($0.name) }.reduce(0) { $0 + $1.count }
        return Spread(samples: samples, pcs: atPC.count, top: String(top.name.prefix(120)), topShare: Double(top.count) / Double(samples),
                      waiting: Double(waiting) / Double(samples))
    }

    /// What a freeze was, from its sample's spread and how much of the sample was inside it (nil: not known). A sample
    /// taken after the thread answered says what it did then: real work or a wait then isn't the stall's, but a thread
    /// still clustered then, not waiting, was still starved (hang-20261031-001506: sampled after, 2273 samples on 13 PCs).
    public static func verdict(_ spread: Spread?, sampleInside: Double?) -> Verdict? {
        guard let spread, spread.samples >= verdictSamples else { return nil }
        let ofTheStall = (sampleInside ?? 1) >= 0.5
        if spread.waiting >= waitingShare { return ofTheStall ? .waiting : nil }
        if spread.samples >= starvedSamplesPerPC * spread.pcs { return .starved }
        return ofTheStall ? .work : nil
    }

    /// The spread and its verdict in words, for a hang's .log and the lead's digest.
    public static func describe(_ spread: Spread, verdict: Verdict?) -> String {
        var text = "main thread's sample: \(spread.samples) samples on \(spread.pcs) top-of-stack PCs"
            + String(format: " (%.1f%%), the busiest %.0f%% of them (%@)", Double(spread.pcs) / Double(spread.samples) * 100, spread.topShare * 100, spread.top)
        switch verdict {
        case .starved?: text += ": likely starvation or paging, not the app's work"
        case .work?: text += ": real work"
        case .waiting?: text += String(format: ": waiting, %.0f%% of it in a kernel wait (a blocking call)", spread.waiting * 100)
        case nil: break
        }
        return text
    }

    /// The 1-minute load average and the core count, as a hang's .log records them at the stall.
    public static func describeLoad(_ load: Double, cpus: Int?) -> String {
        String(format: "1-minute load %.1f", load) + (cpus.map { " on \($0) cores" } ?? "")
    }

    /// A call graph line ("    + ! : | 2345 frame  (in Image) + 12  [0x…]"): its depth (the width of its tree
    /// marks), its sample count and its text.
    static func graphLine(_ line: String) -> (Int, Int, String)? {
        var depth = 0
        var rest = Substring(line)
        while let first = rest.first, " +!:|".contains(first) {
            depth += 1
            rest = rest.dropFirst()
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let count = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.first == " " else { return nil }
        return (depth, count, String(rest.dropFirst()))
    }

    // MARK: Crashes

    /// One crash report of one of VibeSwitcher's programs.
    public struct Crash: Equatable, Sendable {
        /// Its file's name in DiagnosticReports.
        public var file: String
        public var program: String
        public var version: String?
        /// "EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS at 0x0000000000000010".
        public var exception: String
        /// The crashed thread's top frames, "symbol (image)", the top first, at most 5.
        public var frames: [String]

        public var signature: String { ([program, exception.prefix { $0 != "," }.description] + frames.prefix(3)).joined(separator: " < ") }
    }

    /// The program a DiagnosticReports file is a crash report of, if it's one of `programs`' (its name is the
    /// program's, a date, and .ips or .crash).
    public static func crashProgram(file: String) -> String? {
        guard file.hasSuffix(".ips") || file.hasSuffix(".crash") else { return nil }
        return programs.first { program in
            guard file.hasPrefix(program + "-") else { return false }
            let date = file.dropFirst(program.count + 1).prefix(17)
            return date.count == 17 && date.enumerated().allSatisfy { index, character in
                [4, 7, 10].contains(index) ? character == "-" : character.isNumber
            }
        }
    }

    /// A crash report (.ips: a JSON header line, then the report as JSON; or an older .crash's text), or nil when
    /// it isn't a crash of one of `programs` (a resource report, a file still being written).
    public static func crash(file: String, text: String) -> Crash? {
        guard let program = crashProgram(file: file) else { return nil }
        if file.hasSuffix(".crash") { return legacyCrash(file: file, program: program, text: text) }
        guard let newline = text.firstIndex(of: "\n"),
              let header = try? JSONSerialization.jsonObject(with: Data(text[..<newline].utf8)) as? [String: Any],
              ["309", "109"].contains(header["bug_type"] as? String ?? ""),
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any]
        else { return nil }
        let exception = body["exception"] as? [String: Any] ?? [:]
        var words = [exception["type"] as? String ?? "unknown exception"]
        if let signal = exception["signal"] as? String { words[0] += " (\(signal))" }
        if let subtype = exception["subtype"] as? String { words.append(subtype) }
        if let indicator = (body["termination"] as? [String: Any])?["indicator"] as? String { words.append(indicator) }
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int
        let thread = threads.first { $0["triggered"] as? Bool == true } ?? faulting.flatMap { threads.indices.contains($0) ? threads[$0] : nil }
        let frames = (thread?["frames"] as? [[String: Any]] ?? []).prefix(5).map { frame -> String in
            let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
            return "\(String((frame["symbol"] as? String ?? "???").prefix(120))) (\(image))"
        }
        let version = (header["app_version"] as? String).map { version in
            (header["build_version"] as? String).map { "\(version) (\($0))" } ?? version
        }
        return Crash(file: file, program: program, version: version, exception: words.joined(separator: ", "), frames: Array(frames))
    }

    /// An older text crash report: its "Exception Type:" and the crashed thread's frames.
    static func legacyCrash(file: String, program: String, text: String) -> Crash? {
        let lines = text.components(separatedBy: "\n")
        guard let type = lines.first(where: { $0.hasPrefix("Exception Type:") }) else { return nil }
        var frames: [String] = []
        if let crashed = lines.firstIndex(where: { $0.hasPrefix("Thread ") && $0.contains("Crashed") }) {
            for line in lines[(crashed + 1)...] {
                // "0   libsystem_kernel.dylib   0x00000001 __pthread_kill + 8"
                let words = line.split(separator: " ", omittingEmptySubsequences: true)
                guard words.count >= 4, Int(words[0]) != nil, frames.count < 5 else { break }
                let symbol = words[3...].prefix { $0 != "+" }.joined(separator: " ")
                frames.append("\(symbol.prefix(120)) (\(words[1]))")
            }
        }
        let version = lines.first { $0.hasPrefix("Version:") }.map { $0.dropFirst("Version:".count).trimmingCharacters(in: .whitespaces) }
        return Crash(file: file, program: program, version: version,
                     exception: type.dropFirst("Exception Type:".count).trimmingCharacters(in: .whitespaces), frames: frames)
    }

    // MARK: Error lines

    /// Words that make an app.log line an error.
    static let errorWords = ["error", "failed", "couldn't", "could not", "can't", "cannot", "crashed", "fatal", "exception", "timed out"]

    /// The parts of the app that start their app.log lines with their name ("lead: …"); a line starting with anything
    /// else is the app's ("app: …"), so no word of what a line says becomes its kind.
    static let logParts: Set<String> = ["app", "app health", "bench", "chat", "composer", "handover refused", "host", "keep awake", "lead",
                                        "move", "privacy", "role sweep", "sandbox", "shutdown refused", "spawn failed", "vault", "watchdog",
                                        "window", "witness"]

    /// An app.log line's kind, when it's an error ("lead: couldn't"): what part of the app wrote it (one of `logParts`,
    /// before the line's first colon) and the error word. Nothing else of the line: that's what it says.
    public static func errorKind(_ line: String) -> String? {
        var text = Substring(line)
        // Breadcrumbs start each line with its time: "14:02:10.123 lead: …".
        if let space = text.firstIndex(of: " "), text[..<space].first?.isNumber == true, text[..<space].contains(":") {
            text = text[text.index(after: space)...]
        }
        let lower = text.lowercased()
        guard let word = errorWords.first(where: { contains(lower, word: $0) }) else { return nil }
        var part = "app"
        if let colon = lower.firstIndex(of: ":") {
            let name = String(lower[..<colon])
            if logParts.contains(name) { part = name }
        }
        return "\(part): \(word)"
    }

    /// Whether `text` has `word` with no letter right before or after it ("error", not "apierror" or "errors").
    static func contains(_ text: String, word: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: word, range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before?.isLetter ?? false), !(after?.isLetter ?? false) { return true }
            start = range.upperBound
        }
        return false
    }

    // MARK: The files

    /// Where the reports are: the app's debug folder and macOS's DiagnosticReports (scratch ones in tests).
    public struct Folders: Sendable {
        public var debug: URL
        public var reports: URL

        public init(debug: URL, reports: URL) {
            self.debug = debug
            self.reports = reports
        }

        /// The app's: `~/.vibeswitcher/debug` and `~/Library/Logs/DiagnosticReports` under this process's home.
        public static var app: Folders {
            Folders(debug: VibePaths.root.appendingPathComponent("debug", isDirectory: true),
                    reports: URL(fileURLWithPath: VibePaths.home).appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true))
        }

        /// The hangs in the debug folder, by name ("hang-20261025-140210", whichever of its files is there).
        public func hangNames() -> [String] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: debug.path)) ?? []
            return Set(files.filter { $0.hasPrefix("hang-") && ($0.hasSuffix(".txt") || $0.hasSuffix(".log")) }
                .map { ($0 as NSString).deletingPathExtension }).sorted()
        }

        /// The crash reports of VibeSwitcher's programs in DiagnosticReports.
        public func crashFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: reports.path)) ?? []).filter { crashProgram(file: $0) != nil }.sorted()
        }

        public func hang(_ name: String) -> Hang {
            AppHealth.hang(name: name, log: read(debug.appendingPathComponent(name + ".log")),
                           sample: read(debug.appendingPathComponent(name + ".txt")))
        }

        public func crash(_ file: String) -> Crash? {
            read(reports.appendingPathComponent(file)).flatMap { AppHealth.crash(file: file, text: $0) }
        }

        /// A report, read only (at most 8 MB of it).
        func read(_ url: URL) -> String? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 8 << 20) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The app's memory as it reads it now: its footprint, its peak since launch, and its footprint at launch (MB).
    public struct Memory: Equatable, Sendable {
        public var footprint: Double
        public var peak: Double
        public var atLaunch: Double
        public var launched: Date

        public init(footprint: Double, peak: Double, atLaunch: Double, launched: Date) {
            self.footprint = footprint
            self.peak = peak
            self.atLaunch = atLaunch
            self.launched = launched
        }

        /// MB an hour since launch; nil before `growthAfter`.
        public func growth(now: Date) -> Double? {
            let hours = now.timeIntervalSince(launched) / 3600
            guard now.timeIntervalSince(launched) >= AppHealth.growthAfter else { return nil }
            return (footprint - atLaunch) / hours
        }
    }

    // MARK: What's told

    /// What the watch has taken in and told, kept across launches (`AppHealthWatcher` saves it), so each report is
    /// told once and a repeat is counted.
    public struct Watch: Codable, Equatable, Sendable {
        /// Reports already taken in: each is told (or counted) once, whenever the app sees it.
        public var seenHangs: Set<String> = []
        public var seenCrashes: Set<String> = []
        /// The digest under way: when its first event came, and what it holds.
        public var opened: Double?
        public var hangs: [String] = []
        public var crashes: [String] = []
        public var errors: [String: Int] = [:]
        /// What was told, by signature ("hang …", "crash …"): when, and how often it was seen again since.
        public var told: [String: Told] = [:]
        /// Error kinds told, and when.
        public var errorKindsTold: [String: Double] = [:]
        /// What each day had (yyyy-MM-dd, this Mac's time zone).
        public var days: [String: Day] = [:]
        /// The day the watch last looked on: its trend is due once a later day starts.
        public var lookedOn: String?
        /// Digests no lead could take yet (none ran with watch_app_logs on): sent at the next look.
        public var pending: [String] = []

        public struct Told: Codable, Equatable, Sendable {
            public var at: Double
            public var repeats: Int
            /// What it was, in short: the hang's or crash report's name.
            public var first: String
        }

        public struct Day: Codable, Equatable, Sendable {
            public var hangs = 0
            public var crashes = 0
            public var errors = 0

            var quiet: Bool { hangs == 0 && crashes == 0 && errors == 0 }
        }

        public init() {}

        /// The first time it runs: what's there already is history, not news.
        public mutating func baseline(hangs: [String], crashes: [String]) {
            seenHangs.formUnion(hangs)
            seenCrashes.formUnion(crashes)
        }

        /// The reports in the folders now: new ones go into the digest under way (opened by the first). Returns whether
        /// any was new. Names no longer there are forgotten (`HangWatchdog` keeps a week of them), but not on an empty
        /// list: a folder that couldn't be read for a moment would make every report in it news again.
        @discardableResult
        public mutating func saw(hangs: [String], crashes: [String], now: Date) -> Bool {
            let newHangs = hangs.filter { !seenHangs.contains($0) }
            let newCrashes = crashes.filter { !seenCrashes.contains($0) }
            if !hangs.isEmpty { seenHangs = Set(hangs) }
            if !crashes.isEmpty { seenCrashes = Set(crashes) }
            guard !newHangs.isEmpty || !newCrashes.isEmpty else { return false }
            open(now)
            self.hangs += newHangs
            self.crashes += newCrashes
            days[Self.day(now), default: Day()].hangs += newHangs.count
            return true
        }

        /// New app.log lines: their error kinds, counted into the digest under way.
        public mutating func saw(lines: [String], now: Date) {
            let kinds = lines.compactMap(AppHealth.errorKind)
            guard !kinds.isEmpty else { return }
            open(now)
            for kind in kinds { errors[kind, default: 0] += 1 }
            days[Self.day(now), default: Day()].errors += kinds.count
        }

        private mutating func open(_ now: Date) {
            if opened == nil { opened = now.timeIntervalSince1970 }
        }

        /// When the watch should look next: the digest under way closes, the day ends (its trend), or a pending
        /// digest is tried again.
        public func nextLook(now: Date) -> Date {
            var next = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 60)
            if let opened { next = min(next, Date(timeIntervalSince1970: opened + AppHealth.window)) }
            if !pending.isEmpty { next = min(next, now.addingTimeInterval(5 * 60)) }
            return next
        }

        /// What's due now: the digest under way once `window` has passed since it opened, and a day's trend once a
        /// later day starts. Each goes into `pending`; `AppHealthWatcher` hands those to the lead.
        public mutating func look(now: Date, folders: Folders, memory: Memory?) {
            if let opened, now.timeIntervalSince1970 >= opened + AppHealth.window {
                if let digest = digest(now: now, folders: folders) { pending.append(digest) }
            }
            let today = Self.day(now)
            if let last = lookedOn, last < today, let trend = trend(of: last, now: now, memory: memory) {
                pending.append(trend)
                // Its repeats are told now.
                for key in told.keys { told[key]?.repeats = 0 }
            }
            lookedOn = today
            prune(now: now)
            // A lead that never takes them doesn't make them pile up.
            pending = Array(pending.suffix(10))
        }

        /// The digest under way, read from its files; nil when nothing in it is news (every freeze and crash told within
        /// `repeatWithin`, and no new error kind), each repeat counted.
        mutating func digest(now: Date, folders: Folders) -> String? {
            let at = now.timeIntervalSince1970
            // A freeze that began moments ago may not have its sample yet (`sample` takes 3 s, after the .log): it
            // goes in the next digest, read whole.
            let read = hangs.sorted().map(folders.hang)
            let unsampled = read.filter { $0.sampled == false && at - ($0.since?.timeIntervalSince1970 ?? 0) < Self.sampleWait }
            defer {
                opened = unsampled.isEmpty ? nil : at
                hangs = unsampled.map(\.name)
                crashes = []
                errors = [:]
            }
            var freezes: [String] = []
            var starved = 0
            var repeated: [String] = []
            // One without a signature is a group of its own. A starved one isn't the same freeze as the app's own work
            // in the same frames (nor counted as its repeat).
            func mark(_ hang: Hang) -> String { hang.verdict == .starved ? " [likely starvation]" : "" }
            let groups = Dictionary(grouping: read.filter { hang in !unsampled.contains { $0.name == hang.name } }, by: { ($0.signature ?? $0.name) + mark($0) })
            for (_, group) in groups.sorted(by: { $0.value[0].name < $1.value[0].name }) {
                guard let signature = group[0].signature else {
                    freezes.append(Self.line(group))
                    continue
                }
                let key = "hang " + signature + mark(group[0])
                if let last = told[key], at - last.at < AppHealth.repeatWithin {
                    told[key]?.repeats += group.count
                    repeated.append("\(group.count == 1 ? "a freeze" : "\(group.count) freezes") like \(last.first) (\(signature + mark(group[0])))")
                    continue
                }
                told[key] = Told(at: at, repeats: 0, first: group[0].name)
                freezes.append(Self.line(group))
                if group[0].verdict == .starved { starved += 1 }
            }
            var crashLines: [String] = []
            for crash in crashes.sorted().compactMap(folders.crash) {
                days[Self.day(now), default: Day()].crashes += 1
                let key = "crash " + crash.signature
                if let last = told[key], at - last.at < AppHealth.repeatWithin {
                    told[key]?.repeats += 1
                    repeated.append("a crash like \(last.first)")
                    continue
                }
                told[key] = Told(at: at, repeats: 0, first: crash.file)
                crashLines.append(Self.line(crash))
            }
            let newKinds = errors.keys.filter { kind in errorKindsTold[kind].map { at - $0 >= AppHealth.repeatWithin } ?? true }
            guard !freezes.isEmpty || !crashLines.isEmpty || !newKinds.isEmpty else { return nil }
            for kind in errors.keys { errorKindsTold[kind] = at }
            var parts = ["VibeSwitcher's own logs show something new (read by VibeSwitcher itself, no model; only names, numbers and function names, never what a message or transcript says):"]
            if !freezes.isEmpty {
                parts.append("Freezes of its main thread (reports in ~/.vibeswitcher/debug, .txt the sampled stacks, .log the state):")
                parts += freezes
            }
            if !crashLines.isEmpty {
                parts.append("Crashes (reports in ~/Library/Logs/DiagnosticReports):")
                parts += crashLines
            }
            if !errors.isEmpty {
                let counted = errors.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                parts.append("Error lines in app.log within \(Int(AppHealth.window / 60)) min, by kind: "
                             + counted.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
            }
            if !repeated.isEmpty {
                parts.append("Seen again, told within 24 h, so only counted (the daily trend has the counts): " + repeated.joined(separator: "; "))
            }
            if starved > 0, starved == freezes.count, crashLines.isEmpty, errors.isEmpty {
                parts.append("\(starved == 1 ? "That freeze looks" : "Those freezes look") like starvation (the Mac loaded or paging), not the app's work: no task for "
                             + "\(starved == 1 ? "it" : "them"); the reports have the full stacks.")
            } else {
                parts.append("Turn what's a real bug into a task (one already on the board needs nothing"
                             + (starved > 0 ? "; one marked likely starvation needs none" : "") + "); read the reports for the full stacks.")
            }
            return Redaction.secrets(in: parts.joined(separator: "\n"))
        }

        /// How long a freeze's sample is waited for before it's told without one.
        static let sampleWait: TimeInterval = 120

        /// One line for freezes with the same top frames.
        public static func line(_ group: [Hang]) -> String {
            let hang = group[0]
            var words = ["- \(hang.name)" + (group.count > 1 ? " and \(group.count - 1) more like it (\(group.dropFirst().map(\.name).joined(separator: ", ")))" : "") + ":"]
            let verdict = hang.verdict
            let load = hang.load.map { AppHealth.describeLoad($0, cpus: hang.cpus) }
            if verdict == .starved, let spread = hang.spread {
                words.append("likely starvation: the Mac was loaded or paging; no app work to fix (" + AppHealth.describe(spread, verdict: nil)
                             + (load.map { "; \($0)" } ?? "") + ");")
            }
            words.append(hang.duration.map { String(format: "stuck %.1f s", $0) + ";" } ?? "stuck, no recovery recorded;")
            if hang.shown == "window never opened" {
                words.append("window never opened;")
            } else if hang.session != nil || hang.shown != nil || hang.key != nil {
                words.append("\(hang.session ?? "unknown") session selected, \(hang.shown ?? "unknown") shown, window \(hang.key == true ? "key" : hang.key == false ? "not key" : "key unknown");")
            } else {
                words.append("no app state;")
            }
            if let footprint = hang.footprint {
                words.append(String(format: "footprint %.0f MB", footprint) + (hang.peak.map { String(format: " (peak %.0f MB)", $0) } ?? "") + ";")
            }
            let source = hang.caught ? " (caught while stuck)" : ""
            if !hang.frames.isEmpty { words.append("top app frames\(source): " + hang.frames.joined(separator: " < ")) }
            else if !hang.systemFrames.isEmpty { words.append("no app frames on the main thread's busiest path\(source); its top frames: " + hang.systemFrames.joined(separator: " < ")) }
            else { words.append("no sample of its stacks") }
            if let inside = hang.sampleInside { words.append(String(format: "(%.0f%% of its sample inside the stall)", inside * 100)) }
            // Real work or a wait reads as before, with what its sample says after it.
            if verdict != .starved {
                let after = [verdict.flatMap { verdict in hang.spread.map { AppHealth.describe($0, verdict: verdict) } }, load].compactMap { $0 }
                if !after.isEmpty { words.append("— " + after.joined(separator: "; ")) }
            }
            return words.joined(separator: " ")
        }

        static func line(_ crash: Crash) -> String {
            "- \(crash.file): \(crash.program)\(crash.version.map { " \($0)" } ?? ""): \(crash.exception); top frames: "
                + (crash.frames.isEmpty ? "none recorded" : crash.frames.joined(separator: " < "))
        }

        /// A day's trend: its freezes against the 7 days before, crashes, error lines, memory now, and the repeats
        /// counted since they were told. Nil on a quiet day (none of those, and memory not growing fast).
        func trend(of day: String, now: Date, memory: Memory?) -> String? {
            let had = days[day] ?? Day()
            let growth = memory?.growth(now: now)
            let growing = growth.map { $0 >= AppHealth.worryingGrowth } ?? false
            let repeats = told.filter { $0.value.repeats > 0 }.sorted { $0.key < $1.key }
            guard !had.quiet || growing || !repeats.isEmpty else { return nil }
            let before = (1...7).compactMap { Self.day(day, offset: -$0) }.map { days[$0]?.hangs ?? 0 }
            let average = Double(before.reduce(0, +)) / 7
            var parts = ["VibeSwitcher's day, \(day), from its own logs (read by VibeSwitcher itself, no model): "
                         + "\(had.hangs) \(had.hangs == 1 ? "freeze" : "freezes") (" + String(format: "%.1f", average) + " a day over the 7 days before), "
                         + "\(had.crashes) \(had.crashes == 1 ? "crash" : "crashes"), \(had.errors) error \(had.errors == 1 ? "line" : "lines")."]
            if let memory {
                let hours = now.timeIntervalSince(memory.launched) / 3600
                parts.append(String(format: "Memory now: footprint %.0f MB, peak %.0f MB since launch %.0f h ago", memory.footprint, memory.peak, hours)
                             + (growth.map { String(format: ", %@%.0f MB an hour since launch", $0 >= 0 ? "+" : "", $0) } ?? "")
                             + (growing ? " (growing: worth a look)." : "."))
            }
            if !repeats.isEmpty {
                parts.append("Seen again since told, not told again: " + repeats.map { "\($0.key) ×\($0.value.repeats) (first \($0.value.first))" }.joined(separator: "; ") + ".")
            }
            return Redaction.secrets(in: parts.joined(separator: " "))
        }

        /// What was told two days ago or more is forgotten, and days older than the trend's week.
        mutating func prune(now: Date) {
            let at = now.timeIntervalSince1970
            told = told.filter { at - $0.value.at < 2 * AppHealth.repeatWithin }
            errorKindsTold = errorKindsTold.filter { at - $0.value < 2 * AppHealth.repeatWithin }
            if let oldest = Self.day(Self.day(now), offset: -8) { days = days.filter { $0.key >= oldest } }
        }

        /// yyyy-MM-dd in this Mac's time zone.
        public static func day(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }

        /// The day `offset` days from `day`.
        static func day(_ day: String, offset: Int) -> String? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: day), let moved = Calendar.current.date(byAdding: .day, value: offset, to: date) else { return nil }
            return formatter.string(from: moved)
        }
    }
}
