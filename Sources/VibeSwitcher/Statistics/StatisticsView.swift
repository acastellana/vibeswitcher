import AppKit
import SwiftUI
import VibeCore

/// The Statistics page: a range picker, the Mac-wide figures and a table of the projects with their totals. It only
/// shows `StatisticsModel`'s state: the stats are read and worked out off the main thread, never here.
struct StatisticsView: View {
    @ObservedObject var model: StatisticsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.state {
            case .loading:
                ProgressView("Loading statistics…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading statistics")
            case .loaded(let page):
                StatisticsPageView(page: page)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $model.range) {
                ForEach(StatisticsRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Range")
            .fixedSize()
            if case .loaded(let page) = model.state {
                Text(page.span).font(.callout).foregroundStyle(.secondaryInk).accessibilityLabel("From \(page.span)")
            }
            Spacer()
            Button("Refresh") { model.reload() }
                .controlSize(.small)
                .disabled(model.state == .loading)
                .help("Work the figures out again")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// The figures of one `StatisticsPage`, as Settings' grouped sections.
struct StatisticsPageView: View {
    let page: StatisticsPage

    var body: some View {
        Form {
            Section("This Mac") {
                ForEach(page.mac) { FigureRow(figure: $0) }
            }
            Section {
                ProjectTable(rows: page.projects, total: page.total)
            } header: {
                Text("Projects")
            } footer: {
                Text("Merges, audits and start-to-merge count tasks merged in the range; worker hours, cost and Codex share "
                     + "the tasks that ended in it. ≥: some of those tasks' cost isn't known. Not recorded: the data isn't kept on "
                     + "this Mac. –: nothing to count.")
                    .font(.caption).foregroundStyle(.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// One Mac-wide figure: its name, its value on the right, the line under it, and a usage bar when it has one.
private struct FigureRow: View {
    let figure: StatisticsPage.Figure

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(figure.label)
                if let detail = figure.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondaryInk).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if let meter = figure.meter {
                UsageMeter(meter: meter).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            Text(figure.value)
                .monospacedDigit()
                .foregroundStyle(figure.value == StatisticsPage.notRecorded ? .secondaryInk : .primary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(figure.spoken)
    }
}

/// A usage limit's small bar: used, with a mark where the window's time has got to (on pace at the mark).
private struct UsageMeter: View {
    let meter: StatisticsPage.Meter
    static let width: CGFloat = 120

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(meter.reached ? Color.red : meter.used > (meter.elapsed ?? 1) ? Color.orange : Color.accentColor)
                .frame(width: Self.width * meter.used)
            if let elapsed = meter.elapsed {
                Rectangle().fill(.secondary).frame(width: 1.5, height: 10).offset(x: Self.width * elapsed - 0.75)
            }
        }
        .frame(width: Self.width, height: 6)
        // a11y: the row's label says the percentage and the pace.
        .accessibilityHidden(true)
    }
}

/// The projects, a column per figure, their totals last.
private struct ProjectTable: View {
    let rows: [StatisticsPage.ProjectRow]
    let total: StatisticsPage.ProjectRow?

    /// A column's title on two lines when it's two words or more, so the columns stay narrow.
    static func header(_ column: String) -> String {
        switch column {
        case "Audits · rounds": return "Audits ·\nrounds"
        case "Median to merge": return "Median\nto merge"
        default: return column.replacingOccurrences(of: " ", with: "\n")
        }
    }

    var body: some View {
        if rows.isEmpty {
            Text("No project with a board").foregroundStyle(.secondaryInk)
        } else {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow(alignment: .bottom) {
                    Text("Project").gridColumnAlignment(.leading)
                    ForEach(StatisticsPage.columns, id: \.self) {
                        Text(Self.header($0)).multilineTextAlignment(.trailing).fixedSize()
                    }
                }
                .font(.caption).foregroundStyle(.secondaryInk)
                .accessibilityHidden(true)
                Divider()
                ForEach(rows) { ProjectGridRow(row: $0) }
                if let total {
                    Divider()
                    ProjectGridRow(row: total).fontWeight(.semibold)
                }
            }
        }
    }
}

private struct ProjectGridRow: View {
    let row: StatisticsPage.ProjectRow

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1)
                if let note = row.note { Text(note).font(.caption2).foregroundStyle(.secondaryInk).lineLimit(1).help(note) }
            }
            .frame(minWidth: 130, maxWidth: 170, alignment: .leading)
            if row.cells.allSatisfy({ $0 == StatisticsPage.notRecorded }) {
                // A board that can't be read: said once, across the row.
                Text(StatisticsPage.notRecorded).foregroundStyle(.secondaryInk)
                    .gridCellColumns(row.cells.count).gridCellAnchor(.leading)
            } else {
                ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                    Text(cell)
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(cell == StatisticsPage.notRecorded ? .secondaryInk : .primary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }
}

/// The Statistics window: one for the app, its stats worked out again each time it's shown.
final class StatisticsWindowController: NSWindowController, NSWindowDelegate {
    static let size = CGSize(width: 980, height: 640)
    let model: StatisticsModel

    init(model: StatisticsModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Statistics"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Statistics")
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: StatisticsView(model: model))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        if window?.isVisible != true { model.reload() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) { model.stop() }
}
