import AppKit
import Foundation
import JavaScriptCore
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// One word per state (WL-3): Needs you, Working, Background, Done, Idle, Paused, Ended (and Unknown), from
/// `StateWord`, on every surface, and one duration format, `Durations.short`. The lint scans the app's, VibeCore's and
/// the phone's string literals, so a new "waiting" or "Ready" for a state fails here.
struct GlossaryTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let app = root.appendingPathComponent("Web/app.js")

    // MARK: The lint

    /// Words for a state that aren't the glossary's, and the glossary's phrases after a count, which only `StateWord`
    /// (and the phone's copy of it) may spell out. Matched against a whole literal, less its numbers, punctuation and
    /// interpolations: "waiting", "\(n) need you", 'Ready', never prose like "1 session needs you: api.".
    static let offGlossary: Set<String> = ["waiting", "ready", "needs input", "need input", "needs attention", "busy",
                                           "background jobs", "status unknown", "needs you", "need you", "in background"]

    /// Where such a word is fine: the glossary itself, a key nobody reads, and words that aren't a session's state.
    static let allowed: [(file: String, word: String, why: String)] = [
        ("Sources/VibeCore/Models.swift", "needs you", "the glossary: StateWord.counted"),
        ("Sources/VibeCore/Models.swift", "need you", "the glossary: StateWord.counted"),
        ("Sources/VibeCore/Models.swift", "in background", "the glossary: StateWord.counted"),
        ("Web/app.js", "needs you", "the phone's copy of the glossary, WORDS (checked below)"),
        ("Web/app.js", "need you", "the phone's copy of the glossary, WORDS (checked below)"),
        ("Web/app.js", "in background", "the phone's copy of the glossary, WORDS (checked below)"),
        ("Sources/VibeSwitcher/PhoneAccess.swift", "waiting", "the Today ledger's JSON key, never shown"),
        ("Sources/VibeCore/LeadActivity.swift", "needs input", "what the lead's tools tell the lead agent, not the user"),
    ]

    /// The string literals on a line of Swift or JavaScript, with each interpolation (`\(…)`, `${…}`) a space and the
    /// literals inside it listed too. A `//` comment ends the line; so does an unclosed quote.
    static func literals(in line: String, quotes: Set<Character>) -> [String] {
        let chars = Array(line)
        var index = 0
        var found: [String] = []

        func skipInterpolation(closing: Character) {
            let opening: Character = closing == ")" ? "(" : "{"
            var depth = 1
            while index < chars.count {
                let char = chars[index]
                index += 1
                if quotes.contains(char) {
                    found.append(string(char))
                } else if char == opening {
                    depth += 1
                } else if char == closing {
                    depth -= 1
                    if depth == 0 { return }
                }
            }
        }

        /// Called past the opening quote; returns the literal's text, leaving `index` past the closing quote.
        func string(_ quote: Character) -> String {
            var text = ""
            while index < chars.count {
                let char = chars[index]
                if char == quote { index += 1; return text }
                if char == "\\", index + 1 < chars.count {
                    index += 2
                    if chars[index - 1] == "(" && quote == "\"" {
                        skipInterpolation(closing: ")")
                        text += " "
                    } else {
                        text.append(chars[index - 1])
                    }
                    continue
                }
                if quote == "`", char == "$", index + 1 < chars.count, chars[index + 1] == "{" {
                    index += 2
                    skipInterpolation(closing: "}")
                    text += " "
                    continue
                }
                text.append(char)
                index += 1
            }
            return text
        }

        while index < chars.count {
            let char = chars[index]
            if char == "/", index + 1 < chars.count, chars[index + 1] == "/" { break }
            index += 1
            guard quotes.contains(char) else { continue }
            let literal = string(char)
            found.append(literal)
        }
        return found
    }

    /// A literal less its numbers, punctuation and the spaces left by interpolations, in lower case: "\(n) need you" →
    /// "need you".
    static func core(_ literal: String) -> String {
        literal.trimmingCharacters(in: CharacterSet.whitespaces.union(.decimalDigits).union(CharacterSet(charactersIn: "·:,;()!.…⏸-—")))
            .lowercased()
    }

    /// "File:12: 'waiting' in <line>" for each state word outside the glossary in a file's text; `allowedSeen` gets the
    /// allow-list's entries that matched.
    static func offGlossaryWords(in text: String, file: String, allowedSeen: inout Set<String>) -> [String] {
        let quotes: Set<Character> = file.hasSuffix(".js") ? ["\"", "'", "`"] : ["\""]
        var found: [String] = []
        var inMultiline = false
        for (number, line) in text.components(separatedBy: "\n").enumerated() {
            // A Swift multi-line literal is prose (a prompt, a script); its lines aren't code to scan.
            let fences = line.components(separatedBy: "\"\"\"").count - 1
            if fences > 0 {
                if fences % 2 == 1 { inMultiline.toggle() }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inMultiline || trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            for literal in literals(in: line, quotes: quotes) {
                let word = core(literal)
                guard offGlossary.contains(word) else { continue }
                if allowed.contains(where: { $0.file == file && $0.word == word }) {
                    allowedSeen.insert("\(file) \(word)")
                    continue
                }
                found.append("\(file):\(number + 1): '\(word)' in \(trimmed)")
            }
        }
        return found
    }

    @Test func theLintFindsOffGlossaryWordsAndOnlyThose() {
        var seen = Set<String>()
        let swift = { (line: String) in Self.offGlossaryWords(in: line, file: "Sources/VibeCore/X.swift", allowedSeen: &seen) }
        #expect(swift(#"case .needsInput: return RowState(text: "waiting", since: since, group: .needsYou)"#).count == 1)
        #expect(swift(#"case .ready: return "Ready""#).count == 1)
        #expect(swift(#"case .needsInput: return "Needs input""#).count == 1)
        #expect(swift(#"parts.append(n == 1 ? "1 needs you" : "\(n) need you")"#).count == 2)
        #expect(swift(#"Text("\(count) waiting")"#).count == 1)
        #expect(swift(#"Text("\(count == 1 ? "1 waiting" : "\(count) waiting")")"#).count == 2)
        #expect(swift(#"Text("\(count) report\(count == 1 ? "" : "s") waiting")"#).isEmpty)
        #expect(swift(#"return "background jobs""#).count == 1)
        #expect(swift(#"Text(StateWord.needsYou.label) // was "waiting""#).isEmpty)
        #expect(swift(#"text.hasSuffix("1 session needs you: api.")"#).isEmpty)
        #expect(swift("let prompt = \"\"\"\nworkers \"waiting\" here\n\"\"\"").isEmpty)
        let js = { (line: String) in Self.offGlossaryWords(in: line, file: "Web/x.js", allowedSeen: &seen) }
        #expect(js("const LABELS = { needsInput: 'need you', working: 'working' };").count == 1)
        #expect(js("chip.append(dot, `${count} waiting`);").count == 1)
        #expect(js("el('span', 'chip', counted('paused', n)); // don't say 'waiting'").isEmpty)
    }

    @Test func everyStateWordIsTheGlossarys() throws {
        var files = [Self.app]
        for folder in ["Sources/VibeSwitcher", "Sources/VibeCore"] {
            let walk = try #require(FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            files += walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        #expect(files.count > 100)
        var found: [String] = []
        var seen = Set<String>()
        for url in files {
            let file = url.standardizedFileURL.path.replacingOccurrences(of: Self.root.standardizedFileURL.path + "/", with: "")
            found += Self.offGlossaryWords(in: try String(contentsOf: url, encoding: .utf8), file: file, allowedSeen: &seen)
        }
        let stale = Self.allowed.filter { !seen.contains("\($0.file) \($0.word)") }.map { "\($0.file): '\($0.word)'" }
        #expect(stale.isEmpty, "Allowed but no longer there; take them off the list:\n\(stale.joined(separator: "\n"))")
        #expect(found.isEmpty, "Say a session's state with StateWord (label, text, counted), not another word for it:\n\(found.joined(separator: "\n"))")
    }

    // MARK: The glossary on each surface

    static func session(_ status: SessionStatus, paused: Bool = false) -> Session {
        var session = Session(tty: "ttys001", agent: .claude, pid: 1, startedAt: Date(timeIntervalSince1970: 0), cwd: nil, project: "p",
                              task: nil, status: status, statusSince: Date(timeIntervalSince1970: 100), detail: nil, hasHooks: true,
                              inTerminalApp: true)
        if paused { session.pausedUntil = .distantFuture }
        return session
    }

    static let statuses: [SessionStatus] = [.needsInput, .working, .background, .done, .idle, .unknown]

    @Test func everySurfaceSaysTheGlossarysWord() {
        #expect(StateWord.allCases.map(\.label) == ["Needs you", "Working", "Background", "Done", "Idle", "Paused", "Ended", "Unknown"])
        #expect(Self.statuses.map(\.label) == ["Needs you", "Working", "Background", "Done", "Idle", "Unknown"])
        #expect(AttentionGroup.allCases.map(\.title) == ["Needs you", "Working", "Done", "Idle"])
        let now = Date(timeIntervalSince1970: 1000)
        for status in Self.statuses {
            let row = WindowRow(content: .agent(Self.session(status)), project: "p")
            #expect(row.state(now: now).text == status.word.text)
            #expect(row.pillLabel(row.state(now: now)) == status.label)
            #expect(PhoneAccess.statusLabel(Self.session(status)) == status.label)
        }
        let paused = WindowRow(content: .agent(Self.session(.working, paused: true)), project: "p")
        #expect(paused.state(now: now).text == "paused" && paused.pillLabel(paused.state(now: now)) == "Paused")
        #expect(StateWord.needsYou.counted(1) == "1 needs you" && StateWord.needsYou.counted(2) == "2 need you")
        #expect(StateWord.background.counted(3) == "3 in background" && StateWord.paused.counted(2) == "2 paused")
    }

    /// The phone's `WORDS` and `counted`, run as the phone runs them, against `StateWord`.
    @Test func thePhonesWordsAreTheGlossarys() throws {
        let source = try String(contentsOf: Self.app, encoding: .utf8)
        let words = try #require(source.range(of: "const WORDS = {"))
        let wordsEnd = try #require(source.range(of: "\n};\n", range: words.upperBound..<source.endIndex))
        let counted = try #require(source.range(of: "function counted(state, count) {"))
        let countedEnd = try #require(source.range(of: "\n", range: counted.upperBound..<source.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript(source[words.lowerBound..<wordsEnd.upperBound].replacingOccurrences(of: "const WORDS", with: "var WORDS"))
        context.evaluateScript(String(source[counted.lowerBound..<countedEnd.lowerBound]))
        #expect(context.exception == nil, "\(String(describing: context.exception))")
        // The phone keys its words by the status it gets from /api/state, plus paused and ended.
        let keys: [StateWord: String] = [.needsYou: SessionStatus.needsInput.rawValue, .working: "working", .background: "background",
                                         .done: "done", .idle: "idle", .paused: "paused", .ended: "ended", .unknown: "unknown"]
        let phoneKeys = context.evaluateScript("Object.keys(WORDS)").toArray() as? [String]
        #expect(Set(phoneKeys ?? []) == Set(keys.values))
        for word in StateWord.allCases {
            let key = try #require(keys[word])
            #expect(context.evaluateScript("WORDS.\(key).label").toString() == word.label, "\(key)")
            for count in [1, 2, 7] {
                #expect(context.evaluateScript("counted('\(key)', \(count))").toString() == word.counted(count), "\(key) × \(count)")
            }
        }
        for status in Self.statuses {
            #expect(keys[status.word] == status.rawValue)
        }
    }

    // MARK: One duration format

    /// The phone's `short`, run as the phone runs it, against `Durations.short`.
    @Test func thePhoneFormatsDurationsAsTheMac() throws {
        let source = try String(contentsOf: Self.app, encoding: .utf8)
        let start = try #require(source.range(of: "function short(seconds) {"))
        let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript(String(source[start.lowerBound..<end.upperBound]))
        #expect(context.exception == nil, "\(String(describing: context.exception))")
        for seconds: Double in [-5, 0, 0.9, 1, 45, 59, 60, 61, 719, 3599, 3600, 3659, 3660, 7325, 86399, 86400, 93600, 200_000, 2_000_000] {
            #expect(context.evaluateScript("short(\(seconds))").toString() == Durations.short(seconds), "\(seconds)s")
        }
        #expect(Durations.short(26 * 3600) == "1d 2h")   // the popover said "26h 0m"
    }

    /// The popover, the rows and the phone say a duration only through `Durations.short` (the phone through its copy,
    /// `short`): no arithmetic on 60, 3600 or 86400 seconds of their own.
    @Test func durationsHaveOneFormatter() throws {
        let files = ["Sources/VibeSwitcher/PopoverView.swift", "Sources/VibeSwitcher/MainWindow/SessionListView.swift",
                     "Sources/VibeSwitcher/MainWindow/SessionHeaderView.swift", "Sources/VibeSwitcher/MainWindow/Lead/TeamRows.swift",
                     "Sources/VibeSwitcher/MainWindow/MainWindowController.swift", "Web/app.js"]
        let arithmetic = try NSRegularExpression(pattern: #"[/%]\s*(60|3600|86400)\b"#)
        var found: [String] = []
        for file in files {
            var text = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
            if file.hasSuffix(".js"), let start = text.range(of: "function short(seconds) {"),
               let end = text.range(of: "\n}\n", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
            for (number, line) in text.components(separatedBy: "\n").enumerated()
            where arithmetic.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil || line.contains("Durations.compact") {
                found.append("\(file):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(found.isEmpty, "Format durations with Durations.short:\n\(found.joined(separator: "\n"))")
    }
}

/// Pictures of the glossary on the window: the sidebar list by attention (its group headers and a row per state, the
/// Ended fold open) and the header's pill for each state. Only with `GLOSSARY_SNAPSHOT_DIR=/some/folder swift test
/// --filter GlossarySnapshots` (the popover's and the sidebar's session rows: `StatusSnapshots`).
@MainActor
struct GlossarySnapshots {
    static let folder = ProcessInfo.processInfo.environment["GLOSSARY_SNAPSHOT_DIR"]

    @Test(.enabled(if: folder != nil)) func drawTheWindowsWords() throws {
        let folder = try #require(Self.folder)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let now = EndedFoldTests.now
        var sessions = [("Release notes", SessionStatus.needsInput), ("Menu shortcuts", .working), ("Nightly import", .background),
                        ("Docs pass", .done), ("Notes", .idle), ("Billing", .working), ("Scratch", .unknown)].map { name, status in
            var session = EndedFoldTests.agent(name, project: "acme", status: status)
            session.statusSince = now - (status == .background ? 26 * 3_600 : status == .idle ? 3 * 3_600 + 300 : 420)
            return session
        }
        sessions[5].pausedUntil = .distantFuture
        let ended = [EndedFoldTests.hosted("Build script", project: "acme", exit: 129)]
        let model = WindowModel()
        let grouping = model.grouping
        defer {
            model.grouping = grouping
            UserDefaults.standard.removeObject(forKey: WindowModel.endedOpenKey)
        }
        model.grouping = .attention
        model.update(sessions: sessions, hosted: ended, table: TableRead(at: now))
        model.endedOpen = true
        let scratch = FileManager.default.temporaryDirectory
        let host = HostClient(socketPath: scratch.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { scratch }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: scratch.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: scratch, home: scratch.path) { _ in "true" }
        let snapshots = EndedSnapshots()
        try snapshots.write(SessionListView(model: model, leads: leads, actions: EndedSnapshots.actions), name: "window-rows",
                            folder: folder, size: NSSize(width: 300, height: 560))
        let pills = VStack(alignment: .leading, spacing: 6) {
            ForEach(model.allRows, id: \.id) { row in StatusPill(row: row, now: now) }
        }
        .padding(12)
        try snapshots.write(pills, name: "window-pills", folder: folder, size: NSSize(width: 200, height: 260))
    }
}
