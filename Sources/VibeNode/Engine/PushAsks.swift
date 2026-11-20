import Foundation
import VibeCore

/// push_remote on a node (the app's `PushRequests.swift`): the lead's tool records a push request in the vault
/// (`LeadPush`), and only the user settles it, here with `vibeswitcher push FOLDER` or `vibeswitcher decline-push FOLDER`
/// (the user's voice: the command line's typed code, the request recorded in the vault, `Requests.push`), where the app
/// has the Push and Decline buttons on its card. Each refresh asks the vault for every running lead's open request (one
/// call per root at a time, off the engine's queue, none while that root's push runs, as the app's `look`); the lead's
/// value carries it (`LeadStore.Lead.push`: `status` and the page show it, and the page drafts the command, never pushes),
/// and `status` has a notice while it's open. Settling asks the vault to hand the request over (`LeadVault.settlePush`,
/// the node's server being the vault's app) and pushes it (`LeadPush.settle`, off the engine's queue); the lead hears
/// the outcome from VibeSwitcher (`LeadPush.message`, the app's `onSettled`), and the progress log has it.
extension LeadEngine {
    /// Asks the vault for each root's open push request. On `queue`.
    func lookAtPushes(roots: Set<String>) {
        for root in pushAsked.keys where !roots.contains(root) { keepPush(nil, root: root) }
        pushNoted = pushNoted.filter { roots.contains($0.key) }
        let vault = link.vault
        for root in roots where !pushLooking.contains(root) && !pushSettling.contains(root) {
            pushLooking.insert(root)
            work.async { [weak self] in
                let request = Result { try vault.pushRequest(root: root) }
                guard let self else { return }
                self.queue.async { self.pushLooked(root, request) }
            }
        }
    }

    /// What the vault said of `root`'s push request; not known (the host didn't answer): what was kept stays. A new
    /// request is noted once. On `queue`.
    func pushLooked(_ root: String, _ result: Result<LeadPush.Request?, Error>) {
        pushLooking.remove(root)
        guard case .success(let request) = result, !pushSettling.contains(root) else { return }
        keepPush(request, root: root)
        guard let request, pushNoted[root] != request.id else { return }
        pushNoted[root] = request.id
        note("lead: \(LeadMail.project(of: root))'s lead asked for push \(ConfigSeal.inert(request.id, limit: 40)): "
             + "`vibeswitcher push` or `vibeswitcher decline-push` settles it")
    }

    /// `root`'s open request as kept, and on its lead's value. On `queue`.
    private func keepPush(_ request: LeadPush.Request?, root: String) {
        if let request { pushAsked[root] = request } else { pushAsked[root] = nil }
        let project = NodeIds.project(root: root)
        if let lead = leads.leads[project], lead.push != request { leads.lead(root: root) { $0.push = request } }
    }

    /// The user's `vibeswitcher push` (`push` true) or `decline-push` of `root`'s request `id`, the one their command
    /// showed them: the vault hands that request over (nil when it's no longer open: replaced or settled), Push pushes
    /// exactly it (`LeadPush.settle`, off the engine's queue), and the lead is told the outcome. `then` hears on `queue`
    /// what came of it. From any thread.
    public func settlePush(root: String, id: String, push: Bool, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        queue.async { [self] in
            guard link.state == .connected else {
                return then(.failure(.refused("the server's link to its host isn't welcomed yet: try again")))
            }
            guard !pushSettling.contains(root) else {
                return then(.failure(.refused("a push of \(ConfigSeal.inert(root, limit: 400))'s is under way: wait for it")))
            }
            pushSettling.insert(root)
            let vault = link.vault
            let settle = pushSettle
            work.async { [weak self] in
                let settled = settle(id, root, push, vault)
                guard let self else { return }
                self.queue.async { self.settled(root: root, id: id, request: settled.request, outcome: settled.outcome, then: then) }
            }
        }
    }

    /// What settling `root`'s request `id` came to. On `queue`.
    private func settled(root: String, id: String, request: LeadPush.Request?, outcome: LeadPush.Outcome,
                         then: (Result<NodeWire.Value, CardFailure>) -> Void) {
        pushSettling.remove(root)
        let shown = request ?? pushAsked[root]
        if pushAsked[root]?.id == id { keepPush(nil, root: root) }
        let said = request.map { Self.pushOutcome($0, outcome) } ?? Self.pushGone(id, outcome)
        note("lead: \(LeadMail.project(of: root))'s push request \(ConfigSeal.inert(id, limit: 40)): \(ConfigSeal.inert(said, limit: 400))")
        // The lead hears what came of it, from VibeSwitcher (the app's `onSettled`): only of a request the vault handed over.
        if let request { deliver(built: { LeadPush.message(request, outcome) }, from: .system("push"), root: root, action: nil) }
        then(.success(.object([
            "request": .string(id), "settled": .string(Self.settledWord(outcome)),
            "ok": .bool(outcome.pushed || outcome == .declined), "said": .string(said),
            "target": shown.map { .string($0.target) } ?? .null,
        ])))
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
