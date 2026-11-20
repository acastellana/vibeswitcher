import Foundation
import VibeCore

/// The reminder to run Claude Code's `/doctor prompt-audit` in each project a lead runs in (the app's
/// `PromptAuditDesk` and `PromptAuditCard`, for a node; the rule and the record are `PromptAudit`'s, shared): the
/// projects' transcripts are looked at (read only, on from where the last look stopped) at the engine's first refresh
/// and every 30 minutes; a project due one, after the interval (14 days) or once its sessions answer on another model
/// than the last audit was for, gets a `status` notice saying why and what to type in its lead's session. Nothing types
/// it: the user does (a run found in the transcripts resets the clock). `vibeswitcher prompt-audit FOLDER snooze|off|on`
/// (the user's voice, `prompt-audit`) is the card's Remind me in a week and Not for this project, and turns it back on.
/// The record is the node's own, `<node root>/prompt-audit.json`; the app's settings (on, the interval) aren't the
/// node's: on, at the default interval.
extension LeadEngine {
    static let promptAuditEvery: TimeInterval = 30 * 60

    /// The node's record of the projects' audits.
    var promptAuditFile: URL { root.appendingPathComponent("prompt-audit.json") }

    /// Looks at each running lead's project's transcripts, keeps what it found and works out which are due. `done` once
    /// they're out (a look under way: at once, without another). On `queue`.
    func lookAtPromptAudits(done: (() -> Void)? = nil) {
        guard !promptAuditLooking else { done?(); return }
        promptAuditLooking = true
        promptAuditLooked = true
        let roots = leadRoots.map { ($0 as NSString).standardizingPath }
        let (file, home, now, queue, note) = (promptAuditFile, self.home, promptAuditNow(), self.queue, self.note)
        promptAuditBook.async { [weak self] in
            var book = PromptAudit.Book.load(from: file)
            for root in roots {
                let kept = book.projects[root]
                let scan = PromptAudit.scan(PromptAudit.transcripts(root: root, home: home), read: kept?.read ?? [:])
                book.projects[root] = PromptAudit.observe(kept, scan: scan, now: now)
            }
            do { try book.save(to: file) } catch { note("prompt audit: \(file.path) not written: \(error)") }
            let due = Self.promptAuditsDue(book, roots: roots, now: now)
            queue.async {
                self?.promptAuditsDue = due
                self?.promptAuditLooking = false
                done?()
            }
        }
    }

    /// The projects of `roots` due an audit at `now` in `book`.
    static func promptAuditsDue(_ book: PromptAudit.Book, roots: [String], now: Date) -> [String: PromptAudit.Due] {
        var due: [String: PromptAudit.Due] = [:]
        for root in roots { if let project = book.projects[root], let why = PromptAudit.due(project, now: now) { due[root] = why } }
        return due
    }

    /// What `status` says of each project due an audit.
    var promptAuditNotices: [String] {
        let now = promptAuditNow()
        return promptAuditsDue.sorted { $0.key < $1.key }.map { root, due in
            "time for a prompt audit in \(LeadMail.project(of: root)) (\(root)): \(PromptAudit.reason(due, now: now)) Type "
                + "`\(PromptAudit.command)` in its lead's session: Claude Code checks its CLAUDE.md, AGENTS.md, .claude rules, skills, "
                + "commands and agents for prompting a newer model makes obsolete. `vibeswitcher prompt-audit \(root) snooze` reminds you "
                + "in a week, `off` stops these reminders there"
        }
    }

    /// What `prompt-audit` does to a project's record.
    enum PromptAuditChange: String {
        case snooze, off, on
    }

    /// `change` made to `root`'s record (a project the record doesn't know yet starts from now), then which are due
    /// again; `done` with the project's record as it then is. On `queue`; `done` on it too.
    func changePromptAudit(root: String, _ change: PromptAuditChange, done: @escaping (PromptAudit.Project) -> Void) {
        let (file, now, queue, note) = (promptAuditFile, promptAuditNow(), self.queue, self.note)
        let roots = leadRoots.map { ($0 as NSString).standardizingPath }
        promptAuditBook.async { [weak self] in
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
            let due = Self.promptAuditsDue(book, roots: roots, now: now)
            queue.async {
                self?.promptAuditsDue = due
                done(project)
            }
        }
    }
}
