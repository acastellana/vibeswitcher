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

/// What the app makes of a program's status: hooks, then the program, then the title; rows and their details.
struct ProgramStatusInAppTests {
    let now = Date(timeIntervalSince1970: 1_000)

    private func program(_ state: ProgramStatus.State, kind: String? = nil, title: String? = nil,
                         message: String? = nil) -> ProgramStatus {
        ProgramStatus(state: state, kind: kind, app: "fake", title: title, message: message, since: now)
    }

    private func hosted(_ status: ProgramStatus?, agent: String? = nil, ended: Bool = false) -> HostSession {
        HostSession(id: UUID(), tty: "ttys080", childPID: 80, cwd: "/tmp/p", command: "fake", label: "Fake", agent: agent,
                    title: "fake", startedAt: now.addingTimeInterval(-600), cols: 80, rows: 24,
                    exit: ended ? HostSession.Exit(status: 0, at: now.addingTimeInterval(5)) : nil, programStatus: status)
    }

    /// Without hooks the program's word decides, whatever the title shows (or doesn't).
    @Test func withoutHooksTheProgramDecides() {
        let at = now.timeIntervalSince1970
        #expect(StatusRules.resolve(hook: nil, program: program(.working), title: .none, now: at) == .working)
        #expect(StatusRules.resolve(hook: nil, program: program(.blocked, kind: "permission"), title: .busy, now: at) == .needsInput)
        #expect(StatusRules.resolve(hook: nil, program: program(.done), title: .busy, now: at) == .done)
        #expect(StatusRules.resolve(hook: nil, program: program(.idle), title: .idle, now: at, seenBusy: true) == .idle)
        #expect(StatusRules.resolve(hook: nil, program: program(.error), title: .none, now: at) == .done)
        // No report: the title, as before.
        #expect(StatusRules.resolve(hook: nil, program: nil, title: .none, now: at) == .unknown)
    }

    /// Hooks win when both exist: the program's status changes nothing a hook (with the title) decides.
    @Test func hooksWinOverTheProgram() {
        let at = now.timeIntervalSince1970
        let asking = HookState(agent: .claude, tty: "ttys080", lastEvent: "PermissionRequest", lastEventAt: at - 1)
        #expect(StatusRules.resolve(hook: asking, program: program(.working), title: .busy, now: at) == .needsInput)
        let working = HookState(agent: .claude, tty: "ttys080", lastEvent: "UserPromptSubmit", lastEventAt: at - 1)
        #expect(StatusRules.resolve(hook: working, program: program(.blocked), title: .busy, now: at) == .working)
        // A settled hook is still corrected by the title, not the program.
        #expect(StatusRules.resolve(hook: working, program: program(.working), title: .idle, now: at + 60) == .done)
    }

    @Test func detailsSayWhatTheProgramWaitsOnOrDoes() {
        #expect(StatusRules.detail(for: program(.blocked, kind: "permission", message: "Bash")) == "Asks permission: Bash")
        #expect(StatusRules.detail(for: program(.blocked, kind: "permission")) == "Asks permission")
        #expect(StatusRules.detail(for: program(.blocked, kind: "question", message: "Which one?")) == "Which one?")
        #expect(StatusRules.detail(for: program(.blocked, kind: "auth")) == "Needs you to sign in")
        #expect(StatusRules.detail(for: program(.blocked)) == "Waiting for you")
        #expect(StatusRules.detail(for: program(.working, title: "Build", message: "step 2")) == "Build")
        #expect(StatusRules.detail(for: program(.working, message: "step 2")) == "step 2")
        #expect(StatusRules.detail(for: program(.error, message: "rate limited")) == "Ended on an error: rate limited")
        #expect(StatusRules.detail(for: program(.idle)) == nil)
    }

    /// A window session the scan finds no agent in shows what its program reports, since it reported it.
    @Test func hostedRowsShowTheProgramsStatus() {
        func state(_ status: ProgramStatus?, agent: String? = nil) -> RowState {
            WindowRow(content: .hosted(hosted(status, agent: agent)), project: "p").state(now: now.addingTimeInterval(30))
        }
        #expect(state(program(.working)) == RowState(text: "working", since: now, group: .working))
        #expect(state(program(.working, title: "Indexing")) == RowState(text: "Indexing", since: now, group: .working))
        #expect(state(program(.blocked, kind: "permission")) == RowState(text: "needs you", since: now, group: .needsYou))
        #expect(state(program(.done)) == RowState(text: "done", since: now, group: .ready))
        #expect(state(program(.error)) == RowState(text: "error", since: now, group: .ready))
        #expect(state(program(.idle)) == RowState(text: "idle", since: now, group: .idle))
        // Over its preset's "starting" or "agent ended" (an agent the scan hasn't found, or that quit).
        #expect(state(program(.blocked), agent: "claude").group == .needsYou)
        // No report: a shell, as before.
        #expect(state(nil).text == "shell")
        let row = WindowRow(content: .hosted(hosted(program(.blocked))), project: "p")
        #expect(row.statusSince == now)
        #expect(WindowGroups.attention([WindowSection(project: "p", rows: [row])]).map(\.project) == ["Needs you"])
    }

    /// An ended session says nothing of its program's last report, even if one was left on it.
    @Test func endedSessionsShowNoProgramStatus() {
        let ended = hosted(program(.working), ended: true)
        #expect(ended.liveProgramStatus == nil)
        #expect(hosted(program(.working)).liveProgramStatus?.state == .working)
        let state = WindowRow(content: .hosted(ended), project: "p").state(now: now.addingTimeInterval(30))
        #expect(state.text == "finished" && state.group == .idle)
        #expect(WindowRow(content: .hosted(ended), project: "p").statusSince == ended.startedAt)
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
