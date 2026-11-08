import Foundation

/// The lead server's periodic fetch. Uses fetch_remote's pinned URL and isolated transport path; never lands work.
/// State lives beside the vault's scratch data, outside the worker-writable project, and survives a server restart.
final class LeadRemotePoller: @unchecked Sendable {
    static let sender = "remote_fetch"
    static let interval: TimeInterval = 2 * 60 * 60
    static let maximumInterval: TimeInterval = 12 * 60 * 60

    private struct State: Codable {
        var next: Date = .distantPast
        var interval: TimeInterval = LeadRemotePoller.interval
        var seen: String?
        var reported: String?
    }

    private weak var lead: LeadToolset?
    private var timer: DispatchSourceTimer?

    init(lead: LeadToolset) { self.lead = lead }
    deinit { timer?.cancel() }

    /// Each tick is background MCP work, so an install waits for it as it does for fetch_remote itself.
    func start(run: @escaping (@escaping () -> Void) -> Bool) {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "vibeswitcher.remote-fetch"))
        timer.schedule(deadline: .now(), repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let done = DispatchSemaphore(value: 0)
            if run({ self.tick(); done.signal() }) { done.wait() }
        }
        self.timer = timer
        timer.resume()
    }

    /// Clock injected by callers in tests; no sleeps, real remotes, or alternate git path needed.
    /// `state.next` is checked first of all: a tick that isn't due asks the session host nothing, however many a day.
    func tick(now: Date = Date()) {
        guard let lead, lead.role == .lead else { return }
        let workflow = lead.workflow
        let dueFile = lead.vault.scratch(root: lead.root, "remote-poll")
            .appendingPathComponent(LeadVault.hash(workflow.remoteName + "\n" + workflow.base) + ".next")
        if let next = (try? Data(contentsOf: dueFile)).flatMap({ try? JSONDecoder().decode(Date.self, from: $0) }), now < next { return }
        guard (try? lead.authenticate()) != nil,
               (try? lead.checkSettings(workflow, not: "Not fetched")) != nil,
              (try? lead.checkBattery(not: "Not fetched")) != nil,
              !(lead.runtime.steadyLoad().map { $0 > lead.macLimits().loadLimit } ?? false),
              let pin = try? lead.vault.guardedSettings(root: lead.root)?[LeadRemote.urlKey(workflow.remoteName)] else { return }
        let folder = lead.vault.scratch(root: lead.root, "remote-poll")
        guard (try? lead.vault.ensurePrivate(folder)) != nil,
              let held = FileLock.attempt(folder.appendingPathComponent("poll.lock").path) else { return }
        defer { held.release() }
        let key = LeadVault.hash(workflow.remoteName + "\n" + workflow.base + "\n" + pin)
        let file = folder.appendingPathComponent(key + ".json")
        var state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: file))) ?? State()
        guard now >= state.next,
              let url = try? lead.pinnedURL(workflow.remoteName, not: "Not fetched", first: false).url else { return }
        defer {
            try? LeadVault.writePrivate(JSONEncoder().encode(state), to: file)
            // What the next tick reads before asking the vault for anything.
            try? LeadVault.writePrivate(JSONEncoder().encode(state.next), to: dueFile)
        }
        let remote = workflow.remoteName, base = workflow.base
        let scratch = lead.vault.scratch(root: lead.root, "remote-git")
        do {
            try lead.vault.ensurePrivate(scratch)
            let tip = try LeadRemote.fetch(root: lead.root, remote: remote, url: url, branch: base, scratch: scratch).get()
            // Keep merge_remote's exact fetched-tip guard, just as fetch_remote does.
            try lead.vault.setHead(tip, root: lead.root, branch: LeadRemote.trackingRef(remote: remote, branch: base))
            guard let head = lead.branchHead(base) else { throw LeadRemote.Failure("No local branch \(base)") }
            let incoming = try LeadRemote.incoming(root: lead.root, head: head, tip: tip, records: workflow.recordsDir).get()
            state.interval = Self.interval
            state.next = now.addingTimeInterval(state.interval)
            let label = "\(remote)/\(base)"
            let text = "\(LeadToolset.commits(incoming.behind)) from the other Mac at \(label) (\(tip)): "
                + "merge_remote would " + LeadToolset.outlook(incoming.outlook, base: base, label: label)
            if state.seen != tip {
                try lead.store.appendProgress("Automatically fetched \(label) at \(tip.prefix(8)): \(text)")
                state.seen = tip
            }
            if incoming.behind > 0, state.reported != tip {
                // tellLead records the report before delivery. A delivery error still leaves it on the board;
                // that counts as reported, so the same tip cannot produce a second report on the next poll.
                let already = lead.store.load().reports?.contains { $0.about == Self.sender && $0.text.contains("(\(tip)):") } ?? false
                if !already { _ = try lead.tellLead(text, about: Self.sender) }
                state.reported = tip
            }
        } catch {
            // Offline, timeout, or any failed fetch: no report flood. Recover on the next successful fetch.
            state.interval = min(Self.maximumInterval, state.interval * 2)
            state.next = now.addingTimeInterval(state.interval)
        }
    }
}
