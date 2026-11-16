import Foundation
import Testing
@testable import VibeCore

/// Builds report themselves (the start plan's S5): on Linux the tool server's build is the `build-info` two folders up
/// from its resolved executable (`ServerBuildLinux`), the merge gate's refusal names the Linux install, and the host's
/// notes carry its build optionally. The Mac's cases say its behaviour is today's.
struct ServerBuildLinuxTests {
    let scratch = Scratch()
    static let commit = String(repeating: "c", count: 40)
    static let program = "vibeswitcher-mcp"

    /// `<root>/<commit>/bin/vibeswitcher-mcp` holding `bytes`, and its build's `build-info` recording their SHA-256:
    /// the executable's path.
    func installed(_ bytes: Data = Data("a tool server".utf8)) throws -> (root: URL, executable: URL) {
        let root = scratch.url("server-build")
        let build = root.appendingPathComponent(Self.commit, isDirectory: true)
        let bin = build.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent(Self.program)
        try bytes.write(to: executable)
        let info = BuildInfo(commit: Self.commit, binaries: [Self.program: BuildInfo.sha256(of: bytes)], swift: "test",
                             resolved: String(repeating: "0", count: 64))
        try info.encoded.write(to: build.appendingPathComponent(BuildInfo.fileName))
        return (root, executable)
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux: the build-info read"))
    func aLinuxToolServerNamesItsBuild() throws {
        let (root, executable) = try installed()
        let build = try #require(ServerBuild.read(executable: executable.path))
        #expect(build.commit == Self.commit)
        #expect(build.changed == false)
        #expect(build.builtAt == nil)
        // Reached through a link (`current`, as `vs` is), the path resolves to the build's own folder.
        let current = root.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: Self.commit)
        #expect(ServerBuild.read(executable: current.appendingPathComponent("bin/" + Self.program).path)?.commit == Self.commit)
        // One byte changed: the gate fails closed.
        try Data("a tool server!".utf8).write(to: executable)
        #expect(ServerBuild.read(executable: executable.path)?.changed == true)
        // A program its build-info doesn't name is changed too.
        let other = executable.deletingLastPathComponent().appendingPathComponent("vibeswitcher-other")
        try Data("other".utf8).write(to: other)
        #expect(ServerBuild.read(executable: other.path)?.changed == true)
        // No build-info: no build.
        try FileManager.default.removeItem(at: root.appendingPathComponent(Self.commit).appendingPathComponent(BuildInfo.fileName))
        #expect(ServerBuild.read(executable: executable.path) == nil)
        // No executable: no build.
        #expect(ServerBuild.read(executable: root.appendingPathComponent("missing/bin/x").path) == nil)
    }

    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's"))
    func theMacStillReadsOnlyTheAppBundle() throws {
        let (_, executable) = try installed()
        #expect(ServerBuild.read(executable: executable.path) == nil)
    }

    static func lag() -> LeadToolset.GateLag {
        LeadToolset.GateLag(commits: [(id: "abc1234", subject: "the gate")], build: ServerBuild(commit: commit, builtAt: nil))
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux: the node's install"))
    func theGateNamesTheLinuxInstallOnLinux() {
        let refusal = Self.lag().refusal(base: "main", what: "The merge")
        #expect(refusal.contains("install-node.sh"), "\(refusal)")
        #expect(refusal.contains("vs switch"), "\(refusal)")
        #expect(!refusal.contains("build-app.sh"), "\(refusal)")
        #expect(refusal.contains(ServerBuildLinux.installHint), "\(refusal)")
    }

    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's"))
    func theGateStillNamesTheAppInstallOnTheMac() {
        let refusal = Self.lag().refusal(base: "main", what: "The merge")
        #expect(refusal.contains("scripts/build-app.sh --install"), "\(refusal)")
        #expect(!refusal.contains("install-node.sh"), "\(refusal)")
    }

    /// A host from before S5 sends notes with no `build` or `binaries`: they still read, both nil.
    @Test func anOlderHostsNotesWithoutABuildStillRead() throws {
        let older = Data(#"{"startedAt":0,"serverRestarts":2,"replacedPaths":["/a"],"refusedAppConnections":1}"#.utf8)
        let notes = try JSONDecoder().decode(HostNotes.self, from: older)
        #expect(notes.serverRestarts == 2 && notes.replacedPaths == ["/a"] && notes.refusedAppConnections == 1)
        #expect(notes.build == nil && notes.binaries == nil)
        // A newer host's carry both, and they come back as sent.
        var newer = notes
        newer.build = Self.commit
        newer.binaries = [Self.program: String(repeating: "1", count: 64)]
        let again = try JSONDecoder().decode(HostNotes.self, from: JSONEncoder().encode(newer))
        #expect(again == newer)
    }
}
