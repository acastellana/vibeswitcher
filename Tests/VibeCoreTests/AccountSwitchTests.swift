import Foundation
import Testing
@testable import VibeCore

/// Usage readings and refusals are each Claude account's (see `ClaudeAccount`): 2026-11-07 the user logged in to
/// another account with /login, Fable ran fine there, and the old account's Fable refusal still held every Fable audit
/// until its reset; the weekly reading flipped between 82 % and 3–4 % as each account's sessions reported last.
/// On fake sessions and a scratch home only; the `session-owner` line is as Claude Code 2.1.319 writes it.
struct AccountSwitchTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    /// The scratch home whose `.claude.json` says which account Claude Code is logged in to.
    let home: URL
    init() throws {
        vault = Self.newVault(in: temp)
        home = temp.url("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/p"), withIntermediateDirectories: true)
    }

    static let a = "aaaa1111-0000-4000-8000-000000000001"
    static let b = "bbbb2222-0000-4000-8000-000000000002"
    static let now = AccountUsageTests.now

    /// Where this test's leads keep the usage, the active account read from the scratch home.
    var store: AccountUsageStore { AccountUsageStore(file: vault.folder.appendingPathComponent("account-usage.json"), home: home.path) }

    /// Logs the scratch home in to `account` (as /login rewrites `~/.claude.json`), with a token-free config around it.
    func login(_ account: String, email: String) throws {
        let config: [String: Any] = ["numStartups": 3, "projects": [:],
                                     "oauthAccount": ["accountUuid": account, "emailAddress": email, "organizationUuid": "org", "displayName": "Someone"]]
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".claude.json"), options: .atomic)
    }

    /// A transcript in the scratch home's Claude folder whose session runs on `account`.
    func transcript(_ account: String, then lines: String = "") throws -> URL {
        let file = home.appendingPathComponent(".claude/projects/p/\(UUID().uuidString).jsonl")
        let owner = #"{"type":"session-owner","accountUuid":"\#(account)","organizationUuid":"org","sessionId":"s"}"#
        try (owner + "\n" + lines).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A status line run of a session whose transcript is `transcript`, the weekly window at `weekly` %.
    func statusLine(_ transcript: URL, weekly: Double) {
        let input = #"{"session_id":"s","transcript_path":"\#(transcript.path)","rate_limits":{"seven_day":{"used_percentage":\#(weekly),"resets_at":\#(AccountUsageTests.tomorrow)}}}"#
        UsageStatusLine.run(input: Data(input.utf8), store: store, home: home.path, now: Self.now, runner: { _, _, _ in Data() }) { _ in }
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

    func lead(_ root: String, _ runtime: FakeRuntime) throws -> LeadToolset {
        let grant = try vault.startLead(root: root, branch: Worktrees.currentBranch(root: root) ?? "main")
        try vault.bind(grant, root: root, session: try #require(runtime.me.session))
        let lead = LeadToolset(root: root, runtime: runtime, vault: vault(for: runtime))
        lead.testLock = testLock
        lead.macLimits = { MacLimits(maxSessions: 6) }
        lead.roomWaits = roomWaits
        lead.usageStore = store
        lead.usageClock = { Self.now }
        return lead
    }

    func call(_ tools: LeadToolset, _ name: String, _ arguments: [String: Any] = [:]) -> MCPToolResult { tools.call(name, arguments) }

    // MARK: The account

    @Test func theActiveAccountIsReadMaskedAndNothingElseOfTheLogin() throws {
        #expect(ClaudeAccount.active(home: home.path) == nil)
        try login(Self.a, email: "alice@example.com")
        let active = try #require(ClaudeAccount.active(home: home.path))
        #expect(active.id == Self.a)
        #expect(active.name == "al•••@ex•••.com (aaaa…)", "\(active.name)")
        #expect(!active.name.contains("alice") && !active.name.contains("example"))
        // /login to another account: read again.
        try login(Self.b, email: "bo@b.invalid")
        #expect(ClaudeAccount.active(home: home.path) == ClaudeAccount(id: Self.b, name: "b•••@b•••.invalid (bbbb…)"))
        #expect(ClaudeAccount.name(email: nil, id: Self.a) == "account aaaa…")
        #expect(ClaudeAccount.mask("not an email") == nil)
        // A transcript's session runs on its last session-owner line's account.
        let file = try transcript(Self.a, then: #"{"type":"session-owner","accountUuid":"\#(Self.b)","sessionId":"s"}"# + "\n")
        #expect(ClaudeAccount.owner(transcript: file) == Self.b)
        #expect(ClaudeAccount.owner(Data(#"{"type":"user","accountUuid":"x"}"#.utf8)) == nil)
    }

    @Test func aRefusalReadFromATranscriptIsItsSessionsAccounts() throws {
        let file = try transcript(Self.a, then: AccountUsageTests.fableRefusal)
        let limit = try #require(TranscriptTail.read(url: file)?.usageLimit)
        #expect(limit.account == Self.a)
        #expect(AccountUsage.fromRefusal(limit, model: "fable", now: Self.now)?.account == Self.a)
    }

    // MARK: Switching accounts

    /// The acceptance check: a refusal recorded for account A holds Fable starts while A is active; after a /login to
    /// B it no longer does, and B's own readings apply; back on A, A's hold is back until its reset.
    @Test func aRefusalOnOneAccountHoldsOnlyWhileThatAccountIsActive() throws {
        try login(Self.a, email: "alice@example.com")
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!call(lead, "configure", ["max_workers": 4]).isError)
        // Room on the Mac for four workers and three verifiers.
        lead.macLimits = { MacLimits(maxSessions: 8) }
        for title in ["One", "Two", "Three", "Four"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        for task in ["one", "two", "three", "four"] { #expect(!call(lead, "start_worker", ["task": task]).isError) }
        #expect(lead.auditModel(lead.workflow) == "fable")
        /// The model the last audit of `slug` was started on, as its command line says.
        func audited(_ slug: String) -> String? {
            runtime.spawned.last { $0.command.contains("--name 'verify-\(slug)'") }.map { LeadWorkflow.claudeModel(command: $0.command) ?? "" }
        }
        #expect(!call(lead, "audit", ["task": "one"]).isError)
        let verifier = try #require(BoardStore(root: root).load().task("one")?.verifier)
        // The verifier, on A, stopped at the Fable limit (its transcript says so, and that it runs on A).
        var refusal = try #require(TranscriptTail.read(url: try transcript(Self.a, then: AccountUsageTests.fableRefusal))?.usageLimit)
        refusal.at = Self.now.timeIntervalSince1970
        refusal.resetsAt = Self.now.timeIntervalSince1970 + 86_400
        runtime.usageLimits[verifier] = refusal
        // Fable held back on A: the audit starts on Opus instead (LeadUsageFallback), Fable itself still held.
        let moved = call(lead, "audit", ["task": "two"])
        #expect(!moved.isError && audited("two") == "opus", "\(moved.text)")
        #expect(lead.usageHold(model: "fable", sessions: try lead.advanceSessions())?.reached == true)
        let status = call(lead, "status").text
        #expect(status.contains("Account usage for al•••@ex•••.com (aaaa…), the account Claude Code is logged in to")
                && status.contains("the fable limit (seven_day_overage_included): reached"), "\(status)")
        #expect(!status.contains("alice@example.com"))

        // /login to B: the refusal, its session still live, no longer holds Fable, and isn't kept as B's.
        try login(Self.b, email: "bob@corp.test")
        #expect(lead.usageHold(model: "fable", sessions: try lead.advanceSessions()) == nil)
        #expect(!store.load().limits.contains { $0.account == Self.b && $0.reached }, "\(store.load().limits)")
        // B's own readings apply: its session at 90 % of the weekly limit holds every model. A session still on A
        // reporting 3 % doesn't change B's reading, nor A's refusal hold B.
        statusLine(try transcript(Self.b), weekly: 90)
        statusLine(try transcript(Self.a), weekly: 3)
        #expect(lead.usageHold(model: "sonnet", sessions: nil)?.name == "seven_day")
        #expect(lead.usageHold(model: "sonnet", sessions: nil)?.usedPercent == 90)
        let onB = call(lead, "status").text
        #expect(onB.contains("Account usage for bo•••@co•••.test (bbbb…), the account Claude Code is logged in to (best effort: what sessions' status lines and refusals said): the weekly limit (every model): 90% used"), "\(onB)")
        // A's readings, named masked, hold nothing back.
        #expect(onB.contains("Other accounts' readings (they hold nothing back): al•••@ex•••.com (aaaa…): ")
                && onB.contains("the fable limit (seven_day_overage_included): reached"), "\(onB)")
        // B under its threshold: the audit starts, on Fable (A's refusal holds nothing on B).
        statusLine(try transcript(Self.b), weekly: 40)
        let started = call(lead, "audit", ["task": "three"])
        #expect(!started.isError && audited("three") == "fable", "\(started.text)")

        // Back on A: A's hold is back, B's reading isn't A's.
        try login(Self.a, email: "alice@example.com")
        #expect(lead.usageHold(model: "fable", sessions: nil)?.reached == true)
        let back = call(lead, "audit", ["task": "four"])
        #expect(!back.isError && audited("four") == "opus", "\(back.text)")
        #expect(lead.usageHold(model: "sonnet", sessions: nil) == nil)
        // Until its reset, and no longer.
        let reset = Date(timeIntervalSince1970: try #require(refusal.resetsAt))
        lead.usageClock = { reset.addingTimeInterval(-1) }
        #expect(lead.usageHold(model: "fable", sessions: nil) != nil)
        lead.usageClock = { reset }
        #expect(lead.usageHold(model: "fable", sessions: nil) == nil)
    }

    /// A refusal whose transcript didn't say its account is the one logged in to when it's first kept: the stopped
    /// session stays live, and after a /login it isn't kept again as the new account's.
    @Test func aRefusalWithoutItsAccountIsKeptOnceForTheAccountThenActive() throws {
        try login(Self.a, email: "alice@example.com")
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        for task in ["one", "two"] { #expect(!call(lead, "start_worker", ["task": task]).isError) }
        #expect(!call(lead, "audit", ["task": "one"]).isError)
        let verifier = try #require(BoardStore(root: root).load().task("one")?.verifier)
        runtime.usageLimits[verifier] = UsageLimit(said: "You've reached your Fable limit.", resetsAt: Self.now.timeIntervalSince1970 + 86_400,
                                                   at: Self.now.timeIntervalSince1970, kind: "seven_day_overage_included",
                                                   apiError: "model_requires_usage_credits")
        #expect(lead.usageHold(model: "fable", sessions: try lead.advanceSessions())?.account == Self.a)
        try login(Self.b, email: "bob@corp.test")
        #expect(lead.usageHold(model: "fable", sessions: try lead.advanceSessions()) == nil)
        #expect(store.load().limits.filter(\.reached).map(\.account) == [Self.a], "\(store.load().limits)")
    }

    /// Readings kept before they named an account (the store as it was on 2026-11-07) hold nothing back once the active
    /// account is known: whose they were can't be told. With no account known (an API key), every reading holds as before.
    @Test func readingsOfNoKnownAccountHoldNothingBackOnceTheActiveOneIsKnown() throws {
        let old = AccountUsage.Limit(name: "seven_day_overage_included", model: "fable", usedPercent: 100,
                                     resetsAt: AccountUsageTests.tomorrow, at: Self.now.timeIntervalSince1970, reached: true)
        store.record([old], now: Self.now)
        #expect(store.load().hold(model: "fable", now: Self.now) != nil)
        try login(Self.b, email: "bob@corp.test")
        let usage = store.load()
        #expect(usage.hold(model: "fable", now: Self.now) == nil)
        let text = try #require(usage.statusText(now: Self.now))
        #expect(text.contains("bo•••@co•••.test (bbbb…), the account Claude Code is logged in to (best effort: what sessions' status lines and refusals said): nothing known")
                && text.contains("an account not recorded: the fable limit"), "\(text)")
    }
}

extension AccountSwitchTests {
    /// The watch the app nudges the leads by sees a /login to another account, and only that.
    @Test func theAccountWatchSeesALoginToAnotherAccount() throws {
        let watch = ClaudeAccountWatch(home: home.path)
        #expect(!watch.changed())
        try login(Self.a, email: "alice@example.com")
        #expect(watch.changed())
        #expect(!watch.changed())
        // The same account written again (Claude Code rewrites the file often): no change.
        try login(Self.a, email: "alice@example.com")
        #expect(!watch.changed())
        try login(Self.b, email: "bob@corp.test")
        #expect(watch.changed())
        // Caught half written: still B, not "no account known" (which would let every account's readings hold).
        try Data(#"{"oauthAccount":{"accountUu"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        #expect(ClaudeAccount.active(home: home.path)?.id == Self.b)
        #expect(!watch.changed())
    }
}

extension LeadAdvanceTests {
    /// The blind check's case: auto_advance held by account A's limit, then a /login to B. The app's watch sees it and
    /// nudges the lead (nothing in the project's folder changes), and what was held starts then, not at A's reset.
    @Test func aLoginToAnotherAccountReleasesWhatTheOldAccountsLimitHeld() async throws {
        let (root, runtime, lead) = try team()
        let now = AccountUsageTests.now
        lead.usageClock = { now }
        // Only the reset's look is armed; it isn't run here.
        let armed = Armed()
        lead.usageWake = { date, body in armed.add(date, body) }
        let home = temp.url("home")
        let projects = home.appendingPathComponent(".claude/projects/p")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        func login(_ account: String) throws {
            let config: [String: Any] = ["oauthAccount": ["accountUuid": account, "emailAddress": "someone@example.com"]]
            try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".claude.json"), options: .atomic)
        }
        let store = AccountUsageStore(file: vault.folder.appendingPathComponent("account-usage-\(UUID().uuidString).json"), home: home.path)
        lead.usageStore = store
        try login(AccountSwitchTests.a)
        let watch = ClaudeAccountWatch(home: home.path)
        #expect(!watch.changed())
        // A session on A at 91 % of the weekly limit.
        let transcript = projects.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (#"{"type":"session-owner","accountUuid":"\#(AccountSwitchTests.a)","sessionId":"s"}"# + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let input = #"{"transcript_path":"\#(transcript.path)","rate_limits":{"seven_day":{"used_percentage":91,"resets_at":\#(AccountUsageTests.tomorrow)}}}"#
        UsageStatusLine.run(input: Data(input.utf8), store: store, home: home.path, now: now, runner: { _, _, _ in Data() }) { _ in }
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "First", "goal": "g", "acceptance": ["a"]])
        let told = { reports(runtime).filter { $0.contains("The account's usage is near a limit: the weekly limit (every model): 91% used") } }
        #expect(await advancing.until { !told().isEmpty }, "\(reports(runtime))")
        await advancing.settle()
        #expect(task("first", root)?.status == .planned && runtime.spawned.isEmpty)
        // /login to B: the watch sees it, and its nudge starts the task.
        try login(AccountSwitchTests.b)
        #expect(watch.changed())
        LeadAdvance.nudge(root: root)
        #expect(await advancing.until { task("first", root)?.status == .running }, "\(String(describing: task("first", root)?.status))")
    }
}
