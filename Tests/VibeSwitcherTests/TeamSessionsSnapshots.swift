import AppKit
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// A lead's workers and verifiers apart from your own sessions (UI audit 2026-10-22 #1): 14 sessions, 10 of them two
/// projects' teams, leave the menu bar in dots (your 4), the pill at 4 dots, and the popover lists your 4 numbered
/// first, then each team under its header. The checks always run; with `TEAM_SNAPSHOT_DIR=/some/folder` it also draws
/// the menu bar, the pill and the popover (team-sessions-light.png, team-sessions-dark.png).
@MainActor
struct TeamSessionsSnapshots {
    static let folder = ProcessInfo.processInfo.environment["TEAM_SNAPSHOT_DIR"]
    private let stateDir = scratchRoot.appendingPathComponent("team-snapshots-\(UUID().uuidString)")

    /// tty, window label (nil: in Terminal), cwd, the last hook event.
    static let sessions: [(String, String?, String, String)] = {
        let acme = "/r/acme/.vibeswitcher/worktrees", projectC = "/r/project-c/.vibeswitcher/worktrees"
        return [
            ("ttys900", "Lead · acme", "/r/acme", "PreToolUse"),
            ("ttys901", nil, "/r/notes", "PermissionRequest"),
            ("ttys902", "w", "/r/site", "Stop"),
            ("ttys903", nil, "/r/billing", "SessionStart"),
            ("ttys910", "Worker: Fix login", "\(acme)/fix-login", "PreToolUse"),
            ("ttys911", "Verifier: Fix login", "\(acme)/fix-login", "PreToolUse"),
            ("ttys912", "Worker: Docs", "\(acme)/docs", "Stop"),
            ("ttys913", "Worker: Export", "\(acme)/export", "PermissionRequest"),
            ("ttys914", "Worker: Search", "\(acme)/search", "PreToolUse"),
            ("ttys915", "Verifier: Search", "\(acme)/search", "PreToolUse"),
            ("ttys920", "Worker: Plan", "\(projectC)/plan", "PreToolUse"),
            ("ttys921", "Worker: Fees", "\(projectC)/fees", "Stop"),
            ("ttys922", "Verifier: Fees", "\(projectC)/fees", "PreToolUse"),
            ("ttys923", "Worker: Oracle", "\(projectC)/oracle", "SessionStart"),
        ]
    }()

    /// A store that scanned these sessions: made-up processes and hook files, and the window sessions' labels.
    private func store() async throws -> SessionStore {
        AppStatus.enabled = false
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let now = Date().addingTimeInterval(10)
        let started = now.addingTimeInterval(-3600)
        var procs = [Int32(890): ProcInfo(pid: 890, ppid: 1, tty: nil, comm: "vibeswitcher-hos", startTime: started, agent: nil)]
        var cwds: [Int32: String] = [:]
        for (tty, _, cwd, event) in Self.sessions {
            let pid = Int32(tty.dropFirst(4))!
            procs[pid] = ProcInfo(pid: pid, ppid: 890, tty: tty, comm: "claude", startTime: started, agent: .claude)
            cwds[pid] = cwd
            var state = HookState(agent: .claude, tty: tty, lastEvent: event, lastEventAt: now.timeIntervalSince1970)
            state.agentPid = pid
            if event == "PreToolUse" { state.toolName = "Bash" }
            try state.save(to: stateDir.appendingPathComponent("\(tty).json"))
        }
        let table = procs, dir = stateDir
        let store = SessionStore(scanner: SessionScanner(processes: { table }, stateDir: { dir }, cwd: { cwds[$0] },
                                                         arguments: { _ in [] }))
        store.clock = { now }
        store.updateHosted(Self.sessions.compactMap { tty, label, cwd, _ in
            label.map { HostSession(id: UUID(), tty: tty, childPID: Int32(tty.dropFirst(4))!, cwd: cwd, command: "claude", label: $0,
                                    agent: "claude", title: "", startedAt: started, cols: 80, rows: 24, exit: nil) }
        })
        let before = store.scansApplied
        store.refresh()
        #expect(await until { store.scansApplied > before && store.sessions.count == Self.sessions.count })
        return store
    }

    @Test func teamsAreDrawnApartFromYourSessions() async throws {
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let store = try await store()
        let split = store.split
        #expect(store.sessions.count == 14)
        #expect(Set(split.own.map(\.tty)) == ["ttys900", "ttys901", "ttys902", "ttys903"])
        #expect(split.teams.map(\.project).sorted() == ["acme", "project-c"])
        #expect(split.teamCount == 10)
        // Dots, not counts: the menu bar draws your 4.
        #expect(split.own.count <= MenuBarDots.maxDots)
        #expect(StatusIcon.image(for: split.own).size.width == MenuBarDots.width(count: 4))
        // The popover's counts are yours: one needs you (a worker asking too is under its team).
        #expect(split.own.filter { $0.status == .needsInput }.count == 1)
        #expect(store.sessions.filter { $0.status == .needsInput }.count == 2)

        guard let folder = Self.folder else { return }
        for scheme in [ColorScheme.light, .dark] {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
            let bar = StatusSnapshots.rasterize(StatusIcon.image(for: split.own), appearance)
            let view = TeamPicture(store: store, own: split.own, bar: bar).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            var image: NSImage?
            appearance.performAsCurrentDrawingAppearance { image = renderer.nsImage }
            let tiff = try #require(image?.tiffRepresentation)
            let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("team-sessions-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}

private struct TeamPicture: View {
    let store: SessionStore
    let own: [Session]
    let bar: NSImage
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            caption("Menu bar and pill: your 4 sessions of 14")
            HStack(spacing: 24) {
                Image(nsImage: bar).resizable().interpolation(.high)
                    .frame(width: bar.size.width * 2, height: bar.size.height * 2)
                FloatingDots(sessions: own, onOpen: { _ in }, onShowList: {})
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 48)
            .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.93))
            caption("Popover list")
            PopoverView(store: store, state: PopoverState(), preferences: Preferences(), onOpen: { _ in },
                        onInstallHooks: {}, onQuit: {})
                .list(store.split)
                .frame(width: 400)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
        .background(scheme == .dark ? Color(white: 0.12) : Color.white)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}
