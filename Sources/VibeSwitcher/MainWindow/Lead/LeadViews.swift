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
    /// Reports VibeSwitcher couldn't wake the lead for (see `LeadWake.shownAfter`), by the lead's terminal.
    @ObservedObject var waiting = ReportsWaiting.shared

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
                if let count = board.leadTTY.flatMap({ waiting.count[$0] }), let text = reportsWaiting(count) {
                    Label(text, systemImage: "tray.full.fill")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.orange)
                        .help("VibeSwitcher couldn't wake the lead for them: a draft in its box or a dialog on its screen. They go along with its next prompt.")
                }
                let open = board.openQuestions.count
                if open > 0 {
                    Label(questionCount(open), systemImage: "questionmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(board.blockingQuestions > 0 ? .red : .orange)
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

extension LeadQuestion.Priority {
    var label: String {
        switch self {
        case .blocking: return "Blocking"
        case .important: return "Important"
        case .whenever: return "Whenever"
        }
    }

    var color: Color {
        switch self {
        case .blocking: return .red
        case .important: return .orange
        case .whenever: return .secondary
        }
    }
}

/// "1 report waiting", "3 reports waiting"; nothing for none.
func reportsWaiting(_ count: Int) -> String? { count > 0 ? "\(count) report\(count == 1 ? "" : "s") waiting" : nil }

/// "1 question for you", "3 questions for you".
func questionCount(_ count: Int) -> String { "\(count) question\(count == 1 ? "" : "s") for you" }

/// The lead's questions as one stack (see `LeadBoard.questionStack`): the open ones, most important first, each
/// answered on its own (the answer goes to the lead without stopping it), then the ones it withdrew lately as dim
/// lines.
struct LeadQuestionStack: View {
    let questions: [LeadQuestion]
    /// What became of answers that didn't land as answers, by question id.
    var notices: [String: String] = [:]
    let answer: (LeadQuestion, String) -> Void
    /// Earlier wordings shown open to begin with (by question id).
    var historyOpen: Set<String> = []
    /// Drafts to begin with, by question id (pictures of a draft under a withdrawn question).
    var drafts: [String: String] = [:]

    var body: some View {
        if !questions.isEmpty {
            let open = questions.filter(\.isOpen)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.bubble.fill").foregroundStyle(open.contains { $0.rank == .blocking } ? Color.red : Color.accentColor)
                    Text(open.isEmpty ? "No questions waiting" : questionCount(open.count)).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if open.count > 1 {
                        Text("Answer in any order").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                ForEach(questions) { question in
                    LeadQuestionCard(question: question, notice: notices[question.id], answer: answer,
                                     showHistory: historyOpen.contains(question.id), text: drafts[question.id] ?? "")
                }
            }
        }
    }
}

private struct LeadQuestionCard: View {
    let question: LeadQuestion
    let notice: String?
    let answer: (LeadQuestion, String) -> Void
    @State var showHistory: Bool
    /// The answer being written: kept through a revision, and through a withdrawal (to send anyway or discard).
    @State var text: String

    var body: some View {
        if question.state == .withdrawn {
            withdrawn
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(question.rank.label.uppercased()).font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .foregroundStyle(question.rank == .whenever ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                    .background(Capsule().fill(question.rank == .whenever ? Color.secondary.opacity(0.15) : question.rank.color))
                TimelineView(.ticking(every: 30)) { context in
                    Text("asked \(Durations.compact(context.date.timeIntervalSince1970 - question.askedAt)) ago")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            Text(question.text).font(.system(size: 14, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let why = question.whyNow {
                Text(why).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let revision = question.lastRevision { history(revision) }
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
            if let notice { Text(notice).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Text("It keeps working while you think; the answer reaches it at its next step.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((question.rank == .blocking ? Color.red : Color.accentColor).opacity(0.45)))
    }

    /// "Updated 17:42: <note>", and the earlier wordings behind a disclosure.
    private func history(_ revision: LeadQuestion.Revision) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showHistory.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                    Text("Updated \(LeadBoard.clock(revision.at)): \(revision.note)").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showHistory ? 90 : 0))
                }
                .font(.system(size: 11)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showHistory ? "Hide the earlier wording" : "See the earlier wording")
            if showHistory, let revisions = question.revisions {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(revisions.enumerated().reversed()), id: \.offset) { index, earlier in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Version \(index + 1), until \(LeadBoard.clock(earlier.at))").font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(earlier.text).font(.system(size: 11.5)).foregroundStyle(.secondary).strikethrough(color: .secondary.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                            if !earlier.options.isEmpty {
                                Text(earlier.options.joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            }
                            if index > 0 {
                                Text("Changed: \(revisions[index - 1].note)").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    /// Collapsed to one dim line; a draft you were writing can still go to the lead, as a note.
    private var withdrawn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Withdrawn: \(question.withdrawReason ?? "no reason given")").font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(question.text).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if let notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 8) {
                    Text("You were writing: “\(text)”").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Send as a Note", action: send).controlSize(.small)
                    Button("Discard") { text = "" }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .opacity(0.8)
    }

    private func send() {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        answer(question, reply)
        text = ""
    }
}

/// An answered question (with the wording that was answered) or a withdrawn one (with why), in the Team tab's history.
private struct ClosedQuestionRow: View {
    let question: LeadQuestion

    var body: some View {
        let saw = question.answeredVersion ?? question.version
        VStack(alignment: .leading, spacing: 2) {
            if question.state == .withdrawn {
                Text(question.text).font(.system(size: 12)).foregroundStyle(.tertiary).strikethrough(color: .secondary.opacity(0.5))
                Text("Withdrawn: \(question.withdrawReason ?? "no reason given")").font(.system(size: 11)).foregroundStyle(.secondary)
                if let answer = question.answer {
                    Text("Answered anyway → \(answer)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text(question.wording(saw).text).font(.system(size: 12))
                Text("→ \(question.answer ?? "")").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                if saw < question.version {
                    Text("Answered version \(saw); it was reworded to “\(question.text)”").font(.system(size: 10.5)).foregroundStyle(.orange)
                } else if question.version > 1 {
                    Text("Reworded \(question.version - 1)×; last: \(question.lastRevision?.note ?? "")").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .opacity(question.state == .withdrawn ? 0.75 : 1)
    }
}

/// The inspector's Team tab for a lead, calm enough to glance at: the lead's questions, its recent decisions (fading
/// out as they age), then each task in one line (see `TeamRows`) with what its agent is doing in plain words, the
/// merged ones folded; below, your answers, the results, the files.
struct LeadTeamView: View {
    let root: String
    let board: LeadBoard
    /// What the team's window sessions are doing, by host id.
    let seen: [String: MemberSeen]
    /// Opens a team member's session (its host id) in the window.
    let open: (String) -> Void
    /// Rows shown opened, and the finished tasks unfolded, to begin with.
    var openRows: Set<String> = []
    var showFinished = false
    /// Answering the lead's questions from here, and what became of answers that didn't land.
    var answer: (LeadQuestion, String) -> Void = { _, _ in }
    var notices: [String: String] = [:]
    /// The lead's decisions (`BoardStore.decisions`), and the ones shown opened, or the earlier ones unfolded, to
    /// begin with.
    var decisions: [LeadDecision] = []
    var openDecisions: Set<String> = []
    var showEarlier = false
    /// The plain-language lines written so far (see `TeamSummaryModel`).
    var summary: (TeamRow) -> String? = { _ in nil }
    var decisionSummary: (LeadDecision) -> String? = { _ in nil }
    /// Drawn as of this time instead of the clock's (pictures).
    var clock: Date?

    var body: some View {
        let fading = !DecisionFeed.split(decisions, now: (clock ?? Date()).timeIntervalSince1970, reduceMotion: false).recent.isEmpty
        TimelineView(.ticking(every: fading ? 1 : 10)) { context in
            let now = clock ?? context.date
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    glance(now: now)
                    rest
                }
                .padding(14)
            }
        }
    }

    /// What's glanced at, top to bottom: the questions, the recent decisions, the tasks (also drawn alone in pictures).
    @ViewBuilder func glance(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let stack = board.questionStack(now: now.timeIntervalSince1970)
            if !stack.isEmpty {
                LeadQuestionStack(questions: stack, notices: notices, answer: answer)
            }
            DecisionFeedView(decisions: decisions, now: now, summary: decisionSummary, openDecisions: openDecisions, showEarlier: showEarlier)
                .padding(.horizontal, -8)
            section("Tasks") {
                if board.tasks.isEmpty {
                    Text("Nothing on the board yet. Tell the lead what to build.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                TeamTaskList(rows: TeamRows.rows(board, seen: seen), now: now, summary: summary, canOpen: { seen[$0] != nil }, open: open,
                             openRows: openRows, showFinished: showFinished)
                    .padding(.horizontal, -8)
            }
        }
    }

    @ViewBuilder private var rest: some View {
        let closed = board.questions.filter { !$0.isOpen }
        if !closed.isEmpty {
            section("Answered and withdrawn") {
                ForEach(closed.suffix(8).reversed()) { question in ClosedQuestionRow(question: question) }
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

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
