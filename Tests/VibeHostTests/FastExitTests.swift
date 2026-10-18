import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Programs that finish in milliseconds: their output and exit code must still arrive.
struct FastExitTests {
    @Test func quickCommandsKeepTheirOutputAndExitCode() throws {
        let probes = (0..<30).map { _ in SessionProbe() }
        var sessions: [HostedSession?] = Array(repeating: nil, count: probes.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: probes.count) { i in
            let request = SpawnRequest(cwd: "/tmp", command: "echo quick-\(i); exit 3", env: [:], cols: 80, rows: 24,
                                       keepShell: false, label: "T", agent: nil)
            let session = try? probes[i].queue.sync {
                let session = try HostedSession.spawn(request, shell: "/bin/sh", launcher: hostLauncher, baseEnvironment: ["PATH": "/usr/bin:/bin"],
                                                      ringCapacity: 1 << 16, queue: probes[i].queue)
                probes[i].attach(session)
                return session
            }
            lock.lock(); sessions[i] = session; lock.unlock()
        }
        _ = eventually { probes.allSatisfy { $0.lastChange?.exit != nil } }
        let noExit = probes.indices.filter { probes[$0].lastChange?.exit?.status != 3 }
        let noOutput = probes.indices.filter { !probes[$0].text.contains("quick-\($0)") }
        #expect(noExit.isEmpty, "no exit code: \(noExit.map { "\($0):\(String(describing: probes[$0].lastChange?.exit?.status)) out=\(probes[$0].text.debugDescription)" })")
        #expect(noOutput.isEmpty, "lost output: \(noOutput)")
        for i in probes.indices { probes[i].queue.sync { sessions[i]?.close() } }
    }
}
