import Foundation
import VibeCore

/// `stats` (the parity table's Statistics row, 2026-11-21): the Mac's Statistics window from the node, read-only. The
/// node's projects (each lead's root, every session's folder and its start folder, the ended sessions' folders: the
/// collector keeps those with a board, a worktree as its repository) worked out by the Mac's own collector
/// (`SetupStatsCollector`, over the node's root, where its stats, Boost and account usage are kept) for today, 7 or 30
/// days, and worded as the Mac's window words them (`StatisticsPage`, copied). A read: anyone of the uid, a page that
/// reads; nothing changes. One collector a server, so a file unchanged is parsed once.
extension Requests {
    func stats(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let word = request.args?["range"]?.string ?? StatisticsRange.week.rawValue
        guard let range = StatisticsRange(rawValue: word) else {
            return reply(.init(re: request.id, error: .init(.badArgs, "stats' range is today, week or month")))
        }
        let projects = statsProjects()
        let collector = statsCollector
        let interval = range.interval(now: Date())
        let queue = self.queue
        collector.collect(projects: projects, range: interval) { stats in
            let value = StatisticsWire.value(StatisticsPage(stats), range: range)
            queue.async { reply(.init(re: request.id, result: value)) }
        }
    }

    /// The folders whose projects are counted. On `queue`.
    func statsProjects() -> [String] {
        var folders: [String] = engine?.leads.leads.values.map(\.root) ?? []
        for session in sessions?.sessions ?? [] { folders += [session.cwd, session.startFolder].compactMap { $0 } }
        if case .array(let ended) = engine?.endedValue ?? .array([]) { folders += ended.compactMap { $0["folder"]?.string } }
        var seen: Set<String> = []
        return folders.map { ($0 as NSString).standardizingPath }.filter { seen.insert($0).inserted }
    }
}

/// A `StatisticsPage` as `stats` carries it: the Mac's words, its bars as per mille (0–1000) so the wire stays in ints.
enum StatisticsWire {
    static func value(_ page: StatisticsPage, range: StatisticsRange) -> NodeWire.Value {
        .object([
            "range": .string(range.rawValue), "title": .string(range.title), "span": .string(page.span),
            "mac": .array(page.mac.map(figure)),
            "columns": .array(StatisticsPage.columns.map(NodeWire.Value.string)),
            "projects": .array(page.projects.map(row)),
            "total": page.total.map(row) ?? .null,
            "quality": page.quality.map(quality) ?? .null,
        ])
    }

    static func permille(_ value: Double) -> NodeWire.Value { .int(Int((min(1, max(0, value)) * 1000).rounded())) }

    static func text(_ value: String?) -> NodeWire.Value { value.map(NodeWire.Value.string) ?? .null }

    static func figure(_ figure: StatisticsPage.Figure) -> NodeWire.Value {
        .object([
            "label": .string(figure.label), "value": .string(figure.value), "detail": text(figure.detail), "help": text(figure.help),
            "meter": figure.meter.map { meter in
                .object(["used": permille(meter.used), "elapsed": meter.elapsed.map(permille) ?? .null, "reached": .bool(meter.reached)])
            } ?? .null,
            "trend": .array((figure.trend ?? []).map { day in
                .object(["label": .string(day.label), "value": day.value.map { .int(Int(($0 * 1000).rounded())) } ?? .null, "text": .string(day.text)])
            }),
        ])
    }

    static func row(_ row: StatisticsPage.ProjectRow) -> NodeWire.Value {
        .object(["id": .string(row.id), "name": .string(row.name), "note": text(row.note), "cells": .array(row.cells.map(NodeWire.Value.string))])
    }

    static func quality(_ page: QualityPage) -> NodeWire.Value {
        .object([
            "sections": .array(page.sections.map { section in
                .object(["title": .string(section.title), "figures": .array(section.figures.map(figure))])
            }),
            "columns": .array(QualityPage.columns.map(NodeWire.Value.string)),
            "columnHelp": .array(QualityPage.columnHelp.map(NodeWire.Value.string)),
            "breakdown": .array(page.breakdown.map { row in
                .object(["name": .string(row.name), "model": .bool(row.model), "cells": .array(row.cells.map(NodeWire.Value.string))])
            }),
            "modelsNote": text(page.modelsNote),
            "trend": .array(page.trend.map { week in
                .object(["label": .string(week.label), "merged": .int(week.merged), "passRate": .string(week.passRate),
                         "passBar": week.passBar.map(permille) ?? .null, "cost": .string(week.cost), "costBar": week.costBar.map(permille) ?? .null])
            }),
            "compared": .object([
                "title": .string(ComparedPage.title), "badge": .string(ComparedPage.badge), "method": .string(ComparedPage.method),
                "columns": .array(ComparedPage.columns.map(NodeWire.Value.string)),
                "groups": .array(page.compared.groups.map { group in
                    .object(["title": .string(group.title), "rows": .array(group.rows.map { row in
                        .object(["label": .string(row.label), "help": .string(row.help),
                                 "cells": .array(row.cells.map { .object(["value": .string($0.value), "detail": text($0.detail)]) })])
                    })])
                }),
            ]),
        ])
    }
}
