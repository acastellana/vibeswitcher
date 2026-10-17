// Invoked by Claude Code / Codex hooks: `vibeswitcher-hook <claude|codex>` with the event JSON on stdin.
//
// Contract with the agents: print nothing (stdout from some hooks is fed back to the model) and
// always exit 0 (a non-zero exit can block the agent). Every failure path just exits quietly. The one
// exception is a steered message (see `SteerInbox`): handed to Claude as JSON on the events that take it.
import Darwin
import Foundation
import VibeCore

let agent = Agent(rawValue: CommandLine.arguments.dropFirst().first ?? "") ?? .claude
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }

// The agent process is our nearest `claude`/`codex` ancestor; its TTY identifies the session (agents launch hooks
// in a fresh session with no controlling terminal). A second agent further up (e.g. Claude running `codex exec` as a
// tool) makes this a nested run: it must not overwrite the outer session's state for this terminal. Codex 0.157+ runs
// hooks from its background daemon instead, with no session above them: the payload names the session's TUI.
func arguments(_ proc: ProcInfo) -> [String] {
    ProcessTable.arguments(pid: proc.pid, start: Int(proc.startTime.timeIntervalSince1970), comm: proc.comm)
}
func codexOwner() -> (tty: String, pid: Int32)? {
    guard agent == .codex, let processes = ProcessTable.trySnapshot() else { return nil }
    let terminals = HookOwner.codexTerminals(processes: processes, cwd: ProcessTable.cwd(pid:), arguments: arguments,
                                             state: { HookState.load(from: VibePaths.stateFile(tty: $0)) })
    return HookOwner.codexTerminal(for: payload, among: terminals).map { ($0.tty, $0.pid) }
}
let tty: String
let agentPid: Int32?
switch HookOwner.lineage(ProcessTable.ancestors(of: getpid()), arguments: arguments) {
case .agent(let pid, let agentTTY): (tty, agentPid) = (agentTTY, pid)
case .nested: exit(0)
case .detached:
    guard let owner = codexOwner() else { exit(0) }
    (tty, agentPid) = (owner.tty, owner.pid)
case .none:
    if let own = ProcessTable.info(pid: getpid())?.tty { (tty, agentPid) = (own, nil) }
    else if let owner = codexOwner() { (tty, agentPid) = (owner.tty, owner.pid) }
    else { exit(0) }
}

VibePaths.ensurePrivateDirectories()
let stateURL = VibePaths.stateFile(tty: tty)

// Serialize concurrent hooks (parallel tool calls fire PreToolUse at the same time).
let lock = open(stateURL.path + ".lock", O_CREAT | O_RDWR, 0o600)
if lock >= 0 { flock(lock, LOCK_EX) }

// Codex's async questions don't hold the turn: at its end, the rollout says whether one is still open.
let rolloutQuestion = agent == .codex && payload["hook_event_name"] as? String == "Stop"
    ? (payload["transcript_path"] as? String).flatMap { TranscriptReader.openAsyncQuestion(atPath: $0, home: NSHomeDirectory()) }
    : nil
let update = HookState.reduce(current: HookState.load(from: stateURL), payload: payload, agent: agent,
                              tty: tty, agentPid: agentPid, now: Date().timeIntervalSince1970, rolloutQuestion: rolloutQuestion)
switch update {
case .write(let state): try? state.save(to: stateURL)
case .delete: try? FileManager.default.removeItem(at: stateURL)
case .ignore: break
}
if lock >= 0 { flock(lock, LOCK_UN); close(lock) }

// Messages sent to this agent while it works (Claude Code; Codex takes typed input mid-turn itself). Only the main
// thread's hooks take them (a subagent's would put them in its context instead), and a message is marked delivered
// only once its reply is written: a closed pipe leaves it waiting rather than lost.
if agent == .claude, let pid = agentPid {
    signal(SIGPIPE, SIG_IGN)
    SteerReply.answer(payload, tty: tty, agentPid: pid) { (try? FileHandle.standardOutput.write(contentsOf: $0)) != nil }
}
exit(0)
