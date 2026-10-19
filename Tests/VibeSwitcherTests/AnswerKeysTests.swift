import Testing
import VibeCore
@testable import VibeSwitcher

/// The answer card's keys (WC-1): while a question is up and the composer is empty, 1–9 choose, ↩ confirms the
/// highlighted option and ↑ / ↓ move the highlight, as in the terminal; with text in the composer they're the text's.
struct AnswerKeysTests {
    // MARK: Digits

    @Test func aDigitWithAnEmptyComposerChoosesThatOption() {
        #expect(AnswerKeys.action(for: .digit(1), composer: "", options: 3, highlighted: 0) == .choose(0))
        #expect(AnswerKeys.action(for: .digit(2), composer: "", options: 3, highlighted: 0) == .choose(1))
        #expect(AnswerKeys.action(for: .digit(3), composer: "", options: 3, highlighted: nil) == .choose(2))
        #expect(AnswerKeys.action(for: .digit(9), composer: "", options: 12, highlighted: 0) == .choose(8))
    }

    @Test func aDigitBeyondTheOptionsIsTyped() {
        #expect(AnswerKeys.action(for: .digit(4), composer: "", options: 3, highlighted: 0) == .pass)
        #expect(AnswerKeys.action(for: .digit(1), composer: "", options: 0, highlighted: nil) == .pass)
        // Not a 1–9 key: never an option.
        #expect(AnswerKeys.action(for: .digit(0), composer: "", options: 3, highlighted: 0) == .pass)
        #expect(AnswerKeys.action(for: .digit(10), composer: "", options: 12, highlighted: 0) == .pass)
        // A multi-select's Submit row has no number.
        #expect(AnswerKeys.action(for: .digit(3), composer: "", options: 2, submit: true, highlighted: 0) == .pass)
    }

    @Test func aDigitWithTextInTheComposerIsTyped() {
        #expect(AnswerKeys.action(for: .digit(2), composer: "version ", options: 3, highlighted: 0) == .pass)
        // A space is text too: what you're writing isn't cut into by a choice.
        #expect(AnswerKeys.action(for: .digit(2), composer: " ", options: 3, highlighted: 0) == .pass)
    }

    // MARK: Return

    @Test func returnWithAnEmptyComposerConfirmsTheHighlight() {
        #expect(AnswerKeys.action(for: .enter, composer: "", options: 3, highlighted: 1) == .confirm(1))
        #expect(AnswerKeys.action(for: .enter, composer: "", options: 3, highlighted: 0) == .confirm(0))
        // The Submit row (index `options`).
        #expect(AnswerKeys.action(for: .enter, composer: "", options: 2, submit: true, highlighted: 2) == .confirm(2))
    }

    @Test func returnWithoutAHighlightIsTheComposers() {
        #expect(AnswerKeys.action(for: .enter, composer: "", options: 3, highlighted: nil) == .pass)
        #expect(AnswerKeys.action(for: .enter, composer: "", options: 3, highlighted: 3) == .pass)
        #expect(AnswerKeys.action(for: .enter, composer: "", options: 0, highlighted: 0) == .pass)
    }

    @Test func returnWithTextSendsAsBefore() {
        #expect(AnswerKeys.action(for: .enter, composer: "a ripe mango", options: 3, highlighted: 1) == .pass)
    }

    // MARK: Arrows (they stop at the ends, as the terminal's cursor does: no wrapping)

    @Test func theArrowsMoveTheHighlightAndStopAtTheEnds() {
        #expect(AnswerKeys.action(for: .down, composer: "", options: 3, highlighted: 0) == .move(1))
        #expect(AnswerKeys.action(for: .down, composer: "", options: 3, highlighted: 1) == .move(2))
        #expect(AnswerKeys.action(for: .up, composer: "", options: 3, highlighted: 2) == .move(1))
        // Clamped, not wrapped; still the card's key (it doesn't fall through to the composer's history).
        #expect(AnswerKeys.action(for: .down, composer: "", options: 3, highlighted: 2) == .move(2))
        #expect(AnswerKeys.action(for: .up, composer: "", options: 3, highlighted: 0) == .move(0))
        // A multi-select's Submit row is the last stop.
        #expect(AnswerKeys.action(for: .down, composer: "", options: 2, submit: true, highlighted: 1) == .move(2))
        #expect(AnswerKeys.action(for: .down, composer: "", options: 2, submit: true, highlighted: 2) == .move(2))
    }

    @Test func theArrowsWithoutAHighlightStartAtAnEnd() {
        #expect(AnswerKeys.action(for: .down, composer: "", options: 3, highlighted: nil) == .move(0))
        #expect(AnswerKeys.action(for: .up, composer: "", options: 3, highlighted: nil) == .move(2))
    }

    @Test func theArrowsWithTextAreTheComposers() {
        #expect(AnswerKeys.action(for: .up, composer: "two\nlines", options: 3, highlighted: 1) == .pass)
        #expect(AnswerKeys.action(for: .down, composer: "x", options: 3, highlighted: 1) == .pass)
        #expect(AnswerKeys.action(for: .up, composer: "", options: 0, highlighted: nil) == .pass)
    }

    // MARK: VoiceOver

    @Test func eachOptionReadsAsItsPlaceAndLabel() {
        #expect(AnswerKeys.spoken(1, of: 3, label: "Pear") == "option 2 of 3, Pear")
        #expect(AnswerKeys.spoken(0, of: 1, label: "Yes") == "option 1 of 1, Yes")
    }

    // MARK: The shared state (composer → card)

    static let fruit = ScreenMenu(question: "Which fruit?", options: ["Apple", "Pear", "Plum", "Type something."], selected: 0)

    @Test @MainActor func theKeysAreTakenOnlyForAQuestion() throws {
        let keys = AnswerCardKeys()
        let card = AnswerCardContent(menu: Self.fruit, pending: nil)
        keys.highlight = 0
        #expect(keys.take(.down, composer: "", content: card))
        #expect(keys.highlight == 1)
        #expect(keys.press == nil)
        #expect(keys.take(.digit(3), composer: "", content: card))
        #expect(keys.press?.index == 2 && keys.highlight == 2)
        let first = try #require(keys.press)
        // The same key again is a second press.
        #expect(keys.take(.enter, composer: "", content: card))
        #expect(keys.press?.index == 2 && keys.press != first)
        // With text, nothing is taken and nothing moves.
        let before = keys.press
        #expect(!keys.take(.digit(1), composer: "hi", content: card))
        #expect(!keys.take(.down, composer: "hi", content: card))
        #expect(keys.press == before && keys.highlight == 2)
        // The slash-command menu isn't a question: its keys stay the composer's.
        var commands = Self.fruit
        commands.commands = true
        #expect(!keys.take(.digit(1), composer: "", content: AnswerCardContent(menu: commands, pending: nil)))
    }

    @Test @MainActor func whileAnAnswerGoesInTheCardsKeysAreSwallowed() {
        let keys = AnswerCardKeys()
        keys.highlight = 0
        let card = AnswerCardContent(menu: Self.fruit, pending: nil)
        // Not typed into the composer (↩ would then send "2" as a message), and not a second answer.
        #expect(keys.take(.digit(2), composer: "", content: card, busy: true))
        #expect(keys.take(.enter, composer: "", content: card, busy: true))
        #expect(keys.press == nil && keys.highlight == 0)
        #expect(!keys.take(.digit(7), composer: "", content: card, busy: true))
    }

    @Test @MainActor func withoutAHighlightTheKeysStartAtTheTerminalsCursor() {
        let keys = AnswerCardKeys()
        var menu = Self.fruit
        menu.selected = 1
        #expect(keys.take(.enter, composer: "", content: AnswerCardContent(menu: menu, pending: nil)))
        #expect(keys.press?.index == 1)
        let other = AnswerCardKeys()
        #expect(other.take(.down, composer: "", content: AnswerCardContent(menu: menu, pending: nil)))
        #expect(other.highlight == 2)
    }

    @Test func aChosenFreeTextRowOpensItsFieldOtherRowsAnswer() {
        let card = AnswerCardContent(menu: Self.fruit, pending: nil)
        #expect(AnswerKeys.pick(1, in: card) == .answer(1))
        #expect(AnswerKeys.pick(3, in: card) == .freeText)
    }
}
