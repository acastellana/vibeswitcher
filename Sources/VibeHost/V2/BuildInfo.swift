import Foundation
import VibeCore

/// What an installed build is (the stage 2 plan's Task 9b, S2-D7; the security architecture document's S9): the file
/// `<installRoot>/<commit>/build-info` the install writes (the bootstrap path's step 8) beside that build's `bin/`, and
/// the user's host reads at its start (its own image and its `--server` image must match it), a handover's target
/// check reads (Task 9d) and `ServerBuild` reads for merge receipts.
///
/// **The format** (format 1), JSON:
///
///     {"format":1,"commit":"<40 hex>","binaries":{"vibeswitcher-host":"<sha256 hex>",…},
///      "swift":"<swift --version>","resolved":"<sha256 of Package.resolved>"}
///
/// one entry in `binaries` per file in that build's `bin/`, by its name, each the SHA-256 of its bytes in lowercase
/// hex. A newer format is refused (rule 11: a build never guesses at a format it doesn't know), as is a record whose
/// commit or hashes aren't of that shape.
public struct BuildInfo: Codable, Equatable, Sendable {
    /// The format this build writes and reads; a record of a newer one is refused.
    public static let format = 1
    /// The record's name in a build's folder.
    public static let fileName = "build-info"
    /// The names `binaries` records the host's own image and its server under.
    public static let host = "vibeswitcher-host"
    public static let server = "vibeswitcher-server"

    public var format: Int
    /// The commit the build was made from: 40 lowercase hex digits.
    public var commit: String
    /// Each file in the build's `bin/`, by name: the SHA-256 of its bytes, 64 lowercase hex digits.
    public var binaries: [String: String]
    /// What `swift --version` said for the build.
    public var swift: String
    /// The SHA-256 of the build's `Package.resolved`.
    public var resolved: String

    public init(commit: String, binaries: [String: String], swift: String, resolved: String) {
        format = Self.format
        self.commit = commit
        self.binaries = binaries
        self.swift = swift
        self.resolved = resolved
    }

    /// The record in `bytes`, or why it isn't one this build reads: not JSON of this shape, a format other than this
    /// build's (a newer one said so), a commit or a hash of the wrong shape.
    public static func parse(_ bytes: Data) -> Result<BuildInfo, Refused> {
        struct Format: Decodable { var format: Int }
        guard let format = try? JSONDecoder().decode(Format.self, from: bytes).format else {
            return .failure(Refused("not a build record (no format)"))
        }
        guard format <= Self.format else { return .failure(Refused("its format \(format) is newer than this build's (\(Self.format))")) }
        guard format == Self.format else { return .failure(Refused("its format \(format) isn't this build's (\(Self.format))")) }
        guard let info = try? JSONDecoder().decode(BuildInfo.self, from: bytes) else {
            return .failure(Refused("not a build record of format \(format)"))
        }
        guard isHex(info.commit, count: 40) else { return .failure(Refused("its commit isn't 40 hex digits")) }
        guard isHex(info.resolved, count: 64) else { return .failure(Refused("its Package.resolved hash isn't 64 hex digits")) }
        for (name, hash) in info.binaries where !isHex(hash, count: 64) {
            return .failure(Refused("its hash for \(name) isn't 64 hex digits"))
        }
        return .success(info)
    }

    /// The record of the build folder `buildFolder` (`<buildFolder>/build-info`), or why there is none to read.
    public static func read(buildFolder: String) -> Result<BuildInfo, Refused> {
        let path = (buildFolder as NSString).appendingPathComponent(fileName)
        guard let bytes = FileManager.default.contents(atPath: path) else { return .failure(Refused("\(path) can't be read")) }
        return parse(bytes).mapError { Refused("\(path): \($0.description)") }
    }

    /// The JSON this record is written as.
    public var encoded: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Why `copy`, taken for the binary `name`, isn't what this record holds for it (no record for it, or another
    /// hash, both said), or nil when it is. The hash is of the copy's own bytes (`SealedCopy.withBytes`): what runs.
    public func mismatch(of copy: Platform.ProcessSelf.SealedCopy, as name: String) -> String? {
        let hash = Self.sha256(of: copy)
        guard let recorded = binaries[name] else { return "\(name): build-info holds no record for it" }
        guard recorded == hash else { return "\(name): its sha256 \(hash) isn't the one build-info records (\(recorded))" }
        return nil
    }

    /// The SHA-256 of `copy`'s bytes, lowercase hex.
    public static func sha256(of copy: Platform.ProcessSelf.SealedCopy) -> String {
        copy.withBytes { hex(SHA256.hash(data: $0)) }
    }

    /// The SHA-256 of `data`, lowercase hex.
    public static func sha256(of data: Data) -> String { hex(SHA256.hash(data: data)) }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    /// Why a record isn't read.
    public struct Refused: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }
}
