import SwiftUI
import VibeCore

/// The project's reminder to run `/doctor prompt-audit` (`PromptAuditDesk`), pinned in its lead's chat while due.
struct PromptAuditPrompt: View {
    @ObservedObject var desk: PromptAuditDesk
    let root: String
    /// The composer's send into the selected session (the lead's): Run now's message, as yours.
    let send: (String) -> Bool

    var body: some View {
        if let due = desk.due[(root as NSString).standardizingPath] {
            let root = (root as NSString).standardizingPath
            PromptAuditCard(reason: PromptAudit.reason(due, now: desk.clock()), lastRun: desk.book.projects[root]?.lastRun.map(Date.init(timeIntervalSince1970:)),
                            refused: desk.refused[root],
                            run: { desk.runNow(root, send: send) }, snooze: { desk.snooze(root) }, turnOff: { desk.turnOff(root) })
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// The reminder's card, as a shell request's (`ShellCard`): what it is and why now, the exact command, and Run now,
/// Remind me in a week, Not for this project.
struct PromptAuditCard: View {
    let reason: String
    var lastRun: Date? = nil
    var refused: String? = nil
    let run: () -> Void
    let snooze: () -> Void
    let turnOff: () -> Void
    @IncreasedContrast private var increased

    static let detail = "Claude Code's prompt audit checks this project's CLAUDE.md, AGENTS.md, .claude rules, skills, commands and "
        + "agents for prompting a newer model makes obsolete. Run now sends this command to the lead as your message."

    var body: some View {
        let tint = SessionStatus.needsInput.color
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "stethoscope").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Time for a prompt audit").font(.system(size: 13.5, weight: .bold))
                Spacer(minLength: 8)
                if let lastRun {
                    Text("Last run \(lastRun.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text(reason).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text(PromptAudit.command)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.secondary.opacity(0.35), lineWidth: 1))
                .textSelection(.enabled)
                .accessibilityLabel("Command: \(PromptAudit.command)")
            Text(Self.detail)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let refused {
                Label(refused, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Not for This Project", action: turnOff)
                    .help("No more prompt audit reminders for this project")
                Spacer()
                Button("Remind Me in a Week", action: snooze)
                Button(action: run) { Label("Run Now", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .help("Sends \(PromptAudit.command) to this project's lead, as your message")
                    // No key: Return in the composer must never send it.
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(increased ? 0 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(increased ? 1 : 0.4), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Prompt audit reminder")
    }
}
