import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher doctor` (the parity table's first-run row): what the node needs and the steps to get it running, each
/// missing one with the exact command for you to run (`NodeDoctor`). It looks at files only, asks the node nothing but
/// whether it answers, and installs nothing. Exit 0 when nothing needed is missing, 1 otherwise.
enum DoctorCommand {
    static let usage = "usage: vibeswitcher doctor"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.isEmpty else { return Say.usage(usage) }
        let context = NodeContext.current()
        context.sayScratch()
        let home = context.isScratch ? (ProcessInfo.processInfo.environment["HOME"] ?? VibePaths.accountHome) : VibePaths.accountHome
        let probes = NodeDoctor.live(root: context.root, home: home, running: {
            if case .success = NodeClient.connect(context) { return true }
            return false
        })
        let checks = NodeDoctor.checks(probes)
        Say.out(NodeDoctor.lines(checks).joined(separator: "\n"))
        return checks.contains { !$0.ok && $0.level != .advised } ? 1 : 0
    }
}
