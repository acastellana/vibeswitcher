import Foundation
import Testing
@testable import VibeCore

/// Settings › Project lead's "Ignore usage limits" (`MacLimits.ignoreUsageLimits`, 2026-11-07, the user: "a setting to
/// disable worrying about quota"): no start held at 80 % of a Claude limit, no Boost veto, agent: auto on Claude unless
/// Claude refused at a reached limit, and the usage still shown, marked "(limits ignored)". Fake sessions and the
/// scratch vault's usage file only.

extension AccountUsageTests {
    @Test func ignoringUsageLimitsStartsAWorkerAndAnAuditAtEightyPercentWithNoOverride() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime, at: Self.now)
        var ignoring = true
        lead.macLimits = { MacLimits(maxSessions: 6, ignoreUsageLimits: ignoring) }
        for title in ["One", "Two", "Three"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        recordStatusLine(weekly: 91)
        let one = call(lead, "start_worker", ["task": "one"])
        #expect(!one.isError, "\(one.text)")
        let audited = call(lead, "audit", ["task": "one"])
        #expect(!audited.isError, "\(audited.text)")
        // Off again: refused as before, override_usage still overriding.
        ignoring = false
        let refused = call(lead, "start_worker", ["task": "two"])
        #expect(refused.isError && refused.text.contains("Not started: the account's usage is near a limit, the weekly limit (every model): 91% used")
                && refused.text.contains("override_usage: true") && !refused.text.contains("Ignore usage limits"), "\(refused.text)")
        #expect(!call(lead, "start_worker", ["task": "two", "override_usage": true]).isError)
        // On, but Claude refused a request at a limit: that one still holds, and says why.
        ignoring = true
        usageStore.record([AccountUsage.Limit(name: "five_hour", usedPercent: 100, resetsAt: Self.tomorrow, at: Self.now.timeIntervalSince1970, reached: true)],
                          now: Self.now)
        let reached = call(lead, "start_worker", ["task": "three"])
        #expect(reached.isError && reached.text.contains("the 5-hour limit (every model): reached") && reached.text.contains("Ignore usage limits"),
                "\(reached.text)")
        #expect(runtime.spawned.count == 3)
    }

    @Test func ignoringUsageLimitsStatusShowsTheUsageMarkedLimitsIgnored() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime(), at: Self.now)
        var ignoring = true
        lead.macLimits = { MacLimits(maxSessions: 6, ignoreUsageLimits: ignoring) }
        recordStatusLine(weekly: 84)
        let on = call(lead, "status").text
        #expect(on.contains("Account usage (limits ignored)") && on.contains("the weekly limit (every model): 84% used")
                && on.contains("Ignore usage limits in Settings") && !on.contains("override_usage: true overrides"), "\(on)")
        ignoring = false
        let off = call(lead, "status").text
        #expect(!off.contains("(limits ignored)") && off.contains("override_usage: true overrides"), "\(off)")
    }

    /// The status line's own words, with no status line of the user's: marked while the setting is on.
    @Test func ignoringUsageLimitsMarksTheStatusLinesUsage() throws {
        let input = Data(Self.statusLine(weekly: 84, resets: Self.tomorrow).utf8)
        var shown: [String] = []
        for ignored in [true, false] {
            UsageStatusLine.run(input: input, store: usageStore, home: temp.url("no-home").path, now: Self.now, ignored: ignored) {
                shown.append(String(decoding: $0, as: UTF8.self))
            }
        }
        #expect(shown == ["5h 12% · weekly 84% (limits ignored)", "5h 12% · weekly 84%"], "\(shown)")
    }

    @Test func ignoringUsageLimitsIsKeptInMacLimitsJsonOffByDefault() throws {
        let file = temp.url("limits").appendingPathComponent("mac-limits.json")
        #expect(MacLimits.load(from: file).ignoreUsageLimits == false)
        try MacLimits(maxSessions: 4, ignoreUsageLimits: true).save(to: file)
        #expect(MacLimits.load(from: file) == MacLimits(maxSessions: 4, ignoreUsageLimits: true))
        // A file from before the setting: off.
        try Data(#"{"maxSessions":4}"#.utf8).write(to: file)
        #expect(MacLimits.load(from: file).ignoreUsageLimits == false && MacLimits.load(from: file).maxSessions == 4)
        // Kept while boosted.
        let boost = BoostState(on: true, why: "on", limits: BoostLimits(), favored: nil, at: Self.now.timeIntervalSince1970)
        #expect(MacLimits(ignoreUsageLimits: true).boosted(by: boost).ignoreUsageLimits)
    }

    @Test func ignoringUsageLimitsLiftsBoostsUsageVeto() {
        let usage = AccountUsage(limits: [AccountUsage.Limit(name: "seven_day", usedPercent: 85, resetsAt: Self.tomorrow, at: Self.now.timeIntervalSince1970)])
        #expect(Boost.veto(usage, now: Self.now)?.usedPercent == 85)
        #expect(Boost.veto(usage, now: Self.now, ignoring: true) == nil)
        let veto = Boost.veto(usage, now: Self.now, ignoring: true)
        #expect(Boost.decide(mode: .on, onAC: true, away: false, veto: veto, now: Self.now) == (true, "on in Settings, on AC"))
    }
}

extension LeadAdvanceTests {
    @Test func ignoringUsageLimitsAutoAdvanceStartsAPlannedTaskAtEightyPercent() throws {
        let (root, _, lead) = try team()
        let now = AccountUsageTests.now
        lead.usageClock = { now }
        lead.macLimits = { MacLimits(maxSessions: 6, ignoreUsageLimits: true) }
        let input = #"{"rate_limits":{"seven_day":{"used_percentage":91,"resets_at":\#(AccountUsageTests.tomorrow)}}}"#
        UsageStatusLine.run(input: Data(input.utf8), store: usageStore, home: temp.url("no-home").path, now: now, ignored: true) { _ in }
        #expect(lead.usageHold(model: nil, sessions: nil) == nil)
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "First", "goal": "g", "acceptance": ["a"]])
        #expect(advancing.until { task("first", root)?.status == .running })
    }
}

extension LeadAdvanceTests {
    /// The blind check's case: work auto_advance already holds at 85 % starts once the setting is turned on and the
    /// app nudges the lead (`LeadController.nudgeLeads`), not at the limit's reset.
    @Test func ignoringUsageLimitsTurnedOnReleasesWhatAutoAdvanceHolds() throws {
        let (root, runtime, lead) = try team()
        let now = AccountUsageTests.now
        lead.usageClock = { now }
        lead.usageWake = { _, _ in }
        let ignoring = Flag()
        lead.macLimits = { MacLimits(maxSessions: 6, ignoreUsageLimits: ignoring.value) }
        let input = #"{"rate_limits":{"seven_day":{"used_percentage":85,"resets_at":\#(AccountUsageTests.tomorrow)}}}"#
        UsageStatusLine.run(input: Data(input.utf8), store: usageStore, home: temp.url("no-home").path, now: now, ignored: false) { _ in }
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "First", "goal": "g", "acceptance": ["a"]])
        #expect(advancing.until { reports(runtime).contains { $0.contains("The account's usage is near a limit") } }, "\(reports(runtime))")
        advancing.settle()
        #expect(task("first", root)?.status == .planned)
        ignoring.value = true
        LeadAdvance.nudge(root: root)
        #expect(advancing.until { task("first", root)?.status == .running })
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return on }
            set { lock.lock(); on = newValue; lock.unlock() }
        }
    }
}

extension UsageRoutingTests {
    @Test func ignoringUsageLimitsAutoPicksClaudeUnlessClaudeRefusedAtALimit() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let weekly = AccountUsage.Limit(name: "seven_day", usedPercent: 84, resetsAt: 1_000_000 + 0.4 * 604_800, at: 999_000)
        let room = CodexReading.known(CodexUsage(windows: [.init(usedPercent: 40, windowMinutes: 10080, resetsAt: 1_100_000)], at: 999_000))
        let tight = AccountUsage(limits: [weekly])
        #expect(UsageRouting.route(claude: tight, codex: room, model: nil, now: now).agent == .codex)
        let ignored = UsageRouting.route(claude: tight, codex: room, model: nil, ignoringLimits: true, now: now)
        #expect(ignored.agent == .claude && ignored.why.contains("Claude weekly 84%") && ignored.why.contains("(limits ignored)"), "\(ignored.why)")
        let refused = AccountUsage(limits: [weekly, AccountUsage.Limit(name: "five_hour", usedPercent: 100, resetsAt: 1_010_000, at: 999_500, reached: true)])
        let routed = UsageRouting.route(claude: refused, codex: room, model: nil, ignoringLimits: true, now: now)
        #expect(routed.agent == .codex && routed.why.contains("Claude 5-hour reached"), "\(routed.why)")

        // Through start_worker: an auto task at 84 % starts on Claude with no override.
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try routingLead(root, runtime)
        lead.macLimits = { MacLimits(maxSessions: 6, ignoreUsageLimits: true) }
        claudeWeekly(84, gone: 0.6)
        try codexWeekly(40)
        _ = lead.call("add_task", ["title": "Routed", "goal": "g", "acceptance": ["a"], "agent": "auto"])
        let started = lead.call("start_worker", ["task": "routed"])
        #expect(!started.isError && started.text.contains("so it went to Claude: Claude weekly 84%"), "\(started.text)")
        #expect(runtime.agents[try #require(runtime.spawned.last).id] == "claude")
    }
}
