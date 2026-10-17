import AppKit
import SwiftUI
import VibeCore

extension LeadTask.Status {
    var color: Color {
        switch self {
        case .planned: return .secondary
        case .running: return .orange
        case .review: return .blue
        case .done: return .green
        case .failed: return .red
        case .blocked: return .purple
        }
    }

    var label: String {
        switch self {
        case .planned: return "Planned"
        case .running: return "Working"
        case .review: return "In review"
        case .done: return "Done"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        }
    }
}

/// Over the lead's chat: the board at a glance, one chip per task (click: open its worker).
struct TeamStrip: View {
    let board: LeadBoard
    let open: (LeadTask) -> Void

    var body: some View {
        let order: [LeadTask.Status] = [.running, .review, .blocked, .failed, .planned, .done]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.3.fill").foregroundStyle(Color.accentColor)
                Text("Team").font(.system(size: 12, weight: .semibold))
                ForEach(order, id: \.self) { status in
                    let count = board.tasks.filter { $0.status == status }.count
                    if count > 0 {
                        Label("\(count) \(status.label.lowercased())", systemImage: "circle.fill")
                            .labelStyle(StatusDotLabelStyle(color: status.color))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                if board.tasks.isEmpty { Text("No tasks yet").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                Spacer()
                let open = board.questions.filter { $0.answer == nil }.count
                if open > 0 {
                    Label("\(open) question\(open == 1 ? "" : "s") for you", systemImage: "questionmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.orange)
                }
            }
            if !board.tasks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(board.tasks.sorted { order.firstIndex(of: $0.status)! < order.firstIndex(of: $1.status)! }) { task in
                            Button { open(task) } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(task.status.color).frame(width: 7, height: 7)
                                    Text(task.title).font(.system(size: 11.5)).lineLimit(1)
                                    if let evidence = task.evidence {
                                        Image(systemName: evidence.passes ? "checkmark.seal.fill" : "xmark.seal.fill")
                                            .font(.system(size: 10)).foregroundStyle(evidence.passes ? .green : .red)
                                    }
                                }
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(task.status.color.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help("\(task.status.label): \(task.contract.goal)")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct StatusDotLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(color)
            configuration.title
        }
    }
}

/// The lead's open questions, answered from the chat (the answer goes to the lead without stopping it).
struct LeadQuestionCards: View {
    let questions: [LeadQuestion]
    let answer: (LeadQuestion, String) -> Void

    var body: some View {
        ForEach(questions) { question in LeadQuestionCard(question: question, answer: answer) }
    }
}

private struct LeadQuestionCard: View {
    let question: LeadQuestion
    let answer: (LeadQuestion, String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The lead asks", systemImage: "questionmark.bubble.fill").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(question.text).font(.system(size: 14, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        Button { answer(question, option) } label: {
                            Text(option).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.08)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField(question.options.isEmpty ? "Your answer" : "Or answer in your own words", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Answer", action: send).buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("It keeps working while you think; the answer reaches it at its next step.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.45)))
    }

    private func send() {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        answer(question, reply)
        text = ""
    }
}

/// The inspector's Team tab for a lead: each task as a pipeline lane (see `LeadLanes`), questions, results, the files.
struct LeadTeamView: View {
    let root: String
    let board: LeadBoard
    /// What the team's window sessions are doing, by host id.
    let seen: [String: LaneSeen]
    /// Opens a team member's session (its host id) in the window.
    let open: (String) -> Void
    /// Rows shown opened, and the finished tasks unfolded, to begin with.
    var openRows: Set<String> = []
    var showFinished = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Tasks") {
                    if board.tasks.isEmpty {
                        Text("Nothing on the board yet. Tell the lead what to build.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    LaneList(board: board, seen: seen, open: open, openRows: openRows, showFinished: showFinished)
                }
                let answered = board.questions.filter { $0.answer != nil }
                if !answered.isEmpty {
                    section("Answered") {
                        ForEach(answered.suffix(8).reversed()) { question in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(question.text).font(.system(size: 12))
                                Text("→ \(question.answer ?? "")").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                if !board.updates.isEmpty {
                    section("Results") {
                        ForEach(board.updates.reversed()) { update in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(update.title).font(.system(size: 12.5, weight: .semibold))
                                    Spacer()
                                    Text(Date(timeIntervalSince1970: update.at).formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                }
                                MarkdownView(text: update.body, fontSize: 12)
                                ForEach(update.images, id: \.self) { path in
                                    if let image = NSImage(contentsOfFile: path) {
                                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 160)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                                    }
                                }
                            }
                            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                        }
                    }
                }
                section("Files") {
                    HStack(spacing: 8) {
                        ForEach(["workflow.md", "decisions.md", "progress.md"], id: \.self) { name in
                            Button(name) {
                                let path = (root as NSString).appendingPathComponent(".vibeswitcher/\(name)")
                                if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } else { NSSound.beep() }
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("Kept in \(root.replacingOccurrences(of: NSHomeDirectory(), with: "~"))/.vibeswitcher (not committed).")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(14)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
