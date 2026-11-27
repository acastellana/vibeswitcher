import Foundation
import Testing
@testable import VibeCore

/// The build's check that what VibeSwitcher installs into a folder the config seal watches (the hooks' binary, in
/// ~/.vibeswitcher/bin) stays within the seal's per-file read limit (scripts/lib/watched-sizes.sh, run by
/// scripts/build-app.sh on the signed release binary): past `ConfigSeal.readLimit` the seal holds the file for every
/// user's Accept after the update, so the build fails first, already at 80% of it. Scratch files only, sparse: none of
/// them takes the disk its size says.
struct WatchedSizesTests {
    static let repo = KeychainLintTests.repo
    static let helper = repo.appendingPathComponent("scripts/lib/watched-sizes.sh").path
    let scratch = Scratch()

    /// `function arguments…` run with the helper sourced, from the repository's root: its status and what it said.
    func helper(_ function: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let run = Shell.run(executable: "/bin/bash",
                            args: ["-c", "set -euo pipefail; source \"$0\"; \(function) \"$@\"", Self.helper] + arguments,
                            in: Self.repo.path, timeout: 60, grace: 1, interleaved: true)
        return (run.status, run.output)
    }

    /// A sparse scratch file of `size` bytes.
    func file(_ name: String, size: Int) throws -> String {
        let folder = scratch.url("watched-sizes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url.path
    }

    /// The limit the build checks against is read from ConfigSeal.swift's declaration, and is the compiled constant:
    /// changing the limit in the code changes the check, with no copied number to forget.
    @Test func theLimitIsTheSealsOwn() {
        let read = helper("seal_read_limit", [])
        #expect(read.status == 0, Comment(rawValue: read.output))
        #expect(read.output.trimmingCharacters(in: .whitespacesAndNewlines) == String(ConfigSeal.readLimit))
    }

    /// A declaration it can't read fails the build, saying so, rather than checking against nothing.
    @Test func anUnreadableDeclarationFails() throws {
        let source = scratch.url("seal-source")
        try "    static let readLimit = someFunction()\n".write(to: source, atomically: true, encoding: .utf8)
        let read = helper("seal_read_limit", [source.path])
        #expect(read.status != 0)
        #expect(read.output.contains("Couldn't read ConfigSeal.readLimit"))
        let missing = helper("check_watched_sizes", ["", try file("vibeswitcher-hook", size: 1)])
        #expect(missing.status != 0)
        #expect(missing.output.contains("isn't a number of bytes"))
    }

    /// Over the limit: it fails, naming the file, its size and the limit.
    @Test func aBinaryOverTheLimitFails() throws {
        let limit = ConfigSeal.readLimit, path = try file("vibeswitcher-hook", size: limit + 1)
        let check = helper("check_watched_sizes", [String(limit), path])
        #expect(check.status != 0)
        #expect(check.output.contains(path))
        #expect(check.output.contains("\(limit + 1) bytes, over the config seal's per-file limit"))
        #expect(check.output.contains("ConfigSeal.readLimit, \(limit) bytes"))
    }

    /// At 80% of the limit it fails already, saying the threshold and to raise the limit or shrink the binary; just
    /// under 80% passes, and so does a file of today's size (21 MB).
    @Test func eightyPercentOfTheLimitFailsEarly() throws {
        let limit = ConfigSeal.readLimit, threshold = limit * 80 / 100
        let at = try file("at-threshold", size: threshold)
        let early = helper("check_watched_sizes", [String(limit), at])
        #expect(early.status != 0)
        #expect(early.output.contains("\(at) is \(threshold) bytes, at or past 80% (\(threshold) bytes)"))
        #expect(early.output.contains("Raise the limit or shrink the binary before a release"))
        #expect(early.output.contains("ConfigSeal.readLimit, \(limit) bytes"))

        let under = helper("check_watched_sizes", [String(limit), try file("under", size: threshold - 1), try file("today", size: 21_131_296)])
        #expect(under.status == 0, Comment(rawValue: under.output))
        #expect(under.output.contains("under 80%"))
    }

    /// A file it was told to measure and can't find fails: nothing measured is nothing checked.
    @Test func aMissingBinaryFails() {
        let path = scratch.url("absent").appendingPathComponent("vibeswitcher-hook").path
        let check = helper("check_watched_sizes", [String(ConfigSeal.readLimit), path])
        #expect(check.status != 0)
        #expect(check.output.contains("\(path) is missing"))
    }

    /// build-app.sh runs the check on the hooks' binary as it ships (signed, in the app it built), with the limit read
    /// from the code, after the last codesign and before it says it built the app (and before any --install).
    @Test func buildAppChecksTheHookBinaryItShips() throws {
        let script = try String(contentsOf: Self.repo.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("source scripts/lib/watched-sizes.sh"))
        let read = try #require(script.range(of: "SEAL_READ_LIMIT=\"$(seal_read_limit)\"\n"))
        let check = try #require(script.range(of: "check_watched_sizes \"$SEAL_READ_LIMIT\" \"$APP/Contents/MacOS/vibeswitcher-hook\"\n"))
        let signed = try #require(script.range(of: "\n    sign\nfi\n"))
        let built = try #require(script.range(of: "echo \"Built $APP\""))
        let install = try #require(script.range(of: "scripts/lib/install-app.sh \"$APP\""))
        #expect(signed.upperBound <= read.lowerBound && read.upperBound <= check.lowerBound)
        #expect(check.upperBound <= built.lowerBound && built.upperBound <= install.lowerBound)
        // The binary the app installs into ~/.vibeswitcher/bin is the one in the app's MacOS folder, copied as it is.
        #expect(VibePaths.hookBinary.lastPathComponent == "vibeswitcher-hook")
        #expect(VibePaths.hookBinary.deletingLastPathComponent().path == VibePaths.binDir.path)
    }
}
