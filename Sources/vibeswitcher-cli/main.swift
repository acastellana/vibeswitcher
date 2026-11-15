// The command line, installed as `vibeswitcher` (built as `vibeswitcher-cli`: a folder named `vibeswitcher` would be
// the app's `Sources/VibeSwitcher` on the Mac's case-insensitive file system). In stage 1 its commands read and write
// local files, as a probe: `status` and `hooks`. From the engine on, every command goes through the node's server
// (`status --probe` keeps stage 1's local read).
import Foundation
import VibeCore
import VibeNode

// Output to a reader that has gone (`vibeswitcher status | head -1`) is an error for the write, not this process's
// end. It starts no program, so nothing inherits the ignore.
signal(SIGPIPE, SIG_IGN)

let usage = """
    usage: vibeswitcher status [--json] | status --probe [--json] | status --ack
           vibeswitcher start [--interop-is-on]
           vibeswitcher stop
           vibeswitcher lead FOLDER [--goal TEXT] [--take-head] [--replace]
           vibeswitcher hooks install|remove [--agent claude|codex]
    """

let words = Array(CommandLine.arguments.dropFirst())
switch words.first {
case "status":
    exit(StatusCommand.run(Array(words.dropFirst())))
case "start":
    exit(StartCommand.run(Array(words.dropFirst())))
case "stop":
    exit(StopCommand.run(Array(words.dropFirst())))
case "lead":
    exit(LeadCommand.run(Array(words.dropFirst())))
case "hooks":
    exit(HooksCommand.run(Array(words.dropFirst())))
case "help", "-h", "--help":
    try? FileHandle.standardOutput.write(contentsOf: Data((usage + "\n").utf8))
    exit(0)
default:
    try? FileHandle.standardError.write(contentsOf: Data((usage + "\n").utf8))
    exit(64)
}
