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
    public static func hangHeader(since: Date, duration: TimeInterval?) -> String {
        "vibeswitcher-hang: since=\(String(format: "%.3f", since.timeIntervalSince1970))"
            + (duration.map { " duration=\(String(format: "%.1f", $0))" } ?? "")
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

        public init(name: String) { self.name = name }

        /// What makes two freezes the same: their top 3 app frames.
        public var signature: String { frames.isEmpty ? "no app frames" : frames.prefix(3).joined(separator: " < ") }
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
            hang.footprint = sampleMegabytes(sample, "Physical footprint:")
            hang.peak = sampleMegabytes(sample, "Physical footprint (peak):")
            hang.frames = appFrames(sample: sample, image: "VibeSwitcher")
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
    static func nameDate(_ name: String) -> Date? {
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
        let lines = sample.components(separatedBy: "\n")
        guard let graph = lines.firstIndex(where: { $0.hasPrefix("Call graph:") }) else { return [] }
        // The main thread's block: its line, then every line indented deeper.
        var threadDepth: Int?
        var nodes: [(depth: Int, count: Int, text: String, parent: Int?)] = []
        var children: [[Int]] = []
        var stack: [Int] = []
        for line in lines[(graph + 1)...] {
            guard let (depth, count, text) = graphLine(line) else {
                if threadDepth != nil { break }
                continue
            }
            if let top = threadDepth {
                if depth <= top { break }
                while let last = stack.last, nodes[last].depth >= depth { stack.removeLast() }
                nodes.append((depth, count, text, stack.last))
                children.append([])
                if let parent = stack.last { children[parent].append(nodes.count - 1) }
                stack.append(nodes.count - 1)
            } else if text.hasPrefix("Thread_") {
                // The first thread is the main one (sample lists it first, as "com.apple.main-thread").
                threadDepth = depth
            }
        }
        guard !nodes.isEmpty else { return [] }
        let roots = nodes.indices.filter { nodes[$0].parent == nil }
        guard var current = roots.max(by: { nodes[$0].count < nodes[$1].count }) else { return [] }
        var path = [current]
        while let next = children[current].max(by: { nodes[$0].count < nodes[$1].count }) {
            path.append(next)
            current = next
        }
        let marker = "  (in \(image))"
        let names: [String] = path.compactMap { index in
            let text = nodes[index].text
            guard let range = text.range(of: marker) else { return nil }
            var name = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            for prefix in ["specialized ", "merged "] where name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
            guard !name.isEmpty, !entryPoints.contains(name), !wrapperPrefixes.contains(where: name.hasPrefix) else { return nil }
            return String(name.prefix(120))
        }
        var deduplicated: [String] = []
        for name in names.reversed() where deduplicated.last != name { deduplicated.append(name) }
        return Array(deduplicated.prefix(5))
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
        /// any was new. Names no longer there are forgotten (`HangWatchdog` keeps the ten newest).
        @discardableResult
        public mutating func saw(hangs: [String], crashes: [String], now: Date) -> Bool {
            let newHangs = hangs.filter { !seenHangs.contains($0) }
            let newCrashes = crashes.filter { !seenCrashes.contains($0) }
            seenHangs = Set(hangs)
            seenCrashes = Set(crashes)
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
            defer {
                opened = nil
                hangs = []
                crashes = []
                errors = [:]
            }
            let at = now.timeIntervalSince1970
            var freezes: [String] = []
            var repeated: [String] = []
            let groups = Dictionary(grouping: hangs.sorted().map(folders.hang), by: \.signature)
            for (signature, group) in groups.sorted(by: { $0.value[0].name < $1.value[0].name }) {
                let key = "hang " + signature
                if let last = told[key], at - last.at < AppHealth.repeatWithin {
                    told[key]?.repeats += group.count
                    repeated.append("\(group.count == 1 ? "a freeze" : "\(group.count) freezes") like \(last.first) (\(signature))")
                    continue
                }
                told[key] = Told(at: at, repeats: 0, first: group[0].name)
                freezes.append(Self.line(group))
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
            parts.append("Turn what's a real bug into a task (one already on the board needs nothing); read the reports for the full stacks.")
            return Redaction.secrets(in: parts.joined(separator: "\n"))
        }

        /// One line for freezes with the same top frames.
        static func line(_ group: [Hang]) -> String {
            let hang = group[0]
            var words = ["- \(hang.name)" + (group.count > 1 ? " and \(group.count - 1) more like it (\(group.dropFirst().map(\.name).joined(separator: ", ")))" : "") + ":"]
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
            words.append(hang.frames.isEmpty ? "no app frames on the main thread's busiest path" : "top app frames: " + hang.frames.joined(separator: " < "))
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
