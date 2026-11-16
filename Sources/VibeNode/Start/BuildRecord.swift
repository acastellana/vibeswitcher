import Foundation
import VibeCore

/// The install's record of a build (the start plan's S4a, ST-D13): `<prefix>/<commit>/build-info`, written by the
/// just-built command line's unlisted `install-record`, which `scripts/install-node.sh` runs, so the file is
/// `BuildInfo`'s own encoding and the shell never spells the format.
///
/// It hashes every entry of the build folder's `bin/` with `BuildInfo.sha256(of:)`, as `BuildInfo`'s format says
/// ("one entry per file in that build's `bin/`"), each opened once, by its name in the `bin/` listed, without following
/// a link, and refused unless it is a regular file: a link could name a program outside the build, and the record would
/// vouch for it. The script requires `bin/` to hold exactly `installedNames`; this records whatever regular files are
/// there (`ScratchBuilds` keeps its `vibeswitcher-cli` name). `Resources/` isn't hashed: the seal watches the builds
/// folder, and the script's own bytes are checked against git (ST-D9).
public enum BuildRecord {
    /// What an installed build's `bin/` holds, by the names the record and the unit use: the cli under its installed
    /// name, `NodeFolders.installedCLI` (`vibeswitcher`).
    public static let installedNames = [BuildInfo.host, BuildInfo.server, NodeFolders.installedCLI, "vibeswitcher-hook", "vibeswitcher-mcp"]

    /// The suffix of the folder the install lays a build out in before it renames it to `<commit>` (S4b's step 10): a
    /// record is written there, and the rename keeps the name equal to its commit.
    public static let stagingSuffix = ".partial"

    /// Writes `folder/build-info` (0600, by rename) for the build of `commit` in `folder`, and gives what it wrote.
    /// `swiftVersionOutput` is what the toolchain's `swift --version` said, `resolved` the bytes of the commit's
    /// `Package.resolved`. Refused, with nothing written, when `commit` isn't 40 lowercase hex digits, `folder` isn't
    /// named `commit` (or `<commit>.partial`) or is a link, `bin/` is missing, a link or empty, an entry of it isn't a
    /// regular file or can't be read, or the version text is blank.
    public static func write(folder: String, commit: String, swiftVersionOutput: String, resolved: Data) -> Result<BuildInfo, StartRefusal> {
        guard isCommit(commit) else { return refused("the commit \(ConfigSeal.inert(commit, limit: .max)) isn't 40 lowercase hex digits") }
        // Only trailing slashes go: no link in the path is resolved, so the name checked is the name given.
        var path = folder
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let name = (path as NSString).lastPathComponent
        guard name == commit || name == commit + stagingSuffix else {
            return refused("the folder \(ConfigSeal.inert(path, limit: .max)) is named \(ConfigSeal.inert(name, limit: .max)), not the commit \(commit)")
        }
        guard !swiftVersionOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return refused("the toolchain's version text is empty")
        }
        let binaries: [String: String]
        switch hashes(folder: path) {
        case .success(let found): binaries = found
        case .failure(let refusal): return .failure(refusal)
        }
        let info = BuildInfo(commit: commit, binaries: binaries, swift: swiftVersionOutput, resolved: BuildInfo.sha256(of: resolved))
        let file = URL(fileURLWithPath: path).appendingPathComponent(BuildInfo.fileName)
        do {
            try VibePaths.writePrivate(info.encoded, to: file, syncing: VibePaths.syncToDisk)
        } catch {
            return refused("\(ConfigSeal.inert(file.path, limit: .max)) can't be written: \(error.localizedDescription)")
        }
        return .success(info)
    }

    /// The command line's `install-record FOLDER --commit C --swift-version-output F --resolved PATH`, its words after
    /// the subcommand: nil for a misuse (each flag once, all three given, nothing else).
    public struct Arguments: Equatable, Sendable {
        public var folder: String
        public var commit: String
        public var swiftVersionOutput: String
        public var resolved: String

        public static let usage = "usage: vibeswitcher install-record FOLDER --commit C --swift-version-output F --resolved PATH"

        public init?(_ words: [String]) {
            guard let folder = words.first, !folder.hasPrefix("-") else { return nil }
            var flags: [String: String] = [:]
            var rest = words.dropFirst()
            while let flag = rest.first {
                guard ["--commit", "--swift-version-output", "--resolved"].contains(flag), flags[flag] == nil, rest.count >= 2 else { return nil }
                flags[flag] = rest[rest.index(after: rest.startIndex)]
                rest = rest.dropFirst(2)
            }
            guard let commit = flags["--commit"], let version = flags["--swift-version-output"], let resolved = flags["--resolved"] else { return nil }
            self.folder = folder
            self.commit = commit
            swiftVersionOutput = version
            self.resolved = resolved
        }
    }

    /// `write` from the command line's files, each read whole as a regular file opened without following a link: the
    /// version text with its line ends dropped (`swift --version > F` ends with one), and the resolved file's bytes.
    public static func write(_ arguments: Arguments) -> Result<BuildInfo, StartRefusal> {
        readRegular(arguments.swiftVersionOutput).flatMap { version in
            readRegular(arguments.resolved).flatMap { resolved in
                var text = String(decoding: version, as: UTF8.self)
                while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
                return write(folder: arguments.folder, commit: arguments.commit, swiftVersionOutput: text, resolved: resolved)
            }
        }
    }

    /// The whole contents of the regular file at `path`, opened without following a link. Refused naming the path
    /// otherwise.
    static func readRegular(_ path: String) -> Result<Data, StartRefusal> {
        let fd = Sys.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return refused("\(ConfigSeal.inert(path, limit: .max)) can't be read: \(describe(errno))") }
        defer { Sys.close(fd) }
        return contents(fd, path: path)
    }

    /// Each entry of `folder/bin` by name: the SHA-256 of its bytes. The folder and `bin/` are opened without following
    /// a link, `bin/` is listed through that descriptor, and each entry is opened in it the same way, so what is hashed
    /// is what the listing named.
    private static func hashes(folder: String) -> Result<[String: String], StartRefusal> {
        let top = Sys.open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NOCTTY | O_CLOEXEC)
        guard top >= 0 else { return refused("\(ConfigSeal.inert(folder, limit: .max)) isn't a folder (or is a link): \(describe(errno))") }
        defer { Sys.close(top) }
        let binPath = (folder as NSString).appendingPathComponent("bin")
        let bin = openat(top, "bin", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NOCTTY | O_CLOEXEC)
        guard bin >= 0 else { return refused("\(ConfigSeal.inert(binPath, limit: .max)) isn't a folder (or is a link): \(describe(errno))") }
        defer { Sys.close(bin) }
        let names: [[UInt8]]
        switch entries(bin) {
        case .success(let found): names = found
        case .failure(let failure): return refused("\(ConfigSeal.inert(binPath, limit: .max)) can't be listed: \(describe(failure.code))")
        }
        guard !names.isEmpty else { return refused("\(ConfigSeal.inert(binPath, limit: .max)) holds no program") }
        var found: [String: String] = [:]
        for raw in names.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let name = String(decoding: raw, as: UTF8.self)
            let entry = ConfigSeal.inert((binPath as NSString).appendingPathComponent(name), limit: .max)
            guard Array(name.utf8) == raw else { return refused("\(entry) has a name that isn't UTF-8") }
            let fd = openat(bin, raw.map { CChar(bitPattern: $0) } + [0], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
            guard fd >= 0 else {
                let code = errno
                return refused("\(entry) \(code == ELOOP ? "is a link, not a regular file" : "can't be read: \(describe(code))")")
            }
            defer { Sys.close(fd) }
            switch contents(fd, path: entry) {
            case .success(let bytes): found[name] = BuildInfo.sha256(of: bytes)
            case .failure(let refusal): return .failure(refusal)
            }
        }
        return .success(found)
    }

    /// The names in the open folder `fd` (left open), but `.` and `..`: or the error that stopped the listing.
    private static func entries(_ fd: Int32) -> Result<[[UInt8]], Platform.Errno> {
        // A copy of its own (close-on-exec from the call), which `closedir` closes.
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { return .failure(Platform.Errno(code: errno)) }
        guard let folder = fdopendir(copy) else {
            let code = errno
            Sys.close(copy)
            return .failure(Platform.Errno(code: code))
        }
        defer { closedir(folder) }
        var names: [[UInt8]] = []
        while true {
            errno = 0
            guard let entry = readdir(folder) else {
                if errno != 0 { return .failure(Platform.Errno(code: errno)) }
                return .success(names)
            }
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { field -> [UInt8] in
                let bytes = field.bindMemory(to: UInt8.self)
                return Array(bytes[..<(bytes.firstIndex(of: 0) ?? bytes.count)])
            }
            if name != Array(".".utf8), name != Array("..".utf8) { names.append(name) }
        }
    }

    /// The bytes of the open `fd`, refused unless it is a regular file. `path` is already made inert.
    private static func contents(_ fd: Int32, path: String) -> Result<Data, StartRefusal> {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return refused("\(path) can't be read: \(describe(errno))") }
        guard info.st_mode & S_IFMT == S_IFREG else { return refused("\(path) isn't a regular file") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { Sys.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return refused("\(path) can't be read: \(describe(errno))") }
            if count == 0 { return .success(data) }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    private static func isCommit(_ text: String) -> Bool {
        text.utf8.count == 40 && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    private static func refused<T>(_ text: String) -> Result<T, StartRefusal> { .failure(StartRefusal("install-record: " + text)) }

    private static func describe(_ code: Int32) -> String { String(cString: strerror(code)) }
}
