import SwiftUI
import VibeCore

/// The quality part of the Statistics page, as Form sections: quality, autonomy, where time goes and cost, the
/// breakdown by who did the work, the comparison with working solo (estimates), and the last 8 weeks.
struct QualitySectionsView: View {
    let page: QualityPage

    var body: some View {
        ForEach(page.sections) { section in
            Section(section.title) {
                ForEach(section.figures) { FigureRow(figure: $0) }
            }
        }
        Section {
            BreakdownTable(rows: page.breakdown)
        } header: {
            Text("By who did the work")
        } footer: {
            Text((page.modelsNote.map { $0 + ". " } ?? "") + "Codex: tasks a Codex worker worked on; models: the model a Claude worker was "
                 + "started on. Questions about no task count in the totals above only.")
                .font(.caption).foregroundStyle(.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        ComparedSectionView(page: page.compared)
        Section {
            HStack(alignment: .top, spacing: 32) {
                TrendChart(title: "First-audit pass rate", weeks: page.trend, value: \.passRate, bar: \.passBar)
                TrendChart(title: "Cost per merged task", weeks: page.trend, value: \.cost, bar: \.costBar)
            }
        } header: {
            Text("Last 8 weeks")
        } footer: {
            Text("A week a bar, the last ending today. –: no audited merge, or no merge with a known cost, that week.")
                .font(.caption).foregroundStyle(.secondaryInk)
        }
    }
}

/// Compared with working solo: its title marked an estimate, the method said under it on hover (shown from the start
/// with `methodShown`: the sandbox's shot of it), and a row per figure with a column for all merges, Claude's and Codex's.
struct ComparedSectionView: View {
    let page: ComparedPage
    var methodShown = false
    @State private var hovering = false

    var body: some View {
        Section {
            Grid(alignment: .topTrailing, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow(alignment: .bottom) {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(ComparedPage.columns, id: \.self) { Text($0) }
                }
                .font(.caption).foregroundStyle(.secondaryInk)
                .accessibilityHidden(true)
                ForEach(page.groups) { group in
                    Divider()
                    Text(group.title).font(.callout.weight(.semibold)).gridCellAnchor(.leading)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.rows) { row in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(row.label).frame(minWidth: 180, alignment: .leading).help(row.help)
                            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(cell.value).monospacedDigit()
                                        .foregroundStyle(cell.value == StatisticsPage.notRecorded ? .secondaryInk : .primary)
                                    if let detail = cell.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondaryInk).multilineTextAlignment(.trailing)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: 220, alignment: .trailing)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.spoken)
                        .accessibilityHint(row.help)
                    }
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(ComparedPage.title)
                    Text(ComparedPage.badge)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(.secondary))
                        .foregroundStyle(.secondaryInk)
                }
                if hovering || methodShown {
                    Text(ComparedPage.method).font(.caption).foregroundStyle(.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(ComparedPage.title), \(ComparedPage.badge.lowercased())")
            .accessibilityHint(ComparedPage.method)
            .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Per 100: per 100 merged tasks (those whose inputs are kept, where said). ≥: a part of the process's cost isn't recorded, "
                 + "so its share is at least this. The lead works for every agent: its cost is in All only.")
                .font(.caption).foregroundStyle(.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The breakdown: a row per agent (Claude's models indented under it), a column per figure.
private struct BreakdownTable: View {
    let rows: [QualityPage.BreakdownRow]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow(alignment: .bottom) {
                Text("Who").gridColumnAlignment(.leading)
                ForEach(Array(QualityPage.columns.enumerated()), id: \.offset) { index, column in
                    Text(column.replacing(" ", with: "\n", maxReplacements: 1)).multilineTextAlignment(.trailing).fixedSize()
                        .help(QualityPage.columnHelp[index])
                }
            }
            .font(.caption).foregroundStyle(.secondaryInk)
            .accessibilityHidden(true)
            Divider()
            ForEach(rows) { row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(row.name).lineLimit(1).padding(.leading, row.model ? 14 : 0)
                        .foregroundStyle(row.model ? .secondaryInk : .primary)
                        .frame(minWidth: 90, alignment: .leading)
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        Text(cell).monospacedDigit().fixedSize()
                            .foregroundStyle(cell == StatisticsPage.notRecorded ? .secondaryInk : .primary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.spoken)
            }
        }
    }
}

/// One measure's 8 weeks: a thin bar a week from a shared baseline, its value under it; hover says the week.
private struct TrendChart: View {
    let title: String
    let weeks: [QualityPage.TrendWeek]
    let value: KeyPath<QualityPage.TrendWeek, String>
    let bar: KeyPath<QualityPage.TrendWeek, Double?>
    static let height: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(weeks) { week in
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(.quaternary).frame(width: 18, height: 1)
                            if let height = week[keyPath: bar] {
                                UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                    .fill(Color.accentColor)
                                    .frame(width: 18, height: max(2, Self.height * height))
                            }
                        }
                        .frame(height: Self.height, alignment: .bottom)
                        Text(week[keyPath: value]).font(.caption2).monospacedDigit().foregroundStyle(.primary).fixedSize()
                        Text(week.label).font(.caption2).foregroundStyle(.secondaryInk).fixedSize()
                    }
                    .frame(minWidth: 36)
                    .help(week.spoken)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(title), week of \(week.label): \(week[keyPath: value]), \(week.merged) merged")
                }
            }
        }
    }
}
