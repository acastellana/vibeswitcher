import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// `vibeswitcher doctor` (`NodeDoctor`): each thing the node needs, looked at in fixed places (a scratch home here,
/// nothing run), each missing one with the command for the user to run; advised notes don't count as missing.
struct NodeDoctorTests {
    private let scratch = Scratch()

    private func probes(home: String, executable: Set<String> = [], exists: Set<String> = [], claude: String? = nil, git: String? = nil,
                        interop: Bool = false, mode: NodeFolders.Mode = .systemd, running: Bool = false, hooks: Bool = false) -> NodeDoctor.Probes {
        NodeDoctor.Probes(home: home, claude: { claude.map { ($0, nil) } ?? (nil, "claude: ~/.local/bin/claude leads nowhere") },
                          git: { git }, executable: { executable.contains($0) }, exists: { exists.contains($0) },
                          read: { $0.hasSuffix("WSLInterop") && interop ? "enabled\ninterpreter /init\n" : nil },
                          systemd: { mode }, nodeRunning: { running }, hooksInstalled: { hooks })
    }

    private func check(_ checks: [NodeDoctor.Check], _ name: String) -> NodeDoctor.Check? { checks.first { $0.name == name } }

    @Test func aBareMachineNamesEachCommand() throws {
        let home = scratch.url("home").path
        let checks = NodeDoctor.checks(probes(home: home, interop: true, mode: .noSystemd))
        for name in ["claude", "git", "swift", "node", "a build installed", "the node", "hooks"] {
            #expect(check(checks, name)?.ok == false, "\(name)")
            #expect(check(checks, name)?.fix?.isEmpty == false, "\(name)")
        }
        #expect(check(checks, "claude")?.fix == ToolInstall.claudeCodeCommand)
        #expect(check(checks, "git")?.fix == "sudo apt-get install -y git")
        #expect(check(checks, "the node")?.fix == "vibeswitcher start")
        #expect(check(checks, "hooks")?.fix == "vibeswitcher hooks install")
        #expect(check(checks, "WSL interop")?.ok == false && check(checks, "systemd")?.fix?.contains("systemd=true") == true)
        let lines = NodeDoctor.lines(checks)
        #expect(lines.last?.contains("7 needed things are missing") == true, "\(lines)")
        #expect(lines.contains("       run: vibeswitcher start"))
    }

    @Test func aReadyMachineIsOkWithAdvisedNotesOnly() throws {
        let home = scratch.url("ready").path
        let node = home + "/.nvm/versions/node/v22.16.0/bin"
        try FileManager.default.createDirectory(atPath: node, withIntermediateDirectories: true)
        let swift = home + "/.local/share/swiftly/bin/swift"
        let checks = NodeDoctor.checks(probes(home: home, executable: [swift, node + "/node", "/usr/bin/gh"],
                                              exists: [home + "/.vibeswitcher/v2/builds/current", home + "/.config/gh/hosts.yml"],
                                              claude: "/c/claude", git: "/usr/bin/git", interop: true, running: true, hooks: true))
        #expect(checks.filter { $0.level != .advised }.allSatisfy { $0.ok }, "\(checks.filter { !$0.ok })")
        #expect(check(checks, "node")?.says.contains("v22.16.0") == true)
        #expect(check(checks, "WSL interop")?.ok == false && check(checks, "gh")?.ok == true && check(checks, "Tailscale")?.ok == false)
        #expect(NodeDoctor.lines(checks).last?.hasPrefix("Nothing needed is missing") == true)
    }
}
