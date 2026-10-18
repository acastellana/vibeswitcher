import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Programs that finish in milliseconds: their output and exit code must still arrive.
struct FastExitTests {
    @Test func quickCommandsKeepTheirOutputAndExitCode() throws {
        let probes = (0..<30).map { _ in SessionProbe() }
        var sessions: [HostedSession?] = Array(repeating: nil, count: probes.count)
        var failures: [Int: String] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: probes.count) { i in
            let request = SpawnRequest(cwd: "/tmp", command: "echo quick-\(i); exit 3", env: [:], cols: 80, rows: 24,
                                       keepShell: false, label: "T", agent: nil)
            do {
                let session = try probes[i].queue.sync {
                    let session = try HostedSession.spawn(request, shell: "/bin/sh", launcher: hostLauncher, baseEnvironment: ["PATH": "/usr/bin:/bin"],
                                                          ringCapacity: 1 << 16, queue: probes[i].queue)
                    probes[i].attach(session)
                    return session
                }
                lock.lock(); sessions[i] = session; lock.unlock()
            } catch {
                lock.lock(); failures[i] = "\(error)"; lock.unlock()
            }
        }
        #expect(failures.isEmpty, "spawn failed: \(failures)")
        _ = eventually { probes.indices.allSatisfy { failures[$0] != nil || probes[$0].lastChange?.exit != nil } }
        let noExit = probes.indices.filter { failures[$0] == nil && probes[$0].lastChange?.exit?.status != 3 }
        let noOutput = probes.indices.filter { failures[$0] == nil && !probes[$0].text.contains("quick-\($0)") }
        #expect(noExit.isEmpty, "no exit code: \(noExit.map { i in "\(i):\(String(describing: probes[i].lastChange?.exit?.status)) \(sessions[i].map { probes[i].diagnosis($0) } ?? "")" })")
        #expect(noOutput.isEmpty, "lost output: \(noOutput)")
        for i in probes.indices { probes[i].queue.sync { sessions[i]?.close() } }
    }

    /// Sessions started from many threads at once each start, and each get their own terminal: the program writes to
    /// the one its session reads, and no two sessions name the same one. (ttyname and ptsname share one buffer between
    /// threads, and ttyname can find no name for a terminal just made on a busy Mac: with them a session could fail to
    /// start, or its program open another session's terminal.)
    @Test func sessionsStartedAtOnceEachGetTheirOwnTerminal() throws {
        for _ in 0..<5 {
            let probes = (0..<40).map { _ in SessionProbe() }
            var sessions: [HostedSession?] = Array(repeating: nil, count: probes.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: probes.count) { i in
                // Running until the test ends it: every session holds its terminal while the names are compared.
                let request = SpawnRequest(cwd: "/tmp", command: "echo mine-\(i).; \(keepRunning)", env: [:], cols: 80, rows: 24,
                                           keepShell: false, label: "T", agent: nil)
                let session = try? probes[i].queue.sync {
                    let session = try HostedSession.spawn(request, shell: "/bin/sh", launcher: hostLauncher, baseEnvironment: ["PATH": "/usr/bin:/bin"],
                                                          ringCapacity: 1 << 16, queue: probes[i].queue)
                    probes[i].attach(session)
                    return session
                }
                lock.lock(); sessions[i] = session; lock.unlock()
            }
            let started = probes.indices.filter { sessions[$0] != nil }
            #expect(started.count == probes.count, "didn't start: \(probes.indices.filter { sessions[$0] == nil })")
            _ = eventually { started.allSatisfy { probes[$0].text.contains("mine-\($0).") } }
            let elsewhere = started.filter { i in
                probes[i].text.components(separatedBy: "mine-").dropFirst().contains { !$0.hasPrefix("\(i).") }
            }
            let lost = started.filter { !probes[$0].text.contains("mine-\($0).") }
            #expect(lost.isEmpty && elsewhere.isEmpty, "lost: \(lost), got another's: \(elsewhere.map { "\($0): \(probes[$0].text.debugDescription)" })")
            let ttys = started.map { i in probes[i].queue.sync { sessions[i]!.info.tty } }
            #expect(Set(ttys).count == ttys.count && !ttys.contains(""), "terminals: \(ttys)")
            for i in probes.indices { probes[i].queue.sync { sessions[i]?.terminate(); sessions[i]?.close() } }
        }
    }
}
