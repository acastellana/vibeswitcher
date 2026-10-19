import Foundation
import Testing
@testable import VibeCore

/// 2026-10-18: the 18:10 install replaced all three leads, and the old ones kept answering the user for four hours with
/// no tools: genswap's "split the GenLayer layer out" and films' "do what we need to do" never reached a board. A
/// replaced lead now says so in the window, what's typed into it goes to the live lead, and the new lead reads its
/// last turns before greeting.
struct ReplacedLeadTests {
    let temp = Scratch()

    // MARK: The window's state

    @Test func aLeadOtherThanTheOneItsBoardNamesIsReplacedByThatOne() {
        let old = UUID(), new = UUID(), other = UUID()
        let leads = [(id: old, root: "/genswap"), (id: new, root: "/genswap"), (id: other, root: "/films")]
        #expect(StatusRules.replacedLeads(leads, holders: ["/genswap": new, "/films": other]) == [old: new])
        // The board names a session that's gone (or none, a new lead still starting): nothing is said replaced by it.
        #expect(StatusRules.replacedLeads(leads, holders: ["/genswap": UUID()]).isEmpty)
        #expect(StatusRules.replacedLeads(leads, holders: [:]).isEmpty)
        // A lead of another project never replaces this one.
        #expect(StatusRules.replacedLeads([(id: old, root: "/genswap"), (id: other, root: "/films")], holders: ["/genswap": other]).isEmpty)
    }

    @Test func aReplacedLeadSaysWhereToContinueNotAnOrdinaryStatus() {
        let replaced = ReplacedLead(root: "/genswap", project: "genswap", tty: "ttys004", live: UUID())
        #expect(replaced.label == "replaced — continue in Lead · genswap")
        #expect(replaced.rowState.text == replaced.label)
        #expect(replaced.rowState.group == .idle && replaced.rowState.since == nil)
        let ordinary = ["needs you", "working", "background", "done", "idle", "unknown", "paused", "starting", "shell"]
        #expect(!ordinary.contains(replaced.rowState.text))
        #expect(replaced.routed("split the GenLayer layer out")
                == "(typed into the replaced lead's session on ttys004, which has no tools; VibeSwitcher sent it on to you) split the GenLayer layer out")
        let at = Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970
        #expect(ReplacedLead.notice("do what we need to do", to: "films", at: at, held: false)
                .hasPrefix("“do what we need to do” went to Lead · films as your message"))
        #expect(ReplacedLead.notice("x", to: "films", at: at, held: true).contains("waits for Lead · films, starting"))
    }

    // MARK: What's typed into it

    @Test func typedKeysMakeALineThatEnterSubmits() {
        var line = HostInput.Line()
        #expect(line.feed(Array("split the GenLayer".utf8)).isEmpty)
        #expect(line.draft == "split the GenLayer")
        // Backspace takes a whole character (é is two bytes), arrows and Esc do nothing.
        #expect(line.feed(Array(" é".utf8) + [127, 127] + [27, 91, 68] + [27, 79, 65] + [27]).isEmpty)
        #expect(line.draft == "split the GenLayer")
        #expect(line.feed(Array(" layer out".utf8) + [13]) == ["split the GenLayer layer out"])
        #expect(line.draft.isEmpty)
        // An empty Enter sends nothing; ⌃C and ⌃U clear the line.
        #expect(line.feed([13]).isEmpty)
        #expect(line.feed(Array("oops".utf8) + [3] + Array("again".utf8) + [21] + [13]).isEmpty)
    }

    @Test func aPasteKeepsItsNewlinesAndItsEnterDoesntSubmit() {
        var line = HostInput.Line()
        let paste: [UInt8] = [27, 91, 50, 48, 48, 126] + Array("first\r\nsecond\r".utf8) + [127] + [27, 91, 50, 48, 49, 126]
        #expect(line.feed(paste).isEmpty)
        #expect(line.draft == "first\n\nsecond\n")
        #expect(line.feed([13]) == ["first\n\nsecond"])
        // The composer's and the phone's writes come the same way: text (or a paste), then Enter on its own.
        #expect(line.feed(ComposerText.writes("do what we need to do", bracketed: true).flatMap(\.bytes)) == ["do what we need to do"])
        #expect(line.feed(HostInput.writes(text: "and the films", submit: true, key: nil).flatMap(\.bytes)) == ["and the films"])
    }

    // MARK: The new lead reads its last turns

    func transcript(_ lines: [String]) throws -> (home: String, path: String) {
        let home = temp.url("home")
        let folder = home.appendingPathComponent(".claude/projects/-genswap")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("old-lead.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return (home.path, file.path)
    }

    func user(_ text: String, at minute: Int) -> String {
        let quoted = String(data: try! JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]), encoding: .utf8)!.dropFirst().dropLast()
        return #"{"type":"user","message":{"role":"user","content":\#(quoted)},"uuid":"u\#(minute)","timestamp":"2026-10-18T18:\#(String(format: "%02d", minute)):00.000Z"}"#
    }

    func assistant(_ text: String, at minute: Int) -> String {
        let quoted = String(data: try! JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]), encoding: .utf8)!.dropFirst().dropLast()
        return #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":\#(quoted)}]},"uuid":"a\#(minute)","timestamp":"2026-10-18T18:\#(String(format: "%02d", minute)):30.000Z"}"#
    }

    func tool(at minute: Int) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t\#(minute)","name":"Bash","input":{"command":"git status"}}]},"uuid":"t\#(minute)","timestamp":"2026-10-18T18:\#(String(format: "%02d", minute)):40.000Z"}"#
    }

    @Test func theLastTenPromptsWithTheirRepliesAndOneWithNone() throws {
        var lines = [user(LeadPrompts.startOpening + " Read status…", at: 0), assistant("Board is empty. What next?", at: 0)]
        for minute in 1...12 {
            lines += [user("ask \(minute)", at: minute), tool(at: minute), assistant("answer \(minute)", at: minute)]
        }
        lines.append(user("split the GenLayer layer out", at: 13))
        let (home, path) = try transcript(lines)
        let text = try #require(LastTurns.read(transcript: path, tty: "ttys004", home: home))
        #expect(text.contains("lead on ttys004"))
        // The last ten prompts: 4 to 12 answered, then the one that got no reply.
        for minute in 4...12 { #expect(text.contains("ask \(minute)\n") && text.contains("answer \(minute)\n")) }
        for minute in 1...3 { #expect(!text.contains("ask \(minute)\n")) }
        #expect(text.contains("split the GenLayer layer out\n\n(No reply: act on this.)"))
        // The app's start prompt isn't the user's, and tool calls aren't turns.
        #expect(!text.contains(LeadPrompts.startOpening) && !text.contains("git status"))
        #expect(text.range(of: "ask 4")!.lowerBound < text.range(of: "ask 12")!.lowerBound)
    }

    @Test func longTurnsAreCutToTheLimitKeepingTheUnanswered() throws {
        var lines: [String] = []
        for minute in 1...9 { lines += [user("ask \(minute) " + String(repeating: "x", count: 3000), at: minute), assistant(String(repeating: "y", count: 3000), at: minute)] }
        lines.append(user("do what we need to do", at: 10))
        let (home, path) = try transcript(lines)
        let text = try #require(LastTurns.read(transcript: path, tty: "ttys009", home: home))
        #expect(text.count <= LastTurns.limit)
        #expect(text.contains("do what we need to do\n\n(No reply: act on this.)"))
        #expect(text.contains("ask 9 ") && !text.contains("ask 1 "))
    }

    @Test func noTranscriptNoTurns() throws {
        let (home, path) = try transcript([assistant("hello", at: 1)])
        #expect(LastTurns.read(transcript: path, tty: "ttys004", home: home) == nil)
        #expect(LastTurns.read(transcript: home + "/missing.jsonl", tty: "ttys004", home: home) == nil)
        // Outside the agents' folders it isn't read.
        let outside = temp.url("outside.jsonl")
        try (user("hi", at: 1) + "\n").write(to: outside, atomically: true, encoding: .utf8)
        #expect(LastTurns.read(transcript: outside.path, tty: "ttys004", home: home) == nil)
    }

    @Test func theStartPromptNamesTheTurnsFileOnlyWhenThereIsOne() throws {
        let root = temp.url("repo").path
        let file = try #require(try LeadLaunch.writeTurns("# The replaced lead's last turns\n\n## The user\n\nsplit it\n", root: root))
        #expect(file == root + "/.vibeswitcher/replaced-lead-turns.md")
        #expect(try String(contentsOfFile: file, encoding: .utf8).contains("split it"))
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)
        for goal in [nil, "build it"] {
            let start = LeadPrompts.leadStart(root: root, goal: goal, note: "n", replaced: (tty: "ttys004", turnsFile: file))
            #expect(start.hasPrefix(LeadPrompts.startOpening))
            #expect(start.contains("You replace the lead on ttys004"))
            #expect(start.contains("Before greeting, read \(file)"))
            #expect(start.contains("act on what the user asked there"))
            #expect(start.contains("\(root)/docs/lead/decisions.md"))
        }
        // A replaced lead with no transcript: no file (an earlier one goes), and the prompt names none.
        #expect(try LeadLaunch.writeTurns(nil, root: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: file))
        let plain = LeadPrompts.leadStart(root: root, goal: nil, note: "n", replaced: nil)
        #expect(plain == LeadPrompts.leadStart(root: root, goal: nil, note: "n"))
        #expect(!plain.contains("replaced-lead-turns") && !plain.contains("You replace"))
        #expect(plain.hasPrefix("You're starting as the project lead. Read status"))
    }
}
