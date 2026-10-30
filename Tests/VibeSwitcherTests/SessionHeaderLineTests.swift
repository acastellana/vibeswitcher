import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The session header's one-line texts (its title, the details line, a replaced lead's line) are `lineLimit(1)`, but a
/// `Text` still lays out its whole string each time it's measured, and the header's stacks measure it a few times a
/// layout: a 200,000-character draft typed into a replaced lead took 350 ms a measure. Each is cut to what the header
/// could show (hang-20261030-003929 measured the details line).
struct SessionHeaderLineTests {
    @Test func aLongDraftGivesTheReplacedLeadsLineNoMoreThanTheHeaderShows() {
        var replaced = ReplacedLead(root: "/project-c", project: "project-c", tty: "ttys004", live: UUID())
        replaced.draft = String(repeating: "split the layer out\nand then the next one ", count: 5_000)
        let line = SessionHeaderView.replacedLine(replaced)
        #expect(line.count == 401)
        #expect(line.hasPrefix("replaced — continue in Lead · project-c  ·  Enter sends to Lead · project-c: split the layer out and then"))
        #expect(line.hasSuffix("…"))
        #expect(!line.contains("\n"))
    }

    @Test func aLineTheHeaderCanShowIsGivenAsItIs() {
        var replaced = ReplacedLead(root: "/project-c", project: "project-c", tty: "ttys004", live: UUID())
        replaced.draft = "split the layer out\nnow"
        #expect(SessionHeaderView.replacedLine(replaced)
                == "replaced — continue in Lead · project-c  ·  Enter sends to Lead · project-c: split the layer out now")
        // Up to 400 characters as they are; one more is cut.
        let prefix = "replaced — continue in Lead · project-c  ·  Enter sends to Lead · project-c: "
        replaced.draft = String(repeating: "a", count: 400 - prefix.count)
        #expect(SessionHeaderView.replacedLine(replaced) == prefix + replaced.draft)
        replaced.draft += "b"
        #expect(SessionHeaderView.replacedLine(replaced) == prefix + replaced.draft.dropLast() + "…")
    }
}
