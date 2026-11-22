import Foundation
import Testing
import VibeCore
import VibeHost
@testable import VibeNode

/// The host-probe nightly (`.github/workflows/v2-host-probe.yml`, `scripts/ci/host-probe.sh`): `config held` of the
/// home folder on a fresh scratch node with a held first look, `VIBESWITCHER_HOST_PROBE_ROUNDS` times, the host kept
/// dumpable and its crash traced on its stderr (`hostBacktrace`), its image base in its log (`HostHardening
/// .imageBaseLine`). Twice on 2026-11-22 that request killed the host (SIGILL) right after a worktree switched trees,
/// never since (docs/process/v2-flaky-tests.md): a host that dies fails the round with its wait status, and its stderr
/// and log go to `VIBESWITCHER_HOST_PROBE_OUT` for the script to symbolize. Off (no rounds) in every other run.
/// The nightly's settings: how many rounds (none: the suite is off), and where a dead round's record goes.
enum HostProbe {
    static let rounds = Int(ProcessInfo.processInfo.environment["VIBESWITCHER_HOST_PROBE_ROUNDS"] ?? "") ?? 0
    static let out = ProcessInfo.processInfo.environment["VIBESWITCHER_HOST_PROBE_OUT"]
}

@Suite(NodeTraits.linuxOnly, .enabled(if: HostProbe.rounds > 0, "the host-probe nightly's: VIBESWITCHER_HOST_PROBE_ROUNDS"),
       .serialized, .timeLimit(.minutes(60)))
struct HostProbeTests {
    private let scratch = Scratch()

    @Test func configHeldNeverKillsTheHost() async throws {
        var died = 0
        for round in 0..<HostProbe.rounds {
            let node = try await ScratchNode(scratch, holdFirstLook: true, hostArguments: [HostHardening.staysDumpableFlag], hostBacktrace: true)
            let held = try await node.run(["config", "held", node.home.path])
            // A host that crashed on the request is gone by the time the command line was refused; give it a moment.
            if held.status != 0 { _ = await exited(node.process, within: 5) }
            if let status = node.process.waitStatus {
                died += 1
                let log = (try? String(contentsOf: node.root.appendingPathComponent("host.log"), encoding: .utf8)) ?? ""
                let record = "round \(round): the host died, wait status \(status) (signal \(status & 0x7f))\n--- its stderr\n\(node.said)\n--- its log\n\(log)\n"
                if let out = HostProbe.out { try? record.write(toFile: out + "/round-\(round).log", atomically: true, encoding: .utf8) }
                Issue.record("\(record.prefix(8000))")
            }
            node.stop()
        }
        print("host probe: \(HostProbe.rounds) rounds, \(died) host deaths")
    }
}
