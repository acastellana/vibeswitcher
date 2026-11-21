import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// `stats` (the parity table's Statistics row, 2026-11-21): the Mac's Statistics window from the node. The Mac's own
/// collector over the impact-metrics fixtures (a project and a VibeSwitcher home laid out as the Mac's tests lay them
/// out), worded as the Mac's window words them, is what the schema says; a range out of form is refused; the projects
/// counted are the node's.
struct StatsTests {
    private let scratch = Scratch()
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = repo.appendingPathComponent("Tests/Fixtures/impact-metrics")
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func layout() throws -> (project: URL, home: URL) {
        let root = scratch.url("stats")
        let project = root.appendingPathComponent("proj"), home = root.appendingPathComponent("home")
        let fm = FileManager.default
        let board = project.appendingPathComponent(".vibeswitcher"), lead = project.appendingPathComponent("docs/lead")
        for folder in [board, lead, home] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        for name in ["board.json", "board-archive.jsonl"] { try fm.copyItem(at: Self.fixtures.appendingPathComponent(name), to: board.appendingPathComponent(name)) }
        for name in ["progress.md", "incidents.md"] { try fm.copyItem(at: Self.fixtures.appendingPathComponent(name), to: lead.appendingPathComponent(name)) }
        for name in ["stats", "debug"] { try fm.copyItem(at: Self.fixtures.appendingPathComponent(name), to: home.appendingPathComponent(name)) }
        return (project, home)
    }

    @Test func theFixturesStatisticsAreWhatTheSchemaSays() async throws {
        let (project, home) = try layout()
        let day = Self.utc.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        let collector = SetupStatsCollector(home: home, codexHome: nil, calendar: Self.utc, now: { day.addingTimeInterval(86_000) })
        let stats = await collector.collect(projects: [project.path], range: DateInterval(start: day, end: day.addingTimeInterval(86_400)))
        let page = StatisticsPage(stats, calendar: Self.utc)
        let value = StatisticsWire.value(page, range: .today)
        #expect(WireSchema.check(value, as: "stats.result", strict: true) == nil, "\(WireSchema.check(value, as: "stats.result", strict: true) ?? "")")
        let projects = try #require(value["projects"]?.array)
        #expect(projects.count == 1 && projects[0]["name"] == .string("proj") && projects[0]["cells"]?.array?.count == StatisticsPage.columns.count)
        #expect(value["mac"]?.array?.first?["label"] == .string("Load"))
        #expect(value["quality"] != .null)
        // The figures are the Mac's own words: the table's row is the window's.
        #expect(projects[0]["cells"]?.array?.compactMap(\.string) == page.projects[0].cells)
    }

    @Test func aMeterAndATrendAreSentAsIntegers() {
        let figure = StatisticsPage.Figure(label: "Claude weekly", value: "42%", detail: nil,
                                           meter: .init(used: 0.4234, elapsed: 1.7, reached: false), help: nil,
                                           trend: [.init(label: "Nov 7", value: 3.9, text: "3.9 an hour (94)"), .init(label: "Nov 8", value: nil, text: "not counted")])
        let value = StatisticsWire.figure(figure)
        #expect(value["meter"] == .object(["used": .int(423), "elapsed": .int(1000), "reached": .bool(false)]))
        #expect(value["trend"]?.array?.map { $0["value"] ?? .null } == [.int(3900), .null])
    }

    @Test func aRangeOutOfFormIsRefusedAndTheNodesProjectsAreCounted() async throws {
        let queue = DispatchQueue(label: "engine")
        let link = HostLink(dialer: NoHost(), root: scratch.url("link-root"), queue: queue)
        let requests = Requests(link: link, sessions: nil, rule: VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's"),
                                root: scratch.url("node-root"), hostSocket: "/nonexistent/host.sock", commit: "abc123", hostPID: 1)
        func ask(_ args: [String: NodeWire.Value]) async -> NodeWire.Reply {
            await withCheckedContinuation { continuation in
                queue.async { requests.stats(NodeWire.Request(id: "1", kind: "stats", args: args)) { continuation.resume(returning: $0) } }
            }
        }
        let refused = await ask(["range": .string("year")])
        #expect(refused.error?.code == NodeWire.Code.badArgs.rawValue)
        let week = await ask([:])
        #expect(week.ok && week.result?["range"] == .string("week") && week.result?["projects"] == .array([]), "\(week)")
        #expect(WireSchema.check(week.result ?? .null, as: "stats.result", strict: true) == nil)
        #expect(queue.sync { requests.statsProjects() }.isEmpty)
    }

    private struct NoHost: HostDialer {
        func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw HostLink.Failure("no host in this test") }
    }
}

/// `vibeswitcher stats` as it prints (`StatisticsText`), and end to end on a scratch node.
struct StatsTextTests {
    private let scratch = Scratch()

    @Test func theFixturesStatisticsPrintAsTheWindowWordsThem() async throws {
        let home = scratch.url("empty-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let stats = await SetupStatsCollector(home: home, codexHome: nil, calendar: StatsTests.utc)
            .collect(projects: [], range: DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 86_400))
        let page = StatisticsPage(stats, calendar: StatsTests.utc)
        let empty = StatisticsText.lines(StatisticsWire.value(page, range: .today))
        #expect(empty.first?.hasPrefix("Statistics · Today · ") == true, "\(empty)")
        #expect(empty.contains("This node") && empty.contains("  Load: Not recorded") && empty.contains("  No project with a lead's board on this node yet."), "\(empty)")
        // A usage limit with its bar, a table in columns.
        let meter = StatisticsText.figure(.object(["label": .string("Claude weekly"), "value": .string("42%"), "detail": .string("on pace"),
                                                   "meter": .object(["used": .int(420), "elapsed": .null, "reached": .bool(false)])]))
        #expect(meter == ["  Claude weekly: 42% [########............] — on pace"])
        #expect(StatisticsText.table(["Project", "Merged"], [["site", "21"], ["api-long-name", "7"]])
                == ["  Project        Merged", "  site               21", "  api-long-name       7"])
        // A name with a terminal's escape in it is inert.
        let named = StatisticsText.lines(.object(["title": .string("7 days"), "span": .string("x"), "mac": .array([]), "columns": .array([]),
                                                  "projects": .array([.object(["id": .string("a"), "name": .string("evil\u{1B}[2J"), "note": .null, "cells": .array([])])]),
                                                  "total": .null, "quality": .null]))
        #expect(!named.joined().contains("\u{1B}"), "\(named)")
    }
}

@Suite(NodeTraits.linuxOnly)
struct StatsNodeTests {
    private let scratch = Scratch()

    @Test func statsPrintsAndGivesItsJSONOnAScratchNode() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let printed = try await node.run(["stats"])
        #expect(printed.status == 0 && printed.output.hasPrefix("Statistics · 7 days · "), "\(printed.output)\(printed.errors)")
        #expect(printed.output.contains("No project with a lead's board on this node yet."), "\(printed.output)")
        let json = try await node.run(["stats", "today", "--json"])
        let value = try #require(try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any], "\(json.output)\(json.errors)")
        #expect(value["range"] as? String == "today")
        let refused = try await node.run(["stats", "year"])
        #expect(refused.status != 0 && refused.errors.contains("usage: vibeswitcher stats"), "\(refused.errors)")
    }
}
