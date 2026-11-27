import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The Mac node's record of its builds' code (the node on the Mac's design, "The anchor"; docs/process/v2-mac-tasks.md
/// items 3, 10 and 12): for each build a rollback may go to, the cdhashes of its host, its server and its command line,
/// written by the install's administrator step alone (`scripts/node-pins-mac.sh`, as root) in a file only root can
/// change (`Platform.Service.nodePinsRecord`, read through `Platform.Files.readRootRecord`: here `Keep.Service` and
/// `Keep.Files`). The node's checks find a build by the code a process runs, never by a path under the user's home.
/// Text, one fact per line, parsed whole (moved from VibeCore unchanged; VibeCore's `NodePins` is this):
///
///     # a comment (any line starting with #)
///     format 1
///     uid 501
///     build <commit: 40 hex> host <cdhash: 40 hex> server <cdhash> cli <cdhash>
///
/// `uid` the reader's own; one to `maxBuilds` builds, the installed one first; no commit and no cdhash twice; every
/// other line, word, case or byte refused. Anything unusual about the record or its path is a refusal, never a case to
/// handle (`Refused`, with what to do).
public struct NodePins: Equatable, Sendable {
    /// One build's code, by the cdhash of each program as the install signed it (this Mac's slice).
    public struct Build: Equatable, Sendable {
        public var commit: String
        public var host: Data
        public var server: Data
        public var cli: Data

        public init(commit: String, host: Data, server: Data, cli: Data) {
            self.commit = commit
            self.host = host
            self.server = server
            self.cli = cli
        }

        /// Its line in the record.
        public var line: String {
            "build \(commit) host \(NodePins.hex(host)) server \(NodePins.hex(server)) cli \(NodePins.hex(cli))"
        }
    }

    /// Why the record can't be used: one plain line naming it and what to do.
    public struct Refused: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    public var uid: uid_t
    public var builds: [Build]

    public init(uid: uid_t, builds: [Build]) {
        self.uid = uid
        self.builds = builds
    }

    public static let format = "format 1"
    public static let maxBytes = 64 * 1024
    public static let maxBuilds = 16
    /// What to do about a refused record.
    public static let remedy = "install a newer commit with scripts/install-node-mac.sh, whose administrator step writes the record from the build it checked (never type a build's values by hand)"

    /// The installed record's place for this account: `/` and `Platform.Service.nodePinsRecord`'s folders. nil where
    /// there is none (Linux).
    public static func installedPath(uid: uid_t = getuid()) -> [String]? { Keep.Service.nodePinsRecord(uid: uid) }

    /// The record for `uid` read from `components` below `base` (the installed one: `installedPath`, from `/`), checked
    /// as only root's to write (`Platform.Files.readRootRecord`; `owner` a test's fact), then parsed (`parse`). Every
    /// failure is a refusal naming the record.
    public static func read(uid: uid_t = getuid(), components: [String]? = installedPath(), base: String = "/",
                            owner: (String, uid_t) -> uid_t = { $1 }) -> Result<NodePins, Refused> {
        guard let components else { return .failure(Refused("this system keeps no record of the node's builds")) }
        let named = components.reduce(base == "/" ? "" : base) { $0 + "/" + $1 }
        switch Keep.Files.readRootRecord(components, base: base, maxBytes: maxBytes, owner: owner) {
        case .failure(let why):
            return .failure(Refused("the node's record of its builds can't be taken: \(why.description); \(remedy)"))
        case .success(let data):
            return parse(data, uid: uid).mapError { Refused("the node's record of its builds (\(named)) \($0.description); \(remedy)") }
        }
    }

    /// The record `data` holds for `uid`, or why it is refused (said after "the record").
    public static func parse(_ data: Data, uid: uid_t) -> Result<NodePins, Refused> {
        guard !data.isEmpty, data.last == 0x0a else { return .failure(Refused("doesn't end with a line's end")) }
        guard data.allSatisfy({ $0 == 0x0a || (0x20...0x7e).contains($0) }) else { return .failure(Refused("holds a byte that isn't printable ASCII")) }
        let text = String(decoding: data.dropLast(), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.hasPrefix("#") }
        guard lines.count >= 3 else { return .failure(Refused("names no build")) }
        guard lines[0] == format else { return .failure(Refused("isn't in \(format)")) }
        let uidWords = lines[1].split(separator: " ", omittingEmptySubsequences: false)
        guard uidWords.count == 2, uidWords[0] == "uid", let read = decimal(String(uidWords[1])) else { return .failure(Refused("names no uid")) }
        guard read == uid else { return .failure(Refused("is uid \(read)'s, not \(uid)'s")) }
        let rows = lines.dropFirst(2)
        guard rows.count <= maxBuilds else { return .failure(Refused("names more than \(maxBuilds) builds")) }
        var builds: [Build] = []
        var commits = Set<String>()
        var hashes = Set<Data>()
        for row in rows {
            let words = row.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard words.count == 8, words[0] == "build", words[2] == "host", words[4] == "server", words[6] == "cli",
                  isHex(words[1]), let host = bytes(words[3]), let server = bytes(words[5]), let cli = bytes(words[7]) else {
                return .failure(Refused("has a line that isn't a build's: \(row.prefix(200))"))
            }
            guard commits.insert(words[1]).inserted else { return .failure(Refused("names \(words[1]) twice")) }
            for hash in [host, server, cli] {
                guard hashes.insert(hash).inserted else { return .failure(Refused("names the cdhash \(hex(hash)) twice")) }
            }
            builds.append(Build(commit: words[1], host: host, server: server, cli: cli))
        }
        return .success(NodePins(uid: uid, builds: builds))
    }

    /// The record's text: `parse`'s form, the builds in order.
    public var text: String {
        "# VibeSwitcher node pins: written by the install's administrator step (scripts/node-pins-mac.sh); read by the node's checks\n"
            + "\(Self.format)\nuid \(uid)\n" + builds.map { $0.line + "\n" }.joined()
    }

    /// The build whose host is `cdhash`; nil when none is.
    public func build(host cdhash: Data) -> Build? { builds.first { $0.host == cdhash } }

    /// The build whose server is `cdhash`; nil when none is.
    public func build(server cdhash: Data) -> Build? { builds.first { $0.server == cdhash } }

    /// A cdhash in the record's form: lowercase hex.
    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// 40 lowercase hex digits.
    static func isHex(_ word: String) -> Bool {
        word.utf8.count == 40 && word.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A cdhash's 20 bytes from its 40 lowercase hex digits; nil otherwise.
    public static func bytes(_ word: String) -> Data? {
        guard isHex(word) else { return nil }
        var data = Data()
        var index = word.startIndex
        while index < word.endIndex {
            let next = word.index(index, offsetBy: 2)
            guard let byte = UInt8(word[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// A uid in plain decimal (no sign, no leading zero, at most 10 digits); nil otherwise.
    static func decimal(_ word: String) -> uid_t? {
        guard !word.isEmpty, word.utf8.count <= 10, word.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              word == "0" || !word.hasPrefix("0") else { return nil }
        return uid_t(word)
    }
}
