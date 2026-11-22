import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher kinds-doc --write FILE` (not in the usage text): the request kinds' table (`KindsTable`) written
/// between FILE's markers, docs/guide/v2-architecture.md's; ArchitectureDocLintTests fails while it is stale.
enum KindsDocCommand {
    static let usage = "usage: vibeswitcher kinds-doc --write FILE"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2, arguments[0] == "--write" else { return Say.usage(usage) }
        let path = arguments[1]
        guard let data = FileManager.default.contents(atPath: path) else { return Say.refused("\(ConfigSeal.inert(path, limit: 400)) can't be read") }
        guard let made = KindsTable.replacing(in: String(decoding: data, as: UTF8.self)) else {
            return Say.refused("\(ConfigSeal.inert(path, limit: 400)) has no kinds table's markers")
        }
        // The file in place, its mode kept: it exists (it was read above), and nothing new is made.
        guard let file = FileHandle(forWritingAtPath: path) else { return Say.refused("\(ConfigSeal.inert(path, limit: 400)) can't be written") }
        defer { try? file.close() }
        do {
            try file.truncate(atOffset: 0)
            try file.write(contentsOf: Data(made.utf8))
        } catch {
            return Say.refused("\(ConfigSeal.inert(path, limit: 400)) wasn't written: \(error)")
        }
        Say.out("the kinds table written in \(ConfigSeal.inert(path, limit: 400))")
        return 0
    }
}
