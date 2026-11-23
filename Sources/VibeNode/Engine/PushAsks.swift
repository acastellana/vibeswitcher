import Foundation
import VibeCore

/// What the push asks need of the engine: a lead's value to show a request on, and telling a lead.
protocol PushLeads: AnyObject {
    /// `root`'s open request as its lead's value carries it (nil: none). On the engine's queue.
    func pushShown(_ request: LeadPush.Request?, root: String)
    /// What came of `root`'s push, told to its lead from VibeSwitcher. On the engine's queue.
    func pushTold(_ text: @escaping @Sendable () -> String, root: String)
}

/// push_remote on a node (the app's `PushRequests.swift`): the lead's tool records a push request in the vault
/// (`LeadPush`), and only the user settles it, here with `vibeswitcher push FOLDER` or `vibeswitcher decline-push FOLDER`
/// (the user's voice: the command line's typed code, the request recorded in the vault, `Requests.push`), where the app
/// has the Push and Decline buttons on its card. Each refresh asks the vault for every running lead's open request (one
/// call per root at a time, off the engine's queue, none while that root's push runs, as the app's `look`); the lead's
/// value carries it (`LeadStore.Lead.push`: `status` and the page show it, and the page drafts the command, never pushes),
/// and `status` has a notice while it's open. Settling asks the vault to hand the request over (`LeadVault.settlePush`,
/// the node's server being the vault's app) and pushes it (`LeadPush.settle`, off the engine's queue); the lead hears
/// the outcome from VibeSwitcher (`LeadPush.message`, the app's `onSettled`), and the progress log has it.
///
/// Its state is its own, on the engine's queue.
final class PushWatch {
    private let queue: DispatchQueue
    private let work: DispatchQueue
    private let link: HostLink
    private let note: (String) -> Void
    /// Who shows and hears the requests: the engine, held weakly.
    weak var leads: PushLeads?
    /// Each lead's open push request, by root, as the vault last said; the request last noted in the log, by root; the
    /// roots whose vault look is under way, and whose push the user is settling.
    private var asked: [String: LeadPush.Request] = [:]
    private var noted: [String: String] = [:]
    private var looking: Set<String> = []
    private var settling: Set<String> = []
    /// Settles a push request (`LeadPush.settle`: the request's id, the root, push or decline, the vault), off the
    /// engine's queue; a test's stand-in.
    var settler: @Sendable (String, String, Bool, LeadVault) -> (request: LeadPush.Request?, outcome: LeadPush.Outcome) = { id, root, push, vault in
        LeadPush.settle(id: id, root: root, push: push, vault: vault)
    }

    init(queue: DispatchQueue, work: DispatchQueue, link: HostLink, note: @escaping (String) -> Void) {
        self.queue = queue
        self.work = work
        self.link = link
        self.note = note
    }

    /// Each root's open request, as kept. On the engine's queue.
    var open: [String: LeadPush.Request] {
        EngineWatch.assertOn(queue)
        return asked
    }

    /// Asks the vault for each root's open push request. On the engine's queue.
    func look(roots: Set<String>) {
        EngineWatch.assertOn(queue)
        for root in asked.keys where !roots.contains(root) { keep(nil, root: root) }
        noted = noted.filter { roots.contains($0.key) }
        let vault = link.vault
        for root in roots where !looking.contains(root) && !settling.contains(root) {
            looking.insert(root)
            work.async { [weak self] in
                let request = Result { try vault.pushRequest(root: root) }
                guard let self else { return }
                self.queue.async { self.looked(root, request) }
            }
        }
    }

    /// What the vault said of `root`'s push request; not known (the host didn't answer): what was kept stays. A new
    /// request is noted once. On the engine's queue.
    private func looked(_ root: String, _ result: Result<LeadPush.Request?, Error>) {
        looking.remove(root)
        guard case .success(let request) = result, !settling.contains(root) else { return }
        keep(request, root: root)
        guard let request, noted[root] != request.id else { return }
        noted[root] = request.id
        note("lead: \(LeadMail.project(of: root))'s lead asked for push \(ConfigSeal.inert(request.id, limit: 40)): "
             + "`vibeswitcher push` or `vibeswitcher decline-push` settles it")
    }

    /// `root`'s open request as kept, and on its lead's value. On the engine's queue.
    private func keep(_ request: LeadPush.Request?, root: String) {
        if let request { asked[root] = request } else { asked[root] = nil }
        leads?.pushShown(request, root: root)
    }

    /// The user's `vibeswitcher push` (`push` true) or `decline-push` of `root`'s request `id`, the one their command
    /// showed them: the vault hands that request over (nil when it's no longer open: replaced or settled), Push pushes
    /// exactly it (`LeadPush.settle`, off the engine's queue), and the lead is told the outcome. `then` hears on the
    /// engine's queue what came of it. From any thread.
    func settle(root: String, id: String, push: Bool, then: @escaping (Result<WireKinds.PushResult, LeadEngine.CardFailure>) -> Void) {
        queue.async { [self] in
            guard link.state == .connected else {
                return then(.failure(.refused("the server's link to its host isn't welcomed yet: try again")))
            }
            guard !settling.contains(root) else {
                return then(.failure(.refused("a push of \(ConfigSeal.inert(root, limit: 400))'s is under way: wait for it")))
            }
            settling.insert(root)
            let vault = link.vault
            let settle = settler
            work.async { [weak self] in
                let settled = settle(id, root, push, vault)
                guard let self else { return }
                self.queue.async { self.settled(root: root, id: id, request: settled.request, outcome: settled.outcome, then: then) }
            }
        }
    }

    /// What settling `root`'s request `id` came to. On the engine's queue.
    private func settled(root: String, id: String, request: LeadPush.Request?, outcome: LeadPush.Outcome,
                         then: (Result<WireKinds.PushResult, LeadEngine.CardFailure>) -> Void) {
        settling.remove(root)
        let shown = request ?? asked[root]
        if asked[root]?.id == id { keep(nil, root: root) }
        // Shown everywhere (the reply, the log, the lead's chat, which the page reads) with no URL's credentials.
        let said = PushText.scrub(request.map { Self.pushOutcome(Self.shown($0), outcome) } ?? Self.pushGone(id, outcome))
        note("lead: \(LeadMail.project(of: root))'s push request \(ConfigSeal.inert(id, limit: 40)): \(ConfigSeal.inert(said, limit: 400))")
        // The lead hears what came of it, from VibeSwitcher (the app's `onSettled`): only of a request the vault handed over.
        if let request { leads?.pushTold({ PushText.scrub(LeadPush.message(Self.shown(request), outcome)) }, root: root) }
        then(.success(WireKinds.PushResult(request: id, settled: Self.settledWord(outcome), ok: outcome.pushed || outcome == .declined, said: said,
                                           target: shown?.target)))
    }

    /// `request` as it may be shown: its URL without credentials (`PushText.displayURL`).
    static func shown(_ request: LeadPush.Request) -> LeadPush.Request {
        var shown = request
        shown.url = PushText.displayURL(request.url)
        return shown
    }

    /// The outcome as one word, for the command line.
    static func settledWord(_ outcome: LeadPush.Outcome) -> String {
        switch outcome {
        case .pushed: return "pushed"
        case .upToDate: return "upToDate"
        case .notFastForward: return "notFastForward"
        case .remoteRejected: return "remoteRejected"
        case .failed: return "failed"
        case .refused: return "refused"
        case .declined: return "declined"
        case .gone: return "gone"
        }
    }

    /// What the user reads of it (the app's `PushRequests.notice`, copied: the port map's "Copied from the app").
    static func pushOutcome(_ request: LeadPush.Request, _ outcome: LeadPush.Outcome) -> String {
        switch outcome {
        case .pushed: return "Pushed \(request.short) to \(request.target). The lead was told."
        case .upToDate: return "\(request.target) was at \(request.short) already: nothing to push."
        case .notFastForward(let said): return "Not pushed: \(request.target) has commits \(request.short) lacks (not a fast-forward; nothing forced). The lead was told to fetch and merge first.\n\(said)"
        case .remoteRejected(let said): return "Not pushed: the remote refused it.\n\(said)"
        case .failed(let said): return "Not pushed: git push failed.\n\(said)"
        case .refused(let why): return "Not pushed: \(why)"
        case .declined: return "Declined: nothing was pushed. The lead was told."
        case .gone: return "That request was no longer open (the lead asked again since): nothing was pushed."
        }
    }

    /// What the user reads when the vault handed no request over.
    static func pushGone(_ id: String, _ outcome: LeadPush.Outcome) -> String {
        if case .refused(let why) = outcome { return "Not pushed: \(why)" }
        return "Push request \(id) is no longer open (the lead asked again since, or it was settled): nothing was pushed."
    }

    /// What `status` says while the request is open.
    static func pushNotice(_ request: LeadPush.Request, root: String) -> String {
        let said = "\(LeadMail.project(of: root))'s lead asked you to push \(request.branch) at \(request.short) (\(request.ahead) commit"
            + (request.ahead == 1 ? "" : "s") + ") to \(request.target) (request \(request.id)): `vibeswitcher push \(root)` pushes it, "
            + "`vibeswitcher decline-push \(root)` declines it"
        return ConfigSeal.inert(said, limit: 600)
    }
}

extension LeadEngine: PushLeads {
    /// The user's push or decline of `root`'s request `id` (`PushWatch.settle`). From any thread.
    public func settlePush(root: String, id: String, push: Bool, then: @escaping (Result<WireKinds.PushResult, CardFailure>) -> Void) {
        self.push.settle(root: root, id: id, push: push, then: then)
    }

    func pushShown(_ request: LeadPush.Request?, root: String) {
        let project = NodeIds.project(root: root)
        if let lead = leads.leads[project], lead.push != request { leads.lead(root: root) { $0.push = request } }
    }

    func pushTold(_ text: @escaping @Sendable () -> String, root: String) {
        deliver(built: text, from: .system("push"), root: root, action: nil)
    }
}
