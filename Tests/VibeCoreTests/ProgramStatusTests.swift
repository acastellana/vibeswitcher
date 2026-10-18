import Foundation
import Testing
@testable import VibeCore

struct ProgramStatusTests {
    let now = Date(timeIntervalSince1970: 1_000)

    private func status(_ payload: String) -> ProgramStatus? {
        guard case .status(nil, let status)? = ProgramStatus.parse(payload, at: now) else { return nil }
        return status
    }

    private func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    /// What claude 2.1.302 printed in a scratch PTY whose terminal answered the query: the query, then idle, a prompt's
    /// working and done, and `state=clear` as it exited.
    @Test func claudeCodesReports() {
        #expect(ProgramStatus.parse("?", at: now) == .query)
        #expect(status("state=idle:app=claude-code") == ProgramStatus(state: .idle, app: "claude-code", since: now))
        #expect(status("state=working:app=claude-code")?.state == .working)
        #expect(status("state=done:app=claude-code")?.state == .done)
        #expect(ProgramStatus.parse("state=clear", at: now) == .clear(id: nil))
    }

    /// The shape Claude Code builds for a permission prompt (`jEr` in 2.1.302): kind, progress and a base64 message.
    @Test func blockedCarriesKindProgressAndMessage() {
        let parsed = status("state=blocked:app=claude-code:kind=permission:progress=40:msg=\(base64("Bash: rm -rf build"))")
        #expect(parsed == ProgramStatus(state: .blocked, kind: "permission", app: "claude-code", progress: 40,
                                        message: "Bash: rm -rf build", since: now))
        // kind only means something with blocked, progress only with working or blocked.
        #expect(status("state=done:kind=permission:progress=40") == ProgramStatus(state: .done, since: now))
        #expect(status("state=working:title=\(base64("Fix login"))")?.title == "Fix login")
    }

    @Test func tasksHaveIDs() {
        guard case .status("bg-1/sub", let task)? = ProgramStatus.parse("state=working:id=bg-1/sub", at: now) else {
            Issue.record("no task report"); return
        }
        #expect(task.state == .working)
        #expect(ProgramStatus.parse("state=clear:id=bg-1", at: now) == .clear(id: "bg-1"))
    }

    @Test func followsTheSpecsIgnoreAndDiscardRules() {
        // Ignored: no state, an unknown state, a bad id.
        #expect(ProgramStatus.parse("app=claude-code", at: now) == nil)
        #expect(ProgramStatus.parse("state=sleeping", at: now) == nil)
        #expect(ProgramStatus.parse("state=idle:id=a//b", at: now) == nil)
        #expect(ProgramStatus.parse("state=idle:id=\(String(repeating: "a", count: 33))", at: now) == nil)
        // Malformed pairs and unknown keys are skipped; the last of a repeated key wins.
        #expect(status("junk:state=idle:Bad=1:x=y z:future=1:state=working")?.state == .working)
        // Padding is optional.
        #expect(status("state=idle:msg=\(base64("ok").replacingOccurrences(of: "=", with: ""))")?.message == "ok")
        // Discarded whole: not base64, control characters, over the limits, progress out of range.
        #expect(ProgramStatus.parse("state=idle:msg=ab=c", at: now) == nil)
        // A value outside the grammar is a malformed pair, skipped.
        #expect(status("state=idle:msg=%%%")?.message == nil)
        #expect(ProgramStatus.parse("state=idle:msg=\(base64("a\u{1b}[2J"))", at: now) == nil)
        #expect(ProgramStatus.parse("state=idle:title=\(base64(String(repeating: "t", count: 193)))", at: now) == nil)
        #expect(ProgramStatus.parse("state=idle:msg=\(base64(String(repeating: "m", count: 2049)))", at: now) == nil)
        #expect(status("state=idle:msg=\(base64(String(repeating: "m", count: 2048)))") != nil)
        #expect(ProgramStatus.parse("state=working:progress=101", at: now) == nil)
    }

    /// A scratch plan-mode session of claude 2.1.302 reported these, in order, around asking for and approving a plan.
    @Test func reportsReadAsSessionStatuses() throws {
        let reports = ["state=idle:app=claude-code", "state=working:app=claude-code",
                       "state=blocked:app=claude-code:kind=permission:msg=YXBwcm92ZSBwbGFu", "state=working:app=claude-code",
                       "state=working:app=claude-code:msg=Q3JlYXRpbmcgaGVsbG8udHh0IHdpdGggImhpIiBhbmQgcmVhZCBpdCBiYWNr",
                       "state=done:app=claude-code", "state=error:app=claude-code"]
        let statuses = try reports.map { try #require(status($0)) }
        #expect(statuses.map(StatusRules.status(for:)) == [.idle, .working, .needsInput, .working, .working, .done, .done])
        #expect(statuses[2].kind == "permission" && statuses[2].message == "approve plan")
        #expect(statuses[4].message == #"Creating hello.txt with "hi" and read it back"#)
    }

    /// The host sends it; an app from before it ignores the field, and a host from before it sends none.
    @Test func hostSessionsDecodeAcrossVersions() throws {
        var session = HostSession(id: UUID(), tty: "ttys012", childPID: 42, cwd: "/tmp", command: "claude", label: "Claude",
                                  agent: "claude", title: "✳ Fix", startedAt: Date(timeIntervalSince1970: 1_000),
                                  cols: 120, rows: 40, exit: nil)
        let old = try HostCoding.encode(session)
        #expect(!String(decoding: old, as: UTF8.self).contains("programStatus"))
        #expect(try HostCoding.decode(HostSession.self, from: old).programStatus == nil)

        session.programStatus = ProgramStatus(state: .blocked, kind: "question", app: "claude-code", message: "Which one?", since: now)
        let new = try HostCoding.encode(session)
        #expect(try HostCoding.decode(HostSession.self, from: new) == session)
        let olderApp = try HostCoding.decode(HostSessionBeforeProgramStatus.self, from: new)
        #expect(olderApp.id == session.id && olderApp.title == "✳ Fix")
    }
}

/// `HostSession` as apps before OSC 7501 decode it.
private struct HostSessionBeforeProgramStatus: Decodable {
    var id: UUID
    var tty: String
    var childPID: Int32
    var cwd: String
    var command: String?
    var label: String
    var agent: String?
    var title: String
    var startedAt: Date
    var cols: Int
    var rows: Int
    var exit: HostSession.Exit?
}
