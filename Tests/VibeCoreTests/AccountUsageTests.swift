import Foundation
import Testing
@testable import VibeCore

/// The account's usage limits (see `AccountUsage`), read from what Claude Code writes, and the lead's tools backing
/// off near them: 2026-10-31 a worker stalled at the weekly limit, 2026-11-01 every audit stopped at the Fable limit.
/// On fake sessions only; the lines below are as Claude Code 2.1.306–2.1.316 wrote them (ids and paths left out).
struct AccountUsageTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    /// A verifier's last turn, 2026-11-01 04:32: Fable's weekly allowance spent, the account's weekly limit not.
    static let fableRefusal = """
    {"isSidechain":false,"type":"assistant","timestamp":"2026-11-01T04:32:20Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git diff main...HEAD --stat"}}]}}
    {"isSidechain":false,"type":"user","timestamp":"2026-11-01T04:32:21Z","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":" 3 files changed","is_error":false}]}}
    {"parentUuid":"a1","isSidechain":false,"type":"assistant","timestamp":"2026-11-01T04:32:26.222Z","message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","content":[{"type":"text","text":"You've reached your Fable limit. Run /usage-credits to continue or switch models with /model."}]},"apiError":"model_requires_usage_credits","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1793876400,"rateLimitType":"seven_day_overage_included","overageStatus":"rejected","overageDisabledReason":"org_level_disabled","isUsingOverage":false}},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}

    """

    /// A worker's last turn, 2026-10-21: the account's weekly limit.
    static let weeklyRefusal = """
    {"isSidechain":false,"type":"assistant","timestamp":"2026-10-21T16:40:37.759Z","message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","content":[{"type":"text","text":"You've hit your weekly limit · resets Oct 25 at 1am (Europe/Madrid)"}]},"apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1792666800,"rateLimitType":"seven_day","overageStatus":"rejected","isUsingOverage":false}},"quotaLimits":{"status":"rejected","resetsAt":1792666800,"unifiedRateLimitFallbackAvailable":false,"rateLimitType":"seven_day","overageStatus":"rejected"},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}

    """

    /// A status line's input as Claude Code 2.1.316 documents it, its usage windows only.
    static func statusLine(weekly: Double, fiveHour: Double = 12, resets: Double) -> String {
        #"{"session_id":"s","model":{"id":"claude-opus-5-5","display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":\#(fiveHour),"resets_at":\#(resets - 3600)},"seven_day":{"used_percentage":\#(weekly),"resets_at":\#(resets)}}}"#
    }

    /// `AccountUsage.fromRefusal`, as an optional whatever it returns.
    func refusal(_ limit: UsageLimit, model: String?) -> AccountUsage.Limit? { AccountUsage.fromRefusal(limit, model: model) }

    func tail(_ lines: String) throws -> UsageLimit {
        let file = temp.url("transcript-\(UUID().uuidString).jsonl")
        try lines.write(to: file, atomically: true, encoding: .utf8)
        return try #require(TranscriptTail.read(url: file)?.usageLimit, "no usage limit read")
    }

    func repo() throws -> String {
        let url = temp.url("usage")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// The status line's reading kept, as a role session's status line keeps it.
    func recordStatusLine(weekly: Double, resets: Double = Date().timeIntervalSince1970 + 86_400) {
        _ = UsageStatusLine.run(input: Data(Self.statusLine(weekly: weekly, resets: resets).utf8), store: usageStore, home: temp.url("no-home").path)
    }

    // MARK: Reading

    @Test func refusalsAreReadFromTranscriptsPerModelOrForEveryModel() throws {
        let fable = try tail(Self.fableRefusal)
        #expect(fable.kind == "seven_day_overage_included" && fable.apiError == "model_requires_usage_credits" && fable.resetsAt == 1793876400)
        // Only the model that ran out: the session's own.
        let held = try #require(refusal(fable, model: "fable"))
        #expect(held.model == "fable" && held.usedPercent == 100 && held.reached && held.resetsAt == 1793876400)
        let weekly = try tail(Self.weeklyRefusal)
        #expect(weekly.kind == "seven_day" && weekly.apiError == "usage_limit_reached")
        // The account's weekly limit: every model, whatever the session ran.
        #expect(refusal(weekly, model: "fable")?.model == nil)
        #expect(refusal(weekly, model: nil)?.model == nil)
        // A type that names a model holds that model back.
        #expect(refusal(UsageLimit(said: "x", kind: "seven_day_opus"), model: nil)?.model == "opus")
        // A model-only refusal whose model isn't known (Claude's default) is no usage known, never every model.
        #expect(refusal(fable, model: nil) == nil)
    }

    @Test func theStatusLinesWindowsAreTheAccountsAndUnknownUsageHoldsNothingBack() throws {
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let input = try #require(try JSONSerialization.jsonObject(with: Data(Self.statusLine(weekly: 81.5, resets: 1_793_600_000).utf8)) as? [String: Any])
        let limits = AccountUsage.fromStatusLine(input, now: now)
        #expect(limits.map(\.name) == ["five_hour", "seven_day"] && limits.allSatisfy { $0.model == nil })
        let usage = AccountUsage(limits: limits)
        #expect(usage.hold(model: "sonnet", now: now)?.name == "seven_day")
        #expect(usage.hold(model: nil, now: now)?.name == "seven_day")
        // Under 80 %: nothing held back.
        #expect(AccountUsage(limits: limits.map { var limit = $0; limit.usedPercent = 79.9; return limit }).hold(model: "fable", now: now) == nil)
        // Past its reset: not known any more, nothing held back.
        #expect(usage.hold(model: "fable", now: Date(timeIntervalSince1970: 1_793_600_001)) == nil)
        // No windows (an API key, before the first reply), or no reading at all: nothing.
        #expect(AccountUsage.fromStatusLine(["model": ["id": "x"]], now: now).isEmpty)
        #expect(AccountUsage().hold(model: "fable", now: now) == nil)
        // A file that isn't the store's: no usage known.
        try FileManager.default.createDirectory(at: usageStore.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: usageStore.file, atomically: true, encoding: .utf8)
        #expect(usageStore.load().limits.isEmpty)
        // A model's own limit holds back only that model's family.
        let fable = AccountUsage(limits: [AccountUsage.Limit(name: "seven_day_overage_included", model: "fable", usedPercent: 100,
                                                             resetsAt: 1_793_600_000, at: now.timeIntervalSince1970, reached: true)])
        #expect(fable.hold(model: "claude-fable-5-1", now: now) != nil && fable.hold(model: "opus", now: now) == nil && fable.hold(model: nil, now: now) == nil)
    }

    @Test func theStatusLineKeepsTheUsageAndShowsTheUsersOwnStatusLine() throws {
        let home = temp.url("home").path
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        // Your own status line: it gets the same input.
        let settings = #"{"statusLine":{"type":"command","command":"grep -o '\"seven_day\"' | head -1; echo mine"}}"#
        try settings.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        let resets = Date().timeIntervalSince1970 + 86_400
        let shown = UsageStatusLine.run(input: Data(Self.statusLine(weekly: 42, resets: resets).utf8), store: usageStore, home: home)
        #expect(shown == "\"seven_day\"\nmine\n", "\(shown)")
        #expect(usageStore.load().limits.first { $0.name == "seven_day" }?.usedPercent == 42)
        // None of yours: the usage, in a few words.
        let plain = UsageStatusLine.run(input: Data(Self.statusLine(weekly: 43, resets: resets).utf8), store: usageStore, home: temp.url("bare").path)
        #expect(plain == "5h 12% · weekly 43%", "\(plain)")
        // An older reading never replaces a newer one.
        usageStore.record([AccountUsage.Limit(name: "seven_day", usedPercent: 10, resetsAt: resets, at: Date().timeIntervalSince1970 - 600)])
        #expect(usageStore.load().limits.first { $0.name == "seven_day" }?.usedPercent == 43)
        // Not JSON: nothing kept, nothing fails.
        #expect(UsageStatusLine.run(input: Data("garbage".utf8), store: usageStore, home: temp.url("bare").path) == "")
    }

    @Test func everyRolesSessionGetsTheUsageStatusLine() throws {
        let root = try repo()
        let prepared = try LeadLaunch.prepare(role: .worker, root: root, task: "t", base: "claude", prompt: "p", start: "s",
                                              server: "/App/vibeswitcher-mcp", name: "worker-t", folder: temp.url("run"), cwd: root,
                                              temporary: temp.url("tmp"))
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: prepared.settingsFile))) as? [String: Any])
        let line = try #require(settings["statusLine"] as? [String: Any])
        #expect(line["command"] as? String == "'/App/vibeswitcher-mcp' --status-line")
    }

    // MARK: The lead's tools

    @Test func statusShowsTheUsageWhenKnownAndNothingWhenNot() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(!call(lead, "status").text.contains("Account usage"))
        recordStatusLine(weekly: 62)
        let text = call(lead, "status").text
        #expect(text.contains("Account usage") && text.contains("the weekly limit (every model): 62% used, resets ")
                && text.contains("the 5-hour limit (every model): 12% used"), "\(text)")
    }

    @Test func atEightyPercentOfTheWeeklyLimitNoWorkerStartsUnlessTheLeadOverrides() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        recordStatusLine(weekly: 79)
        _ = call(lead, "add_task", ["title": "Two", "goal": "g", "acceptance": ["a"]])
        #expect(!call(lead, "start_worker", ["task": "one"]).isError)
        recordStatusLine(weekly: 84)
        let refused = call(lead, "start_worker", ["task": "two"])
        #expect(refused.isError && refused.text.contains("Not started: the account's usage is near a limit, the weekly limit (every model): 84% used, resets ")
                && refused.text.contains("override_usage: true"), "\(refused.text)")
        #expect(runtime.spawned.count == 1)
        let status = call(lead, "status").text
        #expect(status.contains("84% used"), "\(status)")
        let forced = call(lead, "start_worker", ["task": "two", "override_usage": true])
        #expect(!forced.isError, "\(forced.text)")
        #expect(runtime.spawned.count == 2)
    }

    @Test func aVerifierStoppedAtTheFableLimitHoldsBackFableAuditsNotASonnetWorker() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        _ = call(lead, "add_task", ["title": "Three", "goal": "g", "acceptance": ["a"], "model": "sonnet"])
        #expect(!call(lead, "start_worker", ["task": "one"]).isError)
        #expect(!call(lead, "start_worker", ["task": "two"]).isError)
        // Audits run on fable here (the workers' model is Claude's default).
        #expect(lead.auditModel(lead.workflow) == "fable")
        #expect(!call(lead, "audit", ["task": "one"]).isError)
        let verifier = try #require(BoardStore(root: root).load().task("one")?.verifier)
        // Its transcript's last line, as the host reads it: the Fable limit.
        runtime.usageLimits[verifier] = try tail(Self.fableRefusal)
        let status = call(lead, "status").text
        #expect(status.contains("the fable limit (seven_day_overage_included): reached (Claude refused a request at it)"), "\(status)")
        let refused = call(lead, "audit", ["task": "two"])
        #expect(refused.isError && refused.text.contains("Not audited, no verifier started: the account's usage is near a limit, the fable limit")
                && refused.text.contains("configure verifier_model"), "\(refused.text)")
        // Kept: once the verifier has gone, the limit still holds until its reset.
        runtime.usageLimits = [:]
        try runtime.kill(verifier)
        #expect(call(lead, "audit", ["task": "two"]).isError)
        // A worker on sonnet isn't held back by Fable's limit.
        let sonnet = call(lead, "start_worker", ["task": "three"])
        #expect(!sonnet.isError, "\(sonnet.text)")
        // The lead overrides.
        #expect(!call(lead, "audit", ["task": "two", "override_usage": true]).isError)
    }

    /// The blind check's case: the lead moves audits to opus after a verifier stopped at the Fable limit, the stopped
    /// verifier still live. Its refusal holds back fable, the model it was started on, never the new verifier_model.
    @Test func movingAuditsToAnotherModelAfterTheFableLimitLetsThemStart() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        #expect(!call(lead, "start_worker", ["task": "one"]).isError)
        #expect(!call(lead, "start_worker", ["task": "two"]).isError)
        #expect(!call(lead, "audit", ["task": "one"]).isError)
        let verifier = try #require(BoardStore(root: root).load().task("one")?.verifier)
        runtime.usageLimits[verifier] = try tail(Self.fableRefusal)
        #expect(call(lead, "audit", ["task": "two"]).isError)
        #expect(!call(lead, "configure", ["verifier_model": "opus"]).isError)
        let moved = call(lead, "audit", ["task": "two"])
        #expect(!moved.isError, "\(moved.text)")
        #expect(!usageStore.load().limits.contains { $0.model == "opus" }, "\(usageStore.load().limits)")
        // Fable stays held back.
        #expect(usageStore.load().current().hold(model: "fable") != nil)
    }

    /// The blind check's case: a worker on Claude's default model (not known here) stopped at a model-only limit holds
    /// nothing back: unknown usage is no back-off, and kept for every model it would stop every start.
    @Test func aModelOnlyRefusalOnAnUnknownModelHoldsNothingBack() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        #expect(!call(lead, "start_worker", ["task": "one"]).isError)
        let worker = try #require(BoardStore(root: root).load().task("one")?.worker)
        runtime.usageLimits[worker] = try tail(Self.fableRefusal)
        let started = call(lead, "start_worker", ["task": "two"])
        #expect(!started.isError, "\(started.text)")
        #expect(usageStore.load().limits.isEmpty, "\(usageStore.load().limits)")
    }

    @Test func aTasksModelGoesToItsWorkersCommandAndTheDefaultIsUnchanged() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let added = call(lead, "add_task", ["title": "Mechanical", "goal": "g", "acceptance": ["a"], "model": "sonnet"])
        #expect(added.text.contains("Its worker runs on sonnet."), "\(added.text)")
        _ = call(lead, "add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"]])
        #expect(BoardStore(root: root).load().task("mechanical")?.model == "sonnet")
        #expect(BoardStore(root: root).load().task("plain")?.model == nil)
        #expect(!call(lead, "start_worker", ["task": "mechanical"]).isError)
        #expect(!call(lead, "start_worker", ["task": "plain"]).isError)
        let commands = runtime.spawned.map(\.command)
        #expect(commands[0].contains("--model 'sonnet'"), "\(commands[0])")
        #expect(!commands[1].contains("--model"), "\(commands[1])")
        // update_task changes it, and empty clears it.
        #expect(!call(lead, "update_task", ["task": "plain", "model": "claude-haiku-5-5"]).isError)
        #expect(BoardStore(root: root).load().task("plain")?.model == "claude-haiku-5-5")
        #expect(!call(lead, "update_task", ["task": "plain", "model": ""]).isError)
        #expect(BoardStore(root: root).load().task("plain")?.model == nil)
        // Anything that isn't one model name is refused, before it reaches a command line.
        let bad = call(lead, "update_task", ["task": "plain", "model": "sonnet; rm -rf ~"])
        #expect(bad.isError && bad.text.contains("Nothing was changed"), "\(bad.text)")
        #expect(call(lead, "add_task", ["title": "Odd", "goal": "g", "acceptance": ["a"], "model": "a b"]).isError)
    }

    func call(_ tools: LeadToolset, _ name: String, _ arguments: [String: Any] = [:]) -> MCPToolResult { tools.call(name, arguments) }
}

extension LeadAdvanceTests {
    /// auto_advance starts nothing near a limit, and tells the lead once, with the reset time; once the window has
    /// reset (a new reading under 80 %), the tasks start.
    @Test func nearALimitAutoAdvanceStartsNothingAndTellsTheLeadOnce() throws {
        let (root, runtime, lead) = try team()
        let resets = Date().timeIntervalSince1970 + 86_400
        let status = { (weekly: Double) in
            #"{"rate_limits":{"seven_day":{"used_percentage":\#(weekly),"resets_at":\#(resets)}}}"#
        }
        _ = UsageStatusLine.run(input: Data(status(91).utf8), store: usageStore, home: temp.url("no-home").path)
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "First", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("add_task", ["title": "Second", "goal": "g", "acceptance": ["a"]])
        let told = { reports(runtime).filter { $0.contains("The account's usage is near a limit: the weekly limit (every model): 91% used, resets ") } }
        #expect(advancing.until { !told().isEmpty }, "\(reports(runtime))")
        advancing.settle()
        LeadAdvance.nudge(root: root)
        advancing.settle()
        #expect(told().count == 1, "\(reports(runtime))")
        #expect(told().first?.contains("Tell the user") == true)
        #expect(task("first", root)?.status == .planned && task("second", root)?.status == .planned && runtime.spawned.isEmpty)
        // The next reading is under the threshold: they start.
        _ = UsageStatusLine.run(input: Data(status(30).utf8), store: usageStore, home: temp.url("no-home").path)
        LeadAdvance.nudge(root: root)
        #expect(advancing.until { task("first", root)?.status == .running && task("second", root)?.status == .running })
    }
}
