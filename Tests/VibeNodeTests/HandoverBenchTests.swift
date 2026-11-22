import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The handover's cost against scrollback (the architecture review's row 19), a bench: `VIBESWITCHER_HANDOVER_BENCH=N`
/// sessions, each printing 8.5 MB of its own terminal text (a full 8 MiB ring), then a handover to the same build;
/// says how long it took, the first reply after it, the sealed state's size (in the host's log) and the host's memory
/// before and after. `VIBESWITCHER_HANDOVER_BENCH_RELEASE=1` runs the release products (`swift build -c release`
/// of the five), as installed; the debug ones are some ten times slower at it.
@Suite(.serialized, .enabled(if: HandoverBench.sessions > 0, "a bench: VIBESWITCHER_HANDOVER_BENCH=<sessions>"))
struct HandoverBenchTests {
    private let scratch = Scratch()

    static func status(_ pid: pid_t, _ key: String) -> Int {
        let text = (try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8)) ?? ""
        let line = text.split(separator: "\n").first { $0.hasPrefix(key + ":") } ?? ""
        return Int(line.split(separator: " ").dropFirst().first ?? "0") ?? 0
    }

    /// A build folder of the release products, as `ScratchNode.install` makes the debug one.
    func releaseBuild() throws -> URL {
        let release = ServerLintTests.repo.appendingPathComponent(".build/release")
        let folder = scratch.url("release-build")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        var hashes: [String: String] = [:]
        for name in ScratchNode.products {
            let path = release.appendingPathComponent(name).path
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("bin/" + name).path, withDestinationPath: path)
            hashes[name] = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
        }
        let info = BuildInfo(commit: ScratchNode.commit, binaries: hashes, swift: "bench", resolved: String(repeating: "0", count: 64))
        try info.encoded.write(to: folder.appendingPathComponent(BuildInfo.fileName))
        return folder
    }

    @Test func aHandoverAgainstFullScrollback() async throws {
        let node = try await ScratchNode(scratch, build: HandoverBench.release ? try releaseBuild() : nil)
        defer { node.stop() }
        var body = Data()
        var index = 0
        while body.count < 8_500_000 {
            body.append(Data("\u{1B}[32m\(String(format: "%07d", index))\u{1B}[0m the quick brown fox jumps over the lazy dog; build step ok, 42 tests passed\n".utf8))
            index += 1
        }
        var dones: [String] = []
        for number in 0..<HandoverBench.sessions {
            var own = Data()
            var offset = 0
            while offset < body.count {
                own.append(Data("session \(number) part \(offset)\n".utf8))
                own.append(body[offset..<min(body.count, offset + 65_536)])
                offset += 65_536
            }
            let file = node.root.appendingPathComponent("text-\(number).txt")
            try own.write(to: file)
            let done = node.root.appendingPathComponent("done-\(number)").path
            dones.append(done)
            _ = try await node.spawn("cat \(file.path); touch \(done); exec sleep 600")
        }
        try #require(await eventually(timeout: 600) { dones.allSatisfy { FileManager.default.fileExists(atPath: $0) } })
        let host = node.hostPID
        let before = (Self.status(host, "VmRSS"), Self.status(host, "VmHWM"))
        let started = MacTime.real.awake()
        try await node.handOver()
        let took = MacTime.real.awake() - started
        let after = (Self.status(host, "VmRSS"), Self.status(host, "VmHWM"))
        let asked = MacTime.real.awake()
        _ = try node.sessions()
        let first = MacTime.real.awake() - asked
        let log = (try? String(contentsOf: node.root.appendingPathComponent("host.log"), encoding: .utf8)) ?? ""
        let state = log.split(separator: "\n").last { $0.contains("handover memory written") }.map(String.init) ?? "?"
        print("handover bench (\(HandoverBench.release ? "release" : "debug")): \(HandoverBench.sessions) sessions × 8.5 MB: handover \(String(format: "%.2f", took)) s, first reply \(String(format: "%.3f", first)) s; old image RSS \(before.0 / 1024) MB, new image RSS \(after.0 / 1024) MB (peak \(after.1 / 1024) MB); \(state)")
    }
}

enum HandoverBench {
    static let sessions = Int(ProcessInfo.processInfo.environment["VIBESWITCHER_HANDOVER_BENCH"] ?? "") ?? 0
    static let release = ProcessInfo.processInfo.environment["VIBESWITCHER_HANDOVER_BENCH_RELEASE"] == "1"
}
