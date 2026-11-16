import Foundation
import Testing
import VibeCore
import VibeNode

/// The install's build record (the start plan's S4a, ST-D13): `BuildRecord.write` in process, on scratch build folders,
/// and the command line's unlisted `install-record` that `scripts/install-node.sh` runs from the just-built binary.
/// Nothing here reads or writes the account's builds folder. The Mac runs these.
struct InstallTests {
    private let scratch = Scratch()

    static let commit = String(repeating: "a", count: 40)
    static let other = String(repeating: "b", count: 40)
    static let swift = "Swift version 6.4.2 (swift-6.4.2-RELEASE)\nTarget: x86_64-unknown-linux-gnu"
    static let resolved = Data(#"{"pins":[],"version":3}"#.utf8)

    /// A scratch builds folder holding `<name>/bin/` with `programs` (name to bytes) in it: the build folder's path.
    private func buildFolder(named name: String = InstallTests.commit, programs: [String: Data]) throws -> String {
        let folder = scratch.url("builds").appendingPathComponent(name)
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (program, bytes) in programs {
            try bytes.write(to: bin.appendingPathComponent(program))
        }
        return folder.path
    }

    private func record(_ folder: String, commit: String = InstallTests.commit) -> Result<BuildInfo, StartRefusal> {
        BuildRecord.write(folder: folder, commit: commit, swiftVersionOutput: Self.swift, resolved: Self.resolved)
    }

    private func recordFile(_ folder: String) -> String { (folder as NSString).appendingPathComponent(BuildInfo.fileName) }

    @Test func aRecordForAFolderNamedOtherThanItsCommitIsRefused() throws {
        let programs = ["vibeswitcher-host": Data("host".utf8)]
        // Another commit's folder: refused, naming both, and nothing written.
        let folder = try buildFolder(programs: programs)
        guard case let .failure(refusal) = record(folder, commit: Self.other) else {
            Issue.record("a folder named \(Self.commit) took a record of \(Self.other)")
            return
        }
        #expect(refusal.text.contains(Self.commit) && refusal.text.contains(Self.other), "\(refusal)")
        #expect(!FileManager.default.fileExists(atPath: recordFile(folder)))

        // A name that only starts with the commit, or a commit that isn't 40 lowercase hex digits: refused too.
        for name in [Self.commit + "-old", Self.commit + ".partial.x", "x" + Self.commit] {
            let named = try buildFolder(named: name, programs: programs)
            #expect(throws: StartRefusal.self, "\(name)") { try record(named).get() }
            #expect(!FileManager.default.fileExists(atPath: recordFile(named)), "\(name)")
        }
        for commit in [String(repeating: "A", count: 40), String(repeating: "a", count: 39), "HEAD"] {
            let named = try buildFolder(named: commit, programs: programs)
            #expect(throws: StartRefusal.self, "\(commit)") { try record(named, commit: commit).get() }
            #expect(!FileManager.default.fileExists(atPath: recordFile(named)), "\(commit)")
        }

        // Its own name takes it, and so does the install's staging name (`<commit>.partial`, renamed to `<commit>`
        // after the record: S4b), with a trailing slash or none.
        let own = try buildFolder(programs: programs)
        #expect(try record(own + "/").get().commit == Self.commit)
        let staged = try buildFolder(named: Self.commit + ".partial", programs: programs)
        #expect(try record(staged).get().commit == Self.commit)
        #expect(FileManager.default.fileExists(atPath: recordFile(staged)))
    }

    @Test func aRecordHashesEveryProgramAndRefusesALink() throws {
        // `abc`'s SHA-256 (FIPS 180-2's first example), and two other programs, a hidden one among them.
        let programs = ["vibeswitcher-host": Data("abc".utf8), "vibeswitcher": Data("cli".utf8), ".hidden": Data()]
        let folder = try buildFolder(programs: programs)
        let info = try record(folder).get()
        #expect(info.binaries.count == 3, "\(info.binaries)")
        #expect(info.binaries["vibeswitcher-host"] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for (name, bytes) in programs { #expect(info.binaries[name] == BuildInfo.sha256(of: bytes), "\(name)") }
        #expect(!info.binaries.keys.contains(BuildInfo.fileName))

        // A link in `bin/` (to a program beside it, or to one outside): refused, naming it; nothing written.
        let bin = (folder as NSString).appendingPathComponent("bin")
        for (name, target) in [("vibeswitcher-mcp", "vibeswitcher-host"), ("vibeswitcher-hook", "/bin/sh")] {
            let linked = try buildFolder(programs: programs)
            let linkedBin = (linked as NSString).appendingPathComponent("bin")
            try FileManager.default.createSymbolicLink(atPath: (linkedBin as NSString).appendingPathComponent(name), withDestinationPath: target)
            guard case let .failure(refusal) = record(linked) else {
                Issue.record("a link \(name) -> \(target) in bin/ was recorded")
                continue
            }
            #expect(refusal.text.contains(name), "\(refusal)")
            #expect(!FileManager.default.fileExists(atPath: recordFile(linked)))
        }
        // A folder in `bin/`: not a regular file either.
        let nested = try buildFolder(programs: programs)
        try FileManager.default.createDirectory(atPath: (nested as NSString).appendingPathComponent("bin/sub"), withIntermediateDirectories: false)
        #expect(throws: StartRefusal.self) { try record(nested).get() }
        #expect(!FileManager.default.fileExists(atPath: recordFile(nested)))

        // `bin/` itself a link, the build folder a link, and no `bin/`: refused.
        let linkedFolder = scratch.url("builds").appendingPathComponent(Self.commit)
        try FileManager.default.createDirectory(at: linkedFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkedFolder.appendingPathComponent("bin").path, withDestinationPath: bin)
        #expect(throws: StartRefusal.self) { try record(linkedFolder.path).get() }
        let outer = scratch.url("builds")
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: outer.appendingPathComponent(Self.commit).path, withDestinationPath: folder)
        #expect(throws: StartRefusal.self) { try record(outer.appendingPathComponent(Self.commit).path).get() }
        let empty = scratch.url("builds").appendingPathComponent(Self.commit)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: StartRefusal.self) { try record(empty.path).get() }
        #expect(throws: StartRefusal.self) { try record(try buildFolder(programs: [:])).get() }
    }

    @Test func aRecordNamesItsToolchainAndResolvedFile() throws {
        let folder = try buildFolder(programs: ["vibeswitcher-host": Data("host".utf8), "vibeswitcher-server": Data("server".utf8)])
        let info = try record(folder).get()
        #expect(info.format == BuildInfo.format)
        #expect(info.commit == Self.commit)
        #expect(info.swift == Self.swift)
        #expect(info.resolved == BuildInfo.sha256(of: Self.resolved))
        // Written as `BuildInfo` encodes it, private to the user, and read back whole by `BuildInfo.read`.
        let file = recordFile(folder)
        #expect(FileManager.default.contents(atPath: file) == info.encoded)
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o077 == 0, "build-info is \(String(mode.intValue, radix: 8))")
        #expect(try BuildInfo.read(buildFolder: folder).get() == info)

        // No toolchain text: refused, nothing written.
        let blank = try buildFolder(programs: ["vibeswitcher-host": Data("host".utf8)])
        #expect(throws: StartRefusal.self) {
            try BuildRecord.write(folder: blank, commit: Self.commit, swiftVersionOutput: " \n", resolved: Self.resolved).get()
        }
        #expect(!FileManager.default.fileExists(atPath: recordFile(blank)))
    }

    @Test func theInstalledNamesAreTheBuildsPrograms() {
        #expect(BuildRecord.installedNames == ["vibeswitcher-host", "vibeswitcher-server", "vibeswitcher", "vibeswitcher-hook", "vibeswitcher-mcp"])
        #expect(BuildRecord.installedNames.contains(BuildInfo.host) && BuildRecord.installedNames.contains(BuildInfo.server))
    }

    /// The command line's `install-record`, run as built: it writes what `BuildRecord.write` writes, from the files it
    /// is given; a misuse exits 64 and a refusal 77 (`StartRefusal`'s), each writing nothing; and the usage text doesn't list it.
    @Test func theCommandLineWritesTheRecord() async throws {
        let home = scratch.url("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("home"), withIntermediateDirectories: true)
        let environment = scratchEnvironment(home)
        let folder = try buildFolder(programs: ["vibeswitcher-host": Data("host".utf8), "vibeswitcher": Data("cli".utf8)])
        let inputs = scratch.url("inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let version = inputs.appendingPathComponent("swift-version"), resolvedFile = inputs.appendingPathComponent("Package.resolved")
        // As `swift --version > F` writes it: with its line end, which the record leaves out.
        try Data((Self.swift + "\n").utf8).write(to: version)
        try Self.resolved.write(to: resolvedFile)
        let arguments = ["install-record", folder, "--commit", Self.commit, "--swift-version-output", version.path, "--resolved", resolvedFile.path]

        for misuse in [["install-record"], ["install-record", folder, "--commit", Self.commit], arguments + ["--extra"],
                       ["install-record", folder, "--commit", Self.commit, "--swift-version-output", version.path, "--resolved"]] {
            let ran = try await run(commandLine, misuse, environment: environment)
            #expect(ran.status == 64, "\(misuse): \(ran.status) \(ran.errors)")
        }
        let refused = try await run(commandLine, ["install-record", folder, "--commit", Self.other, "--swift-version-output", version.path,
                                                  "--resolved", resolvedFile.path], environment: environment)
        #expect(refused.status == 77, "\(refused.status) \(refused.errors)")
        #expect(refused.errors.contains(Self.other), "\(refused.errors)")
        let unreadable = try await run(commandLine, ["install-record", folder, "--commit", Self.commit, "--swift-version-output",
                                                     inputs.appendingPathComponent("missing").path, "--resolved", resolvedFile.path], environment: environment)
        #expect(unreadable.status == 77, "\(unreadable.status) \(unreadable.errors)")
        #expect(!FileManager.default.fileExists(atPath: recordFile(folder)))

        let ran = try await run(commandLine, arguments, environment: environment)
        #expect(ran.status == 0, "\(ran.status) \(ran.errors)")
        let info = try BuildInfo.read(buildFolder: folder).get()
        #expect(info.commit == Self.commit && info.swift == Self.swift && info.resolved == BuildInfo.sha256(of: Self.resolved))
        #expect(info.binaries == ["vibeswitcher-host": BuildInfo.sha256(of: Data("host".utf8)), "vibeswitcher": BuildInfo.sha256(of: Data("cli".utf8))])

        let help = try await run(commandLine, ["help"], environment: environment)
        #expect(help.status == 0)
        #expect(!help.output.contains("install-record"), "\(help.output)")
    }
}
