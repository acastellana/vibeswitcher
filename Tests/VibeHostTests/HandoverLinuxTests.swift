import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// What the host executes on Linux, checked against its build's record (the stage 2 plan's Tasks 9b to 9d, S2-D7,
/// S2-D8; the security architecture document's S8 and S9). Task 9b: a host started with `--node-root` runs only when
/// its own sealed copy, and its `--server`'s, are what that build folder's `build-info` records; a record of a newer
/// format is refused.
///
/// Serialized: a host here holds a sealed copy of this binary (some hundreds of megabytes) as its server.
@Suite(hostTestLimit, .serialized) struct HandoverLinuxTests {
    /// A build folder in `dir` (`<dir>/<name>`, with a `bin/`) whose `build-info` records `binaries` (name to
    /// SHA-256), in `format`.
    static func buildFolder(in dir: String, _ name: String = "build", binaries: [String: String], format: Int = BuildInfo.format) throws -> String {
        let folder = dir + "/" + name
        try FileManager.default.createDirectory(atPath: folder + "/bin", withIntermediateDirectories: true)
        var info = BuildInfo(commit: String(repeating: "c", count: 40), binaries: binaries, swift: "Swift version 6.4.2",
                             resolved: String(repeating: "e", count: 64))
        info.format = format
        try info.encoded.write(to: URL(fileURLWithPath: folder + "/" + BuildInfo.fileName))
        return folder
    }

    /// The SHA-256 of the file at `path`, taken as the host takes it: of a sealed copy's bytes.
    static func sha256(of path: String) throws -> String {
        let copy = try Platform.ProcessSelf.sealedCopy(of: path, name: "hash").get()
        defer { Sys.close(copy.fd) }
        return BuildInfo.sha256(of: copy)
    }

    /// A scratch host started on its own home, socket and lock with `extra` after them, which isn't expected to start:
    /// once it has ended, its exit status and what it said.
    static func refusedHost(in dir: String, _ extra: [String]) async throws -> (status: Int32, said: String) {
        let home = dir + "/home-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let output = home + "/out"
        FileManager.default.createFile(atPath: output, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hostLauncher)
        process.arguments = ["--socket", home + "/h.sock", "--lock", home + "/h.lock", "--idle-exit", "600", "--log", home + "/session.log"] + extra
        process.environment = ["HOME": home, "CFFIXED_USER_HOME": home, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "TMPDIR": dir + "/"]
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try TestHosts.run(process)
        defer { TestHosts.end(process) }
        #expect(await eventually { !process.isRunning })
        let said = (try? String(contentsOfFile: output, encoding: .utf8)) ?? ""
        return (process.isRunning ? -1 : process.terminationStatus, said)
    }

    /// A scratch `--node-root` whose `build-info` records another hash for the host's own image, or for its server, or
    /// none for either: the host exits non-zero, saying which binary, and binds no socket.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's sealed copies and build-info; the Mac has neither"))
    func aHostWhoseImageDiffersFromItsBuildInfoDoesNotStart() async throws {
        let dir = "\(shortScratchRoot)/vshl-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let host = try Self.sha256(of: hostLauncher)
        let other = BuildInfo.sha256(of: Data("another build".utf8))
        let server = "/bin/true"
        let serverHash = try Self.sha256(of: server)

        let wrongHost = try Self.buildFolder(in: dir, "wrong-host", binaries: [BuildInfo.host: other, BuildInfo.server: serverHash])
        var (status, said) = try await Self.refusedHost(in: dir, ["--node-root", wrongHost, "--server", server])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: vibeswitcher-host: its sha256 \(host) isn't the one build-info records (\(other))"), "\(said)")
        #expect(!said.contains("vibeswitcher-host: started"), "\(said)")

        let wrongServer = try Self.buildFolder(in: dir, "wrong-server", binaries: [BuildInfo.host: host, BuildInfo.server: other])
        (status, said) = try await Self.refusedHost(in: dir, ["--node-root", wrongServer, "--server", server])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: vibeswitcher-server: its sha256 \(serverHash) isn't the one build-info records (\(other))"), "\(said)")

        let noServer = try Self.buildFolder(in: dir, "no-server", binaries: [BuildInfo.host: host])
        (status, said) = try await Self.refusedHost(in: dir, ["--node-root", noServer, "--server", server])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: vibeswitcher-server: build-info holds no record for it"), "\(said)")

        let noHost = try Self.buildFolder(in: dir, "no-host", binaries: [:])
        (status, said) = try await Self.refusedHost(in: dir, ["--node-root", noHost])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: vibeswitcher-host: build-info holds no record for it"), "\(said)")

        (status, said) = try await Self.refusedHost(in: dir, ["--node-root", dir + "/no-such-build"])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: its build-info: \(dir)/no-such-build/build-info can't be read"), "\(said)")
    }

    /// A record of a newer format is refused (rule 11), as is one whose commit or hashes aren't of the format's shape;
    /// format 1 is read. A host whose `--node-root` holds a newer record doesn't start.
    @Test func aNewerBuildInfoFormatIsRefused() async throws {
        let hash = String(repeating: "a", count: 64)
        let valid = BuildInfo(commit: String(repeating: "0", count: 40), binaries: [BuildInfo.host: hash], swift: "Swift 6.4.2", resolved: hash)
        #expect(try BuildInfo.parse(valid.encoded).get() == valid)
        var newer = valid
        newer.format = 2
        #expect(BuildInfo.parse(newer.encoded) == .failure(.init("its format 2 is newer than this build's (1)")))
        // A newer format is refused by its number alone, whatever else it holds.
        #expect(BuildInfo.parse(Data(#"{"format":3,"layout":"another"}"#.utf8)) == .failure(.init("its format 3 is newer than this build's (1)")))
        #expect(BuildInfo.parse(Data("not json".utf8)) == .failure(.init("not a build record (no format)")))
        var shortCommit = valid
        shortCommit.commit = "abc"
        #expect(BuildInfo.parse(shortCommit.encoded) == .failure(.init("its commit isn't 40 hex digits")))
        var upperHash = valid
        upperHash.binaries[BuildInfo.host] = hash.uppercased()
        #expect(BuildInfo.parse(upperHash.encoded) == .failure(.init("its hash for vibeswitcher-host isn't 64 hex digits")))

        guard !Platform.CodeIdentity.isAvailable else { return }
        let dir = "\(shortScratchRoot)/vshl-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let folder = try Self.buildFolder(in: dir, binaries: [BuildInfo.host: try Self.sha256(of: hostLauncher)], format: 2)
        let (status, said) = try await Self.refusedHost(in: dir, ["--node-root", folder])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: its build-info: \(folder)/build-info: its format 2 is newer than this build's (1)"), "\(said)")
    }

    /// A scratch host whose `--node-root` records its own image's hash and its server's starts, and its server child is
    /// told that folder as its `--node-root` (S2-D1), not the host's executable's.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's sealed copies and build-info; the Mac has neither"))
    func aHostWhoseImagesMatchItsBuildInfoStartsAndTellsItsServerTheFolder() async throws {
        let dir = "\(shortScratchRoot)/vshl-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let binary = try #require(Bundle.main.executablePath)
        let folder = try Self.buildFolder(in: dir, binaries: [BuildInfo.host: try Self.sha256(of: hostLauncher),
                                                              BuildInfo.server: try Self.sha256(of: binary)])
        let host = try await ServerChildHost(actions: ["sleep"], extra: ["--node-root", folder])
        defer { host.stop() }
        #expect(await host.firstHelper() != nil, "\(host.said)")
        let line = try #require(host.started.first?.line)
        #expect(line.contains(" node-root=\(folder) "), "\(line)")
        #expect(line.contains(" root=\(host.home)/.vibeswitcher "), "\(line)")
    }
}
