import SwiftUI
import VibeCore

extension TeamRow.Mark {
    var color: Color {
        switch self {
        case .failed, .stalled, .ended: return .red
        case .blocked: return .purple
        case .waits, .working, .rework: return .orange
        case .review: return .blue
        case .merge, .merged, .folded: return .green
        case .kept: return .teal
        case .queued, .abandoned: return .secondary
        case .reverted: return .red
        }
    }
}

/// A task's status mark: its color and its shape.
struct TeamMark: View {
    let mark: TeamRow.Mark

    var body: some View {
        Image(systemName: mark.symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(mark.color)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

/// A task in one line: its mark, its title, its state and time; under it, dim, what its agent is doing (or what it
/// asks, or why it's red; for a folded task, the task it's folded into, a link that opens that task's row). Clicking it
/// shows its details. Equal while it shows the same (its actions aside: they're the same ones), SwiftUI leaves it as it
/// is: a tick of the Team view's clock that changes no row's time made every row's spoken label and accessibility
/// actions again, and an accessibility client watching compared them all (hang-20261027-203816, 203741).
struct TeamRowView: View, Equatable {
    let row: TeamRow
    let now: Date
    let summary: String?
    let isOpen: Bool
    let canOpen: (String) -> Bool
    let open: (String) -> Void
    /// Opens another task's row (its id): a folded task's link.
    var openTask: (String) -> Void = { _ in }
    let toggle: () -> Void

    static func == (a: TeamRowView, b: TeamRowView) -> Bool {
        a.row == b.row && a.summary == b.summary && a.isOpen == b.isOpen && a.row.stateText(now: a.now) == b.row.stateText(now: b.now)
            // Its links and actions to the worker's and the verifier's sessions, there while they're listed.
            && a.row.task.worker.map(a.canOpen) == b.row.task.worker.map(b.canOpen)
            && a.row.task.verifier.map(a.canOpen) == b.row.task.verifier.map(b.canOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isOpen {
                TeamRowDetails(row: row, canOpen: canOpen, open: open).padding(.leading, 18).padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(isOpen ? Color.secondary.opacity(0.07) : Color.clear))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TeamMark(mark: row.mark).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(row.task.title).font(.system(size: 12.5, weight: .medium)).lineLimit(isOpen ? nil : 1)
                    .fixedSize(horizontal: false, vertical: isOpen)
                Spacer(minLength: 8)
                Text(row.stateText(now: now)).font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(row.mark.isRed ? Color.red : Color.secondary).lineLimit(1).fixedSize()
            }
            if let target = row.foldedInto, let line = row.foldedText {
                Button { openTask(target.id) } label: {
                    Text(line).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).padding(.leading, 18)
                .help("Opens \(target.title), which carries this task's work")
            } else if let line = row.line(summary: summary) {
                Text(line).font(.system(size: 11)).foregroundStyle(row.mark.isRed ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1).truncationMode(.tail).padding(.leading, 18)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken(now: now, summary: summary))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isOpen ? "Hides the task's details" : "Shows the task's details")
        .accessibilityAction(.default, toggle)
        .accessibilityActions {
            if let worker = row.task.worker, canOpen(worker) { Button("Open the worker") { open(worker) } }
            if let verifier = row.task.verifier, canOpen(verifier) { Button("Open the verifier") { open(verifier) } }
            if let target = row.foldedInto { Button("Open \(target.title)") { openTask(target.id) } }
        }
    }
}

/// A row opened: why it last failed, its checkpoints with their times, the worker's report, the audit, and links to
/// the worker's and the verifier's sessions.
struct TeamRowDetails: View {
    let row: TeamRow
    let canOpen: (String) -> Bool
    let open: (String) -> Void

    var body: some View {
        let task = row.task
        VStack(alignment: .leading, spacing: 9) {
            if let failure = Self.failure(task) {
                part("Last failure") { Text(failure).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            if let checkpoints = task.checkpoints, !checkpoints.isEmpty {
                part("Checkpoints") {
                    ForEach(Array(checkpoints.suffix(8).enumerated()), id: \.offset) { _, checkpoint in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(LeadBoard.clock(checkpoint.at)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
                            Text(checkpoint.text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let report = task.report, !report.isEmpty {
                part("Worker report") { Text(report).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
            if let evidence = task.evidence ?? task.setback?.evidence {
                part(task.evidence == nil ? "Last audit" : "Audit") {
                    Label(evidence.passes ? "Passed" : "Not passed: \(evidence.completion.rawValue), \(evidence.integrity.rawValue)",
                          systemImage: evidence.passes ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(evidence.passes ? .green : .red)
                    Text(evidence.summary).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let vote = task.audits?.vote, task.evidence != nil {
                        Text(vote.text).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else if let panel = task.panel {
                part("Audit") {
                    Text("\(panel.progress) (\(panel.focuses.joined(separator: "; "))); the shared build and test run: \(panel.run)")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let audits = task.audits, !audits.findings.isEmpty {
                part("Findings (round \(audits.rounds))") {
                    ForEach(audits.bySeverity, id: \.severity) { group in
                        Text(Self.groupTitle(group.severity, group.findings))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(group.severity == .important && group.findings.contains(where: \.blocks) ? Color.red : Color.secondary)
                            .padding(.top, 2)
                        ForEach(group.findings) { finding in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: finding.isOpen ? "circle" : finding.status == .fixed ? "checkmark.circle.fill"
                                    : finding.status == .unconfirmed ? "questionmark.circle" : "minus.circle")
                                    .font(.system(size: 9)).foregroundStyle(finding.isOpen ? Color.secondary : finding.status == .fixed ? Color.green : Color.secondary)
                                    .accessibilityHidden(true)
                                Text(Self.findingText(finding)).font(.system(size: 11.5)).textSelection(.enabled)
                                    .foregroundStyle(finding.isOpen ? Color.primary : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            if let merged = task.merged {
                Text("Merged \(merged.commit.prefix(8)) at \(LeadBoard.clock(merged.at))" + (merged.tested ? ", tests passed" : ", no tests ran")
                     + (merged.unaudited ? ", no audit" : ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // Its review level shows in it (scores counted before review levels have none).
            if let score = task.score, score.review != nil || score.rounds > 0 || score.questions > 0 || task.merged != nil {
                Text(score.line).font(.system(size: 11))
                    .foregroundStyle(score.revertedBy != nil ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if task.worker.map(canOpen) == true || task.verifier.map(canOpen) == true {
                HStack(spacing: 8) {
                    if let worker = task.worker, canOpen(worker) { link("Open worker") { open(worker) } }
                    if let verifier = task.verifier, canOpen(verifier) { link("Open verifier") { open(verifier) } }
                }
                .fixedSize()
            }
        }
    }

    /// Why it last failed: the merge or audit that sent it back, a failed verdict, or what blocks it.
    static func failure(_ task: LeadTask) -> String? {
        if let setback = task.setback { return setback.reason }
        if task.status == .failed { return task.evidence?.summary }
        if task.status == .blocked { return task.blocker }
        return nil
    }

    /// "Important · 1 open of 2", "Nit · 1 open of 3, 1 unconfirmed".
    static func groupTitle(_ severity: LeadFinding.Severity, _ findings: [LeadFinding]) -> String {
        let open = findings.filter(\.isOpen).count
        let unconfirmed = findings.filter { $0.status == .unconfirmed }.count
        return "\(severity.rawValue) · " + (open == findings.count ? "\(open) open" : "\(open) open of \(findings.count)")
            + (unconfirmed > 0 ? ", \(unconfirmed) unconfirmed" : "")
    }

    /// "F1 b.txt:1 — evidence (fixed in round 2)", "… (dismissed by the lead: reason → task fix-a)".
    static func findingText(_ finding: LeadFinding) -> String {
        var text = "\(finding.id) \(finding.place) — \(finding.evidence)"
        switch finding.status {
        case .open: break
        case .unconfirmed: text += " (unconfirmed\(finding.reason.map { ": \($0)" } ?? ""))"
        case .fixed: text += " (fixed\(finding.closed.map { " in round \($0)" } ?? ""))"
        case .dismissed:
            text += " (dismissed\(finding.closedBy == "lead" ? " by the lead" : "")\(finding.reason.map { ": \($0)" } ?? "")"
                + "\(finding.followUp.map { " → task \($0)" } ?? ""))"
        }
        return text
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.up.forward.app").font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private func part<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// The board's tasks, one line each, in their order, with the finished ones folded into "Merged (n)".
struct TeamTaskList: View {
    let rows: [TeamRow]
    let now: Date
    let summary: (TeamRow) -> String?
    let canOpen: (String) -> Bool
    let open: (String) -> Void
    @State var openRows: Set<String> = []
    @State var showFinished = false
    /// The rows as last drawn, for `reveal`: a row equal to the one before keeps its first closure (`TeamRowView` is
    /// equatable), which must still find the rows of now.
    @State private var shown = Shown()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    final class Shown {
        var rows: [TeamRow] = []
    }

    var body: some View {
        let _ = shown.rows = rows
        let finished = rows.filter { $0.group == .finished }
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows.filter { $0.group != .finished }) { row in line(row, proxy) }
                if !finished.isEmpty {
                    Fold(title: TeamRows.finishedTitle(finished), isOpen: $showFinished, hint: "the finished tasks").padding(.top, 3)
                    if showFinished {
                        ForEach(finished) { row in line(row, proxy) }
                    }
                }
            }
        }
    }

    private func line(_ row: TeamRow, _ proxy: ScrollViewProxy) -> some View {
        TeamRowView(row: row, now: now, summary: summary(row), isOpen: openRows.contains(row.id), canOpen: canOpen, open: open,
                    openTask: { [shown] in reveal($0, in: shown.rows, proxy) }) {
            if openRows.contains(row.id) { openRows.remove(row.id) } else { openRows.insert(row.id) }
        }
        .equatable()
        .id(row.id)
    }

    /// Opens task `id`'s row (unfolding the finished ones when it's there) and scrolls to it.
    private func reveal(_ id: String, in rows: [TeamRow], _ proxy: ScrollViewProxy) {
        guard let target = rows.first(where: { $0.id == id }) else { return }
        if target.group == .finished { showFinished = true }
        openRows.insert(id)
        DispatchQueue.main.async { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .top) } }
    }
}

/// The lead's scorecard in a row of four small numbers: mean audit rounds to pass, the share passing the first audit
/// ("—" over too few audited tasks), the user's minutes per merged task, and reverts (red when there's one), each
/// saying what it means in its help tag; merges without tests under it.
struct ScorecardView: View {
    let scorecard: LeadScorecard
    /// The batch's receipts summed (`LeadReceiptTotals.current`): nil when no task has one, and then nothing shows.
    var receipts: (totals: LeadReceiptTotals, last: Double?)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if scorecard.merged == 0 {
                Text("Nothing merged yet: the numbers start with the first merge.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ForEach(Array(scorecard.tiles.enumerated()), id: \.offset) { index, tile in
                        self.tile(tile, red: index == 3 && scorecard.reverts > 0)
                    }
                }
                Text(Self.footnote(scorecard))
                    .font(.system(size: 10.5)).foregroundStyle(scorecard.mergedWithoutTests > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            }
            if let receipts {
                Text(Self.cost(receipts.totals, last: receipts.last))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Each finished task's receipt: its worker's working time, and the tokens its worker and verifier sessions spent, "
                        + "read from their transcripts. Costs are estimates at the API prices of \(receipts.totals.pricesAsOf).")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scorecard.spoken + (receipts.map { " " + Self.cost($0.totals, last: $0.last) } ?? ""))
    }

    /// "This batch: 4 tasks, 6.2 h of worker time, 61M tokens, est. $38.12; most expensive: …".
    static func cost(_ totals: LeadReceiptTotals, last: Double?) -> String {
        (last == nil ? "This batch: " : "Last batch: ") + totals.text + "."
    }

    /// A number, what it is and, dim under it, why it's not shown ("too few audited tasks (1)"); its meaning on hover.
    private func tile(_ tile: LeadScorecard.Tile, red: Bool) -> some View {
        let style: AnyShapeStyle = red ? AnyShapeStyle(Color.red) : tile.note == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
        return VStack(alignment: .leading, spacing: 1) {
            Text(tile.value).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(style)
            Text(tile.label).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let note = tile.note {
                Text(note).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(tile.help)
    }

    /// "Over 5 merged tasks (audit rounds known for 2); 2 with no audit (review none); 1 merged without tests."
    static func footnote(_ scorecard: LeadScorecard) -> String {
        var text = "Over \(scorecard.merged) merged task\(scorecard.merged == 1 ? "" : "s")"
        if scorecard.counted < scorecard.merged - scorecard.mergedUnaudited { text += " (audit rounds known for \(scorecard.counted))" }
        if scorecard.mergedUnaudited > 0 { text += "; \(scorecard.mergedUnaudited) with no audit (review none)" }
        if scorecard.mergedWithoutTests > 0 { text += "; \(scorecard.mergedWithoutTests) merged without tests" }
        return text + "."
    }
}

/// One dim line that unfolds what's under it.
struct Fold: View {
    let title: String
    @Binding var isOpen: Bool
    /// What it shows or hides, for VoiceOver ("the finished tasks").
    let hint: String

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .semibold)).rotationEffect(.degrees(isOpen ? 90 : 0))
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 11.5, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.secondary).contentShape(Rectangle())
            .padding(.horizontal, 8).padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isOpen ? "Hides \(hint)" : "Shows \(hint)")
    }
}

/// The lead's own decisions: a new one in full view, then fading and blurring out, then folded into
/// "Earlier decisions (n)" (see `DecisionFeed`). Clicking one shows it in full, with why; an open one stays.
struct DecisionFeedView: View {
    let decisions: [LeadDecision]
    let now: Date
    let summary: (LeadDecision) -> String?
    @State var openDecisions: Set<String> = []
    @State var showEarlier = false
    @State private var feed = DecisionFeed.Cache()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let split = feed.split(decisions, now: now.timeIntervalSince1970, reduceMotion: reduceMotion)
        // One you opened stays in view while it's open.
        let kept = split.earlier.filter { openDecisions.contains($0.id) && !showEarlier }
        let recent = (split.recent + kept.map { ($0, DecisionFeed.Phase.fresh) }).sorted { $0.decision.at > $1.decision.at }
        if !decisions.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(recent, id: \.decision.id) { item in
                    let look = DecisionFeed.look(openDecisions.contains(item.decision.id) ? .fresh : item.phase)
                    row(item.decision, dim: false)
                        .opacity(look.opacity)
                        .blur(radius: look.blur)
                        .animation(reduceMotion ? nil : .linear(duration: 1), value: look.opacity)
                }
                let earlier = split.earlier.filter { !kept.contains($0) }
                if !earlier.isEmpty {
                    Fold(title: "Earlier decisions (\(earlier.count))", isOpen: $showEarlier, hint: "the lead's earlier decisions")
                    if showEarlier {
                        ForEach(earlier) { decision in row(decision, dim: true) }
                    }
                }
            }
        }
    }

    private func row(_ decision: LeadDecision, dim: Bool) -> some View {
        let isOpen = openDecisions.contains(decision.id)
        let toggle = { if isOpen { openDecisions.remove(decision.id) } else { openDecisions.insert(decision.id) } }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "signpost.right.fill").font(.system(size: 9)).foregroundStyle(Color.accentColor.opacity(dim ? 0.5 : 1))
                    .frame(width: 12).accessibilityHidden(true)
                Text(DecisionFeed.line(decision, summary: summary(decision))).font(.system(size: 12, weight: dim ? .regular : .medium))
                    .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)).lineLimit(1)
                Spacer(minLength: 8)
                Text(LeadBoard.clock(decision.at)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isOpen ? "Hides the decision" : "Shows the whole decision and why")
            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    // The line says it all when it's short; a long one is shown whole.
                    if DecisionFeed.needsSummary(decision) {
                        Text(decision.text).font(.system(size: 11.5, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if !decision.why.isEmpty {
                        Text(decision.why).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 18).padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(isOpen ? Color.accentColor.opacity(0.07) : Color.clear))
    }
}

/// The Team tab as the window shows it: `LeadTeamView` with the plain-language lines, asked for every few seconds
/// while it's on screen. Equal (its actions aside: they're the same ones), SwiftUI leaves it as it is: the inspector is
/// drawn again for every session the host changes.
struct LeadTeamPane: View, Equatable {
    let root: String
    let board: LeadBoard
    let decisions: [LeadDecision]
    let seen: [String: MemberSeen]
    /// The board's rows, made already (`TeamRowsCache`); nil: made here from `seen`.
    var rows: [TeamRow]? = nil
    let open: (String) -> Void
    let answer: (LeadQuestion, String) -> Void
    let notices: [String: String]
    @ObservedObject var summaries: TeamSummaryModel
    /// Whether the Mac is kept awake for this team (see `KeepAwake`).
    @ObservedObject var keepAwake: KeepAwake
    /// Every session the host lists, of every project (the Mac-wide line counts their teams).
    var hosted: [MacLine.Session] = []
    /// Where the lead's records are kept (`LeadController.recordsDirs`).
    var recordsDir: String? = LeadWorkflow.defaultRecordsDir
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts 5-second ticks while it's on screen (a `.task`, so a re-render of the window doesn't restart it).
    @State private var tick = 0
    /// The Mac's load and the Mac-wide limits, read again with each tick.
    @State private var load: Double?
    @State private var limits = MacLimits()
    /// The Mac-wide line, made with each tick and when the host's sessions change, never in `body`: counting every
    /// project's team sessions is a walk of all their folders, and the body is drawn again many times a second while
    /// the window updates (hang-20261027-201145, 201501).
    @State private var mac: MacLine?

    static func == (a: LeadTeamPane, b: LeadTeamPane) -> Bool {
        a.root == b.root && a.board == b.board && a.decisions == b.decisions && a.seen == b.seen && a.rows == b.rows
            && a.notices == b.notices && a.summaries === b.summaries && a.keepAwake === b.keepAwake && a.hosted == b.hosted
            && a.recordsDir == b.recordsDir
    }

    private var teamRows: [TeamRow] { rows ?? TeamRows.rows(board, seen: seen) }

    var body: some View {
        LeadTeamView(root: root, board: board, seen: seen, open: open, answer: answer, notices: notices, decisions: decisions,
                     summary: { summaries.line($0) }, decisionSummary: { summaries.line($0) }, keepingAwake: keepAwake.held.contains(root),
                     mac: mac, rows: teamRows, recordsDir: recordsDir)
            .onAppear(perform: request)
            .onChange(of: tick) { request() }
            .onChange(of: hosted) { mac = MacLine.make(listed: hosted, load: load, limits: limits) }
            .onChange(of: summaries.enabled) { request() }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    tick += 1
                }
            }
    }

    private func request() {
        load = MacLoad.oneMinute()
        limits = MacLimits.load()
        mac = MacLine.make(listed: hosted, load: load, limits: limits)
        let recent = DecisionFeed.split(decisions, now: Date().timeIntervalSince1970, reduceMotion: reduceMotion).recent.map(\.decision)
        summaries.request(rows: teamRows, decisions: recent)
    }
}
