import Foundation
import Testing
@testable import VibeCore

/// The spoken briefing's input, prompt and template: bounded, redacted before any model sees it, and high-level.
/// Made-up logs only: no real progress text, no real model.
struct BriefingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970

    /// A token assembled at runtime, so secret scanners don't flag this file.
    let token = "ghp" + "_" + String(String(repeating: "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789", count: 2).prefix(36))

    /// A progress log as the lead's tool server writes it, entry `i` `minutes[i]` minutes before `now`.
    func log(_ lines: [(minutesAgo: Double, text: String)]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "# Progress\n\n" + lines.map { "- \(formatter.string(from: Date(timeIntervalSince1970: now - $0.minutesAgo * 60))) \($0.text)\n" }.joined()
    }

    func task(_ slug: String, _ title: String, _ status: LeadTask.Status) -> LeadTask {
        LeadTask(slug: slug, title: title, contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""), status: status)
    }

    func session(_ name: String, _ status: SessionStatus, since: Double = 0) -> Session {
        Session(tty: "ttys0\(name.count)", agent: .claude, pid: 1, startedAt: .distantPast, cwd: nil, project: name, task: nil,
                status: status, statusSince: Date(timeIntervalSince1970: since), detail: nil, hasHooks: true, inTerminalApp: false)
    }

    @Test func itCoversTheLastBriefingOrThreeHoursWhicheverIsLonger() {
        #expect(Briefing.since(lastBriefed: nil, now: now) == now - 3 * 3600)
        // Briefed ten minutes ago: still the last three hours.
        #expect(Briefing.since(lastBriefed: now - 600, now: now) == now - 3 * 3600)
        // Briefed yesterday: everything since.
        #expect(Briefing.since(lastBriefed: now - 86_400, now: now) == now - 86_400)
    }

    /// The newest N entries, newest first, only those since the window began, each redacted before any model call;
    /// a project with nothing new is one line at most.
    @Test func theInputIsBoundedRedactedAndAQuietProjectIsOneLine() {
        let entries = (0..<50).map { (minutesAgo: Double(50 - $0), text: "Update: step \($0) done") }
            + [(minutesAgo: 0, text: "Update: pushed with token \(token)")]
            + [(minutesAgo: 400, text: "Update: too old to say")]
        var board = LeadBoard()
        board.tasks = [task("fix-a", "Fix A", .running), task("fix-b", "Fix B", .review), task("fix-c", "Fix C", .blocked)]
        board.questions = [LeadQuestion(text: "Ship with key \(token)?", options: ["yes", "no"])]
        var quietBoard = LeadBoard()
        quietBoard.tasks = [task("x", "X", .running)]
        quietBoard.questions = [LeadQuestion(text: "Which logo?", options: [])]
        let input = Briefing.compose([.init(name: "vibeswitcher", progress: log(entries.sorted { $0.minutesAgo > $1.minutesAgo }), board: board),
                                      .init(name: "genswap", progress: log([(minutesAgo: 600, text: "Update: long ago")]), board: quietBoard),
                                      .init(name: "films", progress: nil, board: LeadBoard())],
                                     sessions: [session("api", .needsInput), session("web", .working), session("docs", .needsInput)],
                                     lastBriefed: now - 60, now: now)

        let busy = try! #require(input.projects.first { $0.name == "vibeswitcher" })
        #expect(busy.newsCount == 51)
        #expect(busy.news.count == Briefing.entriesPerProject)
        // Newest first: the token's entry (now), then step 49 (a minute ago), 48…
        #expect(busy.news[0].hasPrefix("Update: pushed with token"))
        #expect(!busy.news[0].contains(String(token.dropFirst(4))))
        #expect(busy.news[1] == "Update: step 49 done")
        #expect(busy.news.last == "Update: step 43 done")
        #expect(!busy.news.contains { $0.contains("step 30") })
        #expect(!busy.news.contains { $0.contains("too old") })
        #expect((busy.running, busy.review, busy.blocked, busy.questionCount) == (1, 1, 1, 1))

        let text = input.text
        #expect(!text.contains(token))
        #expect(!text.contains(String(token.dropFirst(4))))
        #expect(!BriefingPrompts.prompt(input, language: .english).contains(String(token.dropFirst(4))))
        #expect(text.contains("Question for the user: Ship with key"))
        // Quiet projects: one line each, counts and all.
        #expect(text.components(separatedBy: "\n").filter { $0.contains("genswap") }.count == 1)
        #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("  ") && $0.contains("logo") }.isEmpty)
        #expect(text.contains("genswap: nothing new; 1 running, 1 question for the user."))
        #expect(text.contains("films: nothing new."))
        #expect(text.contains("Sessions waiting on the user: api, docs."))
        #expect(!text.contains("web"))
        #expect(text.count <= Briefing.inputLimit)
    }

    /// A lead's worker or verifier waiting on input waits on its lead: not one of the sessions that need you (F3 of
    /// notifications-only-when: the briefing said "2 sessions need you" for one of yours and a worker).
    @Test func aTeamMemberWaitingOnItsLeadIsntASessionThatNeedsYou() {
        var worker = session("acme", .needsInput)
        worker.cwd = "/r/acme/.vibeswitcher/worktrees/fix-login"
        worker.teamRole = .worker
        var verifier = session("acme-v", .needsInput)
        verifier.teamRole = .verifier
        var lead = session("acme", .needsInput)
        lead.teamRole = .lead
        let input = Briefing.compose([], sessions: [worker, session("api", .needsInput), verifier], lastBriefed: nil, now: now)
        #expect(input.waitingCount == 1 && input.waiting.map(\.name) == ["api"])
        #expect(Briefing.template(input).contains("1 session needs you: api."))
        // A lead on a prompt in its terminal does need you.
        #expect(Briefing.compose([], sessions: [worker, lead], lastBriefed: nil, now: now).waitingCount == 1)
    }

    @Test func theLogsLinesAreSaidInPlainWordsWithoutSlugsOrHashes() {
        let titles = ["phone-menu": "The phone's menu"]
        #expect(Briefing.plain("Merged phone-menu: The phone's menu", titles: titles) == "Landed: The phone's menu")
        #expect(Briefing.plain("Started a worker on phone-menu", titles: titles) == "Work started: The phone's menu")
        #expect(Briefing.plain("Started a worker on other-thing", titles: titles) == "Work started: other thing")
        #expect(Briefing.plain("Audit of phone-menu: complete, clean (1a2b3c4d)", titles: titles) == "Checked The phone's menu: passed")
        #expect(Briefing.plain("Audit of phone-menu: incomplete, clean", titles: titles) == "Checked The phone's menu: didn't pass yet")
        #expect(Briefing.plain("Update: landed 0123abcd4567 on main", titles: titles) == "Update: landed on main")
        let long = Briefing.plain("Update: " + String(repeating: "word ", count: 100), titles: [:])
        #expect(long.count <= Briefing.entryLimit)
        #expect(!long.contains("\n"))
    }

    @Test func landedCountsComeFromTheMerges() {
        let input = Briefing.compose([.init(name: "p", progress: log([(minutesAgo: 30, text: "Merged a: A"), (minutesAgo: 20, text: "Merged b: B"),
                                                                      (minutesAgo: 10, text: "Started a worker on c")]), board: LeadBoard())],
                                     sessions: [], lastBriefed: nil, now: now)
        #expect(input.projects[0].landed == 2)
        #expect(input.text.contains("p: 3 new in its log; 2 landed."))
    }

    final class Model: @unchecked Sendable {
        var prompts: [String] = []
        var answer: String?
        init(_ answer: String?) { self.answer = answer }
    }

    /// The prompt names the language and the word budget; what the model says is what's shown.
    @Test func theModelWritesItInTheChosenLanguage() {
        let input = Briefing.compose([.init(name: "genswap", progress: log([(minutesAgo: 5, text: "Merged a: A")]), board: LeadBoard())],
                                     sessions: [], lastBriefed: nil, now: now)
        let spanish = BriefingLanguage.named("es")!
        let model = Model("**En genswap** se completó una tarea y nada te espera.\n")
        let written = Briefing.write(input, language: spanish, generate: { model.prompts.append($0); return model.answer }, now: now)
        #expect(model.prompts.count == 1)
        let prompt = model.prompts[0]
        #expect(prompt.contains("Spanish"))
        #expect(prompt.contains("language code es"))
        #expect(prompt.contains("70 to 90 words"))
        #expect(prompt.contains("Landed: A"))
        #expect(written.text == "En genswap se completó una tarea y nada te espera.")
        #expect(written.byModel)
        #expect(written.language == spanish)
        #expect(written.notice == nil)
        #expect(BriefingPrompts.system.contains("file names"))
        #expect(BriefingPrompts.system.contains("commit hashes"))
    }

    /// No Claude: the English template from the same input, and the panel says so.
    @Test func withoutClaudeTheTemplateInEnglishSaysSo() {
        var board = LeadBoard()
        board.tasks = [task("x", "X", .blocked)]
        board.questions = [LeadQuestion(text: "Signing setup?", options: [])]
        let input = Briefing.compose([.init(name: "vibeswitcher", progress: log((0..<9).map { (minutesAgo: Double(60 - $0), text: "Merged t\($0): Fix \($0)") }), board: board),
                                      .init(name: "genswap", progress: nil, board: LeadBoard()),
                                      .init(name: "films", progress: nil, board: LeadBoard())],
                                     sessions: [session("api", .needsInput)], lastBriefed: nil, now: now)
        let written = Briefing.write(input, language: BriefingLanguage.named("fr")!, generate: { _ in nil }, now: now)
        #expect(!written.byModel)
        #expect(written.language == .english)
        #expect(written.notice == "Claude isn't available, so this is a template briefing in English.")
        #expect(written.text.hasPrefix("In vibeswitcher, 9 updates; 9 landed, 1 blocked, 1 question for the user. Latest: Landed: Fix 8."))
        #expect(written.text.contains("Nothing new in films and genswap."))
        #expect(written.text.hasSuffix("1 session needs you: api."))
        #expect(written.text.split(separator: " ").count <= 90)
        #expect(Briefing.template(Briefing.compose([], sessions: [], lastBriefed: nil, now: now)) == "No project lead is running and no session needs you.")
    }

    @Test func aLongOrMarkedUpAnswerIsOneSpokenParagraph() {
        let answer = "# Briefing\n- one\n- two\n" + String(repeating: "word ", count: 200)
        let cleaned = try! #require(Briefing.cleanAnswer(answer))
        #expect(!cleaned.contains("#"))
        #expect(!cleaned.contains("\n"))
        #expect(cleaned.hasPrefix("Briefing one two word"))
        #expect(cleaned.split(separator: " ").count == Briefing.wordLimit)
        #expect(Briefing.cleanAnswer("  \n ") == nil)
    }

    @Test func theDefaultLanguageIsTheMacsFirstWhenTheModelSpeaksIt() {
        #expect(BriefingLanguage.preferred(["es-ES", "en-US"]).code == "es")
        #expect(BriefingLanguage.preferred(["zh-Hans-CN"]).code == "zh")
        #expect(BriefingLanguage.preferred(["nb-NO"]).code == "no")
        #expect(BriefingLanguage.preferred(["ca-ES"]).name == "Catalan")
        #expect(BriefingLanguage.preferred(["xx"]) == .english)
        #expect(BriefingLanguage.preferred([]) == .english)
        #expect(Set(BriefingLanguage.all.map(\.code)).count == BriefingLanguage.all.count)
        #expect(BriefingLanguage.all.count > 80)
    }

    /// The briefing runs through the same headless Claude as the one-liners: no tools, no settings, its own system prompt.
    @Test func theHeadlessCommandIsTheOneLinersWithTheBriefingsSystemPrompt() {
        let command = ClaudeHeadless.command(prompt: "p", system: BriefingPrompts.system)
        #expect(command.args.contains("--tools"))
        #expect(command.args.contains(BriefingPrompts.system))
        #expect(ClaudeHeadless.briefingTimeout > ClaudeHeadless.timeout)
    }
}
