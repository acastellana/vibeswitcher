import Combine
import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The session list is published only when something it shows changed: every publish redraws the menu bar icon, the
/// popover or sidebar, and recomputes the window's sections.
@MainActor
struct SessionStoreTests {
    private let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("store-tests-\(UUID().uuidString)")

    /// A working agent and one whose turn is over with a background shell still running (its age is in the detail).
    private func store(started: Date) throws -> SessionStore {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        var working = HookState(agent: .claude, tty: "ttys970", lastEvent: "PreToolUse", lastEventAt: now - 30)
        working.agentPid = 970
        working.toolName = "Bash"
        working.toolDetail = "npm test"
        working.toolStartedAt = now - 30
        try working.save(to: stateDir.appendingPathComponent("ttys970.json"))
        var finished = HookState(agent: .claude, tty: "ttys971", lastEvent: "Stop", lastEventAt: now - 600)
        finished.agentPid = 971
        try finished.save(to: stateDir.appendingPathComponent("ttys971.json"))
        let launched = started.addingTimeInterval(-3600)
        let procs = [
            ProcInfo(pid: 960, ppid: 1, tty: nil, comm: "vibeswitcher-hos", startTime: launched, agent: nil),
            ProcInfo(pid: 970, ppid: 960, tty: "ttys970", comm: "claude", startTime: launched, agent: .claude),
            ProcInfo(pid: 971, ppid: 960, tty: "ttys971", comm: "claude", startTime: launched, agent: .claude),
            ProcInfo(pid: 972, ppid: 971, tty: "ttys971", comm: "zsh", startTime: started.addingTimeInterval(-5), agent: nil),
        ]
        let table = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        let dir = stateDir
        return SessionStore(scanner: SessionScanner(
            processes: { table }, stateDir: { dir }, cwd: { _ in "/tmp/store-tests" },
            arguments: { $0.pid == 972 ? ["/bin/zsh", "-c", "source /h/.claude/shell-snapshots/a.sh && eval 'npm run dev' < /dev/null"] : [] }))
    }

    private func settle() async throws {
        // A scan runs on the store's queue and lands back on the main thread.
        try await Task.sleep(for: .milliseconds(400))
    }

    @Test func scansThatFindNothingNewDontRepublish() async throws {
        AppStatus.enabled = false
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let store = try store(started: Date())
        var publishes = 0
        let watching = store.$sessions.dropFirst().sink { _ in publishes += 1 }
        defer { watching.cancel() }
        store.refresh()
        try await settle()
        #expect(store.sessions.map(\.status) == [.working, .background] || store.sessions.map(\.status) == [.background, .working])
        #expect(store.sessions.first { $0.tty == "ttys971" }?.detail == "Waiting on npm run dev · <1m")
        #expect(publishes == 1)
        // Seconds later: the background shell is older, the working agent's tool has run longer; nothing shown changed.
        for _ in 0..<3 {
            store.refresh()
            try await settle()
        }
        #expect(publishes == 1)
    }
}
