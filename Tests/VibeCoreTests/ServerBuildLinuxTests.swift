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

    /// The review of S5 (2026-11-16): a build its `build-info` doesn't vouch for says why, not the Mac's "changes not
    /// committed"; is named by no commit in a receipt; and a record whose commit isn't its folder's name (only `commit`
    /// rewritten, to the base's head) doesn't vouch for it. The bytes hashed are the running image's when the path is
    /// this process's own executable (`/proc/self/exe`: a file renamed over the path later isn't what runs).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux: the build-info read"))
    func aLinuxBuildItsRecordDoesntVouchForSaysWhy() throws {
        let (root, executable) = try installed()
        try Data("a tool server!".utf8).write(to: executable)
        let tampered = try #require(ServerBuild.read(executable: executable.path))
        #expect(tampered.changed && tampered.changedWhy?.contains("SHA-256") == true, "\(tampered)")
        #expect(tampered.label.hasPrefix("unknown (") && !tampered.label.contains("not committed"), "\(tampered.label)")
        #expect(SetupInstalls.commit(ofBuild: tampered.label) == nil)
        #expect(LeadProvenance.buildText(tampered).hasPrefix("unknown (") && !LeadProvenance.buildText(tampered).contains("not committed"))
        let other = executable.deletingLastPathComponent().appendingPathComponent("vibeswitcher-other")
        try Data("other".utf8).write(to: other)
        #expect(ServerBuild.read(executable: other.path)?.changedWhy?.contains("vibeswitcher-other") == true)
        // Only the record's commit rewritten (to another commit, the program's hash kept): it doesn't vouch.
        let bytes = Data("a tool server".utf8)
        try bytes.write(to: executable)
        let head = String(repeating: "d", count: 40)
        let rewritten = BuildInfo(commit: head, binaries: [Self.program: BuildInfo.sha256(of: bytes)], swift: "test",
                                  resolved: String(repeating: "0", count: 64))
        try rewritten.encoded.write(to: root.appendingPathComponent(Self.commit).appendingPathComponent(BuildInfo.fileName))
        let moved = try #require(ServerBuild.read(executable: executable.path))
        #expect(moved.changed && moved.changedWhy?.contains("folder") == true, "\(moved)")
        // The bytes hashed are the image's: another file's than the path's is changed.
        let record = BuildInfo(commit: Self.commit, binaries: [Self.program: BuildInfo.sha256(of: bytes)], swift: "test",
                               resolved: String(repeating: "0", count: 64))
        try record.encoded.write(to: root.appendingPathComponent(Self.commit).appendingPathComponent(BuildInfo.fileName))
        #expect(ServerBuild.read(executable: executable.path)?.changed == false)
        #expect(ServerBuildLinux.read(executable: executable.path, image: other.path)?.changed == true)
        // This process's own executable is read through /proc/self/exe; any other path as itself.
        let own = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        #expect(ServerBuildLinux.image(of: own) == "/proc/self/exe")
        #expect(ServerBuildLinux.image(of: executable.resolvingSymlinksInPath().path) == executable.resolvingSymlinksInPath().path)
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

extension LeadRemoteTests {
    /// The review of S5 (2026-11-16): a build `changed` for another reason than changes not committed (on Linux, its
    /// `build-info` doesn't vouch for its program) fails the gate closed saying that reason.
    @Test func aBuildChangedForAnotherReasonIsSaidSoByTheGate() throws {
        let scene = try makeScene()
        let lead = try lead(scene.root, FakeRuntime())
        lead.power = { nil }
        try gateCommit(scene)
        let why = "its program's SHA-256 isn't the one its build-info records"
        lead.runningBuild = { ServerBuild(commit: self.head(scene.root), changed: true, builtAt: nil, changedWhy: why) }
        let status = lead.call("status", [:]).text
        #expect(status.contains("couldn't be compared with the installed build (unknown (\(why))): \(why), so its commit doesn't say what it holds"),
                "\(status)")
        #expect(!status.contains("not committed"), "\(status)")
    }
}
