import Foundation

/// What start_worker and auto_advance's start tell the lead when a task's boundaries name a source file other work has
/// too: another running or planned task's boundaries name it, or a live branch changed it. A warning only: it refuses
/// nothing and orders nothing (2026-11-09; on 2026-10-23 the composer and phone tasks both edited the send path, each
/// conflict cost rework and a re-audit, and on 2026-11-08 the lead missed the rule that was set by hand after it).
/// Whatever can't be read (a boundary with no path in it, a branch git can't diff) says nothing.
enum LeadOverlap {
    /// Other work, as far as it can be told.
    struct Other {
        var slug: String
        var state: String
        /// Its boundaries name these; empty unless it's running or planned.
        var named: Set<String> = []
        /// Its branch changes these.
        var changed: Set<String> = []
        /// It's set to start after the task being started (its `after`): the order the rule asks for is already there.
        var startsAfter = false
    }

    /// The input path's files (decision 2026-10-23 11:59), each with the names a boundary may call it by: PhoneAccess's
    /// send functions, HostClient.send and its per-session paced input, the host's per-session InputOrder, RemoteInput.
    static let inputPath: [(file: String, names: [String])] = [
        ("Sources/VibeSwitcher/PhoneAccess.swift", [#"\bPhoneAccess\b"#]),
        ("Sources/VibeSwitcher/HostClient.swift", [#"\bHostClient\b"#, #"\bPacedInput\b"#, #"(?i)\bsend[- ]?queue\b"#]),
        ("Sources/VibeSwitcher/RemoteInput.swift", [#"\bRemoteInput\b"#]),
        ("Sources/VibeHost/InputOrder.swift", [#"\bInputOrder\b"#, #"(?i)\bsend[- ]?queue\b"#]),
    ]

    /// What the lead is told the input path is, in the words of the rule.
    static let inputPathWords = "PhoneAccess's send functions, HostClient.send, the per-session send queue, RemoteInput"

    /// The extensions of what counts as a source file: a closed list, so "e.g.", "v1.2", "HostClient.send" and a
    /// board.json in a boundary's prose aren't taken for files, and docs (.md, .txt) never count.
    private static let sourceExtensions = "swift|m|mm|h|c|cc|cpp|hpp|sh|bash|zsh|py|js|jsx|mjs|ts|tsx|rs|go|rb|java|kt|php|css|scss|html|sql|ex|exs|metal"
    private static let pathPattern = try? NSRegularExpression(
        pattern: #"(?<![\w./*-])(?:\.?/)?(?:[\w.+-]+/)*[\w+-][\w.+-]*\.(?:"# + sourceExtensions + #")(?![\w/-])(?!\.\w)"#)
    /// A boundary is read a sentence at a time, and "A.swift but not B.swift" or "A.swift, and must not change B.swift"
    /// as two clauses: what's forbidden is only what follows the negation.
    private static let clauseBreak = try? NSRegularExpression(
        pattern: #"(?<=[.;!?])\s+|;\s*|\n+|\s+but\s+|(?:,\s*(?:and\s+)?|\s+and\s+)(?=(?:not|never|no|except|must not|mustn['’]t|may not|do not|don['’]t|leave|avoid)\b)"#,
        options: [.caseInsensitive])

    /// The input path's files this repository has: another project's HostClient is none of the rule's business.
    static func inputFiles(root: String) -> [String] {
        inputPath.map(\.file).filter { FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent($0)) }
    }

    /// `a` and `b` are the same file: one path, or one's the end of the other ("HostClient.swift" and
    /// "Sources/VibeSwitcher/HostClient.swift"), a whole path component at a time.
    static func same(_ a: String, _ b: String) -> Bool { a == b || a.hasSuffix("/" + b) || b.hasSuffix("/" + a) }

    /// Counts as a source file others could collide on: docs and the lead's records never do.
    static func counts(_ path: String, records: String?) -> Bool {
        let path = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        guard !path.hasPrefix("docs/"), !path.hasPrefix(".vibeswitcher/"), path != ProductInventory.output else { return false }
        if let records, path.hasPrefix(records + "/") { return false }
        guard let dot = path.lastIndex(of: ".") else { return false }
        return sourceExtensions.split(separator: "|").contains(path[path.index(after: dot)...])
    }

    private static func clauses(of boundary: String) -> [String] {
        guard let clauseBreak else { return [boundary] }
        let text = boundary as NSString
        var parts: [String] = []
        var from = 0
        for match in clauseBreak.matches(in: boundary, range: NSRange(location: 0, length: text.length)) {
            parts.append(text.substring(with: NSRange(location: from, length: match.range.location - from)))
            from = match.range.location + match.range.length
        }
        parts.append(text.substring(from: from))
        return parts
    }

    /// A clause that keeps a file out of the task rather than giving it to it ("Must not change X", "Y stays untouched").
    private static func forbids(_ clause: String) -> Bool {
        let text = clause.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        // "No changes outside A.swift" gives it A.swift.
        if text.contains(" outside ") { return false }
        let starts = ["no ", "not ", "never ", "don't ", "do not ", "does not ", "must not ", "mustn't ", "may not ", "can't ", "cannot ",
                      "avoid ", "leave ", "without ", "except ", "excluding ", "out of scope", "hands off", "read-only", "read only"]
        if starts.contains(where: text.hasPrefix) { return true }
        return [" must not ", " mustn't ", " may not ", "don't touch", "do not touch", "don't change", "do not change",
                "out of scope", "off limits", "untouched", " stays as "].contains(where: text.contains)
    }

    /// The source files `boundaries` name, read from their text; the input path's by its names too. Nothing for text
    /// with no path in it.
    static func claims(in boundaries: [String], input: [String], records: String?) -> Set<String> {
        guard let pathPattern else { return [] }
        var found = Set<String>()
        for clause in boundaries.flatMap(clauses(of:)) where !forbids(clause) {
            let text = clause as NSString
            for match in pathPattern.matches(in: clause, range: NSRange(location: 0, length: text.length)) {
                let path = text.substring(with: match.range)
                found.insert(path.hasPrefix("./") ? String(path.dropFirst(2)) : path)
            }
            for entry in inputPath where input.contains(entry.file) {
                if entry.names.contains(where: { clause.range(of: $0, options: .regularExpression) != nil }) { found.insert(entry.file) }
            }
        }
        // The input path's files under their whole names, and one file once however many ways it's named.
        let whole = Set(found.filter { counts($0, records: records) }.map { path in input.first { same($0, path) } ?? path })
        return whole.filter { path in !whole.contains { $0 != path && $0.count > path.count && same($0, path) } }
    }

    /// The warning for `slug`'s start: each file its `claims` share with `others`, who has it and in what state, and
    /// the stronger line when one is on the input path. nil when none overlap.
    static func warning(slug: String, claims: Set<String>, others: [Other], input: [String]) -> String? {
        struct Holder { var other: Other; var named = false; var changed = false }
        var files: [String: [String: Holder]] = [:]
        func note(_ path: String, _ claim: String, _ other: Other, named: Bool) {
            let file = path.count > claim.count ? path : claim
            var holder = files[file, default: [:]][other.slug] ?? Holder(other: other)
            if named { holder.named = true } else { holder.changed = true }
            files[file, default: [:]][other.slug] = holder
        }
        for claim in claims {
            for other in others {
                for path in other.named where same(path, claim) { note(path, claim, other, named: true) }
                for path in other.changed where same(path, claim) { note(path, claim, other, named: false) }
            }
        }
        guard !files.isEmpty else { return nil }
        func said(_ holder: Holder) -> String {
            let how = [holder.changed ? "its branch changes it" : nil, holder.named ? "its boundaries name it" : nil].compactMap { $0 }.joined(separator: " and ")
            return "\(holder.other.slug) (\(holder.other.state)\(holder.other.startsAfter ? ", set to start after this one" : ""): \(how))"
        }
        let listed = files.keys.sorted().map { file in
            "\(file): " + files[file, default: [:]].keys.sorted().compactMap { files[file]?[$0].map(said) }.joined(separator: ", ")
        }
        var text = "Overlap for \(slug)'s start (a warning only: nothing was refused or reordered). " + listed.joined(separator: "; ") + "."
        let onInput = files.keys.sorted().filter { file in input.contains { same($0, file) } }
        if !onInput.isEmpty {
            let who = Set(onInput.flatMap { files[$0, default: [:]].keys }).sorted().joined(separator: ", ")
            text += " Input path: \(onInput.joined(separator: ", ")) \(onInput.count == 1 ? "is" : "are") on the phone and session send path (\(inputPathWords))."
                + " The 2026-10-23 rule has tasks on it run one after another, never in parallel, the later one starting from the base after the earlier merges: \(slug) and \(who). Put them in order with after, unless they already are, or hold one. This is told by file: tasks in other functions of it, off the send path, may run side by side."
        }
        return text
    }
}

extension LeadToolset {
    /// `LeadOverlap`'s warning for starting `task`, from the board and the live branches as they are now.
    func overlapWarning(_ task: LeadTask) -> String? {
        let workflow = self.workflow
        let records = workflow.recordsDir
        let input = LeadOverlap.inputFiles(root: root)
        let claims = LeadOverlap.claims(in: task.contract.boundaries, input: input, records: records)
        guard !claims.isEmpty else { return nil }
        let others = store.load().tasks.compactMap { other -> LeadOverlap.Other? in
            guard other.id != task.id, !Self.finishedStates.contains(other.status), !other.isAbandoned else { return nil }
            var seen = LeadOverlap.Other(slug: other.slug, state: other.status.rawValue, startsAfter: other.after?.contains(task.slug) ?? false)
            if [.running, .planned].contains(other.status) {
                seen.named = LeadOverlap.claims(in: other.contract.boundaries, input: input, records: records)
            }
            if let branch = other.branch {
                let diff = Self.changedFiles("\(workflow.base)...\(branch)", root: root)
                if diff.ok {
                    seen.changed = Set(diff.output.split(whereSeparator: \.isNewline).map(String.init).filter { LeadOverlap.counts($0, records: records) })
                }
            }
            return seen
        }
        return LeadOverlap.warning(slug: task.slug, claims: claims, others: others, input: input)
    }
}
