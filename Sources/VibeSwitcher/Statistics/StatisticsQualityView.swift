import SwiftUI
import VibeCore

/// The quality part of the Statistics page, as Form sections: quality, autonomy, where time goes and cost, the
/// breakdown by who did the work, and the last 8 weeks. A section comparing with working solo (plain Claude Code and
/// Codex runs) goes after the breakdown, once those runs are recorded.
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
