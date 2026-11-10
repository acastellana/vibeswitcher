import CryptoKit
import Foundation

/// What the held config's card says (`ConfigHolds`, `ConfigHeldCard`): which files, named as a person would, what's
/// different in them, and what most likely did it. The seal keeps hashes, so a difference needs a copy of the text as
/// last accepted (`SealCopies`): only text, only under `copiedFolder`, owner-only, capped, replaced at each seal.
///
/// Nothing here decides what's held, and no label lets anything through: a real sync and a forged one are alike on
/// disk, so the source is only ever "most likely", and only your Accept seals it (`LeadVault.Book.judge`).
extension ConfigSeal {
    /// The watched folder whose text is kept and compared. Computed: no path under the home is kept once per process.
    public static var copiedFolder: String { "~/.claude/skills" }

    /// One file of a held folder, for the card. Paths, hashes and times, never contents.
    public struct HeldFile: Codable, Equatable, Sendable, Identifiable {
        public enum Change: String, Codable, Sendable { case added, changed, removed }

        /// Its path relative to the watched folder.
        public var path: String
        public var change: Change
        /// When it was last changed (nil when removed: it has no time).
        public var at: Double?
        /// What it is: "f" a file, "d" a folder, "l" a link, "o" anything else; nil from a seal before kinds were kept.
        public var kind: String?
        /// Its hash as sealed and as it was when held (`FolderRead.entries`' first part).
        public var before: String?
        public var after: String?

        public var id: String { path }

        public init(path: String, change: Change, at: Double? = nil, kind: String? = nil, before: String? = nil, after: String? = nil) {
            self.path = path
            self.change = change
            self.at = at
            self.kind = kind
            self.before = before
            self.after = after
        }
    }

    /// What the card shows of one held thing beyond its name.
    public struct HeldDetail: Codable, Equatable, Sendable {
        /// A held folder's files that changed, by path (`maxHeldFiles` at most; empty for what isn't a folder, or a
        /// folder sealed by a version before per-path hashes).
        public var files: [HeldFile] = []
        /// How many more changed than `files` lists.
        public var more = 0
        /// The team sessions running when this was first held, as the card names them.
        public var sessions: [String] = []
        /// False when the host couldn't say which sessions run: `sessions` is then the team's, not the running ones.
        public var sessionsKnown = true

        public init(files: [HeldFile] = [], more: Int = 0, sessions: [String] = [], sessionsKnown: Bool = true) {
            self.files = files
            self.more = more
            self.sessions = sessions
            self.sessionsKnown = sessionsKnown
        }

        /// As `heldKey`'s line keeps it: one line, no tabs (JSON escapes both).
        var written: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "" }

        static func read(_ text: String) -> HeldDetail? {
            guard !text.isEmpty else { return nil }
            return try? JSONDecoder().decode(HeldDetail.self, from: Data(text.utf8))
        }
    }

    /// At most this many sessions are named on a line.
    static let maxHeldSessions = 40

    /// A team session as the card names it, and when it started (nil: not known).
    struct TeamSession {
        var label: String
        var boundAt: Double?
    }

    /// At most this many of a held folder's changed files are kept on its line; past them, how many more.
    static let maxHeldFiles = 1000

    /// The most a held thing's detail takes on its line, in bytes. The vault's answer is one message to the app, at most
    /// `HostFrame.maxPayload` (1 MiB): past it the app is told nothing, and a hold with no card has no Accept. So the
    /// skills, the folder a person reads, get the most, and with the other watched folders the whole stays well under.
    static func detailBudget(_ name: String) -> Int { name == copiedFolder ? 256 << 10 : 32 << 10 }

    /// A held thing's detail: `old` and `new` a folder's per-path hashes (nil for what isn't a folder, or one sealed
    /// without them), listed up to `maxHeldFiles` and `detailBudget`, the rest counted. A session that started after the
    /// newest changed file wasn't running then.
    static func heldDetail(name: String, from old: String?, to new: String?, sessions: [TeamSession], known: Bool) -> HeldDetail {
        var detail = HeldDetail(sessionsKnown: known)
        var newest: Double?
        if let old, let new {
            let before = decode(old), after = decode(new)
            let files = changedEntries(from: old, to: after).map { entry in
                HeldFile(path: entry.path, change: HeldFile.Change(rawValue: entry.word) ?? .changed, at: entryTime(after[entry.path]),
                         kind: entryKind(after[entry.path]) ?? entryKind(before[entry.path]),
                         before: entryHash(before[entry.path]), after: entryHash(after[entry.path]))
            }
            var room = detailBudget(name)
            let encoder = JSONEncoder()
            for file in files.prefix(maxHeldFiles) {
                let size = ((try? encoder.encode(file))?.count ?? room) + 1
                guard size <= room else { break }
                room -= size
                detail.files.append(file)
            }
            detail.more = files.count - detail.files.count
            newest = files.compactMap(\.at).max()
        }
        detail.sessions = Array(sessions.filter { session in
            guard let newest, let bound = session.boundAt else { return true }
            // A file's time is in whole seconds: bound in the same second counts.
            return bound.rounded(.down) <= newest
        }.map(\.label).prefix(maxHeldSessions))
        return detail
    }

    // MARK: Names

    /// The folder Claude Code's skill sync keeps, under `copiedFolder`: "synced/<account folder>/<skill>/…".
    static let syncFolder = "synced"

    /// `file` of the watched thing `name`, as a person would name it: "skill built-in-browser, SKILL.md", never an
    /// account's folder. What's outside the skills is its path. Inert: a name can hold anything a file's can.
    public static func fileLabel(_ file: HeldFile, in name: String) -> String {
        inert(rawLabel(file.path, kind: file.kind, in: name))
    }

    /// The skill `file` belongs to, the group the card summarizes it under.
    public static func groupLabel(_ file: HeldFile, in name: String) -> String {
        guard name == copiedFolder else { return inert(String(file.path.split(separator: "/").first ?? "")) }
        let parts = skillParts(file.path)
        if let skill = parts.skill { return inert("skill " + skill) }
        return inert(parts.synced ? "Claude's sync folder" : "the skills folder")
    }

    private static func rawLabel(_ path: String, kind: String?, in name: String) -> String {
        guard name == copiedFolder else { return path }
        let parts = skillParts(path)
        guard let skill = parts.skill else {
            let place = parts.synced ? "Claude's sync folder" : "the skills folder"
            return parts.rest.isEmpty ? place : place + ", " + parts.rest
        }
        // A skill's own folder, or a file directly in the sync's account folder or the skills folder.
        if parts.rest.isEmpty { return kind == "f" ? (parts.synced ? "Claude's sync folder, " : "the skills folder, ") + skill : "skill " + skill }
        return "skill \(skill), \(parts.rest)"
    }

    /// `path` under `copiedFolder`: its skill, what's under the skill, and whether it's in the sync's folder. A file
    /// straight in the folder (or the sync's account folder) comes back as the "skill" with nothing under it, so
    /// `rawLabel` can tell from its kind.
    private static func skillParts(_ path: String) -> (skill: String?, rest: String, synced: Bool) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == syncFolder else {
            return (parts.first, parts.dropFirst().joined(separator: "/"), false)
        }
        // "synced" or "synced/<account>": no skill, and the account's folder is never named.
        guard parts.count >= 3 else { return (nil, "", true) }
        return (parts[2], parts.dropFirst(3).joined(separator: "/"), true)
    }

    /// A held folder's changed files by skill: for a card with many. In name order.
    public struct HeldGroup: Equatable, Sendable, Identifiable {
        public var label: String
        public var added = 0
        public var changed = 0
        public var removed = 0
        public var at: Double?
        public var id: String { label }

        /// "3 changed, 1 added".
        public var counts: String {
            [(changed, "changed"), (added, "added"), (removed, "removed")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        }
    }

    public static func groups(of detail: HeldDetail, in name: String) -> [HeldGroup] {
        var groups: [String: HeldGroup] = [:]
        for file in detail.files {
            let label = groupLabel(file, in: name)
            var group = groups[label] ?? HeldGroup(label: label)
            switch file.change {
            case .added: group.added += 1
            case .changed: group.changed += 1
            case .removed: group.removed += 1
            }
            group.at = [group.at, file.at].compactMap { $0 }.max()
            groups[label] = group
        }
        return groups.keys.sorted().compactMap { groups[$0] }
    }

    // MARK: What most likely did it

    /// What most likely made a held change, as far as the files can say. Never a reason to seal it.
    public enum Source: Equatable, Sendable {
        case likelySync
        case unknown(String)

        public var sentence: String {
            switch self {
            case .likelySync:
                return "Most likely Claude's own skill sync (in its account folder, its manifest updated at the same time). This can't be proved from the files."
            case .unknown(let why): return "Source unknown: \(why)"
            }
        }

        public var isLikelySync: Bool { self == .likelySync }
    }

    /// A manifest written up to this long before a changed file counts as written with it (the sync's own order isn't
    /// known to the second), and up to `syncManifestLag` after: on 2026-11-09 the files came at 17:17 and the manifest
    /// at 17:28.
    static let syncManifestLead: Double = 60
    static let syncManifestLag: Double = 3600

    /// What most likely made the held change in the thing `name` (`detail`, from the vault). A sync only when every
    /// changed thing is a file or folder in a sync account folder (`synced/<account>/…`, neither a link nor the
    /// bookkeeping's own names), every one has been listed, and each account's own manifest (a regular file, reached
    /// through real folders) was written with every one of them: the oldest change as well as the newest, so a change
    /// that sat waiting isn't swept in by a later round. A removal has no time to compare, so it's unknown. Anything else
    /// is unknown. Only times on disk: a forger can set them, so this is a label, and only ever "most likely".
    public static func likelySource(name: String, detail: HeldDetail?, home: String) -> Source {
        let nothing = Source.unknown("nothing in the files says what made this change.")
        guard name == copiedFolder, let detail, !detail.files.isEmpty, detail.more == 0 else { return nothing }
        let noManifest = Source.unknown("it's in Claude's sync folder, but the folder's manifest wasn't updated with it.")
        var spans: [String: (oldest: Double, newest: Double)] = [:]
        for file in detail.files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, parts[0] == syncFolder, parts[1] != "..", !parts[1].isEmpty, !syncBookkeeping.contains(parts[2]),
                  file.kind == "f" || file.kind == "d" else { return nothing }
            guard let at = file.at else { return noManifest }
            spans[parts[1]] = (min(spans[parts[1]]?.oldest ?? at, at), max(spans[parts[1]]?.newest ?? at, at))
        }
        for (account, span) in spans {
            guard let written = manifestTime(home: home, account: account),
                  written >= span.newest - syncManifestLead, written <= span.oldest + syncManifestLag else { return noManifest }
        }
        return .likelySync
    }

    /// When the sync's manifest for `account` was written: it must be a regular file, through real folders.
    private static func manifestTime(home: String, account: String) -> Double? {
        let skills = home + "/.claude/skills"
        for folder in [skills, skills + "/" + syncFolder, skills + "/" + syncFolder + "/" + account] {
            var info = stat()
            guard lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        }
        var info = stat()
        let manifest = skills + "/" + syncFolder + "/" + account + "/manifest.json"
        guard lstat(manifest, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Double(info.st_mtimespec.tv_sec)
    }

    /// Which team sessions ran, said no further than known. `allOutside`: no team session ran between looks.
    public static func sessionsSaid(_ details: [HeldDetail], allOutside: Bool) -> String {
        if allOutside { return "No team session ran between the last seal and this look." }
        var names: [String] = []
        for detail in details { for name in detail.sessions where !names.contains(name) { names.append(name) } }
        let shown = names.count > 6 ? names.prefix(6).joined(separator: ", ") + " and \(names.count - 6) more" : names.joined(separator: ", ")
        guard !details.isEmpty, details.allSatisfy(\.sessionsKnown) else {
            return names.isEmpty ? "Which team sessions were running isn't known."
                : "Which team sessions were running isn't known. The team has: \(shown)."
        }
        return names.isEmpty ? "A team session ran since the last seal, but none was still running when this was found, so which one isn't known."
            : "Team sessions running then: \(shown). None of them is shown to have made this change."
    }

    // MARK: Inert text

    /// `text` for showing, on one line: a control, format or separator character (escape sequences, bidirectional
    /// overrides, invisible ones) is shown as a visible mark instead of acting, and it's cut at `limit` characters.
    public static func inert(_ text: String, limit: Int = 300) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                kept.append(" ")
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                kept.append("\u{FFFD}")
            default:
                kept.append(scalar)
            }
        }
        let line = String(kept)
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// `text` with anything secret hidden, as the lead's mail records it (`LeadMail.masked`): a key whole, tokens,
    /// NAME=value pairs, URLs with credentials, the vendor shapes.
    static func maskedText(_ text: String) -> String { LeadMail.masked(text) }

    // MARK: Kept copies

    /// The largest file a copy is kept of or compared: past it, the card says so.
    public static let copyLimit = 256 << 10

    /// All the kept copies together, at most: past it, the rest go without one (and the card says so).
    static let copiesLimit = 32 << 20

    /// The file a folder entry's hash is taken of (`walk`), and so what a copy is checked against: `SHA256` of its line,
    /// first eight bytes.
    static func lineHash(path: String, mode: mode_t, digest: String) -> String {
        hex(SHA256.hash(data: Data("f \(path) \(mode) \(digest)\n".utf8)).prefix(8))
    }

    /// What's in `data`, hashed as `contentsDigest` does.
    private static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// Whether `data` is text the card can show: UTF-8, no NUL.
    static func isText(_ data: Data) -> Bool {
        !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }

    /// The text of what's sealed under `copiedFolder`, for the card's differences: one copy per file, in
    /// `~/.vibeswitcher/seal-copies` (owner-only, 0700 and 0600). Each copy starts with "<mode> <line hash>\n". What a
    /// shell could plant there is no danger: `earlier` shows a copy only when its hash is the sealed one.
    public struct SealCopies {
        public let home: String

        public init(home: String) { self.home = home }

        var folder: URL { URL(fileURLWithPath: home).appendingPathComponent(".vibeswitcher/seal-copies") }

        private func copyURL(_ path: String) -> URL {
            folder.appendingPathComponent(hex(SHA256.hash(data: Data(path.utf8))))
        }

        private var skills: String { home + "/.claude/skills" }

        /// Brings the copies in line with `sealed` (the sealed folder's per-path entries): a file sealed as it is now
        /// gets a copy when it's text within the limits, one sealed as it is already has one, and a copy of anything
        /// else (superseded, removed, gone binary or too big, or that couldn't be taken) goes.
        func reconcile(sealed: [String: String], limit: Int = copiesLimit) {
            guard (try? VibePaths.ensurePrivate(folder)) != nil, folderIsPrivate else { return }
            var wanted = Set<String>()
            var total = 0
            for path in sealed.keys.sorted() {
                guard let hash = entryHash(sealed[path]), entryKind(sealed[path]) ?? "f" == "f" else { continue }
                let url = copyURL(path)
                if let kept = read(url), kept.hash == hash, total + kept.body.count <= limit {
                    wanted.insert(url.lastPathComponent)
                    total += kept.body.count
                    continue
                }
                guard let current = readFile(path), current.hash == hash, isText(current.body), total + current.body.count <= limit,
                      (try? VibePaths.writePrivate(Data("\(current.mode) \(hash)\n".utf8) + current.body, to: url)) != nil else {
                    unlink(url.path)
                    continue
                }
                wanted.insert(url.lastPathComponent)
                total += current.body.count
            }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !wanted.contains(name) {
                unlink(folder.appendingPathComponent(name).path)
            }
        }

        /// The kept copy of `file` as sealed: nil when there's none, or what's there isn't what was sealed.
        fileprivate func earlier(_ file: HeldFile) -> Data? {
            guard folderIsPrivate, let before = file.before, let kept = read(copyURL(file.path)), kept.hash == before else { return nil }
            return lineHash(path: file.path, mode: kept.mode, digest: digest(kept.body)) == before ? kept.body : nil
        }

        /// `file` as it is now, when it's what the card was drawn from; why not otherwise.
        fileprivate func current(_ file: HeldFile) -> (body: Data?, unavailable: Difference?) {
            guard let after = file.after, safe(file.path) else { return (nil, .unavailable("It isn't a file that can be compared.")) }
            var info = stat()
            guard lstat(skills + "/" + file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                return (nil, .unavailable("It isn't a regular file, so there's no text to compare."))
            }
            guard Int64(info.st_size) <= Int64(copyLimit) else { return (nil, .unavailable(Self.tooBig)) }
            guard let read = readFile(file.path) else { return (nil, .unavailable("It couldn't be read.")) }
            guard read.hash == after else {
                return (nil, .unavailable("It changed again after this card was drawn, so no comparison is shown. Accepting will ask you again."))
            }
            guard isText(read.body) else { return (nil, .unavailable("It's a binary file, so there's no text to compare.")) }
            return (read.body, nil)
        }

        static var tooBig: String { "It's over the \(copyLimit >> 10) KB limit, so no comparison is shown." }

        private func safe(_ path: String) -> Bool {
            !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
        }

        private func readFile(_ path: String) -> (mode: mode_t, hash: String, body: Data)? {
            let full = skills + "/" + path
            var info = stat()
            guard lstat(full, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  let body = regularContents(full, limit: copyLimit, followLink: false) else { return nil }
            let mode = info.st_mode & 0o777
            return (mode, lineHash(path: path, mode: mode, digest: digest(body)), body)
        }

        private func read(_ url: URL) -> (mode: mode_t, hash: String, body: Data)? {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
                  let data = regularContents(url.path, limit: copyLimit + 64, followLink: false),
                  let end = data.firstIndex(of: 0x0A) else { return nil }
            let header = String(decoding: data[..<end], as: UTF8.self).split(separator: " ")
            guard header.count == 2, let mode = mode_t(header[0]) else { return nil }
            return (mode, String(header[1]), data[(end + 1)...])
        }

        private var folderIsPrivate: Bool {
            var info = stat()
            return lstat(folder.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid() && info.st_mode & 0o077 == 0
        }
    }

    // MARK: Differences

    /// A line of a shown difference: text masked and inert.
    public struct DifferenceLine: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case same, added, removed, gap }
        public var id: Int
        public var kind: Kind
        public var text: String
    }

    /// What the card can say of one file's difference from what was last accepted.
    public enum Difference: Equatable, Sendable {
        /// The changed lines with a little context. `moreLines` changed lines weren't shown; `maskedChange`: a value
        /// masked as secret changed too, so the lines shown understate the change.
        case lines([DifferenceLine], moreLines: Int, maskedChange: Bool)
        /// It said no text changed, with why it was held even so.
        case sameText(String)
        /// No difference can be shown, and why: it never guesses.
        case unavailable(String)
    }

    /// Lines around a change kept, and changed lines shown at most.
    static let contextLines = 2
    static let shownLines = 300

    /// Lines compared at most, once what's common at both ends is set aside: `CollectionDifference`'s memory grows with
    /// the square of how much changed.
    static let comparedLines = 3000

    /// How `file` of the thing `name` differs from what was last accepted. Reads the disk: off the main thread.
    public static func difference(of file: HeldFile, in name: String, home: String) -> Difference {
        guard name == copiedFolder, file.change == .changed, file.kind == "f" else {
            return .unavailable("There's no earlier text of this to compare.")
        }
        let copies = SealCopies(home: home)
        let now = copies.current(file)
        guard let body = now.body else { return now.unavailable ?? .unavailable("It couldn't be read.") }
        guard let earlier = copies.earlier(file) else {
            return .unavailable("No earlier copy was kept, so there's nothing to compare it with. It may have been binary or over the limit when last accepted.")
        }
        return lines(before: String(decoding: earlier, as: UTF8.self), after: String(decoding: body, as: UTF8.self))
    }

    /// The difference between two texts, masked and inert.
    static func lines(before raw: String, after rawAfter: String) -> Difference {
        let before = maskedText(raw).components(separatedBy: "\n"), after = maskedText(rawAfter).components(separatedBy: "\n")
        guard let steps = script(from: before, to: after) else {
            return .unavailable("It's too long to compare (over \(comparedLines) changed lines).")
        }
        let rawScript = script(from: raw.components(separatedBy: "\n"), to: rawAfter.components(separatedBy: "\n"))
        let shownChanges = steps.filter { $0.0 != .same }.count
        let maskedChange = (rawScript?.filter { $0.0 != .same }.count ?? shownChanges) > shownChanges
        guard shownChanges > 0 else {
            return .sameText(raw == rawAfter ? "The text is the same as last accepted: only the file's permissions or time changed."
                : "The text is the same apart from a value masked as secret, which changed.")
        }
        // Only the changes, with a little context; the rest is folded.
        var keep = [Bool](repeating: false, count: steps.count)
        for (index, step) in steps.enumerated() where step.0 != .same {
            for near in max(0, index - contextLines)...min(steps.count - 1, index + contextLines) { keep[near] = true }
        }
        var shown: [DifferenceLine] = []
        var changedShown = 0, skipped = 0, more = 0
        for (index, step) in steps.enumerated() {
            guard keep[index] else {
                skipped += 1
                continue
            }
            if step.0 != .same {
                guard changedShown < shownLines else {
                    more += 1
                    continue
                }
                changedShown += 1
            } else if changedShown >= shownLines { continue }
            if skipped > 0 {
                shown.append(DifferenceLine(id: shown.count, kind: .gap, text: "… \(skipped) unchanged line\(skipped == 1 ? "" : "s")"))
                skipped = 0
            }
            shown.append(DifferenceLine(id: shown.count, kind: step.0, text: inert(step.1)))
        }
        return .lines(shown, moreLines: more, maskedChange: maskedChange)
    }

    /// `before` turned into `after`, line by line; nil when too much of it differs to compare.
    private static func script(from before: [String], to after: [String]) -> [(DifferenceLine.Kind, String)]? {
        var head = 0
        while head < before.count, head < after.count, before[head] == after[head] { head += 1 }
        var tail = 0
        while tail < before.count - head, tail < after.count - head, before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }
        let oldMiddle = Array(before[head..<(before.count - tail)]), newMiddle = Array(after[head..<(after.count - tail)])
        guard oldMiddle.count + newMiddle.count <= comparedLines else { return nil }
        let changes = newMiddle.difference(from: oldMiddle)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var script: [(DifferenceLine.Kind, String)] = before[..<head].map { (.same, $0) }
        var old = 0, new = 0
        while old < oldMiddle.count || new < newMiddle.count {
            if old < oldMiddle.count, removed.contains(old) {
                script.append((.removed, oldMiddle[old]))
                old += 1
            } else if new < newMiddle.count, inserted.contains(new) {
                script.append((.added, newMiddle[new]))
                new += 1
            } else if old < oldMiddle.count, new < newMiddle.count {
                script.append((.same, oldMiddle[old]))
                old += 1
                new += 1
            } else {
                break
            }
        }
        script += before[(before.count - tail)...].map { (.same, $0) }
        return script
    }
}
