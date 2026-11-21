import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The sidebar's Close Finished (N)… (`CloseFinished`, `ShellTidier.closeFinished`): in every project, after one
/// confirmation listing them, it ends the finished Run-card shells and the replaced leads between turns, and nothing
/// else; what changed between the question and its answer is skipped. Made-up sessions in a real `WindowModel`; `end`
/// only records, the shells' prompts are a set the test holds.
@MainActor
@Suite(.serialized)
struct CloseFinishedTests {
    let temp = Scratch()
    static let now = ShellTidierTests.start

    /// The sessions of two projects, alpha and bravo, as the host and the scan list them.
    @MainActor
    final class Fixture {
        var hosted: [HostSession] = []
        var scanned: [Session] = []
        /// Run-card shells running a program in the foreground (not at their prompt).
        var busy: Set<UUID> = []
        /// Replaced leads, by window session.
        var replaced: Set<UUID> = []
        /// Sessions the board names as their project's lead.
        var holders: Set<UUID> = []
        var ended: [UUID] = []
        var asked: [ShellTidier.Question] = []
        /// What the question is answered, after `meanwhile` ran.
        var answer = true
        var meanwhile: () -> Void = {}
        let model = WindowModel()
        private var ttys = 0

        func tty() -> String {
            ttys += 1
            return String(format: "ttys%03d", 700 + ttys)
        }

        /// A Run-card shell (`ShellTidierTests.session`'s launch line) in `project`, its command ended as `state` says
        /// (nil: it still runs).
        @discardableResult
        func shell(_ title: String, project: String, state: ProgramStatus.State? = .done, command: String? = ShellTidierTests.runLine) -> HostSession {
            var session = ShellTidierTests.session("Shell: \(title)", command: command, state: state)
            session.tty = tty()
            session.cwd = "/work/\(project)"
            session.title = title
            hosted.append(session)
            return session
        }

        /// A window session whose agent the scan found, labelled `label` (its role), its agent `status`.
        @discardableResult
        func agent(_ title: String, label: String, project: String, status: SessionStatus) -> HostSession {
            let host = HostSession(id: UUID(), tty: tty(), childPID: 1, cwd: "/work/\(project)", command: "claude", label: label, agent: "claude",
                                   title: "", startedAt: CloseFinishedTests.now - 3_600, cols: 80, rows: 24, exit: nil)
            var session = Session(tty: host.tty, agent: .claude, pid: 1, startedAt: host.startedAt, cwd: host.cwd, project: project, task: nil,
                                  status: status, statusSince: CloseFinishedTests.now - 60, detail: nil, hasHooks: true, inTerminalApp: false)
            session.hostID = host.id
            session.customName = title
            hosted.append(host)
            scanned.append(session)
            return host
        }

        func status(of id: UUID, _ status: SessionStatus) {
            if let index = scanned.firstIndex(where: { $0.hostID == id }) { scanned[index].status = status }
            feed()
        }

        func feed() {
            model.update(sessions: scanned, hosted: hosted, table: TableRead(at: CloseFinishedTests.now))
            model.replacedLeads = Dictionary(uniqueKeysWithValues: replaced.map {
                ($0, ReplacedLead(root: "/work/alpha", project: "alpha", tty: "ttys000", live: nil))
            })
        }

        func tidier(file: URL) -> ShellTidier {
            let tidier = ShellTidier(file: file, now: { CloseFinishedTests.now }, log: { _ in })
            tidier.sessions = { [unowned self] in hosted }
            tidier.idle = { [unowned self] in !busy.contains($0.id) }
            tidier.holdsRole = { [unowned self] in holders.contains($0) }
            tidier.end = { [unowned self] in ended.append($0) }
            tidier.ask = { [unowned self] question in
                asked.append(question)
                meanwhile()
                feed()
                return answer
            }
            return tidier
        }

        func closeFinished(_ tidier: ShellTidier) -> [UUID] {
            tidier.closeFinished(rows: { [unowned self] in model.allRows }, replaced: { [unowned self] in Set(model.replacedLeads.keys) })
        }
    }

    /// Everything the button may never take, in both projects: the lead holding the role, a replaced lead mid-turn (and
    /// one on a prompt, and one whose state isn't known), a Run-card shell whose command still runs and one running a
    /// program at the moment, a shell the user opened, a worker and a verifier (one of them even marked replaced).
    @discardableResult
    static func neverClosed(_ fixture: Fixture) -> [HostSession] {
        let current = fixture.agent("Lead now", label: "Lead · alpha", project: "alpha", status: .idle)
        let working = fixture.agent("Lead mid-turn", label: "Lead · bravo", project: "bravo", status: .working)
        let asking = fixture.agent("Lead on a prompt", label: "Lead · bravo", project: "bravo", status: .needsInput)
        let unknown = fixture.agent("Lead not known", label: "Lead · bravo", project: "bravo", status: .unknown)
        let background = fixture.agent("Lead waiting on its job", label: "Lead · alpha", project: "alpha", status: .background)
        let running = fixture.shell("Migrate", project: "bravo", state: nil)
        let busy = fixture.shell("Server", project: "alpha")
        fixture.busy.insert(busy.id)
        let byHand = fixture.shell("Mine", project: "alpha", state: .done, command: nil)
        let worker = fixture.agent("Task 1", label: "Worker: Task 1", project: "alpha", status: .idle)
        let verifier = fixture.agent("Audit 1", label: "Verifier: Task 1", project: "bravo", status: .done)
        fixture.replaced.formUnion([working.id, asking.id, unknown.id, background.id, worker.id])
        fixture.holders.insert(current.id)
        return [current, working, asking, unknown, background, running, busy, byHand, worker, verifier]
    }

    /// Finished Run-card shells in two projects and one replaced lead between turns: the confirmation lists exactly
    /// those, grouped by project, shells and leads apart, and confirming ends exactly those.
    @Test func itListsAndEndsTheFinishedShellsOfEveryProjectAndTheIdleReplacedLead() throws {
        let fixture = Fixture()
        let install = fixture.shell("Install", project: "alpha")
        let backup = fixture.shell("Backup", project: "bravo", state: .error)
        let old = fixture.agent("Lead before", label: "Lead · alpha", project: "alpha", status: .done)
        fixture.replaced.insert(old.id)
        let never = Self.neverClosed(fixture)
        fixture.feed()
        let tidier = fixture.tidier(file: temp.url("used").appendingPathComponent("used.json"))

        let listed = tidier.closable(rows: fixture.model.allRows, replaced: fixture.replaced)
        #expect(Set(listed.map(\.id)) == [install.id, backup.id, old.id], "\(listed.map(\.name))")
        #expect(listed.first { $0.id == old.id }?.kind == .replacedLead)
        let shells = Set(listed.filter { $0.kind == .shell }.map(\.id))
        #expect(shells == [install.id, backup.id])

        let ended = fixture.closeFinished(tidier)
        #expect(Set(ended) == [install.id, backup.id, old.id])
        #expect(fixture.ended.count == 3 && Set(fixture.ended) == Set(ended))
        #expect(Set(fixture.ended).isDisjoint(with: never.map(\.id)))

        let question = try #require(fixture.asked.first)
        #expect(fixture.asked.count == 1)
        #expect(question.message == "Close 2 finished shells and 1 replaced lead?", "\(question.message)")
        #expect(question.button == "Close 3 Sessions")
        // Grouped by project, each project's shells and replaced leads named apart.
        let groups = question.detail.components(separatedBy: "\n\n")
        let alpha = try #require(groups.first { $0.hasPrefix("alpha\n") }, "\(question.detail)")
        let bravo = try #require(groups.first { $0.hasPrefix("bravo\n") }, "\(question.detail)")
        #expect(alpha == "alpha\nFinished shell:\n• Install: command finished 0s ago\nReplaced lead:\n• Lead before: between turns", "\(alpha)")
        #expect(bravo == "bravo\nFinished shell:\n• Backup: command failed 0s ago", "\(bravo)")
        for session in never {
            let name = session.title.isEmpty ? (fixture.scanned.first { $0.hostID == session.id }?.customName ?? session.label) : session.title
            #expect(!question.detail.contains(name), "\(name) was listed")
        }
    }

    /// With only what may never be closed, nothing is listed, the question only says so, and nothing ends.
    @Test func whatMayNeverBeClosedIsNeitherListedNorEnded() {
        let fixture = Fixture()
        Self.neverClosed(fixture)
        fixture.feed()
        let tidier = fixture.tidier(file: temp.url("used").appendingPathComponent("used.json"))
        #expect(tidier.closable(rows: fixture.model.allRows, replaced: fixture.replaced).isEmpty)
        #expect(fixture.closeFinished(tidier).isEmpty && fixture.ended.isEmpty)
        #expect(fixture.asked.map(\.button) == [nil])
        #expect(fixture.asked.first?.message == "Nothing finished to close")
    }

    /// What changed between the question and its answer stays: a shell back to running a program, one whose command
    /// runs again (a new start report), a lead that took a turn, and one its board names as the lead again. What
    /// didn't change ends.
    @Test func whatChangedSinceTheQuestionIsSkipped() {
        let fixture = Fixture()
        let busyAgain = fixture.shell("Install", project: "alpha")
        let runningAgain = fixture.shell("Build", project: "bravo")
        let same = fixture.shell("Backup", project: "bravo", state: .error)
        let working = fixture.agent("Lead before", label: "Lead · alpha", project: "alpha", status: .idle)
        let holding = fixture.agent("Lead again", label: "Lead · bravo", project: "bravo", status: .done)
        let stays = fixture.agent("Lead long ago", label: "Lead · bravo", project: "bravo", status: .idle)
        fixture.replaced = [working.id, holding.id, stays.id]
        fixture.feed()
        let tidier = fixture.tidier(file: temp.url("used").appendingPathComponent("used.json"))
        fixture.meanwhile = {
            fixture.busy.insert(busyAgain.id)
            if let index = fixture.hosted.firstIndex(where: { $0.id == runningAgain.id }) {
                fixture.hosted[index].programStatus = ProgramStatus(state: .working, app: ShellTidy.app, since: CloseFinishedTests.now)
            }
            fixture.status(of: working.id, .working)
            fixture.holders.insert(holding.id)
        }
        let ended = fixture.closeFinished(tidier)
        #expect(fixture.asked.first?.button == "Close 6 Sessions", "\(fixture.asked.map(\.message))")
        #expect(Set(ended) == [same.id, stays.id], "\(ended)")
        #expect(Set(fixture.ended) == [same.id, stays.id])
    }

    /// A replaced lead that is no longer replaced when the answer comes (the role came back to it, the list no longer
    /// marks it) is skipped, as is one that ended meanwhile.
    @Test func aLeadNoLongerReplacedOrEndedMeanwhileIsSkipped() {
        let fixture = Fixture()
        let back = fixture.agent("Lead back", label: "Lead · alpha", project: "alpha", status: .idle)
        let gone = fixture.agent("Lead gone", label: "Lead · bravo", project: "bravo", status: .idle)
        fixture.replaced = [back.id, gone.id]
        fixture.feed()
        let tidier = fixture.tidier(file: temp.url("used").appendingPathComponent("used.json"))
        fixture.meanwhile = {
            fixture.replaced.remove(back.id)
            if let index = fixture.hosted.firstIndex(where: { $0.id == gone.id }) {
                fixture.hosted[index].exit = HostSession.Exit(status: 0, at: CloseFinishedTests.now)
            }
        }
        #expect(fixture.closeFinished(tidier).isEmpty && fixture.ended.isEmpty)
        #expect(fixture.asked.first?.button == "Close 2 Sessions")
    }

    /// Cancel ends nothing.
    @Test func cancelEndsNothing() {
        let fixture = Fixture()
        fixture.shell("Install", project: "alpha")
        fixture.feed()
        let tidier = fixture.tidier(file: temp.url("used").appendingPathComponent("used.json"))
        fixture.answer = false
        #expect(fixture.closeFinished(tidier).isEmpty && fixture.ended.isEmpty)
        #expect(fixture.asked.count == 1)
    }

    // MARK: The button

    /// The sidebar in a window off screen, read as an accessibility client reads it.
    @MainActor
    final class Sidebar {
        let window: NSWindow
        let view: NSView

        init(model: WindowModel, leads: LeadController, actions: WindowActions) {
            window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view = NSHostingView(rootView: SessionListView(model: model, leads: leads, actions: actions))
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
            window.contentView = view
            window.orderFrontRegardless()
        }

        func settle() {
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date())
        }

        var said: String { AXClient.dump(view) }
    }

    /// The sidebar's foot shows "Close Finished (N)…" only when there's something to close, N the count the
    /// confirmation lists; pressing it asks that question and ends those.
    @Test func theButtonShowsOnlyWithSomethingToCloseAndItsCountIsTheLists() async throws {
        let fixture = Fixture()
        Self.neverClosed(fixture)
        fixture.feed()
        let tidier = fixture.tidier(file: temp.url("used").appendingPathComponent("used.json"))
        var actions = EndedSnapshots.actions
        actions.closable = { tidier.closable(rows: fixture.model.allRows, replaced: Set(fixture.model.replacedLeads.keys)) }
        actions.closeFinished = { _ = fixture.closeFinished(tidier) }

        let folder = temp.url("sidebar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let host = HostClient(socketPath: folder.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { folder }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: folder.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: folder, home: folder.path) { _ in "true" }
        let sidebar = Sidebar(model: fixture.model, leads: leads, actions: actions)
        defer { sidebar.window.close() }
        #expect(AXClient.attach(sidebar.window) == 1)
        #expect(await until { sidebar.settle(); return sidebar.said.contains("Lead now") }, "the sidebar didn't fill: \(sidebar.said)")
        // Nothing to close: no button.
        #expect(!sidebar.said.contains("Close Finished") && !sidebar.said.contains("finished session"), "\(sidebar.said)")

        let install = fixture.shell("Install", project: "alpha")
        let backup = fixture.shell("Backup", project: "bravo", state: .error)
        let old = fixture.agent("Lead before", label: "Lead · alpha", project: "alpha", status: .done)
        fixture.replaced.insert(old.id)
        fixture.feed()
        // Its words are CloseFinished.title(3), "Close Finished (3)…"; a client reads them as its label.
        #expect(await until { sidebar.settle(); return sidebar.said.contains("Close 3 finished sessions") }, "\(sidebar.said)")
        #expect(AXClient.press(sidebar.view, labelled: "Close 3 finished sessions"), "\(sidebar.said)")
        #expect(await until { !fixture.asked.isEmpty })
        // The count it showed is what the confirmation lists, and what it ended.
        #expect(fixture.asked.first?.button == "Close 3 Sessions")
        #expect(Set(fixture.ended) == [install.id, backup.id, old.id])

        // Once they ended, the button goes.
        for id in fixture.ended {
            if let index = fixture.hosted.firstIndex(where: { $0.id == id }) {
                fixture.hosted[index].exit = HostSession.Exit(status: 129, at: Self.now)
            }
            fixture.scanned.removeAll { $0.hostID == id }
        }
        fixture.replaced.remove(old.id)
        fixture.feed()
        #expect(await until { sidebar.settle(); return !sidebar.said.contains("finished session") }, "\(sidebar.said)")
    }

    @Test func theButtonsWords() {
        #expect(CloseFinished.title(1) == "Close Finished (1)…")
        #expect(CloseFinished.title(12) == "Close Finished (12)…")
    }
}
