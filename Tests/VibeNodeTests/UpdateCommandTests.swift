import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// `vibeswitcher update` on a scratch node whose install root is its home's builds folder (`~/.vibeswitcher/v2/builds`,
/// which its vault watches), with a stand-in for install-node (`--test-installer`, a scratch node's alone) that lays the
/// build out as install-node does (the folder, `installs`, `current`): one code installs, switches, and accepts the
/// builds folder as the install left it, leaving any other held change held; a plant beside the install keeps the
/// folder held and refuses the switch; a failed install switches nothing and leaves no folder.
@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(10)))
struct UpdateCommandTests {
    private let scratch = Scratch()
    static let (a, b) = (String(repeating: "a", count: 40), String(repeating: "b", count: 40))

    struct Rig {
        let node: ScratchNode
        let installs: URL
        let installer: URL
        /// A's folder, whose `Resources/install-node.sh` is the same stand-in (`--test-build`), and the file it writes
        /// as it starts.
        let buildA: URL
        let marker: URL
        var ran: Bool { FileManager.default.fileExists(atPath: marker.path) }
    }

    /// A node running A from its home's builds folder, `current` naming A, B staged for the stand-in (its server a byte
    /// longer, as every switch between commits), the stand-in running `extra` (shell) after it lays B out.
    func rig(extra: String = "", fails: Bool = false) async throws -> Rig {
        let root = try scratch.shortFolder("vsn")
        let installs = root.appendingPathComponent("v2/builds", isDirectory: true)
        let buildA = try ScratchBuilds.install(commit: Self.a, into: installs)
        try FileManager.default.createSymbolicLink(atPath: installs.appendingPathComponent("current").path, withDestinationPath: Self.a)
        let staged = scratch.url("staged")
        var bytes = try Data(contentsOf: builtProducts.appendingPathComponent(BuildInfo.server))
        bytes.append(0)
        let padded = scratch.url("padded-server")
        try bytes.write(to: padded)
        try ScratchBuilds.install(commit: Self.b, into: staged, replacing: [BuildInfo.server: padded.path])
        let installer = scratch.url("installer")
        let marker = scratch.url("installer-ran")
        let script = """
            #!/bin/bash
            set -e
            commit=$1 prefix=$2
            [[ $2 == --prefix ]] && prefix=$3
            echo ran > '\(marker.path)'
            echo "stand-in install of $commit"
            \(fails ? "/bin/cp -a -- '\(staged.path)/'\"$commit\" \"$prefix/$commit\"; echo 'the build failed' >&2; exit 3" : "")
            /bin/cp -a -- '\(staged.path)/'"$commit" "$prefix/$commit"
            printf '%s %s\\n' "$commit" "$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$prefix/installs"
            /bin/ln -s -- "$commit" "$prefix/current.new" && /bin/mv -T -- "$prefix/current.new" "$prefix/current"
            \(extra)
            """
        try writeClosedOnExec(script, to: installer)
        let resources = buildA.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try writeClosedOnExec(script, to: resources.appendingPathComponent("install-node.sh"))
        let node = try await ScratchNode(scratch, reusing: root, build: buildA, installRoot: installs)
        return Rig(node: node, installs: installs, installer: installer, buildA: buildA, marker: marker)
    }

    func held(_ node: ScratchNode) async throws -> String {
        try await node.run(["config", "held", node.home.path]).output
    }

    @Test func oneCodeInstallsSwitchesAndAcceptsTheBuildsFolderOnly() async throws {
        let rig = try await rig()
        let node = rig.node
        defer { node.stop() }
        // The vault's first look records the home as it is (a fresh vault that doesn't hold its first look).
        _ = try await held(node)
        // Held before: a program in the home's bin (code, so no quiet look seals it), which the code never accepts.
        let tool = node.home.appendingPathComponent("bin/tool")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeClosedOnExec("#!/bin/sh\n", to: tool)
        var seen = ""
        let deadline = MacTime.real.awake() + 60
        while !seen.contains("~/bin"), MacTime.real.awake() < deadline {
            seen = try await held(node)
            if !seen.contains("~/bin") { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        try #require(seen.contains("~/bin"), "\(seen)")
        let server = try #require(node.serverPID)

        // The build's own install script, as on the node (`--test-build`: the build this command line "runs from").
        let updated = try await node.runOnTerminal(["update", Self.b, "--test-build", rig.buildA.path])
        let out = updated.output
        #expect(updated.status == 0, "\(out)\(updated.errors)\n\(node.said)")
        #expect(out.contains("This updates the node from the build of commit \(Self.a) to \(Self.b)") && out.contains("these stay held: ~/bin"),
                "\(out)")
        #expect(out.contains("stand-in install of \(Self.b)") && out.contains("installed \(Self.b) in"), "\(out)")
        #expect(out.contains("accepted with this code: ~/.vibeswitcher/v2/builds"), "\(out)\n\(node.said)")
        #expect(out.contains("handed over") && out.contains("the new build's server answers"), "\(out)")
        // The code asked once.
        #expect(out.components(separatedBy: "and Enter").count == 2, "\(out)")
        let hello = try WireClient(node).hello
        #expect(hello.server.pid != server && hello.server.commit == Self.b, "\(hello.server)")
        let now = try await held(node)
        #expect(!now.contains("~/.vibeswitcher/v2/builds") && now.contains("~/bin"), "\(now)")
    }

    @Test func aPlantBesideTheInstallKeepsTheBuildsFolderHeldAndSwitchesNothing() async throws {
        let rig = try await rig(extra: "echo planted > \"$prefix/\(Self.a)/planted\"")
        let node = rig.node
        defer { node.stop() }
        let updated = try await node.runOnTerminal(["update", Self.b, "--test-installer", rig.installer.path])
        let out = updated.output + updated.errors
        #expect(updated.status != 0, "\(out)\n\(node.said)")
        #expect(out.contains("the builds folder changed beyond this install (\(Self.a) changed)"), "\(out)")
        #expect(!out.contains("accepted with this code"), "\(out)")
        #expect(try WireClient(node).hello.server.commit != Self.b)
        #expect(try await held(node).contains("~/.vibeswitcher/v2/builds"))
    }

    @Test func aFailedInstallSwitchesNothingAndLeavesNoFolder() async throws {
        let rig = try await rig(fails: true)
        let node = rig.node
        defer { node.stop() }
        let updated = try await node.runOnTerminal(["update", Self.b, "--test-installer", rig.installer.path])
        let out = updated.output + updated.errors
        #expect(updated.status != 0 && out.contains("the install of \(Self.b) failed (exit 3") && out.contains("nothing was switched")
                && out.contains("the folder it made is removed"), "\(out)")
        #expect(!FileManager.default.fileExists(atPath: rig.installs.appendingPathComponent(Self.b).path))
    }

    /// The script `update` runs (the review of 16f0ce69, U1) is the install-node of the build its command line runs
    /// from, only while `current` names that build and the builds folder is the accepted one: a repointed `current`,
    /// an edited script, any held change under the builds folder: refused before the code is asked and before
    /// anything runs.
    @Test func aRepointedCurrentAnEditedScriptOrAHeldBuildsFolderRunsNothing() async throws {
        let rig = try await rig()
        let node = rig.node
        defer { node.stop() }
        _ = try await held(node)
        func refused(_ says: String) async throws {
            let updated = try await node.runOnTerminal(["update", Self.b, "--test-build", rig.buildA.path])
            let out = updated.output + updated.errors
            #expect(updated.status != 0 && out.contains(says) && !out.contains("and Enter"), "\(out)\n\(node.said)")
            #expect(!rig.ran, "the script ran")
        }
        // `current` repointed to another installed build.
        let c = String(repeating: "c", count: 40)
        try ScratchBuilds.install(commit: c, into: rig.installs)
        let current = rig.installs.appendingPathComponent("current")
        try FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: c)
        try await refused("current names \(rig.installs.appendingPathComponent(c).path), not the build this command line runs from")
        try FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: Self.a)
        // Back as it was named, the folder still isn't the accepted one (the link's and C's times): held.
        try await refused("the builds folder has a change you haven't accepted")
        // The script edited (in place, its bytes): the same, and it never runs.
        let script = rig.buildA.appendingPathComponent("Resources/install-node.sh")
        let handle = try FileHandle(forWritingTo: script)
        handle.seekToEndOfFile()
        handle.write(Data("\necho planted\n".utf8))
        try handle.close()
        try await refused("the builds folder has a change you haven't accepted")
    }
}
