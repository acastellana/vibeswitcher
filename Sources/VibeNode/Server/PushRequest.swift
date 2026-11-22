import Foundation
import VibeCore

/// `push` and `push.decline` (the parity table's push row): `vibeswitcher push FOLDER` and `vibeswitcher decline-push
/// FOLDER`, the user settling the push the project's lead asked for (push_remote), as the app's Push and Decline
/// buttons do. User's-voice kinds (`NodeWire.kinds`), so `Requests.handle` judges the voice (S3: never a session's
/// process, nor branch code, nor a web page) and records the request in the vault before it gets here; the typed code
/// is the command line's, shown with the request it settles. `request` is the id of the request the command showed:
/// only that one is settled (`LeadEngine.settlePush`), so a newer request the lead made meanwhile isn't pushed on a code
/// typed for another.
extension Requests {
    func push(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let folder = request.args?["folder"]?.string, folder.hasPrefix("/") else {
            return reply(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs folder, an absolute path")))
        }
        guard let id = request.args?["request"]?.string, !id.isEmpty, id.count <= 64,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return reply(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs request, the push request's id")))
        }
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server runs no leads"))) }
        let (find, queue, approve) = (repositoryOf, self.queue, request.kind == "push")
        engine.work.async {
            let root = find(folder)
            queue.async {
                engine.settlePush(root: root, id: id, push: approve) { result in
                    switch result {
                    case .success(let settled): reply(.init(re: request.id, typed: settled))
                    case .failure(.refused(let why)), .failure(.gone(let why)), .failure(.badArgs(let why)):
                        reply(.init(re: request.id, error: .init(.refused, why)))
                    }
                }
            }
        }
    }
}
