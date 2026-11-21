import Foundation
import VibeCore

/// The developer tools notice on a node (the app's `ToolchainWatch`, which watches the Mac's Xcode and Command Line
/// Tools; the parity table's row). On Linux the tools a project's gate needs are the ones its files name: a
/// `Package.swift` needs `swift` (the version in its `.swift-version` when it has one), a `package.json` needs `node`
/// (its `.nvmrc` or `.node-version`). Each running lead's project is looked at every 10 minutes.
///
/// Nothing runs in a project's folder, which its agents write (the security review of 2026-11-21: a version manager
/// reads its files there, may install or run what they name, and a relative PATH entry would find a program planted
/// there). The project's files are only read: each one opened without following a link and without blocking (a FIFO),
/// only a regular file directly in its root, at most 256 bytes, and a pinned version kept only when it reads as one
/// (digits and dots, an optional `v`). The tools are asked once a look for the whole node: each found on the server's
/// PATH through its absolute folders only (`Platform.Tools.find`), run by that absolute path from `/` with an
/// environment of PATH (those folders), HOME and LANG only, nothing on its stdin, 15 s at most (`swift --version`,
/// `node --version`: queries; nothing is installed, selected or built). A pinned Swift counts as there when it is the
/// default or swiftly lists it installed (its `toolchains` folder's names, read, never run).
///
/// - A tool that's missing, fails, or isn't the version the project names is a `status` notice while it stands.
/// - A version that changed since the last look (`<node root>/toolchain.json`) is told to the project's lead once, as
///   the witness (the app's `tellToolchainReports`), and is a notice for a day (the app's note).
public enum NodeToolchain {
    /// How often the running leads' projects are looked at (the app's `ToolchainWatch.interval`).
    public static let interval = 10 * 60
    /// How long a change stays a notice (the app's note, dismissed after a day).
    public static let noteFor: TimeInterval = 24 * 60 * 60
    /// The most of a pin file read.
    static let pinLimit = 256

    /// A tool a project needs, and the file that says so.
    public struct Need: Codable, Equatable, Sendable {
        public var tool: String
        public var because: String
        /// The version the project names (`.swift-version`, `.nvmrc`), nil when it names none that reads as a version.
        public var wanted: String?
        public init(tool: String, because: String, wanted: String? = nil) {
            self.tool = tool
            self.because = because
            self.wanted = wanted
        }
    }

    /// What a project's files say it needs. Reads at most a few small files directly in its top folder, never through
    /// a link.
    public static func needs(root: String) -> [Need] {
        let folder = Sys.open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { return [] }
        defer { Sys.close(folder) }
        var needs: [Need] = []
        if isRegular("Package.swift", in: folder) {
            let pin = pinned([".swift-version"], in: folder)
            needs.append(Need(tool: "swift", because: pin.map { "Package.swift, \($0.file)" } ?? "Package.swift", wanted: pin?.version))
        }
        if isRegular("package.json", in: folder) {
            let pin = pinned([".nvmrc", ".node-version"], in: folder)
            needs.append(Need(tool: "node", because: pin.map { "package.json, \($0.file)" } ?? "package.json", wanted: pin?.version))
        }
        return needs
    }

    /// Whether `name` in `folder` is a regular file, not a link to one.
    static func isRegular(_ name: String, in folder: Int32) -> Bool {
        var info = stat()
        return fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// The first of `names` in `folder` that is a regular file (opened without following a link, without blocking) whose
    /// first line reads as a version; nil when none does.
    static func pinned(_ names: [String], in folder: Int32) -> (file: String, version: String)? {
        for name in names {
            let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { Sys.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= off_t(pinLimit) else { continue }
            var buffer = [UInt8](repeating: 0, count: pinLimit)
            let count = read(fd, &buffer, pinLimit)
            guard count > 0 else { continue }
            let first = String(decoding: buffer[0..<count], as: UTF8.self).split(whereSeparator: \.isNewline).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if isVersion(first) { return (name, first) }
        }
        return nil
    }

    /// A version as a pin file or a tool may say it: an optional `v`, then one to four numbers with dots between, each
    /// at most 6 digits.
    public static func isVersion(_ text: String) -> Bool {
        var body = Substring(text)
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.count <= 6 && $0.allSatisfy { ("0"..."9").contains($0) } }
    }

    /// A tool's version from its `--version` output: Swift's "Swift version 6.4.2" (driver builds and the target
    /// aren't a change), node's "v22.1.0"; nil when it says neither.
    public static func version(tool: String, output: String) -> String? {
        let pattern = tool == "swift" ? #"Swift version [0-9]+(?:\.[0-9]+)*"# : #"v?[0-9]+(?:\.[0-9]+)+"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        let found = String(output[range])
        let version = tool == "swift" ? String(found.dropFirst("Swift version ".count)) : (found.hasPrefix("v") ? String(found.dropFirst()) : found)
        return isVersion(version) ? version : nil
    }

    /// Whether `actual` is the version `wanted` names: its numbers, as many as it gives ("6.4" takes 6.4.2; "v22" takes
    /// 22.1.0).
    public static func matches(_ actual: String, wanted: String) -> Bool {
        var wanted = wanted.lowercased()
        if wanted.hasPrefix("v") { wanted.removeFirst() }
        let want = wanted.split(separator: ".")
        let have = actual.split(separator: ".")
        return !want.isEmpty && have.count >= want.count && zip(want, have).allSatisfy { $0 == $1 }
    }

    /// The node's tools, asked once a look: each tool's version (nil: not found or failing), and the Swift versions
    /// swiftly lists installed.
    public struct Tools: Sendable {
        public var versions: [String: String?]
        public var installedSwift: [String]
        public init(versions: [String: String?], installedSwift: [String] = []) {
            self.versions = versions
            self.installedSwift = installedSwift
        }
    }

    /// What one look found for a project: each tool it needs and its version there (nil: missing or failing).
    public struct Found: Codable, Equatable, Sendable {
        public var need: Need
        public var version: String?
    }

    /// Each tool `root`'s files name, with the version the node gives it: the node's own, or for a pinned Swift that
    /// isn't the default, the pin when swiftly has it installed.
    public static func look(needs: [Need], tools: Tools) -> [Found] {
        needs.map { need in
            var version = tools.versions[need.tool] ?? nil
            if need.tool == "swift", let wanted = need.wanted, version.map({ !matches($0, wanted: wanted) }) ?? true,
               let installed = tools.installedSwift.first(where: { matches($0, wanted: wanted) }) {
                version = installed
            }
            return Found(need: need, version: version)
        }
    }

    // MARK: Asking the node

    /// The tools every look asks: `swift` and `node`, each by `version(of:)`.
    public static let asked = ["swift", "node"]

    /// The live answer for the node: each of `asked` (`version(of:home:)`) and swiftly's installed toolchains under
    /// `home`. Blocks: never on a server queue.
    public static func node(home: String) -> Tools {
        Tools(versions: Dictionary(uniqueKeysWithValues: asked.map { ($0, version(of: $0, home: home)) }),
              installedSwift: installedSwift(home: home))
    }

    /// `PATH`'s absolute folders only, in order.
    static func absolutePath(_ path: String?) -> String {
        (path ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":").filter { $0.hasPrefix("/") }.joined(separator: ":")
    }

    /// `tool --version`, the tool found on this process's PATH through its absolute folders only and run by that path
    /// from `/`, with PATH (those folders), HOME and LANG alone; its version, or nil.
    public static func version(of tool: String, home: String) -> String? {
        let path = absolutePath(ProcessInfo.processInfo.environment["PATH"])
        guard let program = Platform.Tools.find(tool, path: path) else { return nil }
        let output = run([program, "--version"], environment: ["PATH=\(path)", "HOME=\(home)", "LANG=C"], timeout: 15)
        return output.flatMap { version(tool: tool, output: $0) }
    }

    /// The Swift versions swiftly has installed: the names of `<home>/.local/share/swiftly/toolchains`' folders that
    /// read as versions (a listing; nothing in it is opened or run).
    static func installedSwift(home: String) -> [String] {
        let folder = (home as NSString).appendingPathComponent(".local/share/swiftly/toolchains")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter(isVersion).sorted()
    }

    /// `command` run from `/` with `environment`, nothing on its stdin, stderr dropped, in a process group of its own
    /// killed after `timeout`; its output when it exited 0, else nil. Never waits unbounded.
    static func run(_ command: [String], environment: [String], timeout: TimeInterval) -> String? {
        var ends: [Int32] = [-1, -1]
        guard let program = command.first, Sys.pipeClosedOnExec(&ends) == 0 else { return nil }
        var spawn = Platform.Spawn(executable: program, arguments: command)
        spawn.environment = environment
        spawn.directory = "/"
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .descriptor(ends[1])
        spawn.stderr = .path("/dev/null", flags: O_WRONLY)
        spawn.group = .ownGroup
        spawn.keep = []
        let started = spawn.start()
        Sys.close(ends[1])
        defer { Sys.close(ends[0]) }
        guard case .success(let pid) = started else { return nil }
        _ = fcntl(ends[0], F_SETFL, fcntl(ends[0], F_GETFL) | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(timeout)
        var output = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var status: Int32 = 0
        var exited = false
        while Date() < deadline, output.count < 64 * 1024 {
            var poller = pollfd(fd: ends[0], events: Int16(POLLIN), revents: 0)
            _ = poll(&poller, 1, 100)
            let got = read(ends[0], &chunk, chunk.count)
            if got > 0 { output.append(contentsOf: chunk[0..<got]); continue }
            if got == 0 || (got < 0 && errno != EAGAIN && errno != EINTR) {
                // Its output ended: it has exited, or does in a moment.
                for _ in 0..<50 where !exited {
                    if waitpid(pid, &status, WNOHANG) == pid { exited = true } else { usleep(20_000) }
                }
                break
            }
        }
        // Its group killed only while it hasn't been reaped (a reaped pid, and its group's id, can be given out again).
        if !exited {
            kill(-pid, SIGKILL)
            for _ in 0..<50 where !exited {
                if waitpid(pid, &status, WNOHANG) == pid { exited = true } else { usleep(20_000) }
            }
        }
        guard exited, status & 0x7f == 0, (status >> 8) & 0xff == 0 else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: Saying

    /// A project's standing problems: a tool it needs that's missing, failing, or not the version it names.
    public static func problems(root: String, found: [Found]) -> [String] {
        let project = ConfigSeal.inert(LeadMail.project(of: root), limit: 80)
        let shownRoot = ConfigSeal.inert(root, limit: 200)
        return found.compactMap { item in
            guard let version = item.version else {
                return "the developer tools: \(project)'s gate needs \(item.need.tool) (\(item.need.because)), and `\(item.need.tool) --version` "
                    + "doesn't run on the node's PATH" + (item.need.wanted.map { " (it names \($0))" } ?? "")
                    + " for \(shownRoot). Its tests and builds fail until it does; VibeSwitcher installs nothing"
            }
            guard let wanted = item.need.wanted, !matches(version, wanted: wanted) else { return nil }
            return "the developer tools: \(project) names \(item.need.tool) \(wanted) (\(item.need.because)), and the node's PATH runs "
                + "\(version)\(item.need.tool == "swift" ? ", with no installed swiftly toolchain of that version" : "") (\(shownRoot)). "
                + "Its tests and builds may fail; VibeSwitcher installs nothing"
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
        return "Developer tools changed for \(ConfigSeal.inert(LeadMail.project(of: root), limit: 80)): " + changed.joined(separator: "; ")
            + " (on the node's PATH, for \(ConfigSeal.inert(root, limit: 200))). If its tests or builds now fail, this may be why. "
            + "VibeSwitcher only reads these tools; it never changes them."
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

    /// One look at `roots`' projects with the node's `tools`: what to tell each lead (a change), the notices now, and the
    /// book to keep. Reads only the projects' small files.
    public static func observe(_ book: Book, roots: [String], now: Date, tools: Tools) -> (told: [String: String], notices: [String], book: Book) {
        var book = book
        var told: [String: String] = [:]
        var problems: [String] = []
        for root in roots.sorted() {
            let needs = needs(root: root)
            guard !needs.isEmpty else { continue }
            let found = look(needs: needs, tools: tools)
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
