import Foundation
import VibeCore

/// `tell` (2026-11-19): `vibeswitcher tell FOLDER TEXT`, the user telling the project's running lead something that
/// isn't an answer. A user's-voice kind (`NodeWire.kinds`), so `Requests.handle` judges the voice (S3: never a
/// session's process, nor branch code, nor a web page) and records the request in the vault before it gets here; its
/// typed code is the command line's, as `lead`'s is (no card). The folder is taken to its repository's top, the lead's
/// root, and the engine tells that lead (`LeadEngine.tellLead`), refusing when none runs there.
extension Requests {
    func tell(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let folder = request.args?["folder"]?.string, folder.hasPrefix("/") else {
            return reply(.init(re: request.id, error: .init(.badArgs, "tell needs folder, an absolute path")))
        }
        guard let text = request.args?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reply(.init(re: request.id, error: .init(.badArgs, "tell needs text")))
        }
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server runs no leads"))) }
        let (find, queue, action) = (repositoryOf, self.queue, request.action?.lowercased())
        engine.work.async {
            let root = find(folder)
            queue.async {
                engine.tellLead(text, root: root, action: action) { result in
                    switch result {
                    case .success(let told): reply(.init(re: request.id, typed: told))
                    case .failure(.refused(let why)), .failure(.gone(let why)), .failure(.badArgs(let why)), .failure(.delivered(let why)):
                        reply(.init(re: request.id, error: .init(.refused, why)))
                    }
                }
            }
        }
    }

    /// `tell.retract` (`WireKinds.TellRetract`): the user's tell under `action` taken back before its lead had it
    /// (`LeadEngine.retractTell`); `delivered` when the lead has it.
    func tellRetract(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let action = request.args?["action"]?.string, UUID(uuidString: action) != nil else {
            return reply(.init(re: request.id, error: .init(.badArgs, "tell.retract needs action, the tell's action id")))
        }
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server runs no leads"))) }
        engine.retractTell(action: action) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let retracted): reply(.init(re: request.id, typed: retracted))
            case .failure(let failure): reply(self.failed(request, failure))
            }
        }
    }
}
