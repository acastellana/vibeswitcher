import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Pictures of the sidebar's rows with the status first (`WindowRowView`): a Claude row per status and a paused one, a
/// Codex row, a shell's, an ended one, and a lead with its team open; beside each row's mark, the mark as it was
/// (agent first). Only with `SIDEBAR_SNAPSHOT_DIR=/some/folder swift test --filter SidebarMarkSnapshots`
/// (`SIDEBAR_SNAPSHOT_NAME` names the files, default "sidebar-marks").
@MainActor
struct SidebarMarkSnapshots {
    static let folder = ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIR"]
    static let name = ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_NAME"] ?? "sidebar-marks"

    @Test(.enabled(if: folder != nil)) func drawSidebarMarks() throws {
        let folder = try #require(Self.folder)
        let now = Date()
        var rows: [(row: WindowRow, role: LeadLaunch.Role?, nested: Bool)] = []
        for (index, status) in SessionStatus.all.enumerated() {
            rows.append((Self.agent("Claude \(status.label.lowercased())", agent: .claude, status: status, now: now, index: index), nil, false))
        }
        rows.append((Self.agent("Claude paused", agent: .claude, status: .working, paused: true, now: now, index: 10), nil, false))
        rows.append((Self.agent("Codex working", agent: .codex, status: .working, now: now, index: 11), nil, false))
        rows.append((Self.agent("Codex needs you", agent: .codex, status: .needsInput, now: now, index: 12), nil, false))
        let shell = HostSession(id: UUID(), tty: "ttys099", childPID: 1, cwd: LeadGroupSnapshots.root + "-shell", command: "zsh", label: "Shell", agent: nil,
                                title: "Shell", startedAt: now - 600, cols: 120, rows: 40, exit: nil)
        rows.append((WindowRow(content: .hosted(shell), project: "shell"), nil, false))
        rows.append((LeadGroupSnapshots.hosted("Ended", slug: "ended", started: now - 900, exit: HostSession.Exit(status: 0, at: now - 60)).row,
                     nil, false))
        rows.append((Self.agent("Lead · vibeswitcher", agent: .claude, status: .working, now: now, index: 13), .lead, false))
        rows.append((Self.agent("Worker: waits on its lead", agent: .claude, status: .needsInput, role: .worker, now: now, index: 14), .worker, true))
        rows.append((Self.agent("Verifier: reading the diff", agent: .claude, status: .working, role: .verifier, now: now, index: 15), .verifier, true))
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.row.id) { entry in
                    HStack(spacing: 12) {
                        // As it was: the agent's square, the status on its corner.
                        AgentMark(kind: entry.row.markKind, status: entry.row.statusColor, hollow: entry.row.statusIsHollow,
                                  size: entry.nested ? 18 : 22, mark: entry.row.statusMark)
                            .frame(width: 30)
                        WindowRowView(row: entry.row, showProject: false, role: entry.role, nested: entry.nested, teamOpen: entry.role == .lead)
                    }
                }
            }
            .padding(10)
            .frame(width: 400, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(Self.name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    static func agent(_ label: String, agent: Agent, status: SessionStatus, paused: Bool = false, role: LeadLaunch.Role? = nil,
                      now: Date, index: Int) -> WindowRow {
        var session = Session(tty: "ttys0\(index)", agent: agent, pid: Int32(100 + index), startedAt: now - 600, cwd: LeadGroupSnapshots.root + "-\(index)",
                              project: "project", task: nil, status: status, statusSince: now - 120, detail: nil, hasHooks: true,
                              inTerminalApp: false)
        session.customName = label
        session.hostID = UUID()
        session.teamRole = role
        if paused { session.pausedUntil = .distantFuture }
        return WindowRow(content: .agent(session), project: session.project)
    }
}
