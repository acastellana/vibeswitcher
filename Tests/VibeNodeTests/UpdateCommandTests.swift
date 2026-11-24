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
        let script = """
            #!/bin/bash
            set -e
            commit=$1 prefix=$2
            echo "stand-in install of $commit"
            \(fails ? "/bin/cp -a -- '\(staged.path)/'\"$commit\" \"$prefix/$commit\"; echo 'the build failed' >&2; exit 3" : "")
            /bin/cp -a -- '\(staged.path)/'"$commit" "$prefix/$commit"
            printf '%s %s\\n' "$commit" "$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$prefix/installs"
            /bin/ln -s -- "$commit" "$prefix/current.new" && /bin/mv -T -- "$prefix/current.new" "$prefix/current"
            \(extra)
            """
        try writeClosedOnExec(script, to: installer)
        let node = try await ScratchNode(scratch, reusing: root, build: buildA, installRoot: installs)
        return Rig(node: node, installs: installs, installer: installer)
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

        let updated = try await node.runOnTerminal(["update", Self.b, "--test-installer", rig.installer.path])
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
}
