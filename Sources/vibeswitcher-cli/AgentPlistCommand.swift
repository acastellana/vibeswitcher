import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher agent-plist PREFIX COMMIT`: the Mac's LaunchAgent property list for the installed build (`NodeAgent.
/// installed`) on stdout. `scripts/install-node-mac.sh` runs it from the build it has just installed and writes what it
/// prints for the user to load with `launchctl bootstrap` (it runs no launchctl); `start` on the Mac is still refused
/// (`NodeSystem.macUnbuilt`). Exit 64 for usage, 1 with the refusal on stderr.
enum AgentPlistCommand {
    static let usage = "usage: vibeswitcher agent-plist PREFIX COMMIT"

    static func run(_ words: [String]) -> Int32 {
        guard words.count == 2 else {
            try? FileHandle.standardError.write(contentsOf: Data((usage + "\n").utf8))
            return 64
        }
        switch NodeAgent.installed(prefix: words[0], commit: words[1], home: VibePaths.accountHome) {
        case .success(let data):
            FileHandle.standardOutput.write(data)
            return 0
        case .failure(let refusal):
            try? FileHandle.standardError.write(contentsOf: Data((refusal.text + "\n").utf8))
            return 1
        }
    }
}
