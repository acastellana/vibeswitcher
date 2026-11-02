import Foundation
import Testing
@testable import VibeCore

/// Usage-aware worker routing (2026-11-02, the user: "if there's not a lot of quota I should be leveraging Codex much
/// more"): Codex's usage read from its rollouts (`CodexUsage`), each limit's pace, and a task marked `agent: auto`
/// starting on Codex when Claude's usage is tight and Codex has room (`UsageRouting`), else on Claude. Scratch Codex
/// homes with fake rollout files, fake sessions, and the scratch vault's own usage file: never the Mac's.
struct UsageRoutingTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    /// This test's Codex home (a scratch one: never the Mac's).
    let home: URL
    init() {
        vault = Self.newVault(in: temp)
        home = temp.url("codex-home")
    }

    // MARK: Fake rollouts

    static func window(_ used: Double, minutes: Int = 10080, resets: Double) -> String {
        #"{"used_percent":\#(used),"window_minutes":\#(minutes),"resets_at":\#(Int(resets))}"#
    }

    /// A `token_count` event as Codex 0.160 writes it, its limits given.
    static func event(primary: String?, secondary: String? = nil, credits: String = "null", id: String = #""codex""#,
                      reached: String = "null", at: String = "2026-11-02T06:33:46.148Z") -> String {
        #"{"timestamp":"\#(at)","ordinal":144,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}},"rate_limits":{"limit_id":\#(id),"limit_name":null,"primary":\#(primary ?? "null"),"secondary":\#(secondary ?? "null"),"credits":\#(credits),"individual_limit":null,"spend_control_reached":null,"plan_type":"pro","rate_limit_reached_type":\#(reached)}}}"#
    }

    static let otherEvent = #"{"timestamp":"2026-11-02T06:33:40.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#
    static let credits = #"{"has_credits":true,"unlimited":false,"balance":"36762.8687450000"}"#

    /// Another Codex home in the scratch folder.
    func codexHome(_ name: String) -> URL { temp.url(name) }

    /// Writes a rollout under `home`'s sessions/`day` with `lines`, last modified `modified` seconds ago.
    @discardableResult
    func rollout(_ lines: [String], day: String = "2026/11/02", name: String = "rollout-a.jsonl", home: URL? = nil, modified: Double = 0) throws -> String {
        let folder = (home ?? self.home).appendingPathComponent("sessions/\(day)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(name).path
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-modified)], ofItemAtPath: path)
        return path
    }

    func read(_ home: URL? = nil) -> CodexReading { CodexUsageReader(home: home ?? self.home, ttl: 0).read() }

    var soon: Double { Date().timeIntervalSince1970 + 86_400 }

    // MARK: Reading Codex's usage

    @Test func theNewestRolloutsLastAccountReadingIsReadWithItsWindowsAndCredits() throws {
        // An older day's file, and today's: two sessions, the last written decides.
        try rollout([Self.event(primary: Self.window(20, resets: soon))], day: "2026/11/01", name: "rollout-old.jsonl", modified: 600)
        try rollout([Self.event(primary: Self.window(30, minutes: 300, resets: soon - 3600), secondary: Self.window(55, resets: soon)),
                     Self.otherEvent,
                     Self.event(primary: Self.window(35, minutes: 300, resets: soon - 3600), secondary: Self.window(59, resets: soon), credits: Self.credits),
                     Self.otherEvent])
        let usage = try #require(read().usage)
        #expect(usage.windows.map(\.usedPercent) == [35, 59] && usage.windows.map(\.name) == ["5-hour", "weekly"])
        #expect(usage.hasCredits == true && usage.balance == 36762.868745 && usage.creditsAvailable)
        #expect(usage.at == CodexUsage.timestamp("2026-11-02T06:33:46.148Z"))
        // A session written to last, though started a day earlier, is the newest.
        try rollout([Self.event(primary: Self.window(61, resets: soon))], day: "2026/11/01", name: "rollout-long.jsonl", modified: -60)
        #expect(read().usage?.windows.map(\.usedPercent) == [61])
    }

    @Test func otherLimitsAndOtherEventsArePassedOverAndASessionWithNoneYetFallsBackToTheNextNewest() throws {
        try rollout([Self.event(primary: Self.window(40, resets: soon)),
                     // One model's limit (GPT-5.3-Codex-Spark's) and the premium one: not the account's.
                     Self.event(primary: Self.window(99, resets: soon), id: #""codex_bengalfox""#),
                     Self.event(primary: nil, id: #""premium""#), Self.otherEvent], name: "rollout-a.jsonl", modified: 60)
        // Just started: nothing of its limits yet.
        try rollout([Self.otherEvent], name: "rollout-b.jsonl")
        #expect(read().usage?.windows.map(\.usedPercent) == [40])
    }

    @Test func onlyTheTailIsRead() throws {
        // A reading at the start of a file whose end is past what's read: not seen, so unknown, never room.
        let filler = Array(repeating: Self.otherEvent.replacingOccurrences(of: "done", with: String(repeating: "x", count: 2000)), count: 160)
        try rollout([Self.event(primary: Self.window(10, resets: soon))] + filler)
        let reading = read()
        #expect(reading.usage == nil && !UsageRouting.codex(reading).room, "\(reading)")
        // The same file with a reading at its end: that one.
        try rollout([Self.event(primary: Self.window(10, resets: soon))] + filler + [Self.event(primary: Self.window(45, resets: soon))])
        #expect(read().usage?.windows.map(\.usedPercent) == [45])
    }

    @Test func aStaleReadingPastItsResetIsUnknownNeverRoom() throws {
        try rollout([Self.event(primary: Self.window(10, resets: Date().timeIntervalSince1970 - 60), credits: Self.credits)])
        let reading = read()
        #expect(reading.usage != nil)
        let codex = UsageRouting.codex(reading)
        #expect(!codex.room && codex.text.contains("not known"), "\(codex.text)")
        #expect(reading.statusText().contains("has reset"))
    }

    @Test func malformedOrMissingInputIsUnknownNeverRoom() throws {
        // No Codex home at all.
        #expect(!UsageRouting.codex(read(codexHome("none"))).room)
        // A window without a number: the last reading can't be read, and an older one isn't taken instead.
        let home = codexHome("bad-window")
        try rollout([Self.event(primary: Self.window(10, resets: soon)),
                     Self.event(primary: #"{"used_percent":"lots","window_minutes":10080,"resets_at":1}"#)], home: home)
        let bad = read(home)
        #expect(bad.usage == nil && !UsageRouting.codex(bad).room, "\(bad)")
        // No window at all.
        let empty = codexHome("no-window")
        try rollout([Self.event(primary: nil, secondary: nil)], home: empty)
        #expect(read(empty).usage == nil)
        // Not JSON.
        let garbage = codexHome("garbage")
        try rollout(["{\"rate_limits\": {", "not json at all", "\u{0}\u{1}"], home: garbage)
        #expect(read(garbage).usage == nil && !UsageRouting.codex(read(garbage)).room)
        // Codex says a limit is reached: no room, whatever the window.
        let reached = codexHome("reached")
        try rollout([Self.event(primary: Self.window(10, resets: soon), reached: #""workspace_owner_credits_depleted""#)], home: reached)
        #expect(!UsageRouting.codex(read(reached)).room)
    }

    @Test func readingsAreKeptUntilTheirTimeIsUp() throws {
        let path = try rollout([Self.event(primary: Self.window(40, resets: soon))])
        let reader = CodexUsageReader(home: home, ttl: 3600)
        let now = Date()
        #expect(reader.read(now: now).usage?.windows.first?.usedPercent == 40)
        try (Self.event(primary: Self.window(70, resets: soon)) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        #expect(reader.read(now: now.addingTimeInterval(10)).usage?.windows.first?.usedPercent == 40)
        #expect(reader.read(now: now.addingTimeInterval(3601)).usage?.windows.first?.usedPercent == 70)
    }

    // MARK: Pace and thresholds

    @Test func paceIsTheUseAgainstTheTimeGoneInTheWindow() {
        let now = 1_000_000.0
        let week = 10080.0
        let cases: [(used: Double, left: Double?, minutes: Double?, elapsed: Double?, text: String)] = [
            (64, 0.48 * 604_800, week, 52, "12 points ahead of pace"),
            (40, 0.5 * 604_800, week, 50, "10 points behind pace"),
            (50, 0.5 * 604_800, week, 50, "on pace"),
            (30, 0.9 * 18_000, 300, 10, "20 points ahead of pace"),
            (10, 0, week, 100, "90 points behind pace"),
            // A reset further off than one window doesn't add up; no reset or length: not known.
            (10, 2 * 604_800, week, nil, "pace not known"),
            (10, nil, week, nil, "pace not known"),
            (10, 1000, nil, nil, "pace not known"),
        ]
        for item in cases {
            let pace = UsagePace(used: item.used, elapsed: UsagePace.elapsed(resetsAt: item.left.map { now + $0 }, windowMinutes: item.minutes, now: now))
            #expect(pace.elapsed.map { ($0 * 1000).rounded() / 1000 } == item.elapsed && pace.paceText == item.text, "\(item) → \(pace)")
        }
        #expect(UsagePace(used: 51, elapsed: 50).paceText == "1 point ahead of pace")
    }

    @Test func claudeIsTightAtSeventyPercentOrAWeeklyLimitTenPointsAheadOfPace() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func limit(_ name: String, _ used: Double, gone: Double, model: String? = nil, reached: Bool = false) -> AccountUsage.Limit {
            let window = name == "five_hour" ? 18_000.0 : 604_800.0
            return AccountUsage.Limit(name: name, model: model, usedPercent: used, resetsAt: 1_000_000 + window * (1 - gone), at: 999_000, reached: reached)
        }
        let cases: [(limits: [AccountUsage.Limit], model: String?, tight: Bool, text: String)] = [
            ([], nil, false, "Claude's usage not known"),
            ([limit("seven_day", 70, gone: 0.9)], nil, true, "Claude weekly 70%, 20 points behind pace"),
            ([limit("seven_day", 69, gone: 0.65)], nil, false, "Claude weekly 69%, 4 points ahead of pace"),
            ([limit("seven_day", 64, gone: 0.52)], nil, true, "Claude weekly 64%, 12 points ahead of pace"),
            ([limit("seven_day", 60, gone: 0.50)], nil, false, "Claude weekly 60%, 10 points ahead of pace"),
            ([limit("seven_day", 51, gone: 0.48), limit("five_hour", 75, gone: 0.5)], nil, true, "Claude 5-hour 75%, 25 points ahead of pace"),
            // A 5-hour limit ahead of its pace isn't tight below 70%: only weekly ones count by pace.
            ([limit("seven_day", 30, gone: 0.5), limit("five_hour", 50, gone: 0.1)], nil, false, "Claude weekly 30%, 20 points behind pace"),
            ([limit("seven_day_opus", 40, gone: 0.2)], "opus", true, "Claude weekly Opus 40%, 20 points ahead of pace"),
            // A limit on another model doesn't make a sonnet worker's Claude tight; on its own model it does.
            ([limit("seven_day_overage_included", 100, gone: 0.3, model: "fable", reached: true)], "sonnet", false, "Claude's usage not known"),
            ([limit("seven_day_overage_included", 100, gone: 0.3, model: "fable", reached: true)], "claude-fable-5-1", true,
             "Claude seven day overage included (fable) reached"),
            // One that has reset is no longer known.
            ([AccountUsage.Limit(name: "seven_day", usedPercent: 95, resetsAt: 999_999, at: 900_000)], nil, false, "Claude's usage not known"),
        ]
        for item in cases {
            let claude = UsageRouting.claude(AccountUsage(limits: item.limits), model: item.model, now: now)
            #expect(claude.tight == item.tight && claude.text == item.text, "\(item.text) → \(claude)")
        }
    }

    @Test func codexHasRoomUnderEightyFivePercentOrUnderAHundredWithCredits() {
        let now = Date()
        let resets = now.timeIntervalSince1970 + 86_400
        func usage(_ used: [Double], credits: Bool? = nil, balance: Double? = nil, unlimited: Bool? = nil, reached: String? = nil) -> CodexReading {
            .known(CodexUsage(windows: used.enumerated().map { CodexUsage.Window(usedPercent: $1, windowMinutes: $0 == 0 && used.count > 1 ? 300 : 10080, resetsAt: resets) },
                              hasCredits: credits, unlimited: unlimited, balance: balance, reached: reached, at: now.timeIntervalSince1970))
        }
        let cases: [(reading: CodexReading, room: Bool, text: String)] = [
            (.unknown("no Codex session file"), false, "Codex usage not known"),
            (usage([40]), true, "Codex 40%"),
            (usage([84.9]), true, "Codex 85%"),
            (usage([85]), false, "Codex 85%, no room"),
            (usage([90], credits: true, balance: 36762.87), true, "Codex 90%, with credits"),
            (usage([90], credits: true), true, "Codex 90%, with credits"),
            (usage([100], credits: true, balance: 10), false, "Codex 100%, with credits, no room"),
            (usage([90], credits: true, balance: 0), false, "Codex 90%, no room"),
            (usage([90], credits: false, balance: 50), false, "Codex 90%, no room"),
            (usage([90], unlimited: true), true, "Codex 90%, with credits"),
            (usage([90, 40]), false, "Codex 5-hour 90%, weekly 40%, no room"),
            (usage([20, 40]), true, "Codex 5-hour 20%, weekly 40%"),
            (usage([10], reached: "rate_limit"), false, "Codex 10%, at a limit (rate_limit)"),
            // A full 5-hour window whose reset isn't said: unknown, never room on the weekly alone (blind check).
            (.known(CodexUsage(windows: [.init(usedPercent: 99, windowMinutes: 300), .init(usedPercent: 40, windowMinutes: 10080, resetsAt: resets)],
                               at: now.timeIntervalSince1970)), false, "Codex usage not known (a limit's reset time isn't said)"),
        ]
        for item in cases {
            let codex = UsageRouting.codex(item.reading, now: now)
            #expect(codex.room == item.room && codex.text == item.text, "\(item.text) → \(codex)")
        }
    }

    @Test func autoGoesToCodexOnlyWhenClaudeIsTightAndCodexHasRoom() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tight = AccountUsage(limits: [AccountUsage.Limit(name: "seven_day", usedPercent: 64, resetsAt: 1_000_000 + 0.48 * 604_800, at: 999_000)])
        let calm = AccountUsage(limits: [AccountUsage.Limit(name: "seven_day", usedPercent: 30, resetsAt: 1_000_000 + 0.48 * 604_800, at: 999_000)])
        let room = CodexReading.known(CodexUsage(windows: [.init(usedPercent: 40, windowMinutes: 10080, resetsAt: 1_100_000)], at: 999_000))
        let full = CodexReading.known(CodexUsage(windows: [.init(usedPercent: 92, windowMinutes: 10080, resetsAt: 1_100_000)], at: 999_000))
        let route = UsageRouting.route(claude: tight, codex: room, model: nil, now: now)
        #expect(route == UsageRouting.Route(agent: .codex, why: "Codex: Claude weekly 64%, 12 points ahead of pace; Codex 40%"))
        #expect(UsageRouting.route(claude: tight, codex: full, model: nil, now: now)
                == UsageRouting.Route(agent: .claude, why: "Claude: Claude weekly 64%, 12 points ahead of pace; Codex 92%, no room"))
        #expect(UsageRouting.route(claude: calm, codex: room, model: nil, now: now).agent == .claude)
        #expect(UsageRouting.route(claude: tight, codex: .unknown("x"), model: nil, now: now).agent == .claude)
        #expect(UsageRouting.route(claude: AccountUsage(), codex: room, model: nil, now: now).agent == .claude)
        #expect(UsageRouting.route(claude: tight, codex: room, model: nil, codexWorkers: false, now: now)
                == UsageRouting.Route(agent: .claude, why: "Claude: Codex workers are switched off"))
    }

    // MARK: The lead's tools

    func repo() throws -> String {
        let url = temp.url("routing")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func task(_ slug: String, _ root: String) -> LeadTask? { BoardStore(root: root).load().task(slug) }

    func progress(_ root: String) -> String {
        (try? String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)) ?? ""
    }

    /// A lead whose Codex usage is read from this test's scratch Codex home, Codex workers on.
    func routingLead(_ root: String, _ runtime: FakeRuntime) throws -> LeadToolset {
        let lead = try lead(root, runtime)
        lead.codexUsage = CodexUsageReader(home: home, ttl: 0)
        lead.codexWorkers = true
        lead.power = { nil }
        return lead
    }

    /// Claude's weekly limit at `used`%, `gone` of its week gone.
    func claudeWeekly(_ used: Double, gone: Double) {
        let now = Date().timeIntervalSince1970
        usageStore.record([AccountUsage.Limit(name: "seven_day", usedPercent: used, resetsAt: now + 604_800 * (1 - gone), at: now)])
    }

    func codexWeekly(_ used: Double) throws {
        try rollout([Self.event(primary: Self.window(used, resets: soon))])
    }

    @Test func anAutoTaskStartsOnCodexWhenClaudeRunsAheadOfPaceAndSaysWhy() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try routingLead(root, runtime)
        claudeWeekly(64, gone: 0.52)
        try codexWeekly(40)
        let added = lead.call("add_task", ["title": "Rename x", "goal": "x is y", "acceptance": ["grep -q y a.txt"], "agent": "auto", "model": "sonnet"])
        #expect(!added.isError && added.text.contains("Its agent is auto") && added.text.contains("Now: Codex: Claude weekly 64%"), "\(added.text)")
        #expect(task("rename-x", root)?.agent == .auto && task("rename-x", root)?.reviewLevel == LeadTask.Review.none)
        let started = lead.call("start_worker", ["task": "rename-x"])
        #expect(!started.isError, "\(started.text)")
        let why = "Codex: Claude weekly 64%, 12 points ahead of pace; Codex 40%"
        #expect(started.text.contains("Its agent is auto, so it went to \(why).") && started.text.contains("Codex implements it; a Claude verifier audits it"),
                "\(started.text)")
        #expect(progress(root).contains("Started a worker on rename-x (auto → \(why))"), "\(progress(root))")
        let spawn = try #require(runtime.spawned.last)
        #expect(runtime.agents[spawn.id] == "codex")
        // Its model is Claude's: Codex runs on its own.
        #expect(!spawn.command.contains("sonnet"), "\(spawn.command.prefix(300))")
        // The Codex brief, and the forced Claude audit from here on.
        #expect(spawn.command.contains("You run in the Codex CLI"))
        let after = try #require(task("rename-x", root))
        #expect(after.codexWorked == true && after.codexAudit != nil && after.launchedModels?[spawn.id] == "codex")
        #expect(after.routed == why && after.runningAgent == .codex && after.model == "sonnet")
        let board = lead.call("board", [:]).text
        #expect(board.contains("rename-x") && board.contains("worker: auto (now Codex)"), "\(board)")
    }

    @Test func anAutoTaskStartsOnClaudeWhenClaudeHasRoomOrCodexUsageIsNotKnown() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try routingLead(root, runtime)
        claudeWeekly(40, gone: 0.5)
        try codexWeekly(10)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"], "agent": "auto"])
        let one = lead.call("start_worker", ["task": "one"])
        #expect(!one.isError && one.text.contains("Its agent is auto, so it went to Claude: Claude weekly 40%, 10 points behind pace, not tight; Codex 10%."),
                "\(one.text)")
        #expect(runtime.agents[try #require(runtime.spawned.last).id] == "claude" && task("one", root)?.codexWorked == nil)
        #expect(!(try #require(runtime.spawned.last)).command.contains("You run in the Codex CLI"))
        // Claude tight, Codex's usage not known (no session file): Claude.
        claudeWeekly(75, gone: 0.5)
        try FileManager.default.removeItem(at: home)
        _ = lead.call("add_task", ["title": "Two", "goal": "g", "acceptance": ["a"], "agent": "auto"])
        let two = lead.call("start_worker", ["task": "two"])
        #expect(!two.isError && two.text.contains("so it went to Claude: Claude weekly 75%, 25 points ahead of pace; Codex usage not known"), "\(two.text)")
        #expect(runtime.agents[try #require(runtime.spawned.last).id] == "claude")
    }

    @Test func whereClaudesHoldWouldRefuseAnAutoTaskItStartsOnCodexAndAClaudeTaskStillHolds() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try routingLead(root, runtime)
        claudeWeekly(84, gone: 0.6)
        try codexWeekly(40)
        _ = lead.call("add_task", ["title": "Pinned", "goal": "g", "acceptance": ["a"], "agent": "claude"])
        _ = lead.call("add_task", ["title": "Routed", "goal": "g", "acceptance": ["a"], "agent": "auto"])
        let pinned = lead.call("start_worker", ["task": "pinned"])
        #expect(pinned.isError && pinned.text.contains("Not started: the account's usage is near a limit"), "\(pinned.text)")
        let routed = lead.call("start_worker", ["task": "routed"])
        #expect(!routed.isError && routed.text.contains("so it went to Codex: Claude weekly 84%"), "\(routed.text)")
        #expect(runtime.spawned.count == 1 && runtime.agents[runtime.spawned[0].id] == "codex")
        // Codex full too: the auto task holds as a Claude one does, and says why it stayed on Claude.
        try codexWeekly(95)
        _ = lead.call("add_task", ["title": "Third", "goal": "g", "acceptance": ["a"], "agent": "auto"])
        let third = lead.call("start_worker", ["task": "third"])
        #expect(third.isError && third.text.contains("Its agent is auto, and it stays on Claude: Claude: Claude weekly 84%") && third.text.contains("Codex 95%, no room"),
                "\(third.text)")
        #expect(runtime.spawned.count == 1)
    }

    @Test func autoAdvanceStartsAnAutoTaskOnCodexPastClaudesHoldAndSaysWhy() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try routingLead(root, runtime)
        claudeWeekly(84, gone: 0.6)
        try codexWeekly(40)
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "agent": "auto"])
        #expect(advancing.until { task("add-b", root)?.status == .running })
        let worker = try #require(task("add-b", root)?.worker)
        #expect(runtime.agents[worker] == "codex")
        #expect(progress(root).contains("Started a worker on add-b (auto → Codex: Claude weekly 84%"), "\(progress(root))")
        let told: () -> [String] = {
            runtime.calls.lock()
            defer { runtime.calls.unlock() }
            return runtime.steered.map(\.text)
        }
        #expect(advancing.until { told().contains { $0.contains("Started a worker on add-b") && $0.contains("its agent is auto, so it went to Codex: Claude weekly 84%") } },
                "\(told())")
    }

    @Test func agentDefaultSetsTheAgentOfNewTasksThatNameNone() throws {
        let root = try repo()
        let lead = try routingLead(root, FakeRuntime())
        _ = lead.call("add_task", ["title": "Before", "goal": "g", "acceptance": ["a"]])
        #expect(task("before", root)?.agent == nil)
        #expect(lead.workflow.agentDefault == .claude)
        let refused = lead.call("configure", ["agent_default": "codex"])
        #expect(refused.isError && refused.text.contains("agent_default is claude or auto"), "\(refused.text)")
        let set = lead.call("configure", ["agent_default": "auto"])
        #expect(!set.isError, "\(set.text)")
        #expect(lead.workflow.agentDefault == .auto)
        _ = lead.call("add_task", ["title": "After", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("add_task", ["title": "Pinned", "goal": "g", "acceptance": ["a"], "agent": "claude"])
        _ = lead.call("add_task", ["title": "Codex one", "goal": "g", "acceptance": ["a"], "agent": "codex"])
        #expect(task("after", root)?.agent == .auto && task("pinned", root)?.agent == nil && task("codex-one", root)?.agent == .codex)
        // Cleared: claude again. One the file holds that isn't claude or auto reads claude.
        #expect(!lead.call("configure", ["agent_default": ""]).isError)
        #expect(lead.workflow.agentDefault == .claude)
        #expect(LeadWorkflow.parse("---\nagent_default: codex\n---").agentDefault == .claude)
        #expect(LeadWorkflow.parse("---\nagent_default: Auto\n---").agentDefault == .auto)
        // update_task moves a task to auto and back; a Claude model stays with auto.
        _ = lead.call("add_task", ["title": "Model", "goal": "g", "acceptance": ["a"], "agent": "claude", "model": "sonnet"])
        let moved = lead.call("update_task", ["task": "model", "agent": "auto"])
        #expect(!moved.isError && moved.text.contains("agent auto"), "\(moved.text)")
        #expect(task("model", root)?.agent == .auto && task("model", root)?.model == "sonnet")
        _ = lead.call("update_task", ["task": "model", "agent": "codex"])
        #expect(task("model", root)?.agent == .codex && task("model", root)?.model == nil)
    }

    @Test func statusShowsBothAccountsUsageWithPaceAndWhereTheNextAutoTaskGoes() throws {
        let root = try repo()
        let lead = try routingLead(root, FakeRuntime())
        // Neither account's usage known, and no task is auto: nothing to say.
        var status = lead.call("status", [:]).text
        #expect(!status.contains("Codex usage") && !status.contains("Next auto task"), "\(status)")
        _ = lead.call("add_task", ["title": "Auto one", "goal": "g", "acceptance": ["a"], "agent": "auto"])
        status = lead.call("status", [:]).text
        #expect(status.contains("Codex usage: not known (no Codex session file under ")
                && status.contains("Next auto task → claude (Claude: Claude's usage not known, not tight; Codex usage not known), auto-one first."), "\(status)")
        claudeWeekly(64, gone: 0.52)
        try rollout([Self.event(primary: Self.window(40, resets: soon), credits: Self.credits)])
        status = lead.call("status", [:]).text
        #expect(status.contains("the weekly limit (every model): 64% used, resets ") && status.contains(", 12 points ahead of pace"), "\(status)")
        #expect(status.contains("Codex usage (best effort: its newest session file") && status.contains("the weekly limit: 40% used (")
                && status.contains("credits available (36762.87)"), "\(status)")
        #expect(status.contains("Next auto task → codex (Codex: Claude weekly 64%, 12 points ahead of pace; Codex 40%), auto-one first."), "\(status)")
    }
}
