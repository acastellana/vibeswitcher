import Foundation
import Testing
@testable import VibeCore

/// What notifies (a banner, its sound, the phone's copy through `Notifier.onAlert`): a lead's team only when all its
/// work is done or the user is needed; the user's own sessions as Settings › Notifications says.
struct AlertRulesTests {
    static let wt = "/r/acme/.vibeswitcher/worktrees/fix-login"

    static func session(_ role: LeadLaunch.Role?, _ status: SessionStatus, tty: String = "ttys001", detail: String? = nil,
                        task: String? = nil, activity: String? = nil) -> Session {
        var session = Session(tty: tty, agent: .claude, pid: 1, startedAt: Date(), cwd: role == .lead || role == nil ? "/r/acme" : wt,
                              project: "acme", task: task, status: status, statusSince: Date(), detail: detail, hasHooks: true, inTerminalApp: false)
        session.teamRole = role
        session.activity = activity
        return session
    }

    /// The alert as the user gets it: "nothing", or its banner, whether it plays a sound, and what the phone shows.
    static func said(_ alert: AlertRules.Alert?) -> String {
        guard let alert else { return "nothing" }
        return "banner '\(alert.title)' / '\(alert.body)'" + (alert.sound ? " · sound" : "")
            + " · phone '\(alert.phoneTitle)' / '\(alert.phoneBody)' @\(alert.tty)"
    }

    static let question = LeadQuestion(id: "q1", text: "Ship the beta to everyone?\nOr only to the testers first.", options: ["Everyone", "Testers"])

    static var mark: LeadAllDone {
        LeadAllDone(id: "m1", at: 100, since: 0, tasks: [.init(slug: "a", title: "A", outcome: .merged), .init(slug: "b", title: "B", outcome: .merged)])
    }

    @Test func workersAndVerifiersNeverNotify() {
        for role in [LeadLaunch.Role.worker, .verifier] {
            for status in [SessionStatus.done, .needsInput] {
                // Done for its lead, or asking its lead something: the lead handles it.
                let session = Self.session(role, status, detail: "Which database?")
                #expect(Self.said(AlertRules.attention(session, question: nil, settings: .init())) == "nothing", "\(role) \(status)")
                // Even with a question of the lead's open: that's the lead's to tell.
                #expect(AlertRules.attention(session, question: Self.question, settings: .init()) == nil)
            }
        }
    }

    @Test func aLeadsTurnEndingWithTasksOpenIsSilent() {
        #expect(Self.said(AlertRules.attention(Self.session(.lead, .done), question: nil, settings: .init())) == "nothing")
        #expect(Self.said(AlertRules.attention(Self.session(.lead, .idle), question: nil, settings: .init())) == "nothing")
    }

    @Test func aLeadsTurnEndingOnAQuestionForTheUserNotifiesWithItsFirstLine() {
        let alert = AlertRules.attention(Self.session(.lead, .done), question: Self.question, settings: .init())
        #expect(Self.said(alert) == "banner 'The lead of acme needs you' / 'Ship the beta to everyone?' · sound"
            + " · phone 'The lead of acme needs you' / 'Ship the beta to everyone?' @ttys001")
        #expect(alert?.kind == .needsYou)
        #expect(alert?.subtitle == "It asks")
        // Its sound follows the setting; it doesn't notify with needing-input notifications off.
        #expect(AlertRules.attention(Self.session(.lead, .done), question: Self.question, settings: .init(sound: false))?.sound == false)
        #expect(AlertRules.attention(Self.session(.lead, .done), question: Self.question, settings: .init(needsInput: false)) == nil)
    }

    @Test func aLeadsTerminalOnAPromptNotifies() {
        let lead = Self.session(.lead, .needsInput, detail: "Claude needs your permission to use Bash")
        let alert = AlertRules.attention(lead, question: nil, settings: .init())
        #expect(Self.said(alert) == "banner 'The lead of acme needs you' / 'Claude needs your permission to use Bash' · sound"
            + " · phone 'The lead of acme needs you' / 'Claude needs your permission to use Bash' @ttys001")
        // A prompt while a question is open: the prompt, which the question's alert doesn't cover.
        #expect(AlertRules.attention(lead, question: Self.question, settings: .init())?.body == "Claude needs your permission to use Bash")
        #expect(AlertRules.attention(lead, question: nil, settings: .init(needsInput: false)) == nil)
    }

    @Test func aQuestionNotifiesOnceWhicheverSaysItFirst() {
        var gate = AlertRules.Gate()
        // The board shows it, then the lead's turn ends on it: one banner.
        let asked = gate.pass(AlertRules.lead(.asked(Self.question, project: "acme", leadTTY: "ttys001"), settings: .init()))
        #expect(Self.said(asked).hasPrefix("banner 'The lead of acme needs you' / 'Ship the beta to everyone?' · sound"))
        #expect(gate.pass(AlertRules.attention(Self.session(.lead, .done), question: Self.question, settings: .init())) == nil)
        // A new wording is news.
        var revised = Self.question
        revised.revisions = [.init(text: "Ship it?", options: [], note: "clearer")]
        #expect(gate.pass(AlertRules.lead(.asked(revised, project: "acme", leadTTY: "ttys001"), settings: .init()))?.subtitle == "It updated a question")
        // A proposal on a timer says so.
        let timed = LeadQuestion(id: "q2", text: "Which port?", options: ["80", "8080"], proposal: "8080", decideIn: 10)
        let alert = AlertRules.lead(.asked(timed, project: "acme", leadTTY: "ttys001"), settings: .init())
        #expect(alert?.subtitle == "Going with ‘8080’ in 10 min unless you answer")
        #expect(alert?.phoneBody == "Going with ‘8080’ in 10 min unless you answer: Which port?")
    }

    @Test func theAllDoneCardNotifiesOncePerBatch() {
        var gate = AlertRules.Gate()
        let alert = gate.pass(AlertRules.lead(.allDone(Self.mark, project: "acme", leadTTY: "ttys001"), settings: .init()))
        #expect(Self.said(alert) == "banner 'All tasks finished in acme' / 'All 2 tasks are finished; every one of them merged.'"
            + " · phone 'All tasks finished in acme' / 'All 2 tasks are finished; every one of them merged.' @ttys001")
        #expect(alert?.kind == .done)
        // The same batch again (its summary written since): nothing.
        var summarized = Self.mark
        summarized.summary = .init(headline: "Login works again.", bullets: [], byModel: true)
        #expect(gate.pass(AlertRules.lead(.allDone(summarized, project: "acme", leadTTY: "ttys001"), settings: .init())) == nil)
        // The next batch notifies, with the card's headline.
        summarized.id = "m2"
        #expect(gate.pass(AlertRules.lead(.allDone(summarized, project: "acme", leadTTY: "ttys001"), settings: .init()))?.body == "Login works again.")
        // Finished notifications off: none.
        #expect(AlertRules.lead(.allDone(Self.mark, project: "acme", leadTTY: nil), settings: .init(done: false)) == nil)
    }

    @Test func remindersAboutTheTeamAreSilentButALeadWaitingOnYouKeepsIt() {
        for role in [LeadLaunch.Role.worker, .verifier] {
            #expect(Self.said(AlertRules.nudge(.stalled(minutes: 20), for: Self.session(role, .working), settings: .init())) == "nothing")
            #expect(Self.said(AlertRules.nudge(.stillWaiting(minutes: 12), for: Self.session(role, .needsInput), settings: .init())) == "nothing")
        }
        // A lead that seems stuck is its own watch's to wake, not a reminder for you.
        #expect(Self.said(AlertRules.nudge(.stalled(minutes: 20), for: Self.session(.lead, .working), settings: .init())) == "nothing")
        let waiting = AlertRules.nudge(.stillWaiting(minutes: 12), for: Self.session(.lead, .needsInput, detail: "Allow Bash?"), settings: .init())
        #expect(Self.said(waiting) == "banner 'acme is still waiting for you' / 'Allow Bash?' · sound"
            + " · phone 'acme is still waiting for you (12 min)' / 'Allow Bash?' @ttys001")
        #expect(AlertRules.nudge(.stillWaiting(minutes: 12), for: Self.session(.lead, .needsInput), settings: .init(reminders: false)) == nil)
    }

    /// Sessions that aren't a lead's team notify as before, under the same toggles.
    @Test func yourOwnSessionsNotifyAsBefore() {
        let asking = Self.session(nil, .needsInput, detail: "Allow Bash?", task: "Fix login")
        let input = AlertRules.attention(asking, question: nil, settings: .init())
        #expect(Self.said(input) == "banner 'acme needs your input' / 'Allow Bash?' · sound · phone 'acme needs your input' / 'Fix login\nAllow Bash?' @ttys001")
        #expect(input?.subtitle == "Fix login")
        let done = AlertRules.attention(Self.session(nil, .done, detail: "All tests pass"), question: nil, settings: .init())
        #expect(Self.said(done) == "banner 'acme is done' / 'All tests pass' · phone 'acme is done' / 'All tests pass' @ttys001")
        #expect(done?.subtitle == "Claude")
        // The toggles.
        #expect(AlertRules.attention(asking, question: nil, settings: .init(needsInput: false)) == nil)
        #expect(AlertRules.attention(asking, question: nil, settings: .init(sound: false))?.sound == false)
        #expect(AlertRules.attention(Self.session(nil, .done), question: nil, settings: .init(done: false)) == nil)
        // Reminders: waiting with the sound, a long command or a stall without.
        let still = AlertRules.nudge(.stillWaiting(minutes: 12), for: asking, settings: .init())
        #expect(Self.said(still) == "banner 'acme is still waiting for you' / 'Allow Bash?' · sound · phone 'acme is still waiting for you (12 min)' / 'Allow Bash?' @ttys001")
        #expect(still?.subtitle == "For 12 min · Fix login")
        let command = AlertRules.nudge(.stalled(minutes: 20), for: Self.session(nil, .working, activity: "swift test"), settings: .init())
        #expect(Self.said(command) == "banner 'acme: one command running for 20 min' / 'No other progress since it started. Check it isn't stuck.'"
            + " · phone 'acme: one command running for 20 min' / 'swift test' @ttys001")
        let stuck = AlertRules.nudge(.stalled(minutes: 20), for: Self.session(nil, .working, task: "Fix login"), settings: .init())
        #expect(Self.said(stuck) == "banner 'acme may be stuck' / '' · phone 'acme may be stuck (20 min)' / '' @ttys001")
        #expect(stuck?.subtitle == "No progress for 20 min · Fix login")
        #expect(AlertRules.nudge(.stalled(minutes: 20), for: asking, settings: .init(reminders: false)) == nil)
    }

    /// A relaunch (an install) doesn't tell again the questions told before it: the first look after it only tells one
    /// asked or revised since (or in the minute before, while it relaunched). Later looks tell each new wording once.
    @Test func aRelaunchDoesntTellTheOpenQuestionsAgain() {
        let launch = 10_000.0
        var board = LeadBoard()
        board.leadTTY = "ttys001"
        let old = LeadQuestion(id: "old", text: "Asked an hour ago?", options: [], at: launch - 3_600)
        var revised = LeadQuestion(id: "revised", text: "Asked long ago, reworded just now?", options: [], at: launch - 7_200)
        revised.revisions = [.init(text: "Asked long ago?", options: [], note: "clearer", at: launch - 20)]
        let meanwhile = LeadQuestion(id: "meanwhile", text: "Asked while it relaunched?", options: [], at: launch - 30)
        board.questions = [old, revised, meanwhile]
        func asked(_ events: [AlertRules.LeadEvent]) -> [String] {
            events.compactMap { if case .asked(let question, _, _) = $0 { return question.id } else { return nil } }
        }
        var seen: Set<String> = []
        #expect(asked(AlertRules.look(previous: nil, board: board, project: "acme", seen: &seen, launchedAt: launch)) == ["revised", "meanwhile"])
        // The next look tells nothing again; a question asked after the launch is told.
        let before = board
        board.questions.append(LeadQuestion(id: "new", text: "Asked now?", options: [], at: launch + 60))
        #expect(asked(AlertRules.look(previous: before, board: board, project: "acme", seen: &seen, launchedAt: launch)) == ["new"])
        // A lead started after the launch (a board seen for the first time): its questions are told.
        var other = LeadBoard()
        other.questions = [LeadQuestion(id: "fresh", text: "First question?", options: [], at: launch + 120)]
        #expect(asked(AlertRules.look(previous: nil, board: other, project: "beta", seen: &seen, launchedAt: launch)) == ["fresh"])
    }

    @Test func theAllDoneCardIsToldWhenItAppearsNotAtTheFirstLook() {
        var board = LeadBoard()
        board.allDone = [Self.mark]
        var seen: Set<String> = []
        #expect(AlertRules.look(previous: nil, board: board, project: "acme", seen: &seen, launchedAt: 0).isEmpty)
        var next = board
        var second = Self.mark
        second.id = "m2"
        next.allDone?.append(second)
        #expect(AlertRules.look(previous: board, board: next, project: "acme", seen: &seen, launchedAt: 0)
            == [.allDone(second, project: "acme", leadTTY: nil)])
        // Seen already (the user opened the lead): not told.
        var seenMark = second
        seenMark.id = "m3"
        seenMark.seenAt = 1
        var third = next
        third.allDone?.append(seenMark)
        #expect(AlertRules.look(previous: next, board: third, project: "acme", seen: &seen, launchedAt: 0).isEmpty)
    }

    @Test func somethingBrokenThatWaitsOnYouNotifies() {
        let alert = AlertRules.lead(.broken(title: "main moved outside the lead's merges", body: "2 in acme", leadTTY: "ttys001", key: nil), settings: .init())
        #expect(alert?.kind == .needsYou && alert?.sound == true && alert?.tty == "ttys001")
    }

    static func move(to: String = "bbbbbbbb") -> LeadVault.BaseMove {
        LeadVault.BaseMove(branch: "project-lead", from: "aaaaaaaa", to: to, accepted: false, commits: [.init(sha: to, subject: "Your own fix")],
                           sessions: [], reason: "No session of yours made it.")
    }

    /// The base branch moved by a commit outside the lead (the user's own, say): silent for the user, as the window's card
    /// asks about it in the lead's chat and the lead's merge tells the lead. Only a merge it refused waits on the user:
    /// told once per move.
    @Test func aBaseMoveOutsideTheLeadIsSilentUntilItRefusesAMerge() {
        var gate = AlertRules.Gate()
        let move = Self.move()
        #expect(AlertRules.baseMoved(move, refused: nil, root: "/r/acme", leadTTY: "ttys001") == nil)
        #expect(AlertRules.baseMoved(nil, refused: nil, root: "/r/acme", leadTTY: "ttys001") == nil)
        // A refusal for another move (an older one), or of another branch: not this one's.
        #expect(AlertRules.baseMoved(move, refused: .init(branch: "project-lead", to: "cccccccc", at: 1), root: "/r/acme", leadTTY: nil) == nil)
        #expect(AlertRules.baseMoved(move, refused: .init(branch: "main", to: "bbbbbbbb", at: 1), root: "/r/acme", leadTTY: nil) == nil)
        // Accepted or kept refused in the window: nothing asks any more.
        #expect(AlertRules.baseMoved(nil, refused: .init(branch: "project-lead", to: "bbbbbbbb", at: 1), root: "/r/acme", leadTTY: nil) == nil)

        let refused = LeadVault.BaseMoveRefusal(branch: "project-lead", to: "bbbbbbbb", at: 1)
        let event = AlertRules.baseMoved(move, refused: refused, root: "/r/acme", leadTTY: "ttys001")
        let alert = gate.pass(event.flatMap { AlertRules.lead($0, settings: .init()) })
        #expect(Self.said(alert) == "banner 'project-lead moved outside the lead's merges' / '1 commit in acme: the lead's merges wait on you. "
            + "Accept them in the lead's chat, or keep its merges refused.' · sound · phone 'project-lead moved outside the lead's merges' / "
            + "'1 commit in acme: the lead's merges wait on you. Accept them in the lead's chat, or keep its merges refused.' @ttys001")
        // The next refresh, or the next refused merge: told already.
        #expect(gate.pass(AlertRules.baseMoved(move, refused: refused, root: "/r/acme", leadTTY: "ttys001").flatMap { AlertRules.lead($0, settings: .init()) }) == nil)
        // A further move that refuses a merge again is news.
        let further = Self.move(to: "dddddddd")
        #expect(gate.pass(AlertRules.baseMoved(further, refused: .init(branch: "project-lead", to: "dddddddd", at: 2), root: "/r/acme", leadTTY: "ttys001")
            .flatMap { AlertRules.lead($0, settings: .init()) }) != nil)
        // With needing-input notifications off, not even then.
        #expect(event.flatMap { AlertRules.lead($0, settings: .init(needsInput: false)) } == nil)
    }

    /// A lead's batch from start to finish, as the user gets it: only the question and the all-done card notify.
    @Test func aLeadsBatchNotifiesOnlyForTheQuestionAndTheAllDoneCard() {
        var gate = AlertRules.Gate()
        let settings = AlertRules.Settings()
        let steps: [(String, AlertRules.Alert?)] = [
            ("worker done", AlertRules.attention(Self.session(.worker, .done, tty: "ttys002"), question: nil, settings: settings)),
            ("worker asks its lead", AlertRules.attention(Self.session(.worker, .needsInput, tty: "ttys002", detail: "Which table?"), question: nil, settings: settings)),
            ("verifier done", AlertRules.attention(Self.session(.verifier, .done, tty: "ttys003"), question: nil, settings: settings)),
            ("worker stalled", AlertRules.nudge(.stalled(minutes: 16), for: Self.session(.worker, .working, tty: "ttys002"), settings: settings)),
            ("merge: the lead's turn ends, tasks open", AlertRules.attention(Self.session(.lead, .done), question: nil, settings: settings)),
            ("question to the user", AlertRules.lead(.asked(Self.question, project: "acme", leadTTY: "ttys001"), settings: settings)),
            ("the lead's turn ends on it", AlertRules.attention(Self.session(.lead, .done), question: Self.question, settings: settings)),
            ("all done", AlertRules.lead(.allDone(Self.mark, project: "acme", leadTTY: "ttys001"), settings: settings)),
            ("all done, read again", AlertRules.lead(.allDone(Self.mark, project: "acme", leadTTY: "ttys001"), settings: settings)),
        ]
        var fired: [String] = []
        for (step, alert) in steps {
            let passed = gate.pass(alert)
            print("lead batch · \(step): \(Self.said(passed))")
            if passed != nil { fired.append(step) }
        }
        #expect(fired == ["question to the user", "all done"])
    }
}
