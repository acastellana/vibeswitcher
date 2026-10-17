import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Pictures of a lead's group in the window list (the lead row with its team open), drawn offscreen from
/// `WindowRowView` and `LeadTeams`. Only with `LEAD_SNAPSHOT_DIR=/some/folder swift test --filter LeadGroupSnapshots`
/// (`LEAD_SNAPSHOT_NAME` names the files, default "lead-group").
@MainActor
struct LeadGroupSnapshots {
    static let folder = ProcessInfo.processInfo.environment["LEAD_SNAPSHOT_DIR"]
    static let name = ProcessInfo.processInfo.environment["LEAD_SNAPSHOT_NAME"] ?? "lead-group"
    static let root = "/Users/you/dev/vibeswitcher"

    @Test(.enabled(if: folder != nil)) func drawLeadGroup() throws {
        let folder = try #require(Self.folder)
        let now = Date()
        let lead = Self.agent("Lead · vibeswitcher", cwd: Self.root, status: .working, activity: "Waiting for workers", since: now - 300, now: now)
        var rows = [lead.row]
        var labels = [lead.row.id: lead.label]
        func add(_ member: (row: WindowRow, label: String)) {
            rows.append(member.row)
            labels[member.row.id] = member.label
        }
        add(Self.agent("Worker: Ended sessions leave the list", slug: "ended-sessions-of", status: .working, activity: "Editing LeadTeams.swift", since: now - 240, now: now))
        add(Self.agent("Worker: Task progress at a glance", slug: "task-progress-at-a", status: .working, activity: "Running swift test", since: now - 90, now: now))
        add(Self.agent("Worker: Phone input on remote", slug: "phone-input", status: .done, activity: nil, since: now - 600, now: now))
        add(Self.agent("Verifier: Phone input on remote", slug: "phone-input", status: .working, activity: "Reading the diff", since: now - 120, now: now))
        add(Self.hosted("Worker: Phone and remote", slug: "phone-and-remote", started: now - 1_800, exit: nil))
        let finished = ["greet-sh", "menu-bar", "hang-watchdog", "start-page", "composer-undo", "trust-prompt", "palette"]
        for (index, slug) in finished.enumerated() {
            let at = now - Double(14 + index) * 3_600
            add(Self.hosted("Worker: \(slug)", slug: slug, started: at - 1_200, exit: HostSession.Exit(status: 129, at: at)))
            add(Self.hosted("Verifier: \(slug)", slug: slug, started: at - 600, exit: HostSession.Exit(status: 129, at: at)))
        }
        let arranged = LeadTeams.arrange([WindowSection(project: "vibeswitcher", rows: rows)], label: { labels[$0.id] }, expanded: [lead.row.id])
        let team = arranged.teams[lead.row.id] ?? []
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 2) {
                WindowRowView(row: lead.row, showProject: false, role: .lead, team: team, teamOpen: true)
                ForEach(team) { row in
                    WindowRowView(row: row, showProject: false, role: LeadTeams.role(label: labels[row.id]), nested: true)
                }
            }
            .padding(10)
            .frame(width: 320, alignment: .leading)
            .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.94))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(Self.name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    static func agent(_ label: String, cwd: String? = nil, slug: String? = nil, status: SessionStatus, activity: String?, since: Date,
                      now: Date) -> (row: WindowRow, label: String) {
        let path = cwd ?? Worktrees.path(root: root, slug: slug ?? "")
        var session = Session(tty: "ttys\(abs(label.hashValue) % 900)", agent: .claude, pid: 1, startedAt: since, cwd: path,
                              project: (path as NSString).lastPathComponent, task: nil, status: status, statusSince: since,
                              detail: nil, hasHooks: true, inTerminalApp: false)
        session.customName = label.components(separatedBy: ": ").last
        session.activity = activity
        session.hostID = UUID()
        return (WindowRow(content: .agent(session), project: session.project), label)
    }

    static func hosted(_ label: String, slug: String, started: Date, exit: HostSession.Exit?) -> (row: WindowRow, label: String) {
        let info = HostSession(id: UUID(), tty: "ttys0", childPID: 1, cwd: Worktrees.path(root: root, slug: slug), command: "claude",
                               label: label, agent: "claude", title: label, startedAt: started, cols: 120, rows: 40, exit: exit)
        return (WindowRow(content: .hosted(info), project: slug), label)
    }
}
