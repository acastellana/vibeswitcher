import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The question a session's `prompt` carries, read off its screen (`SessionPrompt.menu(on:)`): Claude's numbered
/// questions and its own first-run dialogs, the folder-trust one drawn without numbers (acceptance run, 2026-11-20).
struct SessionPromptTests {
    /// Claude Code 2.1.30x in a folder it hasn't been trusted in, as `vibeswitcher new ~/projects/vs-acceptance` showed
    /// it on the acceptance run (2026-11-20): the session needs-you, and its rows have no numbers.
    static let trust = """
     Accessing workspace:

     /home/albert/projects/vs-acceptance

     Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source
     project, or work from your team). If not, take a moment to review what's in this folder first.

     Claude Code'll be able to read, edit, and execute files here.

     Security guide

     ❯ No, exit
       Yes, I trust this folder

     Enter to confirm · Esc to cancel



    """

    @Test func claudesFolderTrustQuestionIsAPromptWithItsRowsInScreenOrder() throws {
        let menu = try #require(SessionPrompt.menu(on: Self.trust))
        #expect(menu.options == ["No, exit", "Yes, I trust this folder"])
        #expect(menu.selected == 0 && !menu.multiSelect && menu.hint == "Enter to confirm · Esc to cancel")
        #expect(menu.question.hasPrefix("Accessing workspace:\n/home/albert/projects/vs-acceptance\nQuick safety check:"), "\(menu.question)")
        #expect(menu.question.hasSuffix("Security guide"), "\(menu.question)")
        // `reply S 2`: one down, then Enter, as the app's card answers.
        #expect(menu.keys(toChoose: 1).map(\.bytes) == [[27, 91, 66], [13]])
        // The cursor moved: the same question, its cursor on Yes.
        let moved = Self.trust.replacingOccurrences(of: " ❯ No, exit\n   Yes,", with: "   No, exit\n ❯ Yes,")
        let after = try #require(SessionPrompt.menu(on: moved))
        #expect(after.selected == 1 && after.sameQuestion(as: menu) && after.keys(toChoose: 1).map(\.bytes) == [[13]])
    }

    /// Inside a box, with a row's second line further in.
    @Test func aBoxedDialogsRowsAndTheirSecondLines() throws {
        let screen = """
        ╭──────────────────────────────────────────────╮
        │ Use this API key?                            │
        │                                              │
        │ ❯ Yes                                        │
        │   No (recommended)                           │
        │       keep using your claude.ai sign-in      │
        ╰──────────────────────────────────────────────╯
          Enter to confirm · Esc to cancel
        """
        let menu = try #require(SessionPrompt.menu(on: screen))
        #expect(menu.question == "Use this API key?")
        #expect(menu.options == ["Yes", "No (recommended)"])
        #expect(menu.descriptions == [nil, "keep using your claude.ai sign-in"])
    }

    /// Claude's other first-run dialogs number their rows: read as its questions are.
    @Test func numberedFirstRunDialogsAreReadAsQuestions() throws {
        let theme = """
         Let's get started.

         Choose the text style that looks best with your terminal
         To change this later, run /theme

         ❯ 1. Dark mode ✔
           2. Light mode
           3. Dark mode (colorblind-friendly)

         Enter to confirm · Esc to cancel
        """
        let themeMenu = try #require(SessionPrompt.menu(on: theme))
        #expect(themeMenu.options == ["Dark mode ✔", "Light mode", "Dark mode (colorblind-friendly)"] && themeMenu.selected == 0)

        let mcp = """
        ╭──────────────────────────────────────────────────────────╮
        │ New MCP server found in .mcp.json: scratch-tools          │
        │                                                           │
        │ MCP servers may execute code or access system resources.  │
        │                                                           │
        │ ❯ 1. Use this and all future MCP servers in this project  │
        │   2. Use this MCP server                                  │
        │   3. Continue without using this MCP server               │
        ╰──────────────────────────────────────────────────────────╯
           Enter to confirm · Esc to reject all
        """
        let mcpMenu = try #require(SessionPrompt.menu(on: mcp))
        #expect(mcpMenu.options.count == 3 && mcpMenu.options[2] == "Continue without using this MCP server")
        #expect(mcpMenu.question.contains("New MCP server found"))

        let proceed = """
        ╭──────────────────────────────────────────╮
        │ Edit file                                │
        │ Do you want to make this edit to a.txt?  │
        │ ❯ 1. Yes                                 │
        │   2. Yes, allow all edits during session │
        │   3. No, and tell Claude what to do      │
        ╰──────────────────────────────────────────╯
        """
        #expect(SessionPrompt.menu(on: proceed)?.options.count == 3)
    }

    /// Not questions: a fullscreen Claude's local picker (`▔▔▔`), the slash-command menu, a marked list with no footer
    /// saying Enter chooses, a lone row.
    @Test func picksCommandsAndBareListsAreNot() {
        let picker = """
        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
         Theme
          ❯ Dark mode
            Light mode
         Enter to confirm · Esc to cancel
        """
        #expect(SessionPrompt.menu(on: picker) == nil)
        let commands = """
        ────────────────────────────────────
        ❯ /mo
        ────────────────────────────────────
          ❯ /model     Set the AI model
            /mcp       Manage MCP servers
        """
        #expect(SessionPrompt.menu(on: commands) == nil)
        #expect(SessionPrompt.menu(on: " ❯ No, exit\n   Yes, I trust this folder\n") == nil)
        #expect(SessionPrompt.menu(on: " Trust it?\n\n ❯ Yes\n\n Enter to confirm · Esc to cancel") == nil)
    }
}
