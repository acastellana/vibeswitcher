import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `session.reply` with `choices` (the no-terminal inventory's C5): a multi-select's boxes from a page. The keys are
/// planned from the question on the screen alone (`SessionReplyTicks.plan`), each checked key waiting for the screen to
/// show its cursor and ticks; here they go into a model of Claude's multi-select (as Tests/VibeNodeTests/FakeClaude.swift
/// takes keys: arrows move, Enter ticks or unticks, a letter on the free-text row types and ticks it, Enter on Submit
/// submits) whose screen is drawn and read back with `ScreenMenu.parse`, as the node reads a session's. Not `linuxOnly`:
/// the Mac runs it; the same answer on a fake Claude through the host is `SessionDriveTests.aMultiSelectIsTickedAndSubmitted`.
struct SessionReplyTicksTests {
    /// Claude's multi-select as drawn: its rows `N. [✔] label`, its free-text row, its Submit.
    struct Model {
        var labels = ["Cream", "Nuts", "Sprinkles"]
        var checked: Set<Int> = [0]
        var focus = 4
        var typed = ""
        var submitted: [String]?
        var rows: Int { labels.count + 1 }

        var screen: [String] {
            var lines = ["←   ☐ Toppings  ✔ Submit   →", "", "Which toppings?", ""]
            for index in 0..<rows {
                let label = index == labels.count ? (typed.isEmpty ? "Type something" : typed) : labels[index]
                lines.append((focus == index ? "❯ " : "  ") + "\(index + 1). [\(checked.contains(index) ? "✔" : " ")] \(label)")
            }
            lines += [(focus == rows ? "❯ " : "  ") + "   Submit", "", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]
            return lines
        }
        var menu: ScreenMenu? { ScreenMenu.parse(screen) }

        mutating func take(_ bytes: [UInt8]) {
            switch bytes {
            case [27, 91, 65]: focus = max(0, focus - 1)
            case [27, 91, 66]: focus = min(rows, focus + 1)
            case [13]:
                if focus == rows {
                    submitted = checked.sorted().map { $0 == labels.count ? typed : labels[$0] }
                } else {
                    checked.formSymmetricDifference([focus])
                }
            default:
                guard focus == labels.count else { return }
                typed += String(decoding: bytes, as: UTF8.self)
                if !typed.isEmpty { checked.insert(focus) }
            }
        }

        /// The plan's keys, each checked one only once the screen shows its check (as the node's gate waits): the
        /// first check that doesn't hold stops them there, as the gate's no does. Whether every key went in.
        mutating func run(_ plan: SessionReplyTicks.Plan, from menu: ScreenMenu, lose: Set<Int> = []) -> Bool {
            for (index, write) in plan.writes.enumerated() {
                if let check = plan.checks[index], !SessionReplyTicks.shows(self.menu, check, of: menu) { return false }
                if !lose.contains(index) { take(write.bytes) }
            }
            return true
        }
    }

    private func plan(_ model: Model, _ choices: [Int], text: String? = nil) throws -> SessionReplyTicks.Plan {
        let menu = try #require(model.menu)
        return try SessionReplyTicks.plan(menu, choices: choices, text: text).get()
    }

    private func refusal(_ model: Model, _ choices: [Int], text: String? = nil) throws -> SessionReplyTicks.Refusal? {
        let menu = try #require(model.menu)
        guard case .failure(let refusal) = SessionReplyTicks.plan(menu, choices: choices, text: text) else { return nil }
        return refusal
    }

    @Test func theModelsScreenIsReadAsTheNodeReadsAMultiSelect() throws {
        let menu = try #require(Model().menu)
        #expect(menu.options == ["Cream", "Nuts", "Sprinkles", "Type something"] && menu.checked == [true, false, false, false])
        #expect(menu.submit == "Submit" && menu.selected == 4 && menu.multiSelect)
        #expect(SessionPrompt.takesText(menu, 3))
    }

    /// A valid set: Cream (ticked already) unticked, Nuts ticked, words typed into the free-text row, then Submit; the
    /// boxes as asked, and the reply's words the screen's (the free-text row's the words typed).
    @Test func aValidSetLeavesExactlyThoseTickedAndSubmits() throws {
        var model = Model()
        let menu = try #require(model.menu)
        let planned = try plan(model, [2, 4], text: "Honey")
        #expect(planned.ticked == [1, 3] && planned.words == ["Nuts", "Honey"])
        // Up four from Submit to Cream, Enter; down to Nuts, Enter; down two, the words; down to Submit, Enter.
        let up: [UInt8] = [27, 91, 65], down: [UInt8] = [27, 91, 66]
        #expect(planned.writes.map(\.bytes) == [up, up, up, up, [13], down, [13], down, down, Array("Honey".utf8), down, [13]])
        #expect(planned.checks == [4: .init(cursor: 0, ticks: [true, false, false, false]), 6: .init(cursor: 1, ticks: [false, false, false, false]),
                                9: .init(cursor: 3, ticks: [false, true, false, false]), 11: .init(cursor: 4, ticks: [false, true, false, true])])
        let ran = model.run(planned, from: menu)
        #expect(ran && model.submitted == ["Nuts", "Honey"])
        // Choices already ticked as asked: only the arrows to Submit and its Enter.
        var ticked = Model()
        ticked.focus = 0
        let only = try plan(ticked, [1])
        #expect(only.writes.map(\.bytes) == [down, down, down, down, [13]] && only.checks.keys.sorted() == [4])
        let tickedMenu = try #require(ticked.menu)
        let submittedOnly = ticked.run(only, from: tickedMenu)
        #expect(submittedOnly && ticked.submitted == ["Cream"])
    }

    /// A key lost on the way: the check before the next key that needs the screen fails, the keys stop there, and
    /// Submit is never pressed (the answer is refused, to be given again).
    @Test func aLostKeyStopsBeforeSubmit() throws {
        for lost in [0, 4, 5] {
            var model = Model()
            let menu = try #require(model.menu)
            let plan = try plan(model, [2, 3])
            let ran = model.run(plan, from: menu, lose: [lost])
            #expect(!ran, "key \(lost) lost")
            #expect(model.submitted == nil, "key \(lost) lost: nothing submitted")
        }
    }

    /// An option it hasn't (a fifth of four), more choices than it offers, and a Space-toggled setting: refused
    /// (`refused`, nothing typed); none, one twice, a number under 1 and past `mostChoices`: bad arguments whatever it
    /// asks, refused before the screen is read.
    @Test func choicesItDoesntOfferAreRefused() throws {
        let model = Model()
        #expect(try refusal(model, [5]) == .init("its question has 4 options, not 5"))
        #expect(try refusal(model, [1, 2, 3, 4, 5]) == .init("its question has 4 options: 5 choices are more than it offers"))
        #expect(try refusal(model, [2, 2]) == .init("session.reply's choices name option 2 twice", badArgs: true))
        #expect(try refusal(model, []) == .init("session.reply's choices name no option: tick at least one", badArgs: true))
        #expect(try refusal(model, [0]) == .init("session.reply's choices are options' numbers from 1, not 0", badArgs: true))
        #expect(SessionReplyTicks.badChoices(Array(1...33)) == "session.reply takes at most 32 choices")
        #expect(SessionReplyTicks.badChoices([3, 1]) == nil)
    }

    /// Words only for the free-text row, and that row only with words: nothing else is typed into the session.
    @Test func wordsGoOnlyIntoTheRowThatTakesThem() throws {
        let model = Model()
        #expect(try refusal(model, [2], text: "Honey") == .init("none of the options chosen takes words"))
        #expect(try refusal(model, [4]) == .init("option 4 takes your words: give them with the choices"))
        // The words go in as typed, without a control character (no Enter, Esc or arrow hidden in them).
        let plan = try plan(model, [4], text: "Ho\u{1b}[Bney\r")
        #expect(plan.writes.contains { $0.bytes == Array("Ho[Bney".utf8) } && !plan.writes.contains { $0.bytes.contains(27) && $0.bytes.count > 3 })
    }

    /// A single choice takes no `choices`; a Space-toggled setting's row isn't ticked from here.
    @Test func aSingleChoiceAndASettingAreRefused() throws {
        let single = try #require(ScreenMenu.parse(["Do you want to proceed?", "❯ 1. Yes", "  2. No", "", "Esc to cancel"]))
        guard case .failure(let refusal) = SessionReplyTicks.plan(single, choices: [1], text: nil) else { Issue.record("planned"); return }
        #expect(refusal.why == "its question takes one choice, not several: answer it with choice")
        var setting = try #require(Model().menu)
        setting.hint = "↑/↓ to navigate · Space to toggle · Esc to cancel"
        setting.descriptions = [nil, "on", nil, nil]
        guard case .failure(let toggled) = SessionReplyTicks.plan(setting, choices: [1, 2], text: nil) else { Issue.record("planned"); return }
        #expect(toggled.why.hasPrefix("option 2 is a setting toggled with Space"))
    }

    /// The rule is today's `session.reply`'s, unchanged by `choices`: an acting page's (`pageVoice`), never a page
    /// that only reads or drafts, nor one without the read right; the user's voice on the socket.
    @Test func onlyAnActingPageSendsChoices() {
        let request = NodeWire.Request(id: "1", kind: "session.reply", args: ["session": .string("local:x"), "choices": .array([.int(1), .int(2)])])
        for rights: LiveRights in [[], [.read], [.read, .draft], [.read, .draft, .watch]] {
            #expect(WebAccess.refusal(for: request, rights: rights)?.error?.code == NodeWire.Code.voice.rawValue, "\(rights)")
        }
        #expect(WebAccess.refusal(for: request, rights: [.read, .draft, .watch, .act]) == nil)
        #expect(Principal.page([.read, .draft, .watch, .act], terminals: false).route("session.reply") == .pageVoice)
        #expect(KindSpec.spec("session.reply")?.sender == .user && KindSpec.spec("session.reply")?.page == .acts)
        #expect(KindSpec.spec("session.reply")?.arguments == ["session", "choice", "choices", "text", "question", "options"])
    }

    /// On the wire: `choices` is a typed argument (a wrong form is `bad-args`), and the reply's `choices` and `options`
    /// are added beside a single choice's fields, which keep their bytes (the captured reply, `session.reply-1.json`).
    @Test func theWireAddsChoicesAndKeepsASingleChoicesBytes() throws {
        let wrong = NodeWire.Request(id: "1", kind: "session.reply", args: ["session": .string("s"), "choices": .string("1,2")])
        guard case .failure(let failure) = wrong.typedArgs(WireKinds.SessionReply.Args.self) else { Issue.record("taken"); return }
        #expect(failure.code == "bad-args" && failure.message.contains("choices"), "\(failure)")
        let ticks = WireKinds.SessionReply.Result(session: "local:s", terminal: "pts/1", choices: [2, 4], options: ["Nuts", "Honey"], question: "Which toppings?")
        let text = String(decoding: NodeWire.line(ticks), as: UTF8.self)
        #expect(text == #"{"choices":[2,4],"options":["Nuts","Honey"],"question":"Which toppings?","session":"local:s","terminal":"pts/1"}"# + "\n", "\(text)")
        let one = WireKinds.SessionReply.Result(session: "local:s", terminal: "pts/1", choice: 1, option: "Yes", question: "Proceed?")
        #expect(!String(decoding: NodeWire.line(one), as: UTF8.self).contains("choices"))
    }
}
