// Invoked by Claude Code / Codex hooks: `vibeswitcher-hook <claude|codex>` with the event JSON on stdin.
//
// Contract with the agents: print nothing (stdout from some hooks is fed back to the model) and
// always exit 0 (a non-zero exit can block the agent). Every failure path just exits quietly.
import Darwin
import Foundation
import VibeCore

let agent = Agent(rawValue: CommandLine.arguments.dropFirst().first ?? "") ?? .claude
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }

// The agent process is our nearest `claude`/`codex` ancestor. If there is a second agent further up
// (e.g. Claude running `codex exec` as a tool), this is a nested run: it must not overwrite the
// outer session's state for this terminal.
let agentAncestors = ProcessTable.ancestors(of: getpid()).filter { $0.agent != nil }
if agentAncestors.count > 1 { exit(0) }
let agentPid = agentAncestors.first?.pid

// Agents launch hooks in a fresh session with no controlling terminal, so the TTY that identifies
// this session comes from the agent process itself.
guard let tty = agentAncestors.first?.tty ?? ProcessTable.info(pid: getpid())?.tty else { exit(0) }

try? FileManager.default.createDirectory(at: VibePaths.stateDir, withIntermediateDirectories: true)
let stateURL = VibePaths.stateFile(tty: tty)

// Serialize concurrent hooks (parallel tool calls fire PreToolUse at the same time).
let lock = open(stateURL.path + ".lock", O_CREAT | O_RDWR, 0o644)
if lock >= 0 { flock(lock, LOCK_EX) }

let update = HookState.reduce(current: HookState.load(from: stateURL), payload: payload, agent: agent,
                              tty: tty, agentPid: agentPid, now: Date().timeIntervalSince1970)
switch update {
case .write(let state): try? state.save(to: stateURL)
case .delete: try? FileManager.default.removeItem(at: stateURL)
case .ignore: break
}
exit(0)
