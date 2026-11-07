import Foundation
import VibeCore

/// The pushes the leads ask you for (push_remote, `LeadPush`), watched: each lead's open request, read from the session
/// host's vault at each refresh, is a card in the lead's chat with Push and Decline, and counts with its questions.
/// Your click is the approval, and only here: the vault hands the request over to this process alone
/// (`LeadVault.settlePush`), which runs the push itself (`LeadPush.settle`), off the main thread. The lead hears the
/// outcome (`onSettled`), and the progress log has it.
final class PushRequests: ObservableObject {
    /// The open request, by repository root.
    @Published private(set) var open: [String: LeadPush.Request] = [:]
    /// The roots whose request you clicked on, while the push runs.
    @Published private(set) var settling: Set<String> = []
    /// What came of your last click, by root (until you dismiss it, or the next request comes).
    @Published private(set) var notices: [String: Notice] = [:]

    struct Notice: Equatable {
        var text: String
        var ok: Bool
    }

    /// The vault the requests are read from and settled with (the sandbox gives its own).
    var vault: LeadVault
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    /// A request appeared (new, or replacing one).
    var onAsk: (String, LeadPush.Request) -> Void = { _, _ in }
    /// The open requests changed (the sidebar's counts).
    var onChange: () -> Void = {}
    /// Your click came to this: for the lead.
    var onSettled: (String, LeadPush.Request, LeadPush.Outcome) -> Void = { _, _, _ in }
    private var looking: Set<String> = []

    init(vault: LeadVault = .standard,
         background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         main: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.vault = vault
        self.background = background
        self.main = main
    }

    /// The leads' roots, at each refresh: one vault call per root, never two at once.
    func look(_ roots: Set<String>) {
        if !Set(open.keys).isSubset(of: roots) {
            open = open.filter { roots.contains($0.key) }
            onChange()
        }
        for root in roots where !looking.contains(root) && !settling.contains(root) {
            looking.insert(root)
            let vault = self.vault
            background {
                let request = Result { try vault.pushRequest(root: root) }
                self.main { self.looked(root, request) }
            }
        }
    }

    private func looked(_ root: String, _ result: Result<LeadPush.Request?, Error>) {
        looking.remove(root)
        // Not known (the host didn't answer): what was shown stays.
        guard case .success(let request) = result, !settling.contains(root), open[root] != request else { return }
        let new = request.map { $0.id != open[root]?.id } ?? false
        open[root] = request
        if new, let request {
            notices[root] = nil
            onAsk(root, request)
        }
        onChange()
    }

    /// You clicked Push (`push`) or Decline on the card showing `request`.
    func settle(_ root: String, _ request: LeadPush.Request, push: Bool) {
        guard open[root]?.id == request.id, !settling.contains(root) else { return }
        settling.insert(root)
        let vault = self.vault
        background {
            let settled = LeadPush.settle(id: request.id, root: root, push: push, vault: vault)
            self.main { self.settled(root, request, settled.request, settled.outcome) }
        }
    }

    private func settled(_ root: String, _ shown: LeadPush.Request, _ handed: LeadPush.Request?, _ outcome: LeadPush.Outcome) {
        settling.remove(root)
        if open[root]?.id == shown.id { open[root] = nil }
        notices[root] = Notice(text: Self.notice(shown, outcome), ok: outcome.pushed || outcome == .declined)
        if let handed { onSettled(root, handed, outcome) }
        onChange()
    }

    func dismiss(_ root: String) { notices[root] = nil }

    /// The card's line for what came of it.
    static func notice(_ request: LeadPush.Request, _ outcome: LeadPush.Outcome) -> String {
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
}
