import Foundation
import Testing
@testable import VibeCore

/// How a Run-card shell's command ended, as the host captures it (`CommandCapture`) and the asker is told
/// (`ShellAsk.ending`): only what was printed between the launch line's start and end reports, as plain text, at most
/// 40 lines and 4 KB, secret-shaped text masked; what isn't known is said, never guessed.
struct ShellOutcomeTests {
    static let session = "11111111-2222-4333-8444-555555555555"
    static let now = Date(timeIntervalSince1970: 1_793_448_000)
    static let start = "\u{1b}]7501;state=working:app=vs-shell:id=command\u{07}"
    static func end(_ state: String = "error", exit: String? = "1") -> String {
        "\u{1b}]7501;state=\(state):app=vs-shell\(exit.map { ":exit=\($0)" } ?? "")\u{07}"
    }

    /// Feeds `text` in chunks of `size` bytes; the end, if it came.
    static func capture(_ text: String, size: Int = .max, capture: CommandCapture = CommandCapture()) -> CommandEnd? {
        let bytes = Array(text.utf8)
        var ends: [CommandEnd] = []
        var index = 0
        while index < bytes.count {
            let chunk = Data(bytes[index..<min(bytes.count, index + size)])
            if let end = capture.feed(chunk, at: now.addingTimeInterval(Double(index))) { ends.append(end) }
            index += size
        }
        #expect(ends.count <= 1)
        return ends.first
    }

    static func shell(_ end: CommandEnd?, live: Bool = true) -> HostSession {
        var session = HostSession(id: UUID(), tty: "ttys001", childPID: 1, cwd: "/work", command: "x", label: "Shell", agent: nil,
                                  title: "", startedAt: now, cols: 80, rows: 24, exit: live ? nil : .init(status: 0, at: now))
        session.commandEnd = end
        return session
    }

    static let request = ShellRequest(session: session, cwd: "/work/example", command: "make install", label: "", createdAt: now)
    static let answer = ShellAsk.Answer(state: .started, at: now, shell: "abc", name: "Shell: Install", endTold: false)

    /// What the shell printed before the command (its startup files) and after it (the interactive shell) isn't the
    /// command's; reports split across chunks anywhere are still found.
    @Test func onlyWhatsPrintedBetweenStartAndEndIsKept() throws {
        let text = "rc says hello\r\n" + Self.start + "\u{1b}[1;31merror:\u{1b}[0m it broke\r\n50%\r100%\r\nlast line\r\n"
            + Self.end() + "% echo typed after\r\ntyped after\r\n" + Self.end("done", exit: "0")
        for size in [1, 2, 3, 7, 64, .max] {
            let end = try #require(Self.capture(text, size: size), "chunks of \(size)")
            #expect(!end.ok && end.status == 1, "\(size): \(end)")
            #expect(end.tail == "error: it broke\n100%\nlast line" && !end.cut, "\(size): \(String(describing: end.tail))")
            #expect(!end.tail!.contains("rc says") && !end.tail!.contains("typed"))
        }
        // Once ended, nothing more is looked at.
        let capture = CommandCapture()
        #expect(Self.capture(Self.start + "one\n" + Self.end("done", exit: "0"), capture: capture)?.tail == "one")
        #expect(capture.feed(Data((Self.start + "two\n" + Self.end()).utf8), at: Self.now) == nil)
        // Another program's OSC 7501 inside the command (Claude Code's) isn't the end.
        let inner = "\u{1b}]7501;state=done:app=claude-code\u{07}"
        #expect(Self.capture(Self.start + "a\n" + inner + "b\n" + Self.end("done", exit: "0"))?.tail == "a\nb")
    }

    /// The status as the shell gave it, or not known: never made up.
    @Test func theExitStatusIsReadOrSaidUnknown() {
        #expect(Self.capture(Self.start + Self.end("done", exit: "0"))?.status == 0)
        #expect(Self.capture(Self.start + Self.end(exit: "128"))?.status == 128)
        // A shell that gave none, or something else.
        for odd in ["", "abc", "1x", "999", "-1", "0"] {
            let end = Self.capture(Self.start + Self.end(exit: odd))
            #expect(end?.ok == false && end?.status == nil, "\(odd): \(String(describing: end))")
        }
        // Launch lines from before statuses were reported: done is 0, error not known.
        #expect(Self.capture(Self.start + Self.end("done", exit: nil))?.status == 0)
        #expect(Self.capture(Self.start + Self.end(exit: nil))?.status == nil)
        // Ended with no start seen (a takeover whose replay lost it): its output isn't known.
        let blind = Self.capture("whatever\n" + Self.end())
        #expect(blind?.status == 1 && blind?.tail == nil)
        // An empty output is empty, not unknown.
        #expect(Self.capture(Self.start + Self.end("done", exit: "0"))?.tail == "")
    }

    /// At most 40 lines and 4 KB reach the agent, the last ones; a megabyte of output keeps only `keep` bytes meanwhile.
    @Test func theTailIsCapped() throws {
        let many = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let end = try #require(Self.capture(Self.start + many + Self.end()))
        #expect(end.tail == (61...100).map { "line \($0)" }.joined(separator: "\n") && end.cut)
        let wide = (1...30).map { "\($0) " + String(repeating: "x", count: 500) }.joined(separator: "\n")
        let capped = try #require(Self.capture(Self.start + wide + "\n" + Self.end()))
        #expect(capped.tail!.utf8.count <= CommandEnd.maxBytes && capped.cut && capped.tail!.hasPrefix("23 x"), "\(capped.tail!.prefix(20))")
        let one = try #require(Self.capture(Self.start + String(repeating: "y", count: 10_000) + "z" + Self.end()))
        #expect(one.tail!.utf8.count <= CommandEnd.maxBytes && one.tail!.hasSuffix("yz") && one.tail!.hasPrefix("…") && one.cut)
        let huge = String(repeating: "noise\n", count: 200_000) + "the end\n"
        let big = try #require(Self.capture(Self.start + huge + Self.end(), size: 65_536))
        #expect(big.tail!.hasSuffix("noise\nthe end") && big.cut && big.tail!.split(separator: "\n").count == 40)
    }

    /// The message: the request's id, the status, how long it ran and the last lines, secret-shaped text masked.
    @Test func theAskerHearsTheStatusAndTheLastLinesRedacted() throws {
        let token = "ghp_" + String(repeating: "A1b2", count: 9)
        // (The widest line isn't the token's: Redaction takes a line as wide as the widest to be soft-wrapped onto the next.)
        let output = "Installing… into /Applications/Example.app from the build folder of this worktree\nexport GITHUB_TOKEN=\(token)\nerror: signing failed"
        let failed = CommandEnd(ok: false, status: 1, startedAt: Self.now, at: Self.now.addingTimeInterval(75), tail: output, cut: true)
        let text = try #require(ShellAsk.ending(Self.request, Self.answer, session: Self.shell(failed)))
        #expect(text.hasPrefix("Shell request \(Self.request.id) (`make install` in /work/example) FAILED: the command exited with status 1 after 1m"), "\(text)")
        #expect(text.contains("The last 3 lines of its output") && text.contains("error: signing failed") && text.contains("Installing…"), "\(text)")
        #expect(!text.contains(token) && text.contains(Redaction.mask), "\(text)")
        // Succeeded, printing nothing.
        let ok = CommandEnd(ok: true, status: 0, startedAt: Self.now, at: Self.now.addingTimeInterval(2), tail: "", cut: false)
        #expect(ShellAsk.ending(Self.request, Self.answer, session: Self.shell(ok))?.contains("succeeded: the command exited with status 0 after 2s. It printed nothing.") == true)
        // A fence in the output doesn't close the block early.
        let fenced = CommandEnd(ok: false, status: 2, startedAt: nil, at: Self.now, tail: "```\nrm -rf x", cut: false)
        #expect(ShellAsk.ending(Self.request, Self.answer, session: Self.shell(fenced))?.contains("````\n```\nrm -rf x\n````") == true)
    }

    /// Fail closed: what wasn't captured is said so.
    @Test func whatWasntCapturedIsSaid() {
        // Still running: nothing to say yet.
        #expect(ShellAsk.ending(Self.request, Self.answer, session: Self.shell(nil)) == nil)
        let unknown = CommandEnd(ok: false, status: nil, startedAt: nil, at: Self.now, tail: nil, cut: false)
        let text = ShellAsk.ending(Self.request, Self.answer, session: Self.shell(unknown)) ?? ""
        #expect(text.contains("exited non-zero; its exact status wasn't captured") && text.contains("Its output wasn't captured"), "\(text)")
        // The shell ended first (`exit` in the command, or closed), or the host doesn't have it any more.
        #expect(ShellAsk.ending(Self.request, Self.answer, session: Self.shell(nil, live: false))?.contains("exit status and output weren't captured") == true)
        #expect(ShellAsk.ending(Self.request, Self.answer, session: nil)?.contains("is gone from VibeSwitcher") == true)
    }
}
