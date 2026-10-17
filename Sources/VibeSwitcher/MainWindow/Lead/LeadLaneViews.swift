import SwiftUI
import VibeCore

extension LeadLane.Stage {
    /// The live ring's color at this stage.
    var tint: Color {
        switch self {
        case .plan: return .secondary
        case .work: return .orange
        case .review: return .blue
        case .merge: return .green
        }
    }
}

extension LeadLane {
    var stateColor: Color {
        if isRed { return .red }
        switch group {
        case .live: return .orange
        case .review: return .blue
        case .finished: return task.status == .done ? .green : .secondary
        case .queued, .needsYou: return .secondary
        }
    }
}

/// One stage: filled when done, a ring around a dot while live (pulsing, or still with Reduce Motion), hollow when
/// not yet, red when it failed or needs you.
struct LaneNode: View {
    let node: LeadLane.Node
    let tint: Color
    let ring: LeadLanes.LiveRing
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch node {
            case .done:
                Circle().fill(Color.green)
                Image(systemName: "checkmark").font(.system(size: 6, weight: .heavy)).foregroundStyle(.white)
            case .failed:
                Circle().fill(Color.red)
                Image(systemName: "exclamationmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white)
            case .todo:
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.3)
            case .live:
                if ring == .pulsing {
                    Circle().stroke(tint.opacity(0.6), lineWidth: 2)
                        .scaleEffect(pulse ? 2 : 1).opacity(pulse ? 0 : 1)
                        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
                } else {
                    Circle().stroke(tint.opacity(0.35), lineWidth: 2).scaleEffect(1.55)
                }
                Circle().strokeBorder(tint, lineWidth: 2)
                Circle().fill(tint).padding(3.5)
            }
        }
        .frame(width: 11, height: 11)
    }
}

/// Plan → Work → Review → Merge; a stage with a session behind it (the worker, the verifier) opens it.
struct LaneNodes: View {
    let lane: LeadLane
    let canOpen: (String) -> Bool
    let open: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LeadLane.Stage.allCases, id: \.self) { stage in
                if let previous = LeadLane.Stage(rawValue: stage.rawValue - 1) {
                    Rectangle().fill(lane.node(previous) == .done ? Color.green.opacity(0.7) : Color.secondary.opacity(0.3))
                        .frame(width: 9, height: 1.5)
                }
                let node = LaneNode(node: lane.node(stage), tint: stage.tint, ring: LeadLanes.liveRing(reduceMotion: reduceMotion))
                    .frame(width: 17, height: 17)
                if let session = lane.session(for: stage), canOpen(session) {
                    Button { open(session) } label: { node.contentShape(Circle()) }
                        .buttonStyle(.plain)
                        .help("\(stage.name): open the \(stage == .work ? "worker" : "verifier")")
                } else {
                    node.help(stage.name)
                }
            }
        }
    }
}

/// A task's row: its full title, the checkpoint or live activity under it, the lane and its state on the right.
/// Clicking the row shows its details.
struct LaneRow: View {
    let lane: LeadLane
    let now: Date
    let isOpen: Bool
    let canOpen: (String) -> Bool
    let open: (String) -> Void
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isOpen { LaneDetails(lane: lane, canOpen: canOpen, open: open) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(lane.isRed ? Color.red.opacity(0.07) : Color.secondary.opacity(0.06)))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            summary
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 5) {
                LaneNodes(lane: lane, canOpen: canOpen, open: open)
                Text(lane.stateText(now: now)).font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(lane.stateColor).lineLimit(1)
            }
            .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lane.spoken(now: now))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isOpen ? "Hides the task's details" : "Shows the task's details")
        .accessibilityAction(.default, toggle)
        .accessibilityActions { sessionActions }
    }

    @ViewBuilder private var sessionActions: some View {
        if let worker = lane.task.worker, canOpen(worker) { Button("Open the worker") { open(worker) } }
        if let verifier = lane.task.verifier, canOpen(verifier) { Button("Open the verifier") { open(verifier) } }
    }

    /// The title (whole, wrapping), then the latest checkpoint, the live activity and what went wrong.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(lane.task.title).font(.system(size: 12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if let checkpoint = lane.checkpoint {
                (Text(Image(systemName: "flag.fill")).font(.system(size: 8)).foregroundColor(.secondary) + Text(" ")
                    + Text(checkpoint.text).foregroundColor(.secondary)
                    + Text(" · " + Durations.compact(now.timeIntervalSince1970 - checkpoint.at)).foregroundColor(Color.secondary.opacity(0.6)))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let activity = lane.activity {
                Text(activity).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let problem = lane.problem {
                Text(problem).foregroundStyle(lane.isRed ? Color.red : Color.orange).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
    }
}

/// A row opened: the contract, checkpoints with times, the worker's report, the audit, the merge.
struct LaneDetails: View {
    let lane: LeadLane
    let canOpen: (String) -> Bool
    let open: (String) -> Void

    var body: some View {
        let task = lane.task
        VStack(alignment: .leading, spacing: 10) {
            part("Contract") {
                Text(task.contract.goal).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                ForEach(task.contract.acceptance, id: \.self) { check in
                    Label(check, systemImage: "checkmark.circle").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !task.contract.boundaries.isEmpty {
                    Text("Boundaries: " + task.contract.boundaries.joined(separator: "; ")).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let checkpoints = task.checkpoints, !checkpoints.isEmpty {
                part("Checkpoints") {
                    ForEach(Array(checkpoints.enumerated()), id: \.offset) { _, checkpoint in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Date(timeIntervalSince1970: checkpoint.at).formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
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
                    Label("\(evidence.completion.rawValue), \(evidence.integrity.rawValue)", systemImage: evidence.passes ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(evidence.passes ? .green : .red)
                    Text(evidence.summary).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let commit = evidence.commit {
                        Text("On \(commit.prefix(8))").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
            }
            if let setback = task.setback, setback.stage == .merge, task.status != .done {
                part("Merge") { Text(setback.reason).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            if let merged = task.merged {
                part("Merge") {
                    Text("Merged \(merged.commit.prefix(8)) at \(Date(timeIntervalSince1970: merged.at).formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11.5, design: .monospaced))
                    Label(merged.tested ? "The test command ran and passed" : "Merged without tests (no test_command)",
                          systemImage: merged.tested ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(merged.tested ? .green : .orange)
                }
            }
            if task.worker.map(canOpen) == true || task.verifier.map(canOpen) == true {
                HStack(spacing: 8) {
                    if let worker = task.worker, canOpen(worker) { openButton("Open worker") { open(worker) } }
                    if let verifier = task.verifier, canOpen(verifier) { openButton("Open verifier") { open(verifier) } }
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                if let branch = task.branch {
                    Text(branch).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                if task.rework > 0 {
                    Text("\(task.rework) rework round\(task.rework == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize()
                }
            }
        }
        .padding(.leading, 2)
    }

    private func openButton(_ title: String, action: @escaping () -> Void) -> some View {
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
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// The board's tasks as lanes, in their order, with the finished ones folded into "Merged (n)".
struct LaneList: View {
    let board: LeadBoard
    let seen: [String: LaneSeen]
    let open: (String) -> Void
    @State private var openRows: Set<String>
    @State private var showFinished: Bool

    init(board: LeadBoard, seen: [String: LaneSeen], open: @escaping (String) -> Void, openRows: Set<String> = [], showFinished: Bool = false) {
        self.board = board
        self.seen = seen
        self.open = open
        _openRows = State(initialValue: openRows)
        _showFinished = State(initialValue: showFinished)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let lanes = LeadLanes.lanes(board, seen: seen)
            let finished = lanes.filter { $0.group == .finished }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lanes.filter { $0.group != .finished }) { lane in row(lane, now: context.date) }
                if !finished.isEmpty {
                    Button { showFinished.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(showFinished ? 90 : 0))
                            Text(Self.finishedTitle(finished)).font(.system(size: 11.5, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityHint(showFinished ? "Hides the finished tasks" : "Shows the finished tasks")
                    if showFinished {
                        ForEach(finished) { lane in row(lane, now: context.date) }
                    }
                }
            }
        }
    }

    /// "Merged (4)", "Merged (4) · Abandoned (1)".
    static func finishedTitle(_ finished: [LeadLane]) -> String {
        let merged = finished.filter { $0.task.status == .done }.count
        let abandoned = finished.count - merged
        return "Merged (\(merged))" + (abandoned > 0 ? " · Abandoned (\(abandoned))" : "")
    }

    private func row(_ lane: LeadLane, now: Date) -> some View {
        LaneRow(lane: lane, now: now, isOpen: openRows.contains(lane.id), canOpen: { seen[$0] != nil }, open: open) {
            if openRows.contains(lane.id) { openRows.remove(lane.id) } else { openRows.insert(lane.id) }
        }
    }
}
