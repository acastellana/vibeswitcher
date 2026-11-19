import Foundation
import Testing
@testable import VibeCore

/// The scorecard's two new groups (docs/process/reviews/books-patterns.md shortlist 1 and 7): each project's merge
/// objectives over each week, and the leads' messages to the user per day by reason with the share acted on, from the
/// boards and the leads' chat transcripts by kind and time only.
struct ScorecardMessagesTests {
    let temp = Scratch()

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(_ month: Int, _ day: Int, _ hour: Double = 0) -> Double {
        utc.date(from: DateComponents(year: 2026, month: month, day: day))!.timeIntervalSince1970 + hour * 3600
    }

    static func stamp(_ at: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: at))
    }

    // MARK: Transcript lines as Claude Code writes them

    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func prompt(_ text: String, at: Double, id: String) -> String {
        line(["type": "user", "uuid": id, "timestamp": stamp(at), "isSidechain": false, "message": ["role": "user", "content": text]])
    }

    static func text(_ words: String, at: Double, id: String, sidechain: Bool = false) -> String {
        line(["type": "assistant", "uuid": id, "timestamp": stamp(at), "isSidechain": sidechain,
              "message": ["role": "assistant", "content": [["type": "text", "text": words]]]])
    }

    static func bash(_ command: String, at: Double, id: String) -> String {
        line(["type": "assistant", "uuid": id, "timestamp": stamp(at), "isSidechain": false,
              "message": ["role": "assistant", "content": [["type": "tool_use", "id": "tool-\(id)", "name": "Bash", "input": ["command": command]]]]])
    }

    /// The result of the tool call `call` made (`bash`'s id), its output as Claude Code writes it: a string, or text
    /// blocks.
    static func result(of call: String, _ output: String, at: Double, id: String, blocks: Bool = false) -> String {
        let content: Any = blocks ? [["type": "text", "text": output]] : output
        return line(["type": "user", "uuid": id, "timestamp": stamp(at), "isSidechain": false,
                     "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tool-\(call)", "content": content]]]])
    }

    /// `vs-shell run`'s output for `request`, as `ShellAsk.run` prints it (pinned in `theFiledRequestIsToldByVsShellsOwnOutput`):
    /// filed with a card, or started at once.
    static func filed(_ request: ShellRequest, atOnce: Bool = false) -> String {
        atOnce ? "Filed shell request \(request.id). The user lets agents open shells without asking, so VibeSwitcher starts it"
            : "Filed shell request \(request.id): its card waits in this session's chat in VibeSwitcher"
    }

    static func compactSummary(at: Double, id: String) -> String {
        line(["type": "user", "uuid": id, "timestamp": stamp(at), "isSidechain": false, "isCompactSummary": true,
              "message": ["role": "user", "content": "This session is being continued from a previous conversation that ran out of context."]])
    }

    static func queued(_ text: String, at: Double, id: String) -> String {
        line(["type": "attachment", "uuid": id, "timestamp": stamp(at), "isSidechain": false,
              "attachment": ["type": "queued_command", "prompt": text, "commandMode": "prompt"]])
    }

    static func request(_ n: Int) -> ShellRequest {
        ShellRequest(id: "0000000\(n)-aaaa-4bbb-8ccc-dddddddddddd", session: "abc", cwd: "/Users/someone/project", command: "make install",
                     label: "", createdAt: Date(timeIntervalSince1970: 0))
    }
    static let request = request(1)

    /// VibeSwitcher's message about a shell card, typed into the lead as `LeadDelivery` types it.
    static func shellNotice(_ state: ShellAsk.Answer.State, auto: Bool = false, request: ShellRequest = request, at: Double, id: String) -> String {
        let message = ShellAsk.message(request, ShellAsk.Answer(state: state, at: Date(timeIntervalSince1970: at), auto: auto, name: "shell"))!
        return prompt(LeadDelivery.typed(message, from: .system("from New Shell")), at: at, id: id)
    }

    /// What VibeSwitcher relays as the user's when they answer one of the lead's questions (`LeadAnswerOutcome`).
    static func answerRelay(at: Double, id: String) -> String {
        prompt(LeadAnswerOutcome.answered(LeadQuestion(text: "Which?", options: ["a"], at: 0), saw: 1).message(given: "a")!, at: at, id: id)
    }

    /// The notice's wording is ShellAsk.message's: pressing Run or declining is an answer; expiring, failing or starting
    /// at once (the user lets agents open shells without asking) isn't. Each names its request.
    @Test func aShellAnswerIsToldByShellAsksOwnWording() {
        func says(_ state: ShellAsk.Answer.State, auto: Bool = false) -> LeadChatReader.ShellOutcome? {
            let told = LeadChatReader.shellOutcome(ShellAsk.message(Self.request, ShellAsk.Answer(state: state, at: Date(), auto: auto, why: "x"))!)
            return told?.request == Self.request.id ? told?.outcome : nil
        }
        #expect(says(.started) == .answered && says(.declined) == .answered)
        #expect(says(.started, auto: true) == .atOnce && says(.expired) == .unanswered && says(.failed) == .unanswered)
        #expect(LeadChatReader.shellOutcome("Report from the worker: the user pressed Run") == nil)
        // Steered while the lead works, each line quoted.
        let quoted = SteerReply.quote(ShellAsk.message(Self.request, ShellAsk.Answer(state: .declined, at: Date()))!)
        #expect(LeadChatReader.shellOutcome(quoted).map { $0.outcome == .answered && $0.request == Self.request.id } == true && quoted.hasPrefix(">"))
        // The lead's start and reopening prompts are VibeSwitcher's, pinned to their wording.
        let start = LeadPrompts.leadStart(root: "/r", goal: nil, note: "n")
        #expect(!LeadChatReader.isUsersMessage(start), "\(start.prefix(80))")
        #expect(!LeadChatReader.isUsersMessage(RestartReopen.leadNotice(board: LeadBoard())))
        #expect(LeadChatReader.isShellCard("vs-shell run --cwd x -- make") && LeadChatReader.isShellCard("  vs-shell  run -- ls"))
        #expect(!LeadChatReader.isShellCard("echo vs-shell run") && !LeadChatReader.isShellCard("vs-shell help"))
    }

    /// What VibeSwitcher sends as the user's when they answer or hold a question isn't a reply to the lead's last
    /// message: the board counts it on the question. Pinned to `LeadAnswerOutcome`'s wording, each kind.
    @Test func anAnswerRelayedToTheLeadIsNotAReply() {
        var question = LeadQuestion(text: "Which?", options: ["a", "b"], at: 0)
        question.proposal = "a"
        var revised = question
        revised.revisions = [LeadQuestion.Revision(text: "Which one?", options: ["a"], note: "n", at: 1)]
        let relays = [LeadAnswerOutcome.answered(question, saw: question.version), .answered(revised, saw: 1), .withdrawn(question),
                      .afterAutoDecision(question)].compactMap { $0.message(given: "b") } + [LeadAnswerOutcome.holdMessage(question)]
        #expect(relays.count == 5)
        for relay in relays { #expect(!LeadChatReader.isUsersMessage(relay), "\(relay.prefix(60))") }
        #expect(LeadChatReader.isUsersMessage("thanks, next") && LeadChatReader.isUsersMessage("The user is me: go ahead"))
    }

    /// A card is a request `vs-shell run` says it filed, read from its own output: with a card, or started at once (no
    /// card); a refused or mistyped call filed nothing.
    @Test func theFiledRequestIsToldByVsShellsOwnOutput() throws {
        let folder = temp.url("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cwd = String(cString: realpath(folder.path, nil))
        let book = WalletTestStamps.book
        let vault = LeadVault(folder: temp.url("vault")) { request in
            try book.answer(request, from: .session("11111111-2222-4333-8444-555555555555"), userOpened: true)
        }
        for atOnce in [false, true] {
            let asked = temp.url("asked-\(atOnce)")
            let ran = ShellAsk.run(["run", "--", "make", "install"], cwd: cwd, folder: asked, vault: vault, atOnce: atOnce)
            let request = try #require(ShellAsk.filed(in: asked).requests.first, "\(ran.error)")
            let told = try #require(LeadChatReader.filed(ran.output), "\(ran.output)")
            #expect(told.request == request.id && told.atOnce == atOnce)
            // The fixtures below print the same.
            #expect(LeadChatReader.filed(Self.filed(request, atOnce: atOnce)).map { $0.request == request.id && $0.atOnce == atOnce } == true)
        }
        let refused = ShellAsk.run(["run", "--cwd", "missing", "--", "ls"], cwd: cwd, folder: temp.url("asked-no"), vault: vault)
        #expect(refused.status == 1 && LeadChatReader.filed(refused.output + refused.error) == nil)
        #expect(LeadChatReader.filed("Filed shell request ") == nil && LeadChatReader.filed("Filed shell request abc") == nil)
    }

    /// The transcript's kinds and times: one reply per turn (its last text), the user's typed and queued messages,
    /// shell cards (filed) and how each ended; tool results, sidechains, VibeSwitcher's notices and relays of answers,
    /// and Claude Code's compaction summary aren't the user's messages.
    @Test func theTranscriptGivesKindsAndTimes() {
        let t = Self.date(11, 10, 9)
        let lines = [
            Self.prompt(LeadPrompts.leadStart(root: "/r", goal: nil, note: "n"), at: t - 100, id: "start"),
            Self.prompt(RestartReopen.leadNotice(board: LeadBoard()), at: t - 50, id: "reopen"),
            Self.prompt("Please fix the flake", at: t, id: "u1"),
            Self.text("Looking.", at: t + 10, id: "a1"),
            Self.bash("vs-shell run --cwd . -- make install", at: t + 20, id: "a2"),
            Self.result(of: "a2", Self.filed(Self.request), at: t + 21, id: "r1"),
            Self.bash("echo vs-shell run", at: t + 25, id: "a3"),
            Self.text("Filed the card; press Run.", at: t + 30, id: "a4"),
            Self.text("A subagent's words", at: t + 31, id: "s1", sidechain: true),
            Self.shellNotice(.started, at: t + 60, id: "n1"),
            Self.text("It ran.", at: t + 70, id: "a5"),
            Self.prompt(LeadDelivery.typed("Report from the worker", from: .system("reports")), at: t + 80, id: "n2"),
            Self.text("Merged.", at: t + 90, id: "a6"),
            Self.queued("thanks, next", at: t + 100, id: "q1"),
            Self.text("On it.", at: t + 110, id: "a7"),
            Self.compactSummary(at: t + 120, id: "c1"),
            Self.answerRelay(at: t + 140, id: "v1"),
            Self.text("Going with a.", at: t + 150, id: "a8"),
            Self.prompt(LeadAnswerOutcome.holdMessage(LeadQuestion(text: "Which?", options: ["a"], at: 0)), at: t + 160, id: "h1"),
            Self.text("Waiting.", at: t + 170, id: "a9"),
            "not json",
        ]
        let events = LeadChatReader.events(Data(lines.joined(separator: "\n").utf8))
        let timeline = LeadChatTimeline.merged([events, events])
        #expect(timeline.userMessages == [t, t + 100], "\(timeline)")
        #expect(timeline.replies == [t + 30, t + 70, t + 90, t + 110, t + 150, t + 170], "\(timeline)")
        #expect(timeline.shells == [.init(request: Self.request.id, at: t + 20)], "\(timeline)")
        #expect(timeline.shellEnds == [Self.request.id: .init(.answered, at: t + 60)], "\(timeline)")
        // A call refused (no request filed) and one with no result yet aren't cards; one started at once is told so,
        // from its output or VibeSwitcher's notice; each ending goes to its own request.
        let (r2, r3) = (Self.request(2), Self.request(3))
        let more = [Self.bash("vs-shell run --cwd missing -- ls", at: t, id: "b1"),
                    Self.result(of: "b1", "vs-shell: refused: --cwd: no such folder: missing", at: t + 1, id: "rb1"),
                    Self.bash("vs-shell run -- ls", at: t + 5, id: "b2"), Self.result(of: "b2", Self.filed(r2, atOnce: true), at: t + 6, id: "rb2", blocks: true),
                    Self.shellNotice(.started, auto: true, request: r2, at: t + 7, id: "o2"),
                    Self.bash("vs-shell run -- ls", at: t + 10, id: "b3"), Self.result(of: "b3", Self.filed(r3), at: t + 11, id: "rb3"),
                    Self.bash("vs-shell run -- ls", at: t + 20, id: "b4"),
                    Self.shellNotice(.expired, request: r3, at: t + 1810, id: "o3")]
        let told = LeadChatTimeline.merged([LeadChatReader.events(Data(more.joined(separator: "\n").utf8))])
        #expect(told.shells == [.init(request: r2.id, at: t + 5, atOnce: true), .init(request: r3.id, at: t + 10)], "\(told)")
        #expect(told.shellEnds == [r2.id: .init(.atOnce, at: t + 7), r3.id: .init(.unanswered, at: t + 1810)], "\(told)")
        #expect(LeadMessages.messages(questions: [], updates: [], chat: told, now: t + 2000) == [LeadMessage(reason: .mustAct, at: t + 10, acted: false)])
        #expect(LeadChatReader.events(Data()).isEmpty)
    }

    /// End to end from the transcript: a wake notice, a relayed answer or the compaction summary after the lead's
    /// replies isn't the user acting on them; the user's typed prompt is.
    @Test func onlyTheUsersOwnMessageActsOnTheLeadsReplies() {
        let t = Self.date(11, 10, 9), day = 86_400.0
        let lines = [Self.prompt("go", at: t, id: "u0"), Self.text("Started.", at: t + 10, id: "a1"),
                     Self.prompt(LeadDelivery.typed("Report from the worker", from: .system("reports")), at: t + 100, id: "w1"),
                     Self.text("Merged it.", at: t + 110, id: "a2"),
                     Self.answerRelay(at: t + 200, id: "v1"), Self.text("Going with a.", at: t + 210, id: "a3"),
                     Self.compactSummary(at: t + 300, id: "c1")]
        func acted(_ lines: [String]) -> [Bool?] {
            let chat = LeadChatTimeline.merged([LeadChatReader.events(Data(lines.joined(separator: "\n").utf8))])
            return LeadMessages.messages(questions: [], updates: [], chat: chat, now: t + 2 * day).map(\.acted)
        }
        #expect(acted(lines) == [false, false, false])
        #expect(acted(lines + [Self.prompt("thanks", at: t + 400, id: "u1")]) == [true, true, true])
    }

    /// The board's updates that the tool server and the app post themselves when they take a move of the base aren't
    /// the lead's messages. Pinned to the code: every update VibeSwitcher builds, other than post_update's, is titled
    /// "Took <a base move's count> on <its branch>".
    @Test func theServersOwnUpdatesAreNotTheLeads() throws {
        for commits in [1, 3] {
            let move = LeadVault.BaseMove(branch: "agent/x-1", from: "a", to: "b", accepted: true,
                                          commits: (0..<commits).map { .init(sha: "\($0)", subject: "s") }, sessions: [])
            #expect(!LeadMessages.isLeadsUpdate("Took \(move.count) on \(move.branch)"))
        }
        #expect(LeadMessages.isLeadsUpdate("Took the scorecard to done") && LeadMessages.isLeadsUpdate("Today: Took 3 commits on main"))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = repo.appendingPathComponent("Sources")
        let built = try Regex(#"LeadUpdate\(title: ([^,]+),"#)
        var titles: [String] = []
        for file in FileManager.default.subpaths(atPath: sources.path) ?? [] where file.hasSuffix(".swift") {
            // The sandbox and the benches make their own boards.
            guard !file.hasSuffix("Sandbox.swift"), !file.contains("Bench") else { continue }
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            titles += text.matches(of: built).map { String($0.output[1].substring ?? "") }
        }
        #expect(titles.count >= 3, "\(titles)")
        for title in titles where title != "title" {
            #expect(try Regex(#"^"Took \\\(\w+\.count\) on \\\(\w+(\.branch)?\)"$"#).wholeMatch(in: title) != nil, "\(title)")
        }
    }

    /// The reasons by tool, and acted on within a day: a question answered, a card run or declined, an update or reply
    /// followed by the user's message; a message under a day old with nothing yet isn't judged.
    @Test func messagesAreClassifiedByToolAndActedOnWithinADay() {
        let t = Self.date(11, 10, 9), day = 86_400.0
        var answered = LeadQuestion(text: "Which?", options: ["a"], at: t)
        answered.answer = "a"
        answered.answeredAt = t + 3600
        var late = LeadQuestion(text: "Late?", options: ["a"], at: t)
        late.answer = "a"
        late.answeredAt = t + day + 60
        var withdrawn = LeadQuestion(text: "Gone?", options: ["a"], at: t)
        withdrawn.withdrawnAt = t + 60
        let fresh = LeadQuestion(text: "New?", options: ["a"], at: t + 3 * day - 3600)
        let updates = [(title: "Today: 3 merged", at: t + 100), (title: "Scorecard merged", at: t + 2 * day), (title: "Retrospective: week", at: t + 3 * day - 60)]
        let (r1, r2) = (Self.request(1).id, Self.request(2).id)
        let chat = LeadChatTimeline(replies: [t + 200, t + 2 * day + 100], userMessages: [t + 5000],
                                    shells: [.init(request: r1, at: t + 300), .init(request: r2, at: t + 2 * day + 10)],
                                    shellEnds: [r1: .init(.answered, at: t + 400)])
        let now = t + 3 * day
        let messages = LeadMessages.messages(questions: [answered, late, withdrawn, fresh], updates: updates, chat: chat, now: now)
        func found(_ reason: LeadMessageReason, _ at: Double) -> LeadMessage? { messages.first { $0.reason == reason && $0.at == at } }
        #expect(messages.count == 11)
        #expect(found(.mustAct, t).map { _ in messages.filter { $0.at == t }.map(\.acted) } == [true, false, false])
        #expect(found(.mustAct, t + 3 * day - 3600)?.acted == nil)
        #expect(found(.dailySummary, t + 100)?.acted == true)
        #expect(found(.finishedOrProblem, t + 2 * day)?.acted == false)
        #expect(found(.finishedOrProblem, t + 3 * day - 60)?.acted == nil)
        // Under a day old with nothing yet: not judged.
        #expect(found(.other, t + 200)?.acted == true && found(.other, t + 2 * day + 100).map { $0.acted == nil } == true)
        #expect(found(.mustAct, t + 300)?.acted == true && found(.mustAct, t + 2 * day + 10).map { $0.acted == nil } == true)
        // A shell started at once is no card; one that expired wasn't acted on, even within its day; each card takes
        // its own request's ending, not the next one's.
        let ids = (1...5).map { Self.request($0).id }
        let shells = LeadChatTimeline(shells: [.init(request: ids[0], at: t), .init(request: ids[3], at: t + 50, atOnce: true),
                                               .init(request: ids[1], at: t + 100), .init(request: ids[2], at: t + 200), .init(request: ids[4], at: t + 260)],
                                      shellEnds: [ids[0]: .init(.atOnce, at: t + 10), ids[1]: .init(.unanswered, at: t + 150),
                                                  ids[2]: .init(.answered, at: t + 250)])
        #expect(LeadMessages.messages(questions: [], updates: [], chat: shells, now: t + 300).map(\.acted) == [false, true, nil])
        // A day on, nothing came: not acted on.
        let later = LeadMessages.messages(questions: [], updates: [], chat: chat, now: now + day)
        #expect(later.filter { $0.at > t + day }.map(\.acted) == [false, false])

        let week = ScorecardMessages(messages, from: t - day, to: t + 6 * day, kept: true)
        #expect(week.byReason == [.mustAct: 6, .dailySummary: 1, .finishedOrProblem: 2, .other: 2] && week.total == 11)
        #expect(week.judged == 7 && week.acted == 4 && abs((week.actedShare ?? 0) - 4.0 / 7) < 1e-9, "\(week)")
        #expect(abs((week.perDay ?? 0) - 11.0 / 7) < 1e-9 && week.perDay(.dailySummary) == 1.0 / 7)
        // No transcript: questions and updates only, and an update isn't judged (whether the user replied isn't known).
        let unread = LeadMessages.messages(questions: [answered], updates: updates, chat: nil, now: now)
        #expect(unread.count == 4 && unread.filter { $0.reason != .mustAct }.allSatisfy { $0.acted == nil })
    }

    /// An empty week: counted (0 a day), the share not judged; with no board, not recorded.
    @Test func anEmptyWeekHasNoShare() {
        let empty = ScorecardMessages([LeadMessage(reason: .other, at: 5, acted: true)], from: 10, to: 20, kept: true)
        #expect(empty.total == 0 && empty.perDay == 0 && empty.actedShare == nil && empty.judged == 0)
        #expect(ScorecardMessages().perDay == nil && ScorecardMessages().perDay(.mustAct) == nil)
        let noRuns = MergeObjectives([], project: "proj", after: Date(timeIntervalSince1970: 10), upTo: Date(timeIntervalSince1970: 20))
        #expect(noRuns.runs == 0 && noRuns.rerunPercent == nil && noRuns.calmMedianS == nil && noRuns.statusLine == nil)
    }

    // MARK: From the files, through the collector

    static func merge(_ result: String, project: String = "proj", at: Double, load: Double = 3, minutes: Double = 8) -> MergeSample {
        MergeSample(t: LoadStats.stamp(Date(timeIntervalSince1970: at)), project: project, task: "t", load: [load, load, load],
                    waitedS: 0, slotWaitS: 0, durationS: Int(minutes * 60), firstRun: result == "passed" ? "passed" : result == "conflict" ? nil : "failed",
                    reran: nil, rerunWhole: nil, result: result)
    }

    /// Both groups for this week and the last, each with its n, from merges-<day>.jsonl, the board and its archive, and
    /// the lead's transcript the token ledger names; the week before has no merge run and no message.
    @Test func theCollectorCountsBothGroupsForBothWeeks() async throws {
        let root = temp.url("card")
        let project = root.appendingPathComponent("proj"), home = root.appendingPathComponent("home")
        let folder = project.appendingPathComponent(".vibeswitcher"), claude = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude.appendingPathComponent("p"), withIntermediateDirectories: true)

        // This week (Nov 2 – 8): 12 runs, 1 passed only on a rerun (8.3%: missed), calm median 9 min; a conflict and
        // another project's run aren't counted. The week before: nothing.
        let stats = home.appendingPathComponent("stats")
        var samples = (0..<11).map { Self.merge("passed", at: Self.date(11, 3, Double($0)), minutes: Double(8 + $0 % 3)) }
        samples += [Self.merge("passed_on_rerun", at: Self.date(11, 4, 1), load: 20, minutes: 30), Self.merge("conflict", at: Self.date(11, 4, 2)),
                    Self.merge("passed_on_rerun", project: "other", at: Self.date(11, 4, 3))]
        for sample in samples { try sample.append(in: stats, at: Date(timeIntervalSince1970: Self.date(11, 3))) }

        // The board: a question answered in an hour, an open one from 2 days ago; a daily summary and an update, the
        // first archived.
        var board = LeadBoard()
        var question = LeadQuestion(text: "Which?", options: ["a"], at: Self.date(11, 5, 9))
        question.answer = "a"
        question.answeredAt = Self.date(11, 5, 10)
        board.questions = [question, LeadQuestion(text: "Open?", options: ["a"], at: Self.date(11, 6, 9))]
        var summary = LeadUpdate(title: "Today: 4 merged", body: "b")
        summary.at = Self.date(11, 6, 18)
        var update = LeadUpdate(title: "Done: the scorecard", body: "b")
        update.at = Self.date(11, 7, 12)
        // The tool server's own update when it took a move of the base: not the lead's.
        var taken = LeadUpdate(title: "Took 2 commits on main", body: "accepted 2 commits on main: …")
        taken.at = Self.date(11, 7, 11)
        board.updates = [taken, update]
        try JSONEncoder().encode(board).write(to: folder.appendingPathComponent("board.json"))
        let archived = String(decoding: try JSONEncoder().encode(["update": summary]), as: UTF8.self)
        try (archived + "\n").write(to: folder.appendingPathComponent("board-archive.jsonl"), atomically: true, encoding: .utf8)

        // The lead's transcript (the ledger names it; its subagent's isn't read): two turns, a shell card run, and the
        // user writing an hour after the update.
        let t = Self.date(11, 7, 9)
        let transcript = [Self.prompt("go", at: t, id: "u1"), Self.text("Starting.", at: t + 60, id: "a1"),
                          Self.bash("vs-shell run -- make install", at: t + 120, id: "a2"),
                          Self.result(of: "a2", Self.filed(Self.request), at: t + 121, id: "r1"),
                          Self.shellNotice(.started, at: t + 600, id: "n1"), Self.text("Installed.", at: t + 700, id: "a3"),
                          Self.prompt("great", at: Self.date(11, 7, 13), id: "u2")]
        try transcript.joined(separator: "\n").write(to: claude.appendingPathComponent("p/lead.jsonl"), atomically: true, encoding: .utf8)
        try Self.text("subagent", at: t, id: "s1").write(to: claude.appendingPathComponent("p/sub.jsonl"), atomically: true, encoding: .utf8)
        let ledger: [String: Any] = ["since": Self.date(10, 1), "at": Self.date(11, 8), "days": [:],
                                     "files": ["p/lead.jsonl": ["lead": true, "offset": 0], "p/lead/subagents/sub.jsonl": ["lead": true, "offset": 0],
                                               "p/other.jsonl": ["lead": false, "offset": 0]]]
        try JSONSerialization.data(withJSONObject: ledger).write(to: folder.appendingPathComponent("lead-tokens.json"))

        let now = Date(timeIntervalSince1970: Self.date(11, 8, 12))
        let collector = SetupStatsCollector(home: home, codexHome: nil, calendar: Self.utc, now: { now })
        collector.claudeProjects = claude
        collector.installedApp = { nil }
        let range = DateInterval(start: Date(timeIntervalSince1970: Self.date(11, 2)), end: Date(timeIntervalSince1970: Self.date(11, 9)))
        let card = try #require(await collector.collect(projects: [project.path], range: range).quality?.scorecard)

        // Merge objectives: this week's figures with their n; the week before empty for the same project.
        #expect(card.week.merges.map(\.project) == ["proj"] && card.previous.merges.map(\.project) == ["proj"])
        let objectives = try #require(card.week.merges.first?.objectives)
        #expect(objectives == MergeObjectives(runs: 12, passedOnRerun: 1, calmRuns: 11, calmMedianS: 9 * 60), "\(objectives)")
        #expect(objectives.rerunsMissed && objectives.rerunText.hasPrefix("8.3% passed only on rerun (1 of 12"))
        #expect(card.previous.merges.first?.objectives.runs == 0)

        // Messages: 2 questions and a shell card (must act), a daily summary, an update, 2 replies (other).
        let sent = card.week.messages
        #expect(sent.kept && sent.chatKept)
        #expect(sent.byReason == [.mustAct: 3, .dailySummary: 1, .finishedOrProblem: 1, .other: 2], "\(sent.byReason)")
        // Acted on: the answered question, the shell card, the summary (the user wrote at 9:00 the next morning), the
        // update and both replies (the user wrote at 13:00); not the question still open 2 days on.
        #expect(sent.judged == 7 && sent.acted == 6, "\(sent)")
        #expect(card.previous.messages.total == 0 && card.previous.messages.actedShare == nil && card.previous.messages.perDay == 0)
    }
}
