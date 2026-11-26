import Foundation
import VibeCore

/// `session.reply` with `choices`: a session's multi-select question answered from a page (the no-terminal inventory's
/// C5, 2026-11-26), as the app's card ticks one (`ChatSync.terminalSteps`): for each box whose tick has to change, the
/// arrows from the cursor to it and Enter (which ticks or unticks it), or for its free-text row the words typed (which
/// tick it); then the arrows to its Submit (or Next) row and Enter. Nothing is typed but what the question on the screen
/// offers: only its own options, each named once, never more than it has.
///
/// Every key but the arrows waits for the screen to show what it needs first (`Check`): before a box's Enter or words, the
/// cursor on that box and the ticks as the keys before left them; before the Enter that submits, the cursor on Submit
/// and exactly the ticks asked. Anything else stops the keys there, and nothing is submitted.
enum SessionReplyTicks {
    /// The most `choices` a request may name, before the screen is read: more than any question offers.
    static let mostChoices = 32

    /// What the screen must show before write `index` of `Plan.writes` goes in.
    struct Check: Equatable {
        /// The row the cursor must be on (`options.count`: the Submit / Next row).
        var cursor: Int
        /// The ticks every box must have.
        var ticks: [Bool]
    }

    struct Plan: Equatable {
        var writes: [HostInput.Write]
        /// By write index: the keys that wait for the screen (the first key's check is the whole question, as asked).
        var checks: [Int: Check]
        /// The options ticked once it is submitted, in the options' order (from 0).
        var ticked: [Int]
        /// Their words as the reply gives them: a free-text row's the words typed.
        var words: [String]
    }

    /// Why `choices` can't be taken before the screen is read: none, more than `mostChoices`, a number under 1, one twice.
    /// Nil when they can.
    static func badChoices(_ choices: [Int]) -> String? {
        if choices.isEmpty { return "session.reply's choices name no option: tick at least one" }
        if choices.count > mostChoices { return "session.reply takes at most \(mostChoices) choices" }
        if let low = choices.first(where: { $0 < 1 }) { return "session.reply's choices are options' numbers from 1, not \(low)" }
        var seen = Set<Int>()
        if let twice = choices.first(where: { !seen.insert($0).inserted }) { return "session.reply's choices name option \(twice) twice" }
        return nil
    }

    /// The keys that leave exactly `choices` (options' numbers, from 1) ticked on `menu` and submit it, with `text` for its
    /// free-text row when that is one of them; or why not (nothing typed): a question that isn't a multi-select, more
    /// choices than it has options, an option it hasn't, a setting toggled with Space, words for no row that takes them,
    /// or none for one that does.
    static func plan(_ menu: ScreenMenu, choices: [Int], text: String?) -> Result<Plan, Refusal> {
        guard let start = menu.checked, menu.multiSelect, menu.submit != nil else {
            return .failure(.init("its question takes one choice, not several: answer it with choice"))
        }
        if let why = badChoices(choices) { return .failure(.init(why, badArgs: true)) }
        let count = menu.options.count
        guard choices.count <= count else { return .failure(.init("its question has \(count) options: \(choices.count) choices are more than it offers")) }
        if let missing = choices.first(where: { $0 > count }) { return .failure(.init("its question has \(count) options, not \(missing)")) }
        let wanted = Set(choices.map { $0 - 1 })
        let target = (0..<count).map { wanted.contains($0) }
        let writing = (0..<count).filter { wanted.contains($0) && SessionPrompt.takesText(menu, $0) }
        guard writing.count <= 1 else { return .failure(.init("more than one of its options takes words: answer it in the session's terminal")) }
        if let row = writing.first {
            guard text != nil else { return .failure(.init("option \(row + 1) takes your words: give them with the choices")) }
            // Its field is ticked by typing into it: a row ticked already with no words of its own isn't one to type into.
            guard !start[row] else { return .failure(.init("option \(row + 1) is ticked already with no words: answer it in the session's terminal")) }
        } else if text != nil {
            return .failure(.init("none of the options chosen takes words"))
        }
        var writes: [HostInput.Write] = []
        var checks: [Int: Check] = [:]
        var at = menu
        var ticks = start
        for index in 0..<count where ticks[index] != target[index] {
            if SessionPrompt.toggles(menu, index) {
                return .failure(.init("option \(index + 1) is a setting toggled with Space (\(ConfigSeal.inert(menu.options[index], limit: 80))): set it in the session's terminal"))
            }
            let keys = writing.first == index ? at.keys(toChoose: index, typing: text ?? "") : at.keys(toChoose: index)
            checks[writes.count + keys.count - 1] = Check(cursor: index, ticks: ticks)
            writes += keys
            ticks[index] = target[index]
            at.selected = index
        }
        let submit = at.keys(toChoose: count)
        checks[writes.count + submit.count - 1] = Check(cursor: count, ticks: target)
        writes += submit
        let ticked = (0..<count).filter { target[$0] }
        let words = ticked.map { writing.first == $0 ? (text ?? "") : menu.options[$0] }
        return .success(Plan(writes: writes, checks: checks, ticked: ticked, words: words))
    }

    /// Why a plan was refused: the screen's question can't take it (`refused`), or the arguments themselves were wrong
    /// whatever it asks (`bad-args`).
    struct Refusal: Error, Equatable {
        var why: String
        var badArgs = false
        init(_ why: String, badArgs: Bool = false) {
            self.why = why
            self.badArgs = badArgs
        }
    }

    /// Whether `now` (the screen read again) shows `check` on the question `menu` was: the same question, its cursor on
    /// the row and every tick as asked.
    static func shows(_ now: ScreenMenu?, _ check: Check, of menu: ScreenMenu) -> Bool {
        guard let now, now.sameQuestion(as: menu), now.checked != nil else { return false }
        return now.selected == check.cursor && now.checked == check.ticks
    }
}
