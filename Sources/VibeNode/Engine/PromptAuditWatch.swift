import Foundation
import VibeCore

/// What the prompt-audit watch needs of the engine: the running leads' projects.
protocol PromptAuditLeads: AnyObject {
    /// The roots of the leads running now. On the engine's queue.
    var promptAuditRoots: Set<String> { get }
}

/// The reminder to run Claude Code's `/doctor prompt-audit` in each project a lead runs in (the app's
/// `PromptAuditDesk` and `PromptAuditCard`, for a node; the rule and the record are `PromptAudit`'s, shared): the
/// projects' transcripts are looked at (read only, on from where the last look stopped) at the engine's first refresh
/// and every 30 minutes; a project due one, after the interval (14 days) or once its sessions answer on another model
/// than the last audit was for, gets a `status` notice saying why and what to type in its lead's session. Nothing types
/// it: the user does (a run found in the transcripts resets the clock). `vibeswitcher prompt-audit FOLDER snooze|off|on`
/// (the user's voice, `prompt-audit`) is the card's Remind me in a week and Not for this project, and turns it back on.
/// The record is the node's own, `<node root>/prompt-audit.json`; the app's settings (on, the interval) aren't the
/// node's: on, at the default interval. Its state is its own, on the engine's queue.
final class PromptAuditWatch {
    static let every: TimeInterval = 30 * 60

    /// What `prompt-audit` does to a project's record.
    enum Change: String {
        case snooze, off, on
    }

    private let queue: DispatchQueue
    private let file: URL
    private let home: String
    private let settings: NodeSettings.Files
    private let note: (String) -> Void
    /// Who says which projects' leads run: the engine, held weakly; asked at each look.
    weak var leads: PromptAuditLeads?
    /// The record's reads and writes, one at a time, off the engine's queue.
    private let book = DispatchQueue(label: "vibenode.lead-engine.prompt-audit", qos: .utility)
    /// The look every 30 minutes on the engine's clock.
    private var timer: Subscription?
    /// Whether a look is under way, and whether one ran yet (the first runs at the first refresh).
    private var looking = false
    private var looked = false
    /// The projects due a prompt audit, and why, as the last look found them.
    private var dueNow: [String: PromptAudit.Due] = [:]
    /// The clock a reminder is judged by (a test's later).
    var now: () -> Date = Date.init

    init(queue: DispatchQueue, root: URL, home: String, clock: NodeClock?, note: @escaping (String) -> Void) {
        self.queue = queue
        file = root.appendingPathComponent("prompt-audit.json")
        settings = NodeSettings.Files(root: root)
        self.home = home
        self.note = note
        timer = clock?.every(Int(Self.every)) { [weak self] in self?.queue.async { self?.look() } }
    }

    /// Whether a look ran yet. On the engine's queue.
    var hasLooked: Bool {
        EngineWatch.assertOn(queue)
        return looked
    }

    /// The projects due an audit, as the last look found them. On the engine's queue.
    var due: [String: PromptAudit.Due] {
        EngineWatch.assertOn(queue)
        return dueNow
    }

    /// Looks at each running lead's project's transcripts, keeps what it found and works out which are due. `done` once
    /// they're out (a look under way: at once, without another). On the engine's queue.
    func look(done: (() -> Void)? = nil) {
        EngineWatch.assertOn(queue)
        guard !looking else { done?(); return }
        looking = true
        looked = true
        let roots = (leads?.promptAuditRoots ?? []).map { ($0 as NSString).standardizingPath }
        let (file, home, now, note, settings) = (file, home, now(), note, settings)
        book.async { [weak self] in
            var book = PromptAudit.Book.load(from: file)
            // Settings' reminder and its days (`prompt_audit`, `prompt_audit_days`, the app's keys in settings.plist).
            let store = settings.preferences
            let (on, days) = (store.map(PromptAudit.isOn) ?? true, store.map(PromptAudit.intervalDays) ?? PromptAudit.defaultIntervalDays)
            for root in roots {
                let kept = book.projects[root]
                let scan = PromptAudit.scan(PromptAudit.transcripts(root: root, home: home), read: kept?.read ?? [:])
                book.projects[root] = PromptAudit.observe(kept, scan: scan, now: now)
            }
            do { try book.save(to: file) } catch { note("prompt audit: \(file.path) not written: \(error)") }
            let due = on ? Self.due(book, roots: roots, now: now, intervalDays: days) : [:]
            self?.queue.async {
                self?.dueNow = due
                self?.looking = false
                done?()
            }
        }
    }

    /// The projects of `roots` due an audit at `now` in `book`.
    static func due(_ book: PromptAudit.Book, roots: [String], now: Date, intervalDays: Int = PromptAudit.defaultIntervalDays) -> [String: PromptAudit.Due] {
        var due: [String: PromptAudit.Due] = [:]
        for root in roots {
            if let project = book.projects[root], let why = PromptAudit.due(project, now: now, intervalDays: intervalDays) { due[root] = why }
        }
        return due
    }

    /// What `status` says of each project due an audit. On the engine's queue.
    var notices: [String] {
        let now = now()
        return due.sorted { $0.key < $1.key }.map { root, due in
            "time for a prompt audit in \(LeadMail.project(of: root)) (\(root)): \(PromptAudit.reason(due, now: now)) Type "
                + "`\(PromptAudit.command)` in its lead's session: Claude Code checks its CLAUDE.md, AGENTS.md, .claude rules, skills, "
                + "commands and agents for prompting a newer model makes obsolete. `vibeswitcher prompt-audit \(root) snooze` reminds you "
                + "in a week, `off` stops these reminders there"
        }
    }

    /// `change` made to `root`'s record (a project the record doesn't know yet starts from now), then which are due
    /// again; `done` with the project's record as it then is. On the engine's queue; `done` on it too.
    func change(root: String, _ change: Change, done: @escaping (PromptAudit.Project) -> Void) {
        EngineWatch.assertOn(queue)
        let (file, now, note, settings) = (file, now(), note, settings)
        let roots = (leads?.promptAuditRoots ?? []).map { ($0 as NSString).standardizingPath }
        book.async { [weak self] in
            let store = settings.preferences
            let (on, days) = (store.map(PromptAudit.isOn) ?? true, store.map(PromptAudit.intervalDays) ?? PromptAudit.defaultIntervalDays)
            var book = PromptAudit.Book.load(from: file)
            var project = book.projects[root] ?? PromptAudit.Project(firstSeen: now)
            switch change {
            case .snooze: project = PromptAudit.snoozed(project, at: now)
            case .off: project.off = true
            case .on:
                project.off = false
                project.snoozedUntil = nil
            }
            book.projects[root] = project
            do { try book.save(to: file) } catch { note("prompt audit: \(file.path) not written: \(error)") }
            let due = on ? Self.due(book, roots: roots, now: now, intervalDays: days) : [:]
            self?.queue.async {
                self?.dueNow = due
                done(project)
            }
        }
    }
}

extension LeadEngine: PromptAuditLeads {
    typealias PromptAuditChange = PromptAuditWatch.Change

    var promptAuditRoots: Set<String> { leadRoots }

    /// What `status` says of each project due an audit.
    var promptAuditNotices: [String] { promptAudit.notices }

    /// A look at the running leads' projects' transcripts; `done` once it's out. On `queue`.
    func lookAtPromptAudits(done: (() -> Void)? = nil) { promptAudit.look(done: done) }

    /// `change` made to `root`'s record; `done` with it. On `queue`.
    func changePromptAudit(root: String, _ change: PromptAuditChange, done: @escaping (PromptAudit.Project) -> Void) {
        promptAudit.change(root: root, change, done: done)
    }
}
