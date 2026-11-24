import Foundation
import VibeCore

/// `vibeswitcher tell FOLDER TEXT` in the engine (2026-11-19): something the user tells a project's running lead that
/// isn't an answer to any card. It goes the way an answer's message goes (`tellAsUser`): its digest recorded in the vault
/// under the request's action as the user's message, then delivered from `.user` to the session the vault binds the
/// lead's role to, or held in order until that lead can take it (EN-D9, EN-D14). Refused when no lead runs for the root.
extension LeadEngine {
    /// What the lead reads: the user's words, said to be the user's and not an answer.
    public static func toldText(_ text: String) -> String {
        "A message from the user (not an answer to any question of yours): \(text)"
    }

    /// Tells `root`'s running lead `text` as the user's, under the request's `action`. `then` hears on `queue` the
    /// project and the lead's session, or why not: a lead runs for `root` when the session host lists a live session
    /// labelled as its lead started there (`LeadStore.update`, as each refresh reads it). From any thread.
    public func tellLead(_ text: String, root: String, action: String?, then: @escaping (Result<WireKinds.Tell.Result, CardFailure>) -> Void) {
        queue.async { [self] in
            guard link.state == .connected else {
                return then(.failure(.refused("the server's link to its host isn't welcomed yet, so whether a lead runs can't be told: try again")))
            }
            leads.update(sessions: link.sessions, holders: holders)
            let project = NodeIds.project(root: root)
            guard let session = leads.leads[project]?.session else {
                return then(.failure(.refused("no lead runs in \(ConfigSeal.inert(root, limit: 400)): nothing was sent "
                                              + "(`vibeswitcher lead FOLDER` starts one)")))
            }
            tellAsUser(Self.toldText(text), root: root, action: action, about: .tell)
            note("lead: the user's message for \(LeadMail.project(of: root)) is on its way (action \(action ?? "none"))")
            then(.success(WireKinds.Tell.Result(project: project, session: NodeIds.session(host: session))))
        }
    }
}
