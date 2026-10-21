import Foundation
import Testing
@testable import VibeCore

/// Brief me on <project>: the same composer as the global briefing, restricted to one project: its news since its
/// own last briefing, what's running and blocked, its questions (even when it's quiet), and only its own waiting
/// sessions. Made-up logs only: no real progress text, no real model.
struct ProjectBriefingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970
    let helpers = BriefingTests()

    func task(_ slug: String, _ title: String, _ status: LeadTask.Status) -> LeadTask { helpers.task(slug, title, status) }

    /// A project with news: its entries in plain words, its counts, its questions, its waiting sessions, nothing of
    /// any other project's; the prompt is about it alone.
    @Test func aProjectWithNewsIsBriefedAlone() {
        var board = LeadBoard()
        board.tasks = [task("phone-menu", "The phone's menu", .running), task("signing", "Signing", .blocked), task("docs", "Docs", .done)]
        board.questions = [LeadQuestion(text: "Ship the install tonight?", options: ["yes", "no"], priority: .blocking),
                           LeadQuestion(text: "Which logo?", options: [])]
        let source = Briefing.Source(name: "vibeswitcher", progress: helpers.log([(minutesAgo: 40, text: "Started a worker on phone-menu"),
                                                                                   (minutesAgo: 20, text: "Merged docs: Docs"),
                                                                                   (minutesAgo: 10, text: "Audit of signing: incomplete, clean")]),
                                     board: board)
        let sessions = [helpers.session("vibeswitcher", .needsInput), helpers.session("genswap", .needsInput),
                        helpers.session("vibeswitcher", .working)]
        let input = Briefing.compose(project: source, sessions: sessions, lastBriefed: nil, now: now)

        #expect(input.project == "vibeswitcher")
        #expect(input.projects.map(\.name) == ["vibeswitcher"])
        let project = input.projects[0]
        #expect(project.news == ["Checked Signing: didn't pass yet", "Landed: Docs", "Work started: The phone's menu"])
        #expect((project.landed, project.running, project.blocked, project.questionCount) == (1, 1, 1, 2))
        // Only its own sessions waiting on the user.
        #expect(input.waiting.map(\.project) == ["vibeswitcher"])
        #expect(input.waitingCount == 1)

        let text = input.text
        #expect(text.contains("vibeswitcher: 3 new in its log; 1 landed, 1 running, 1 blocked, 2 questions for the user."))
        #expect(text.contains("  - Question for the user: Ship the install tonight?"))
        #expect(text.contains("  - Question for the user: Which logo?"))
        #expect(!text.contains("genswap"))

        let prompt = BriefingPrompts.prompt(input, language: .english)
        #expect(prompt.contains("in the project vibeswitcher in the last 3 hours"))
        #expect(prompt.contains("what landed, what's running, what's blocked, and the questions waiting on the user"))
        #expect(prompt.contains("70 to 90 words"))
        #expect(!prompt.contains("across these projects"))

        let template = Briefing.template(input)
        #expect(template == "In vibeswitcher, 3 updates; 1 landed, 1 running, 1 blocked, 2 questions for the user. "
                + "Latest: Checked Signing: didn't pass yet. For you: Ship the install tonight? Also: Which logo? "
                + "1 session needs you: vibeswitcher.")
    }

    /// A quiet project still names its questions: they're what the user asked to hear about.
    @Test func aQuietProjectStillNamesItsQuestions() {
        var board = LeadBoard()
        board.tasks = [task("x", "X", .running)]
        board.questions = [LeadQuestion(text: "Which logo?", options: [])]
        let source = Briefing.Source(name: "genswap", progress: helpers.log([(minutesAgo: 600, text: "Update: long ago")]), board: board)
        let input = Briefing.compose(project: source, sessions: [], lastBriefed: nil, now: now)

        #expect(input.projects[0].isQuiet)
        #expect(input.lines == ["genswap: nothing new; 1 running, 1 question for the user.", "  - Question for the user: Which logo?"])
        #expect(Briefing.template(input) == "Nothing new in genswap; 1 running, 1 question for the user. For you: Which logo?")
        // Quiet with nothing on the board: one sentence.
        let empty = Briefing.compose(project: .init(name: "films", progress: nil, board: LeadBoard()), sessions: [], lastBriefed: nil, now: now)
        #expect(Briefing.template(empty) == "Nothing new in films.")
        #expect(!empty.isEmpty)
    }

    /// It covers what's new since that project's own last briefing (or the last three hours, if longer).
    @Test func itCoversWhatsNewSinceItsOwnLastBriefing() {
        let source = Briefing.Source(name: "p", progress: helpers.log([(minutesAgo: 600, text: "Merged a: A"), (minutesAgo: 30, text: "Merged b: B")]),
                                     board: LeadBoard())
        let recent = Briefing.compose(project: source, sessions: [], lastBriefed: now - 60, now: now)
        #expect(recent.projects[0].news == ["Landed: B"])
        let yesterday = Briefing.compose(project: source, sessions: [], lastBriefed: now - 86_400, now: now)
        #expect(yesterday.projects[0].news == ["Landed: B", "Landed: A"])
        #expect(BriefingPrompts.prompt(yesterday, language: .english).contains("in the last 24 hours"))
    }

    /// The global briefing of the same sources is the one it always was: no project, quiet projects one line, the
    /// same prompt and template.
    @Test func theGlobalBriefingIsUnchanged() {
        var board = LeadBoard()
        board.questions = [LeadQuestion(text: "Which logo?", options: [])]
        let input = Briefing.compose([.init(name: "genswap", progress: nil, board: board)], sessions: [], lastBriefed: nil, now: now)
        #expect(input.project == nil)
        #expect(input.lines == ["genswap: nothing new; 1 question for the user."])
        #expect(BriefingPrompts.prompt(input, language: .english).contains("across these projects"))
        #expect(Briefing.template(input) == "In genswap, 1 question for the user.")
    }

    /// Redacted like the global one, before any model sees it.
    @Test func itIsRedactedBeforeTheModel() {
        var board = LeadBoard()
        board.questions = [LeadQuestion(text: "Push with \(helpers.token)?", options: [])]
        let input = Briefing.compose(project: .init(name: "p", progress: helpers.log([(minutesAgo: 5, text: "Update: key \(helpers.token)")]), board: board),
                                     sessions: [], lastBriefed: nil, now: now)
        let secret = String(helpers.token.dropFirst(4))
        #expect(!input.text.contains(secret))
        #expect(!BriefingPrompts.prompt(input, language: .english).contains(secret))
        #expect(!Briefing.template(input).contains(secret))
    }
}
