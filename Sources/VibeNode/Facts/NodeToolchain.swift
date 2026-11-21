import Foundation
import VibeCore

/// The developer tools notice on a node (the app's `ToolchainWatch`, which watches the Mac's Xcode and Command Line
/// Tools; the parity table's row). On Linux the tools a project's gate needs are the ones its files name: a
/// `Package.swift` needs `swift` (the version in its `.swift-version` when it has one: swiftly picks it there), a
/// `package.json` needs `node` (its `.nvmrc` or `.node-version`). Each running lead's project is looked at every 10
/// minutes: each tool it needs is asked its version in the project's folder, through the server's PATH, the one its
/// sessions start with (`swift --version`, `node --version`: queries only; nothing is installed, selected or built).
///
/// - A tool that's missing, fails, or isn't the version the project names is a `status` notice while it stands.
/// - A version that changed since the last look (`<node root>/toolchain.json`) is told to the project's lead once, as
///   the witness (the app's `tellToolchainReports`), and is a notice for a day (the app's note).
public enum NodeToolchain {
    /// How often the running leads' projects are looked at (the app's `ToolchainWatch.interval`).
    public static let interval = 10 * 60
    /// How long a change stays a notice (the app's note, dismissed after a day).
    public static let noteFor: TimeInterval = 24 * 60 * 60

    /// A tool a project needs, and the file that says so.
    public struct Need: Codable, Equatable, Sendable {
        public var tool: String
        public var because: String
        /// The version the project names (`.swift-version`, `.nvmrc`), nil when it names none.
        public var wanted: String?
        public init(tool: String, because: String, wanted: String? = nil) {
            self.tool = tool
            self.because = because
            self.wanted = wanted
        }
    }

    /// What a project's files say it needs. Reads at most a few small files in its top folder.
    public static func needs(root: String) -> [Need] {
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(name)) }
        func pinned(_ names: [String]) -> (file: String, version: String)? {
            for name in names {
                let path = (root as NSString).appendingPathComponent(name)
                guard let handle = FileHandle(forReadingAtPath: path) else { continue }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: 200)) ?? Data()
                let first = String(decoding: data ?? Data(), as: UTF8.self).split(whereSeparator: \.isNewline).first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !first.isEmpty { return (name, first) }
            }
            return nil
        }
        var needs: [Need] = []
        if exists("Package.swift") {
            let pin = pinned([".swift-version"])
            needs.append(Need(tool: "swift", because: pin.map { "Package.swift, \($0.file)" } ?? "Package.swift", wanted: pin?.version))
        }
        if exists("package.json") {
            let pin = pinned([".nvmrc", ".node-version"])
            needs.append(Need(tool: "node", because: pin.map { "package.json, \($0.file)" } ?? "package.json", wanted: pin?.version))
        }
        return needs
    }

    /// A tool's version from its `--version` output: Swift's "Swift version 6.4.2" (driver builds and the target
    /// aren't a change), node's "v22.1.0"; nil when it says neither.
    public static func version(tool: String, output: String) -> String? {
        let pattern = tool == "swift" ? #"Swift version [0-9]+(?:\.[0-9]+)*"# : #"v?[0-9]+(?:\.[0-9]+)+"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        let found = String(output[range])
        return tool == "swift" ? String(found.dropFirst("Swift version ".count)) : (found.hasPrefix("v") ? String(found.dropFirst()) : found)
    }

    /// Whether `actual` is the version `wanted` names: its numbers, as many as it gives ("6.4" takes 6.4.2; "v22" takes
    /// 22.1.0). A name that isn't numbers (`lts/*`, a snapshot) isn't judged: true.
    public static func matches(_ actual: String, wanted: String) -> Bool {
        var wanted = wanted.lowercased()
        if wanted.hasPrefix("v") { wanted.removeFirst() }
        let want = wanted.split(separator: ".")
        guard !want.isEmpty, want.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return true }
        let have = actual.split(separator: ".")
        return have.count >= want.count && zip(want, have).allSatisfy { $0 == $1 }
    }

    /// What one look found for a project: each tool it needs, its version (nil: missing or failing) and what it said.
    public struct Found: Codable, Equatable, Sendable {
        public var need: Need
        public var version: String?
        public var said: String?
    }

    /// Asks each tool `root` needs its version in `root` (`run`: the executable's name, its arguments and the folder;
    /// the output, or nil when it failed).
    public static func look(root: String, needs: [Need], run: (String, [String], String) -> String?) -> [Found] {
        needs.map { need in
            let output = run(need.tool, ["--version"], root)
            let version = output.flatMap { version(tool: need.tool, output: $0) }
            let said = output?.split(whereSeparator: \.isNewline).first.map { ConfigSeal.inert(String($0), limit: 160) }
            return Found(need: need, version: version, said: said)
        }
    }

    /// The live `run`: `/usr/bin/env TOOL ARGS` in the folder, through this process's PATH (what its sessions get), 15 s.
    public static func command(_ tool: String, _ args: [String], _ folder: String) -> String? {
        let result = Shell.run(executable: "/usr/bin/env", args: [tool] + args, in: folder, timeout: 15, grace: 1)
        let text = (result.output + "\n" + result.error).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok ? text : nil
    }

    /// A project's standing problems: a tool it needs that's missing, failing, or not the version it names.
    public static func problems(root: String, found: [Found]) -> [String] {
        let project = LeadMail.project(of: root)
        return found.compactMap { item in
            guard let version = item.version else {
                return "the developer tools: \(project)'s gate needs \(item.need.tool) (\(item.need.because)), and `\(item.need.tool) --version` "
                    + "doesn't run in \(root) on the node's PATH" + (item.need.wanted.map { " (it names \(ConfigSeal.inert($0, limit: 60)))" } ?? "")
                    + ". Its tests and builds fail until it does; VibeSwitcher installs nothing"
            }
            guard let wanted = item.need.wanted, !matches(version, wanted: wanted) else { return nil }
            return "the developer tools: \(project) names \(item.need.tool) \(ConfigSeal.inert(wanted, limit: 60)) (\(item.need.because)), and the node's "
                + "PATH runs \(version) in \(root). Its tests and builds may fail; VibeSwitcher installs nothing"
        }
    }

    /// What changed in a project's tools since `before` (nil: nothing, or nothing to compare yet): told to its lead.
    public static func changes(root: String, before: [String: String]?, after: [Found]) -> String? {
        guard let before else { return nil }
        let changed = after.compactMap { item -> String? in
            guard let old = before[item.need.tool], let new = item.version, old != new else { return nil }
            return "\(item.need.tool) \(old) → \(new)"
        }
        guard !changed.isEmpty else { return nil }
        return "Developer tools changed for \(LeadMail.project(of: root)): " + changed.joined(separator: "; ") + " (in \(root), on the node's PATH). "
            + "If its tests or builds now fail, this may be why. VibeSwitcher only reads these tools; it never changes them."
    }

    /// What's kept across looks and restarts: each project's last versions, and the changes noted with when.
    public struct Book: Codable, Equatable, Sendable {
        public var versions: [String: [String: String]] = [:]
        public var notes: [String: Note] = [:]
        public struct Note: Codable, Equatable, Sendable {
            public var text: String
            public var at: Date
        }

        public static func load(from file: URL) -> Book {
            guard let data = try? Data(contentsOf: file), data.count < 1024 * 1024 else { return Book() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(Book.self, from: data)) ?? Book()
        }

        public func save(to file: URL) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try VibePaths.writePrivate(try encoder.encode(self), to: file)
        }
    }

    /// One look at `roots`' projects: what to tell each lead (a change), the notices now, and the book to keep. Pure but
    /// for `run` and the projects' files.
    public static func observe(_ book: Book, roots: [String], now: Date,
                               run: (String, [String], String) -> String?) -> (told: [String: String], notices: [String], book: Book) {
        var book = book
        var told: [String: String] = [:]
        var problems: [String] = []
        for root in roots.sorted() {
            let needs = needs(root: root)
            guard !needs.isEmpty else { continue }
            let found = look(root: root, needs: needs, run: run)
            if let change = changes(root: root, before: book.versions[root], after: found) {
                told[root] = change
                book.notes[root] = Book.Note(text: change, at: now)
            }
            // Only what answered is kept: a tool missing for a look keeps its last good version, so its return isn't a change.
            var versions = book.versions[root] ?? [:]
            for item in found { if let version = item.version { versions[item.need.tool] = version } }
            book.versions[root] = versions
            problems += self.problems(root: root, found: found)
        }
        book.notes = book.notes.filter { now.timeIntervalSince($0.value.at) < noteFor }
        let notes = book.notes.sorted { $0.key < $1.key }.map(\.value.text)
        return (told, problems + notes, book)
    }
}
