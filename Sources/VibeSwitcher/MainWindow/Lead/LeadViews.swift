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
        case .kept: return .teal
        case .folded: return .green
        case .abandoned: return .secondary
        case .reverted: return .red
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
        case .kept: return "Kept"
        case .folded: return "Folded"
        case .abandoned: return "Abandoned"
        case .reverted: return "Reverted"
        }
    }
}

extension LeadTask {
    /// The state it's shown in: abandoned once cleaned up after failing (older boards, cleanup with force), never failed.
    var shownStatus: Status { isAbandoned ? .abandoned : status }
}

/// Over the lead's chat: the board at a glance, one chip per task (click: open its worker).
struct TeamStrip: View {
    let board: LeadBoard
    let open: (LeadTask) -> Void
    /// Reports VibeSwitcher couldn't wake the lead for (see `LeadWake.shownAfter`), by the lead's terminal.
    @ObservedObject var waiting = ReportsWaiting.shared

    /// How wide the fade at the chips' right edge is.
    static let fade: CGFloat = 32

    var body: some View {
        // Drawn again only when the board or its count of reports waiting changes, not each time the chat is.
        TeamStripContent(board: board, waiting: board.leadTTY.flatMap { waiting.count[$0] }, open: open).equatable()
    }
}

/// What `TeamStrip` draws: equal (its action aside), SwiftUI leaves it as it is.
private struct TeamStripContent: View, Equatable {
    let board: LeadBoard
    /// Reports VibeSwitcher couldn't wake the lead for.
    let waiting: Int?
    let open: (LeadTask) -> Void

    static func == (a: TeamStripContent, b: TeamStripContent) -> Bool { a.board == b.board && a.waiting == b.waiting }

    var body: some View {
        let order = LeadTask.Status.attentionOrder
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.3.fill").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text("Team").font(.system(size: 12, weight: .semibold))
                // Folded tasks count with the done ones ("12 done (3 folded)"), never apart; those cleaned up after
                // failing as abandoned, never failed.
                let folded = board.tasks.filter { $0.status == .folded }.count
                ForEach(order.filter { $0 != .folded }, id: \.self) { status in
                    let count = board.tasks.filter { $0.shownStatus == status }.count + (status == .done ? folded : 0)
                    if count > 0 {
                        Label("\(count) \(status.label.lowercased())" + (status == .done && folded > 0 ? " (\(folded) folded)" : ""), systemImage: "circle.fill")
                            .labelStyle(StatusDotLabelStyle(color: status.color))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                if board.tasks.isEmpty { Text("No tasks yet").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                Spacer()
                if let count = waiting, let text = reportsWaiting(count) {
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
                        ForEach(board.tasks.sorted { $0.shownStatus.attentionRank < $1.shownStatus.attentionRank }) { task in
                            Button { open(task) } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(task.shownStatus.color).frame(width: 7, height: 7)
                                    Text(task.title).font(.system(size: 11.5)).lineLimit(1)
                                    if let evidence = task.evidence {
                                        Image(systemName: evidence.passes ? "checkmark.seal.fill" : "xmark.seal.fill")
                                            .font(.system(size: 10)).foregroundStyle(evidence.passes ? .green : .red)
                                            .accessibilityLabel(evidence.passes ? "Checks pass" : "Checks fail")
                                    }
                                }
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(task.shownStatus.color.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help("\(task.shownStatus.label): \(task.contract.goal)")
                        }
                    }
                    // From the strip's inset, and the last chip can scroll clear of the fade.
                    .padding(.leading, 16).padding(.trailing, TeamStrip.fade + 8)
                }
                // Edge to edge: a chip past the right edge fades out there, never cut off mid-word at the inset.
                .padding(.horizontal, -16)
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: TeamStrip.fade)
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

/// Holding a lead's question (its timer stops). Set where the window's views are made, so every stack of the
/// lead's questions (the chat, the Team tab) can hold one.
private struct HoldLeadQuestionKey: EnvironmentKey {
    static let defaultValue: (LeadQuestion) -> Void = { _ in }
}

/// Answering a lead's question from a row of the chat's history (a note after it closed). Set where the chat is made.
private struct AnswerLeadQuestionKey: EnvironmentKey {
    static let defaultValue: (LeadQuestion, String) -> Void = { _, _ in }
}

/// What you were writing under each of the lead's questions, by question id: a question that closes while you write
/// leaves the stack under the chat for the chat's history, and the draft goes with it (to send as a note or discard).
final class LeadQuestionDrafts {
    var text: [String: String] = [:]
}

private struct LeadQuestionDraftsKey: EnvironmentKey {
    static let defaultValue: LeadQuestionDrafts? = nil
}

extension EnvironmentValues {
    var holdLeadQuestion: (LeadQuestion) -> Void {
        get { self[HoldLeadQuestionKey.self] }
        set { self[HoldLeadQuestionKey.self] = newValue }
    }

    var answerLeadQuestion: (LeadQuestion, String) -> Void {
        get { self[AnswerLeadQuestionKey.self] }
        set { self[AnswerLeadQuestionKey.self] = newValue }
    }

    var leadQuestionDrafts: LeadQuestionDrafts? {
        get { self[LeadQuestionDraftsKey.self] }
        set { self[LeadQuestionDraftsKey.self] = newValue }
    }
}

/// "8 min", "45 s": what's left of a question's timer, rounded up (a timer at 7:42 is going "in 8 min").
func timeLeft(_ seconds: Double) -> String {
    seconds >= 60 ? "\(Int((seconds / 60).rounded(.up))) min" : "\(max(1, Int(seconds.rounded(.up)))) s"
}

/// "1 report waiting", "3 reports waiting"; nothing for none.
func reportsWaiting(_ count: Int) -> String? { count > 0 ? "\(count) report\(count == 1 ? "" : "s") waiting" : nil }

/// "1 question for you", "3 questions for you".
func questionCount(_ count: Int) -> String { "\(count) question\(count == 1 ? "" : "s") for you" }

/// The lead's questions as one stack (see `LeadBoard.questionStack`): the open ones, most important first, each
/// answered on its own (the answer goes to the lead without stopping it), then the ones it withdrew lately and the
/// ones it went ahead on when their timer ran out, as dim lines.
struct LeadQuestionStack: View {
    let questions: [LeadQuestion]
    /// What became of answers that didn't land as answers, by question id.
    var notices: [String: String] = [:]
    let answer: (LeadQuestion, String) -> Void
    /// Earlier wordings shown open to begin with (by question id).
    var historyOpen: Set<String> = []
    /// The withdrawn ones as cards (false: the Team tab, whose history lists them; one still shows while it holds a
    /// draft to send or what became of an answer to it).
    var showsWithdrawn = true
    /// The answers being written, by question id: kept here, so a card hidden once its question is withdrawn keeps
    /// what you were writing (and shows it to send as a note).
    @State private var drafts: [String: String]
    /// The chat's drafts (`LeadQuestionDrafts`): what you write here goes with a question that closes into the chat.
    @Environment(\.leadQuestionDrafts) private var kept

    init(questions: [LeadQuestion], notices: [String: String] = [:], answer: @escaping (LeadQuestion, String) -> Void,
         historyOpen: Set<String> = [], drafts: [String: String] = [:], showsWithdrawn: Bool = true) {
        self.questions = questions
        self.notices = notices
        self.answer = answer
        self.historyOpen = historyOpen
        self.showsWithdrawn = showsWithdrawn
        _drafts = State(initialValue: drafts)
    }

    var body: some View {
        let shown = questions.filter { question in
            showsWithdrawn || question.state != .withdrawn || notices[question.id] != nil
                || !(drafts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !shown.isEmpty {
            let open = shown.filter(\.isOpen)
            VStack(alignment: .leading, spacing: 8) {
                // A withdrawn card alone says what it is.
                if showsWithdrawn || shown.contains(where: { $0.state != .withdrawn }) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.bubble.fill").foregroundStyle(open.contains { $0.rank == .blocking } ? Color.red : Color.accentColor)
                            .accessibilityHidden(true)
                        Text(open.isEmpty ? "No questions waiting" : questionCount(open.count)).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if open.count > 1 {
                            Text("Answer in any order").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                }
                ForEach(shown) { question in
                    LeadQuestionCard(question: question, notice: notices[question.id], answer: answer,
                                     showHistory: historyOpen.contains(question.id),
                                     text: Binding(get: { drafts[question.id] ?? kept?.text[question.id] ?? "" }, set: { drafts[question.id] = $0 }))
                }
            }
        }
    }
}

/// A question of the lead's that closed without your answer, in the chat's history where it closed: the line the stack
/// showed for it, with a draft you were writing (`LeadQuestionDrafts`) still to send as a note.
struct LeadQuestionHistoryRow: View {
    let question: LeadQuestion
    let notice: String?
    @Environment(\.answerLeadQuestion) private var answer
    @Environment(\.leadQuestionDrafts) private var drafts
    /// The draft from the stack, once it's read (the card writes it back to `drafts` as it changes).
    @State private var text: String?

    var body: some View {
        LeadQuestionCard(question: question, notice: notice, answer: answer, showHistory: false,
                         text: Binding(get: { text ?? drafts?.text[question.id] ?? "" }, set: { text = $0 }))
    }
}

private struct LeadQuestionCard: View {
    let question: LeadQuestion
    let notice: String?
    let answer: (LeadQuestion, String) -> Void
    @State var showHistory: Bool
    /// The answer being written (the stack's): kept through a revision, and through a withdrawal (to send anyway or
    /// discard).
    @Binding var text: String
    @Environment(\.holdLeadQuestion) private var hold
    @Environment(\.leadQuestionDrafts) private var drafts
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        Group {
            switch question.state {
            case .withdrawn: withdrawn
            case .autoDecided: decided
            case .open, .answered: card
            }
        }
        .onChange(of: text) { _, text in drafts?.text[question.id] = text.isEmpty ? nil : text }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(question.rank.label.uppercased()).font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .foregroundStyle(question.rank == .whenever ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                    .background(Capsule().fill(question.rank == .whenever ? Color.secondary.opacity(0.15) : question.rank.color))
                TimelineView(.ticking(every: 30)) { context in
                    Text("asked \(Durations.short(context.date.timeIntervalSince1970 - question.askedAt)) ago")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            Text(question.text).font(.system(size: 14, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let why = question.whyNow {
                Text(why).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let revision = question.lastRevision { history(revision) }
            if question.isCounting, let proposal = question.proposal, let deadline = question.decideBy {
                countdown(proposal: proposal, deadline: deadline)
            } else if question.heldAt != nil, let proposal = question.proposal {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    (Text("Held: the timer is off. The lead proposed ") + Text(proposal).fontWeight(.semibold) + Text("; it waits for your answer."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
            }
            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        let proposed = option == question.proposal
                        Button { answer(question, option) } label: {
                            HStack(spacing: 6) {
                                Text(option).font(.system(size: 13, weight: proposed ? .semibold : .regular))
                                Spacer(minLength: 4)
                                if proposed {
                                    Text("PROPOSED").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accentColor)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(proposed ? Color.accentColor.opacity(question.isCounting ? 0.16 : 0.08)
                                                                                         : Color.secondary.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(proposed && question.isCounting ? 0.6 : 0)))
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
            if question.isCounting, let proposal = question.proposal {
                Text("Pick another answer or hold it; if you don't, the lead goes ahead with \(proposal) at \(LeadBoard.clock(question.decideBy ?? 0)).")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("It keeps working while you think; the answer reaches it at its next step.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((question.rank == .blocking ? Color.red : Color.accentColor).opacity(0.45)))
    }

    /// "Going with <proposal> in 8 min", a ring that empties as the time runs out, and Hold. Drawn again on the
    /// deadline's minutes, and on its seconds only in the last minute (never with Reduce Motion or VoiceOver on).
    private func countdown(proposal: String, deadline: Double) -> some View {
        let length = Double(question.decideIn ?? LeadQuestion.defaultDecideIn) * 60
        let end = Date(timeIntervalSince1970: deadline)
        return TimelineView(.countdown(to: end, reduceMotion: reduceMotion, voiceOver: voiceOver)) { context in
            let left = max(0, deadline - context.date.timeIntervalSince1970)
            // The seconds are shown only while they're drawn every second; once a minute, they'd be up to a minute out.
            let perSecond = ElapsedTicks.interval(remaining: left, reduceMotion: reduceMotion, voiceOverRunning: voiceOver) == 1
            let inText = perSecond || left >= 60 ? " in \(timeLeft(left))" : " in under a minute"
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Color.accentColor.opacity(0.2), lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0, min(1, left / length)))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 15, height: 15)
                let going = (Text("Going with ") + Text(proposal).fontWeight(.semibold) + Text(left > 0 ? inText : " now"))
                    .font(.system(size: 12.5))
                // The seconds only where they fit on the line (not in the inspector's narrow column).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        going.fixedSize()
                        if perSecond {
                            Text(String(format: "%d:%02d", Int(left) / 60, Int(left) % 60)).font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(.tertiary).fixedSize()
                        }
                    }
                    going.lineLimit(2)
                }
                Spacer(minLength: 4)
                Button { hold(question) } label: { Label("Hold", systemImage: "pause.fill") }
                    .controlSize(.small)
                    .help("Stop the timer: the lead waits for your answer")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.08)))
        }
    }

    /// The timer ran out and the lead went ahead with its proposal: one line, and the other options to tell it you'd
    /// have chosen otherwise (as a note).
    private var decided: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor.opacity(0.8)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    (Text("Went ahead with ") + Text(question.proposal ?? "").fontWeight(.semibold) + Text(": no answer in \(question.decideInText)"))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Text(question.text).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(LeadBoard.clock(question.autoDecidedAt ?? 0)).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            if let notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let late = question.answer {
                Text("You answered later: \(late). The lead got it as a note.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let others = question.options.filter { $0 != question.proposal }
                if !others.isEmpty {
                    HStack(spacing: 6) {
                        Text("Rather:").font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(others, id: \.self) { option in
                            Button(option) { answer(question, option) }.controlSize(.small)
                        }
                    }
                    .help("Tell the lead you'd have chosen otherwise; it gets it as a note")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.22)))
    }

    /// "Updated 17:42: <note>", and the earlier wordings behind a disclosure.
    private func history(_ revision: LeadQuestion.Revision) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showHistory.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    Text("Updated \(LeadBoard.clock(revision.at)): \(revision.note)").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showHistory ? 90 : 0)).accessibilityHidden(true)
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
                Image(systemName: "xmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
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

/// The Team tab's answered and withdrawn questions, newest first, one line each (the question's first line and its
/// answer); the newest few in view, the rest folded into "Earlier (n)". Clicking one shows it whole.
struct ClosedQuestionList: View {
    static let shown = 3
    let questions: [LeadQuestion]
    @State var showEarlier = false
    /// Questions shown whole, to begin with (pictures).
    @State var openQuestions: Set<String> = []

    var body: some View {
        let newest = Self.newestFirst(questions)
        let earlier = newest.dropFirst(Self.shown)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(newest.prefix(Self.shown)) { question in row(question) }
            if !earlier.isEmpty {
                Fold(title: "Earlier (\(earlier.count))", isOpen: $showEarlier, hint: "the earlier answered and withdrawn questions")
                if showEarlier {
                    ForEach(earlier) { question in row(question) }
                }
            }
        }
    }

    /// Newest first, by when each closed: answered, withdrawn or decided by its timer.
    static func newestFirst(_ questions: [LeadQuestion]) -> [LeadQuestion] {
        questions.sorted { closedAt($0) > closedAt($1) }
    }

    static func closedAt(_ question: LeadQuestion) -> Double {
        [question.answeredAt, question.withdrawnAt, question.autoDecidedAt].compactMap { $0 }.min() ?? question.askedAt
    }

    /// The text's first line: a question's gist.
    static func firstLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// "→ 1 and 3": what it closed with, nil for a withdrawn one nobody answered.
    static func outcome(_ question: LeadQuestion) -> String? {
        switch question.state {
        case .autoDecided: return question.proposal.map { "→ " + clipped($0) }
        case .withdrawn, .answered, .open: return question.answer.map { "→ " + clipped($0) }
        }
    }

    /// A long answer's start, so the question's gist keeps room on its line.
    static func clipped(_ answer: String) -> String {
        let line = firstLine(answer)
        return line.count > 36 || line != answer.trimmingCharacters(in: .whitespacesAndNewlines) ? String(line.prefix(34)) + "…" : line
    }

    private func row(_ question: LeadQuestion) -> some View {
        let isOpen = openQuestions.contains(question.id)
        let withdrawn = question.state == .withdrawn
        let toggle = { if isOpen { openQuestions.remove(question.id) } else { openQuestions.insert(question.id) } }
        let gist = Self.firstLine(question.wording(question.answeredVersion ?? question.version).text)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 10).accessibilityHidden(true)
                if withdrawn {
                    Text("Withdrawn").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary).fixedSize()
                }
                Text(gist).font(.system(size: 12)).foregroundStyle(withdrawn ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(1).truncationMode(.tail)
                if let outcome = Self.outcome(question) {
                    Text(outcome).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(withdrawn ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                        .lineLimit(1).layoutPriority(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((withdrawn ? "Withdrawn: " : "") + gist
                                + ((question.state == .autoDecided ? question.proposal : question.answer).map { ", answer: \($0)" } ?? ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isOpen ? "Hides the question" : "Shows the whole question and its answer")
            .accessibilityAction(.default, toggle)
            if isOpen {
                ClosedQuestionDetails(question: question).padding(.leading, 16).padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(isOpen ? Color.secondary.opacity(0.07) : Color.clear))
    }
}

/// An answered question opened (the wording that was answered, the answer), or a withdrawn one (why), in the Team
/// tab's history.
private struct ClosedQuestionDetails: View {
    let question: LeadQuestion

    var body: some View {
        let saw = question.answeredVersion ?? question.version
        VStack(alignment: .leading, spacing: 3) {
            if question.state == .withdrawn {
                Text(question.text).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Withdrawn: \(question.withdrawReason ?? "no reason given")").font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let answer = question.answer {
                    Text("Answered anyway → \(answer)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if question.state == .autoDecided {
                Text(question.text).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("→ \(question.proposal ?? "")").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.accentColor)
                Text("No answer in \(question.decideInText): the lead went ahead" + (question.answer.map { "; you answered later: \($0)" } ?? ""))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(question.wording(saw).text).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("→ \(question.answer ?? "")").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.accentColor)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if saw < question.version {
                    Text("Answered version \(saw); it was reworded to “\(question.text)”").font(.system(size: 10.5)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if question.version > 1 {
                    Text("Reworded \(question.version - 1)×; last: \(question.lastRevision?.note ?? "")").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// The Team view's line while the Mac is kept awake for the team (see `KeepAwake`); short: "Kept awake".
struct KeepingAwakeLine: View {
    static let text = "Keeping the Mac awake while the team works"
    var short = false

    var body: some View {
        Label(short ? "Kept awake" : Self.text, systemImage: "cup.and.saucer.fill")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .help(Self.text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("VibeSwitcher is keeping the Mac awake while the team works. Settings, Project lead, says when.")
    }
}

/// The Team tab's foot: the Mac-wide line and whether the Mac is kept awake for the team. The Mac's state, apart from
/// the tasks: on one line where it fits.
struct TeamStatusFoot: View {
    let mac: MacLine?
    let keepingAwake: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    if let mac { MacLineView(line: mac) }
                    if keepingAwake { KeepingAwakeLine(short: mac != nil) }
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 3) {
                    if let mac { MacLineView(line: mac) }
                    if keepingAwake { KeepingAwakeLine() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .background(.bar)
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
    /// The earlier results, and the earlier answered and withdrawn questions, unfolded, to begin with.
    var showEarlierResults = false
    var showEarlierQuestions = false
    /// The plain-language lines written so far (see `TeamSummaryModel`).
    var summary: (TeamRow) -> String? = { _ in nil }
    var decisionSummary: (LeadDecision) -> String? = { _ in nil }
    /// Whether the Mac is kept awake while this team works (see `KeepAwake`).
    var keepingAwake = false
    /// Drawn as of this time instead of the clock's (pictures).
    var clock: Date?
    /// The Mac-wide line (every project's team and the load); nil: not shown.
    var mac: MacLine?
    /// The board's rows (`TeamRows.rows`) when they're made already (the window's, kept in `TeamRowsCache`); nil: made
    /// here, from `seen`.
    var rows: [TeamRow]?
    /// Where the lead's records are kept (`BoardStore.recordsDir`, read with the board, never as it draws; nil: in
    /// .vibeswitcher).
    var recordsDir: String? = LeadWorkflow.defaultRecordsDir

    var body: some View {
        // Made once a draw, never as the clock ticks: a day's 200-odd tasks mapped and sorted.
        let rows = self.rows ?? TeamRows.rows(board, seen: seen)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Each drawn again only when what it shows changed, never for the window's other changes.
                glancing(rows).equatable()
                TeamRecords(root: root, board: board, recordsDir: recordsDir, clock: clock,
                            minute: Int((clock ?? Date()).timeIntervalSince1970 / 60), showEarlierResults: showEarlierResults,
                            showEarlierQuestions: showEarlierQuestions).equatable()
            }
            .padding(14)
        }
        // The Mac's state, not a task: a line at the foot, in view however far the tasks scroll.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if mac != nil || keepingAwake { TeamStatusFoot(mac: mac, keepingAwake: keepingAwake) }
        }
    }

    /// What's glanced at, top to bottom: the questions, the recent decisions, the tasks (also drawn alone in pictures).
    func glance(now: Date) -> some View {
        glancing(rows ?? TeamRows.rows(board, seen: seen)).content(now: now)
    }

    private func glancing(_ rows: [TeamRow]) -> TeamGlance {
        var lines: [String: String] = [:]
        for row in rows { if let line = summary(row) { lines[row.id] = line } }
        var decisionLines: [String: String] = [:]
        for decision in decisions { if let line = decisionSummary(decision) { decisionLines[decision.id] = line } }
        return TeamGlance(board: board, rows: rows, openable: Set(seen.keys), notices: notices, decisions: decisions, lines: lines,
                          decisionLines: decisionLines, openRows: openRows, showFinished: showFinished, openDecisions: openDecisions,
                          showEarlier: showEarlier, clock: clock, open: open, answer: answer)
    }
}

/// The Team tab's top: the lead's questions, its recent decisions, the tasks. Drawn again as its clock ticks (what tells
/// time), and when what it shows changes: equal (its actions aside), SwiftUI leaves it as it is.
struct TeamGlance: View, Equatable {
    let board: LeadBoard
    let rows: [TeamRow]
    /// The team's sessions it can open, by host id.
    let openable: Set<String>
    let notices: [String: String]
    let decisions: [LeadDecision]
    /// The plain-language lines written so far, by task id and by decision id (see `TeamSummaryModel`).
    let lines: [String: String]
    let decisionLines: [String: String]
    let openRows: Set<String>
    let showFinished: Bool
    let openDecisions: Set<String>
    let showEarlier: Bool
    let clock: Date?
    let open: (String) -> Void
    let answer: (LeadQuestion, String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (a: TeamGlance, b: TeamGlance) -> Bool {
        a.board == b.board && a.rows == b.rows && a.openable == b.openable && a.notices == b.notices && a.decisions == b.decisions
            && a.lines == b.lines && a.decisionLines == b.decisionLines && a.openRows == b.openRows && a.showFinished == b.showFinished
            && a.openDecisions == b.openDecisions && a.showEarlier == b.showEarlier && a.clock == b.clock
    }

    var body: some View {
        // The decisions still to fade: from the first one's fade to the last one's end (DecisionFeed's times).
        let now = (clock ?? Date()).timeIntervalSince1970
        let fades = decisions.map { $0.at + DecisionFeed.shown }.filter { $0 + DecisionFeed.fade > now }
        let fadeStart = fades.min().map { Date(timeIntervalSince1970: $0) }
        let fadeEnd = fades.max().map { Date(timeIntervalSince1970: $0 + DecisionFeed.fade) }
        // Only what tells time is drawn again as the clock ticks: every 10 s, every second while a decision fades (never
        // with Reduce Motion: it folds instead).
        TimelineView(.fading(from: fadeStart, until: fadeEnd, every: 10, reduceMotion: reduceMotion)) { context in
            content(now: clock ?? context.date)
        }
    }

    @ViewBuilder func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let stack = board.questionStack(now: now.timeIntervalSince1970)
            if !stack.isEmpty {
                // The withdrawn ones are in the history below.
                LeadQuestionStack(questions: stack, notices: notices, answer: answer, showsWithdrawn: false)
            }
            DecisionFeedView(decisions: decisions, now: now, summary: { decisionLines[$0.id] }, openDecisions: openDecisions, showEarlier: showEarlier)
                .padding(.horizontal, -8)
            teamSection("Tasks") {
                if board.tasks.isEmpty {
                    Text("Nothing on the board yet. Tell the lead what to build.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                TeamTaskList(rows: rows, now: now, summary: { lines[$0.id] }, canOpen: { openable.contains($0) }, open: open,
                             openRows: openRows, showFinished: showFinished)
                    .padding(.horizontal, -8)
            }
        }
    }
}

/// The Team tab below the tasks: the scorecard, your answers, the results, the files. Drawn again only when the board
/// changes (or, for the scorecard's minutes waiting on you, a minute on), never as the window's sessions change.
struct TeamRecords: View, Equatable {
    let root: String
    let board: LeadBoard
    let recordsDir: String?
    let clock: Date?
    /// The minute it's drawn in.
    let minute: Int
    let showEarlierResults: Bool
    let showEarlierQuestions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !board.tasks.isEmpty {
                teamSection("Scorecard") {
                    ScorecardView(scorecard: LeadScorecard(board, now: (clock ?? Date()).timeIntervalSince1970),
                                  receipts: LeadReceiptTotals.current(board))
                }
            }
            let closed = board.questions.filter { !$0.isOpen }
            if !closed.isEmpty {
                teamSection("Answered and withdrawn") {
                    ClosedQuestionList(questions: closed, showEarlier: showEarlierQuestions).padding(.horizontal, -8)
                }
            }
            if !board.updates.isEmpty {
                teamSection("Results") {
                    ResultsList(updates: board.updates, showEarlier: showEarlierResults)
                }
            }
            teamSection("Files") {
                HStack(spacing: 8) {
                    ForEach(["workflow.md", "decisions.md", "progress.md", "incidents.md"], id: \.self) { name in
                        Button(name) {
                            let path = name == "workflow.md" ? (root as NSString).appendingPathComponent(".vibeswitcher/\(name)") : recordPath(name)
                            if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } else { NSSound.beep() }
                        }
                        .controlSize(.small)
                    }
                }
                let shown = root.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                Text(recordsDir.map { "workflow.md is kept in \(shown)/.vibeswitcher (not committed); decisions.md, progress.md and incidents.md in \(shown)/\($0), committed to the lead's branch." }
                     ?? "Kept in \(shown)/.vibeswitcher (not committed).")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
    }

    /// Where a record is (`BoardStore.recordPath`), from the records folder read with the board.
    private func recordPath(_ name: String) -> String {
        let store = BoardStore(root: root)
        guard let recordsDir else { return (store.folder as NSString).appendingPathComponent(name) }
        return ((root as NSString).appendingPathComponent(recordsDir) as NSString).appendingPathComponent(name)
    }
}

/// A section of the Team tab: its title in small capitals over its content.
private func teamSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
        content()
    }
}

/// "Mac: load 12.3, 5 team sessions across 2 projects", orange while a limit holds the lead's new sessions back.
struct MacLineView: View {
    let line: MacLine

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: line.isOver ? "gauge.with.dots.needle.100percent" : "gauge.with.dots.needle.33percent")
                .font(.system(size: 10)).accessibilityHidden(true)
            Text(line.text).font(.system(size: 11).monospacedDigit())
        }
        .foregroundStyle(line.isOver ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.spoken)
    }
}

/// The lead's results, newest first: the latest few in full, the rest folded into "Earlier results (n)". Each one's
/// markdown is selectable text, which AppKit hosts view by view: a day's results drawn whole made every switch to the
/// lead take seconds and held a hundred-odd MB.
struct ResultsList: View {
    static let shown = 3
    let updates: [LeadUpdate]
    @State var showEarlier = false

    var body: some View {
        let newest = Array(updates.reversed())
        let earlier = newest.dropFirst(Self.shown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(newest.prefix(Self.shown)) { update in card(update) }
            if !earlier.isEmpty {
                Fold(title: "Earlier results (\(earlier.count))", isOpen: $showEarlier, hint: "the lead's earlier results")
                    .padding(.horizontal, -8)
                if showEarlier {
                    ForEach(earlier) { update in card(update) }
                }
            }
        }
    }

    private func card(_ update: LeadUpdate) -> some View {
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
                } else {
                    // Gone: dropped by the kept images' cap, or an older update's path into a cleaned-up worktree.
                    Label("Image no longer available", systemImage: "photo")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .help(path)
                }
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}

/// The lead's base moved, and not in a way the vault could take as yours (see `BaseMoves`): what came in, and
/// whether to take it. Asked once per move; the lead's merges stay refused until you answer.
struct BaseMovePrompt: View {
    @ObservedObject var moves: BaseMoves
    let root: String

    var body: some View {
        if let move = moves.asking[root] {
            BaseMoveCard(move: move, failure: moves.failures[root], accept: { moves.accept(root) }, keep: { moves.keepRefused(root) })
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

struct BaseMoveCard: View {
    let move: LeadVault.BaseMove
    var failure: String?
    let accept: () -> Void
    let keep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange).accessibilityHidden(true)
                Text("\(move.branch) moved outside the lead's merges").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(move.from.prefix(8)) → \(move.to.prefix(8))").font(.system(size: 10.5).monospaced()).foregroundStyle(.tertiary)
            }
            if let reason = move.reason {
                Text(reason).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !move.commits.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(move.commits.prefix(6), id: \.sha) { commit in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(commit.sha.prefix(7)).font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                            Text(commit.subject).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    if move.commits.count > 6 {
                        Text("and \(move.commits.count - 6) more").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                .textSelection(.enabled)
            }
            Text(move.commits.isEmpty
                 ? "It isn't a fast-forward of where the lead left it. Accept takes it as it is anyway: merges start from there."
                 : "Accept if these are yours: the lead's merges start from here, with the lead and its team running on. Keep Refused leaves its merges refused.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(move.commits.count == 1 ? "Accept This Commit" : "Accept These Commits", action: accept).buttonStyle(.borderedProminent).controlSize(.small)
                Button("Keep Refused", action: keep).controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }
}
