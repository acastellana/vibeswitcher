import Combine
import CryptoKit
import Foundation
import SwiftUI
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// Programs in window sessions that say what they're doing over OSC 7501, end to end: a scratch host (its own socket,
/// lock and key; never the user's) runs fake programs, the app's own client reads its sessions, and the session store
/// and the window's list, wired as the app delegate wires them, show the statuses in the sidebar and the header.
@MainActor
struct ProgramStatusShownTests {
    /// Reads a line, reports the status it names, until `q`. Base64: "Indexing", "Bash".
    static let fakeProgram = #"stty -echo; while read cmd; do case "$cmd" in "#
        + #"w) printf '\033]7501;state=working:app=fake:title=SW5kZXhpbmc\007';; "#
        + #"b) printf '\033]7501;state=blocked:app=fake:kind=permission:msg=QmFzaA\033\\';; "#
        + #"d) printf '\033]7501;state=done:app=fake\007';; "#
        + #"q) exit 0;; esac; done"#

    /// The scanner's view of the Mac: the host, and an agent on the ttys a test says run one (no real process scan).
    final class Agents: @unchecked Sendable {
        private let lock = NSLock()
        private var ttys: [String: Int32] = [:]
        let started = Date().addingTimeInterval(-60)

        func add(tty: String, pid: Int32) { lock.lock(); ttys[tty] = pid; lock.unlock() }

        func table() -> [Int32: ProcInfo] {
            lock.lock(); defer { lock.unlock() }
            var procs = [ProcInfo(pid: 1960, ppid: 1, tty: nil, comm: "vibeswitcher-hos", startTime: started, agent: nil)]
            for (tty, pid) in ttys {
                procs.append(ProcInfo(pid: pid, ppid: 1960, tty: tty, comm: "claude", startTime: started, agent: .claude))
            }
            return Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        }
    }

    @Test func statusesShowInTheSidebarAndHeaderAndLeaveWithTheSession() async throws {
        AppStatus.enabled = false
        let launcher = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
        #expect(FileManager.default.isExecutableFile(atPath: launcher))
        let socket = "/tmp/vsh-ps-\(UUID().uuidString.prefix(8)).sock"
        let key = SymmetricKey(size: .bits256)
        var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: launcher,
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                       hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
        config.idleExit = nil
        config.appKey = key
        config.appExecutable = HostServer.executable(of: getpid())
        let server = HostServer(config: config)
        try server.start()
        let stateDir = scratchRoot.appendingPathComponent("program-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer {
            server.stop(terminateSessions: true)
            unlink(socket + ".lock")
            try? FileManager.default.removeItem(at: stateDir)
        }

        let host = HostClient(socketPath: socket, appKey: { key })
        let agents = Agents()
        let store = SessionStore(scanner: SessionScanner(processes: { agents.table() }, stateDir: { stateDir },
                                                         cwd: { _ in "/tmp/program-status" }, arguments: { _ in [] }))
        let model = WindowModel()
        var wiring: Set<AnyCancellable> = []
        defer { wiring.removeAll() }
        host.$sessions.receive(on: DispatchQueue.main).sink { store.updateHosted($0) }.store(in: &wiring)
        store.$sessions.combineLatest(host.$sessions, host.$state, store.$tableRead).receive(on: DispatchQueue.main)
            .sink { sessions, hosted, state, table in
                model.update(sessions: sessions, hosted: hosted, table: table, hostAnswered: state != .connecting)
            }
            .store(in: &wiring)
        host.connectIfRunning()
        #expect(await until { host.state == .connected })

        func spawn(_ label: String) async throws -> HostSession {
            var result: Result<HostSession, HostClientError>?
            host.spawn(SpawnRequest(cwd: "/tmp", command: Self.fakeProgram, env: [:], cols: 80, rows: 24, keepShell: false,
                                    label: label, agent: nil)) { result = $0 }
            #expect(await until { result != nil })
            return try #require(result).get()
        }
        // A program alone in its session; one the scan takes for an agent without hooks; one with hooks.
        let plain = try await spawn("Plain")
        let agent = try await spawn("Agent")
        let hooked = try await spawn("Hooked")
        agents.add(tty: agent.tty, pid: 1970)
        agents.add(tty: hooked.tty, pid: 1971)
        var hook = HookState(agent: .claude, tty: hooked.tty, lastEvent: "UserPromptSubmit", lastEventAt: Date().timeIntervalSince1970)
        hook.agentPid = 1971
        try hook.save(to: stateDir.appendingPathComponent("\(hooked.tty).json"))
        store.refresh()

        func row(_ session: HostSession) -> WindowRow? {
            model.allRows.first { $0.hostID == session.id || $0.session?.tty == session.tty }
        }
        #expect(await until { row(agent)?.session != nil && row(hooked)?.session != nil && row(plain) != nil })
        #expect(row(plain)?.state(now: Date()).text == "shell")

        /// Types `command` into the session, then waits until `shown` holds; how long that took.
        func say(_ command: String, to session: HostSession, until shown: @escaping () -> Bool) async -> TimeInterval? {
            let sent = Date()
            host.send(session.id, bytes: Data("\(command)\n".utf8), reply: false)
            return await until(shown) ? Date().timeIntervalSince(sent) : nil
        }
        func header(_ session: HostSession) -> String? {
            row(session).map { $0.pillLabel($0.state(now: Date())) }
        }
        var took: [String: TimeInterval] = [:]

        // The sidebar's row and the header's pill, for a session the scan finds no agent in.
        took["plain working"] = await say("w", to: plain) { row(plain)?.state(now: Date()).text == "Indexing" }
        #expect(row(plain)?.state(now: Date()).group == .working)
        #expect(header(plain) == "Working")
        #expect(row(plain)?.statusColor == SessionStatus.working.color)
        took["plain blocked"] = await say("b", to: plain) { row(plain)?.state(now: Date()).group == .needsYou }
        #expect(header(plain) == "Needs you")
        #expect(row(plain)?.statusColor == SessionStatus.needsInput.color)
        #expect(row(plain)?.hosted?.liveProgramStatus.flatMap(StatusRules.detail(for:)) == "Asks permission: Bash")
        took["plain done"] = await say("d", to: plain) { row(plain)?.state(now: Date()).group == .ready }
        #expect(header(plain) == "Done")

        // An agent without hooks: the store's status, and so its row's and the header's, are the program's.
        took["agent blocked"] = await say("b", to: agent) { row(agent)?.session?.status == .needsInput }
        #expect(row(agent)?.session?.detail == "Asks permission: Bash")
        #expect(header(agent) == "Needs you")
        took["agent working"] = await say("w", to: agent) { row(agent)?.session?.status == .working }
        #expect(header(agent) == "Working")

        // Hooks win: a session with hooks reads as its hook says, whatever its program reports.
        #expect(await until { row(hooked)?.session?.status == .working })
        _ = await say("b", to: hooked) { host.sessions.first { $0.id == hooked.id }?.programStatus?.state == .blocked }
        store.refresh()
        let refreshed = store.scansApplied
        #expect(await until { store.scansApplied > refreshed })
        #expect(row(hooked)?.session?.status == .working)
        #expect(header(hooked) == "Working")

        // Ended: no program status, in the row or the header.
        took["plain ended"] = await say("q", to: plain) { row(plain)?.hosted?.isLive == false }
        #expect(row(plain)?.hosted?.liveProgramStatus == nil)
        #expect(row(plain)?.state(now: Date()).text == "finished")
        #expect(header(plain) == "Ended")

        // Each change reached the window as the host sent it (no scan timer runs here: the store isn't started).
        #expect(took.count == 6 && took.values.allSatisfy { $0 < hangGuard })
        print("program status shown after: " + took.sorted { $0.key < $1.key }.map { "\($0.key) \(Int($0.value * 1000)) ms" }.joined(separator: ", "))
    }
}

private final class Anchor {}
