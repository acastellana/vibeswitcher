import Foundation
import VibeCore

extension Requests {
    /// `board [FOLDER]` (`vibeswitcher board`, the parity table's gap 4): the board of the lead whose project holds
    /// `folder` (its repository's top), or every lead's board without one, each as `BoardValue` makes it (what the
    /// `boards` stream carries). A read: anyone of the uid, no code. A folder with no lead is `gone`, saying how to
    /// start one.
    func board(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let boards = { [weak self] () -> [String: NodeWire.Value] in self?.boards?() ?? [:] }
        let args: WireKinds.Board.Args
        switch request.typedArgs(WireKinds.Board.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let typed): args = typed
        }
        guard let folder = args.folder else {
            let all = boards().sorted { $0.key < $1.key }.map(\.value)
            return reply(.init(re: request.id, typed: WireKinds.Board.Result(boards: all)))
        }
        guard folder.hasPrefix("/") else { return reply(.init(re: request.id, error: .init(.badArgs, "folder is an absolute path"))) }
        let (find, queue) = (repositoryOf, self.queue)
        let answer = { (root: String) in
            let project = NodeIds.project(root: root)
            guard let value = boards()[project] else {
                let shown = ConfigSeal.inert(root, limit: 200)
                return reply(.init(re: request.id, error: .init(.gone, "no lead in \(shown): `vibeswitcher lead \(shown)` starts one")))
            }
            reply(.init(re: request.id, typed: WireKinds.Board.Result(boards: [value])))
        }
        guard let engine else { return answer(folder) }
        engine.work.async {
            let root = find(folder)
            queue.async { answer(root) }
        }
    }
}
