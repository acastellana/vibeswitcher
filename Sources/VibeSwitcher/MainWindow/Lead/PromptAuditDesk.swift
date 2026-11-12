import Combine
import Foundation
import VibeCore

/// The reminders to run `/doctor prompt-audit` (`PromptAudit`), one per project a lead runs in: which project's card
/// shows in its lead's chat, and what its buttons do. It looks at the projects' transcripts (read only, off the main
/// thread) at `start` and every `every` seconds; the clock is injected (`clock`) so tests set the time.
///
/// Nothing here types into a session by itself: only `runNow`, from the card's Run now, hands the command to `send`
/// (the composer's own send into the lead's session, as the user's message).
/// Used on the main thread only (its looks run on a queue of their own and come back to it).
final class PromptAuditDesk: ObservableObject {
    /// The projects whose card shows now, and why (none while the reminders are off).
    @Published private(set) var due: [String: PromptAudit.Due] = [:]
    /// Why Run now didn't go, by project (the lead's session couldn't take it).
    @Published private(set) var refused: [String: String] = [:]
    @Published private(set) var book: PromptAudit.Book

    /// Settings › Project lead.
    var enabled = true { didSet { if enabled != oldValue { recompute() } } }
    var intervalDays = PromptAudit.defaultIntervalDays { didSet { if intervalDays != oldValue { recompute() } } }

    let file: URL
    let home: String
    var clock: () -> Date
    /// The projects' root folders: those a lead runs in.
    var roots: () -> [String] = { [] }
    /// How often the transcripts are looked at.
    var every: TimeInterval = 30 * 60

    private let queue = DispatchQueue(label: "dev.vibeswitcher.prompt-audit", qos: .utility)
    private var timer: Timer?
    private var looking = false
    /// Asked for while a look was under way: their `done`s, for the look after it.
    private var again: [() -> Void] = []

    init(file: URL = PromptAudit.Book.file, home: String = VibePaths.home, clock: @escaping () -> Date = Date.init) {
        self.file = file
        self.home = home
        self.clock = clock
        book = PromptAudit.Book.load(from: file)
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
    }

    /// Looks at each project's transcripts (on from where the last look stopped), keeps what it found, and works out
    /// the cards. `done` once the cards are out.
    func refresh(done: (() -> Void)? = nil) {
        // A look under way: another once it's done (what it finds is for roots and a time from before this call).
        guard !looking else {
            again.append(done ?? {})
            return
        }
        let roots = Set(roots().map { ($0 as NSString).standardizingPath })
        looking = true
        let projects = book.projects
        let now = clock()
        let home = home
        queue.async { [weak self] in
            var seen: [String: PromptAudit.Project] = [:]
            for root in roots {
                let kept = projects[root]
                let scan = PromptAudit.scan(PromptAudit.transcripts(root: root, home: home), read: kept?.read ?? [:])
                seen[root] = PromptAudit.observe(kept, scan: scan, now: now)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                do {
                    self.looking = false
                    // What changed meanwhile (a click) is kept: only this look's reading and runs are laid over it.
                    for (root, project) in seen {
                        var merged = project
                        let before = projects[root]
                        if let current = self.book.projects[root], current != before {
                            merged.off = current.off
                            if current.snoozedUntil != before?.snoozedUntil { merged.snoozedUntil = current.snoozedUntil }
                            if (current.lastRun ?? -.infinity) > (merged.lastRun ?? -.infinity) {
                                (merged.lastRun, merged.model) = (current.lastRun, current.model)
                            }
                        }
                        self.book.projects[root] = merged
                    }
                    self.save()
                    self.recompute(roots: roots)
                    done?()
                }
                if !self.again.isEmpty {
                    let waiting = self.again
                    self.again = []
                    self.refresh { waiting.forEach { $0() } }
                }
            }
        }
    }

    /// The cards, from the book as it is now.
    func recompute(roots: Set<String>? = nil) {
        let roots = roots ?? Set(self.roots().map { ($0 as NSString).standardizingPath })
        guard enabled else { due = [:]; return }
        let now = clock()
        var cards: [String: PromptAudit.Due] = [:]
        for root in roots {
            guard let project = book.projects[root], let reason = PromptAudit.due(project, now: now, intervalDays: intervalDays) else { continue }
            cards[root] = reason
        }
        if cards != due { due = cards }
    }

    // MARK: The card's buttons

    /// Run now: `/doctor prompt-audit` into the project's lead session through `send` (the composer's), only on the
    /// user's click. The clock restarts once it's sent; a session that couldn't take it leaves the card up.
    @discardableResult
    func runNow(_ root: String, send: (String) -> Bool) -> Bool {
        guard due[root] != nil, let project = book.projects[root] else { return false }
        guard send(PromptAudit.command) else {
            refused[root] = "The lead's session couldn't take it now; try again once it's open in the chat."
            return false
        }
        refused[root] = nil
        update(root, PromptAudit.ran(project, at: clock()))
        return true
    }

    /// Remind me in a week.
    func snooze(_ root: String) {
        guard let project = book.projects[root] else { return }
        update(root, PromptAudit.snoozed(project, at: clock()))
    }

    /// Not for this project.
    func turnOff(_ root: String) {
        guard var project = book.projects[root] else { return }
        project.off = true
        update(root, project)
    }

    private func update(_ root: String, _ project: PromptAudit.Project) {
        book.projects[root] = project
        save()
        recompute()
    }

    private func save() {
        do { try book.save(to: file) } catch { Breadcrumbs.shared.note("prompt audit: couldn't keep its record: \(error)") }
    }

    /// For the sandbox and tests: the project's record set as given (then the cards worked out again).
    func set(_ root: String, _ project: PromptAudit.Project) { update((root as NSString).standardizingPath, project) }
}
