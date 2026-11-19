import Foundation
import VibeCore

/// push_remote on a node: the lead's tool records a push request in the vault (`LeadPush`) for the user's click on
/// Push, which the app offers (`PushRequests.swift`) and the node doesn't yet: nothing here pushes or settles one. So
/// that neither the lead nor the user waits on a click that can't come, each refresh asks the vault for every running
/// lead's open request (one call per root at a time, off the engine's queue, as the app's `PushRequests.look`); the
/// lead is told once per request that nothing on this node will push it and no outcome will come, and `status` lists
/// it while it's open (`notices`). What the real feature should be is in the parity table's push row.
extension LeadEngine {
    /// Asks the vault for each root's open push request. On `queue`.
    func lookAtPushes(roots: Set<String>) {
        pushAsked = pushAsked.filter { roots.contains($0.key) }
        pushTold = pushTold.filter { roots.contains($0.key) }
        let vault = link.vault
        for root in roots where !pushLooking.contains(root) {
            pushLooking.insert(root)
            work.async { [weak self] in
                let request = Result { try vault.pushRequest(root: root) }
                guard let self else { return }
                self.queue.async { self.pushLooked(root, request) }
            }
        }
    }

    /// What the vault said of `root`'s push request; not known (the host didn't answer): what was kept stays. A request
    /// not told yet is told to the lead. On `queue`.
    func pushLooked(_ root: String, _ result: Result<LeadPush.Request?, Error>) {
        pushLooking.remove(root)
        guard case .success(let request) = result else { return }
        pushAsked[root] = request
        guard let request, pushTold[root] != request.id else { return }
        pushTold[root] = request.id
        note("lead: \(LeadMail.project(of: root))'s lead asked for push \(ConfigSeal.inert(request.id, limit: 40)); no client on this node offers it")
        deliver(built: { Self.pushNotOffered(request) }, from: .system("push"), root: root, action: nil)
    }

    /// What the lead hears: its request is kept, and nothing here pushes it.
    static func pushNotOffered(_ request: LeadPush.Request) -> String {
        "About your push request \(request.id) (\(request.branch) at \(request.short) to \(request.target)): this VibeSwitcher node has no "
            + "Push button or command yet, so nothing here will push it, and no message about its outcome will come. Don't wait on it. "
            + "The request stays recorded and the user sees it in `vibeswitcher status`; they push by hand if they want it pushed. "
            + "Carry on with other work."
    }

    /// What `status` says while the request is open.
    static func pushNotice(_ request: LeadPush.Request, root: String) -> String {
        let said = "\(LeadMail.project(of: root))'s lead asked you to push \(request.branch) at \(request.short) (\(request.ahead) commit"
            + (request.ahead == 1 ? "" : "s") + ") to \(request.target) (request \(request.id)). This node can't push it for you yet: "
            + "push it by hand, or leave it."
        return ConfigSeal.inert(said, limit: 400)
    }
}
