import Foundation
import Testing
@testable import VibeCore

struct ScreenMenuTests {
    let permission = """
    ⏺ Bash(touch /tmp/x)
    ╭──────────────────────────────────────╮
    │ Bash command                         │
    │                                      │
    │   touch /tmp/x                       │
    │   Create the probe file              │
    │                                      │
    │ Do you want to proceed?              │
    │ ❯ 1. Yes                             │
    │   2. Yes, and don't ask again for touch commands in /tmp │
    │   3. No, and tell Claude what to do differently (esc) │
    ╰──────────────────────────────────────╯
    """.components(separatedBy: "\n")

    @Test func readsAPermissionPrompt() {
        let menu = ScreenMenu.parse(permission)
        #expect(menu?.options == ["Yes", "Yes, and don't ask again for touch commands in /tmp", "No, and tell Claude what to do differently (esc)"])
        #expect(menu?.selected == 0)
        #expect(menu?.question == "Bash command\ntouch /tmp/x\nCreate the probe file\nDo you want to proceed?")
    }

    @Test func readsAQuestionWithTheCursorElsewhere() {
        let screen = [" ☐ Color", "Which color do you prefer?", "  1. Red", "❯ 2. Green", "  3. Blue", "  4. Type something.", "",
                      "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        let menu = ScreenMenu.parse(screen)
        #expect(menu?.options == ["Red", "Green", "Blue", "Type something."])
        #expect(menu?.selected == 1)
        #expect(menu?.question == "☐ Color\nWhich color do you prefer?")
    }

    @Test func codexStyleArrow() {
        let menu = ScreenMenu.parse(["Allow command?", "› 1. Yes, proceed", "  2. No, and tell Codex what to do"])
        #expect(menu?.options == ["Yes, proceed", "No, and tell Codex what to do"])
        #expect(menu?.selected == 0)
    }

    @Test func numberedTextWithoutACursorIsNotAMenu() {
        #expect(ScreenMenu.parse(["Steps:", "1. Build", "2. Test"]) == nil)
        #expect(ScreenMenu.parse(["❯ 1. Only one"]) == nil)
        #expect(ScreenMenu.parse(["❯ "]) == nil)
    }

    @Test func choosingMovesFromTheCursorThenPressesEnter() {
        let menu = ScreenMenu(question: "", options: ["a", "b", "c"], selected: 1)
        let down: [UInt8] = [27, 91, 66], up: [UInt8] = [27, 91, 65]
        #expect(menu.keys(toChoose: 2).map(\.bytes) == [down, [13]])
        #expect(menu.keys(toChoose: 0).map(\.bytes) == [up, [13]])
        #expect(menu.keys(toChoose: 1).map(\.bytes) == [[13]])
        #expect(menu.keys(toChoose: 2).map(\.delay) == [0, 0.08])
    }

    @Test func modesFromTheFooter() {
        #expect(AgentMode.parse(["⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents"]) == .auto)
        #expect(AgentMode.parse(["⏸ plan mode on (shift+tab to cycle)"]) == .plan)
        #expect(AgentMode.parse(["⏵⏵ accept edits on (shift+tab to cycle)"]) == .acceptEdits)
        #expect(AgentMode.parse(["⏵⏵ bypass permissions on (shift+tab to cycle)"]) == .bypass)
        #expect(AgentMode.parse(["? for shortcuts"]) == .normal)
        #expect(AgentMode.cycleKey == [27, 91, 90])
    }
}
