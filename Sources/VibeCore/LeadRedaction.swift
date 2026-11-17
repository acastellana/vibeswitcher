import Foundation

/// One line of the lead's records replaced to clear a lint (redact_record): a line that names one of the user's other
/// projects (PrivateNamesLint) or holds a credential's shape (SecretShapeLint). The records otherwise only ever grow
/// (`Worktrees.landingRefusal` refuses a commit that drops a line the base has), so on 2026-11-12 the user's hand fix of
/// such a line in progress.md could never be committed by the records path, and every later record was stuck behind
/// it. A redaction is kept, pending, in the project's `.vibeswitcher/redactions.json` (local: it holds the old line)
/// until the records commit that carries it lands: that commit's landing check accepts exactly that change (the old
/// line gone, the new one there, in that file), and its message names each redaction by its file and new text.
public struct LeadRedaction: Codable, Equatable, Sendable {
    /// The record's path in the repository ("docs/lead/progress.md").
    public var file: String
    /// The line as it was, without the whitespace around it. Kept only in `.vibeswitcher`, never committed.
    public var old: String
    /// The line now, without the whitespace around it.
    public var new: String
    /// The lints the old line failed ("PrivateNamesLint").
    public var lints: [String]
    public var at: Double

    public init(file: String, old: String, new: String, lints: [String], at: Double = Date().timeIntervalSince1970) {
        self.file = file
        self.old = old
        self.new = new
        self.lints = lints
        self.at = at
    }

    /// The commit message's line for it: its file, its new text and what it cleared, never the old line.
    public var messageLine: String {
        "- \(file): one line replaced with “\(new.count > 200 ? String(new.prefix(199)) + "…" : new)” to clear \(lints.joined(separator: " and "))"
    }

    static func file(_ store: BoardStore) -> URL {
        URL(fileURLWithPath: (store.folder as NSString).appendingPathComponent("redactions.json"))
    }

    /// The redactions not committed yet.
    public static func pending(_ store: BoardStore) -> [LeadRedaction] {
        guard let data = try? Data(contentsOf: file(store)) else { return [] }
        return (try? JSONDecoder().decode([LeadRedaction].self, from: data)) ?? []
    }

    static func save(_ redactions: [LeadRedaction], _ store: BoardStore) throws {
        let url = file(store)
        if redactions.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try VibePaths.ensurePrivate(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try VibePaths.writePrivate(try encoder.encode(redactions), to: url)
    }

    /// The landed ones (`landed`) taken off the pending list.
    static func settle(_ landed: [LeadRedaction], _ store: BoardStore) {
        guard !landed.isEmpty else { return }
        try? save(pending(store).filter { !landed.contains($0) }, store)
    }

    /// Whether `line`, missing from `file` in a landing's candidate whose lines are `kept`, went by one of `redactions`.
    static func excuses(_ redactions: [LeadRedaction], file: String, line: String, kept: Set<String>) -> Bool {
        redactions.contains { $0.file == file && $0.old == line && kept.contains($0.new) }
    }

    public struct Refusal: Error, Equatable {
        public let text: String
    }

    /// Replaces the one line of `name` (a record's file name, "progress.md", or its path in the repository) that holds
    /// `line` (the whole line or a part of it found in that line only) with `text`, under the records' lock, and keeps
    /// the redaction pending for the records commit. Only to clear a lint: the old line must fail RecordLint, the new
    /// one pass it. When the working file has the new text already (the user fixed it by hand) and `base`'s copy still
    /// has the old line, only the redaction is kept, so the commit carries that fix.
    public static func redact(_ name: String, line: String, with text: String, in store: BoardStore, base: String,
                              lints: RecordLint.Lints = .all, now: Date = Date()) throws -> (redaction: LeadRedaction, written: Bool) {
        guard !lints.isEmpty else {
            throw Refusal(text: "Nothing redacted: this repository carries neither PrivateNamesLint nor SecretShapeLint, so no line of its records fails them.")
        }
        guard let dir = store.recordsDir else {
            throw Refusal(text: "Nothing redacted: the records aren't kept in the repository (no records_dir), so no commit carries them and no lint reads them.")
        }
        let given = name.trimmingCharacters(in: .whitespaces)
        let plain = given.hasPrefix(dir + "/") ? String(given.dropFirst(dir.count + 1)) : given
        guard let kind = LeadRecords.Kind.allCases.first(where: { $0.name == plain }) else {
            throw Refusal(text: "Nothing redacted: “\(given)” isn't one of the lead's records (\(LeadRecords.Kind.allCases.map(\.name).joined(separator: ", "))).")
        }
        let path = "\(dir)/\(kind.name)"
        let wanted = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { throw Refusal(text: "Nothing redacted: say which line (line): the whole line, or a part of it no other line has.") }
        guard !new.isEmpty, !new.contains(where: \.isNewline) else {
            throw Refusal(text: "Nothing redacted: the corrected text (text) is one line, not empty.")
        }
        let still = RecordLint.problems(in: new, lints: lints)
        guard still.isEmpty else { throw Refusal(text: "Nothing redacted: the corrected text fails the lints too: \(still.joined(separator: "; ")).") }

        /// The one line of `lines` that `wanted` finds: equal to it, else holding it.
        func find(_ lines: [String]) throws -> Int? {
            let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            let exact = trimmed.indices.filter { trimmed[$0] == wanted }
            let found = exact.isEmpty ? trimmed.indices.filter { trimmed[$0].contains(wanted) } : exact
            guard found.count <= 1 else {
                throw Refusal(text: "Nothing redacted: \(found.count) lines of \(path) hold that text; give more of the one line to replace.")
            }
            return found.first
        }
        func checked(_ old: String) throws -> [String] {
            let failed = RecordLint.problems(in: old, lints: lints).map { String($0.prefix { $0 != ":" }) }
            guard !failed.isEmpty else {
                throw Refusal(text: "Nothing redacted: that line of \(path) passes PrivateNamesLint and SecretShapeLint. redact_record only clears a lint; records otherwise only grow (record a correction instead).")
            }
            return failed
        }
        let full = store.recordPath(kind.name)
        let root = store.root
        return try store.withRecordsLock {
            let current = (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
            var lines = current.components(separatedBy: "\n")
            let redaction: LeadRedaction
            var written = false
            if let at = try find(lines) {
                let old = lines[at].trimmingCharacters(in: .whitespaces)
                let failed = try checked(old)
                let indent = String(lines[at].prefix { $0 == " " || $0 == "\t" })
                lines[at] = indent + new
                try LeadRecords.write(lines.joined(separator: "\n"), to: full, in: store)
                written = true
                redaction = LeadRedaction(file: path, old: old, new: new, lints: failed, at: now.timeIntervalSince1970)
            } else {
                // Fixed by hand already: the base's copy has the line, and the working file the corrected text.
                let committed = Git.run(["show", "refs/heads/\(base):\(path)"], in: root)
                guard committed.ok, let at = try find(committed.output.components(separatedBy: "\n")) else {
                    throw Refusal(text: "Nothing redacted: no line of \(path) holds that text, here or on \(base).")
                }
                let old = committed.output.components(separatedBy: "\n")[at].trimmingCharacters(in: .whitespaces)
                let failed = try checked(old)
                guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == new }) else {
                    throw Refusal(text: "Nothing redacted: that line is in \(path) on \(base), but not in the working file, and the working file has no line “\(new)” in its place. Pass the corrected line as it is there.")
                }
                redaction = LeadRedaction(file: path, old: old, new: new, lints: failed, at: now.timeIntervalSince1970)
            }
            var pending = pending(store).filter { !($0.file == path && $0.old == redaction.old) }
            pending.append(redaction)
            try save(pending, store)
            return (redaction, written)
        }
    }
}
