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
    usage: vibeswitcher status [--json] | status --health [--json] | status --probe [--json] | status --check-updates [--json] | status --ack
           vibeswitcher doctor | logs [--lines N] [--sessions]
           vibeswitcher start [--interop-is-on] [--at-login] [--node-version vX.Y.Z]
           vibeswitcher stop
           vibeswitcher switch COMMIT | rollback
           vibeswitcher lead FOLDER [--goal TEXT | --resume] [--take-head] [--replace] [--init]
           vibeswitcher questions [FOLDER] [--all] [--json]
           vibeswitcher board [FOLDER] [--json]
           vibeswitcher stats [today|week|month] [--json]
           vibeswitcher answer CARD [TEXT] | hold CARD
           vibeswitcher tell FOLDER TEXT
           vibeswitcher push FOLDER | decline-push FOLDER
           vibeswitcher send SESSION [TEXT] [--image PATH]... [--now] | reply SESSION CHOICE [TEXT]
           vibeswitcher new FOLDER [--agent claude|codex|shell | --preset NAME] [--model M] | end SESSION | presets [FOLDER]
           vibeswitcher preset add|edit|remove NAME [--folder FOLDER] ...  (`vibeswitcher preset` says more)
           vibeswitcher close-shells [FOLDER]
           vibeswitcher reopen [all | SESSION... | --forget] | resume [SESSION]
           vibeswitcher rename SESSION [NAME] | pause SESSION [--hours N | --tomorrow | --off]
           vibeswitcher new-project NAME [--in LOCATION] [--folder NAME] [--goal TEXT] [--no-lead]
           vibeswitcher mail [FOLDER] [--all] [--json] | brief [FOLDER] [--json] | prompt-audit FOLDER snooze|off|on
           vibeswitcher approve [--only config,base,hooks]   (every held config, base move and hooks update, one code)
           vibeswitcher config held [FOLDER] [--diff NAME] [--long] | config accept CARD | config startup
           vibeswitcher base show FOLDER [--from COMMIT] | base accept CARD | base keep CARD
           vibeswitcher settings [FOLDER] [--find WORDS] [--json] | set [FOLDER] KEY VALUE
           vibeswitcher hooks install|remove [--agent claude|codex]
           vibeswitcher web [--tailnet | --revoke]
    """

let words = Array(CommandLine.arguments.dropFirst())
switch words.first {
case "status":
    exit(StatusCommand.run(Array(words.dropFirst())))
case "doctor":
    exit(DoctorCommand.run(Array(words.dropFirst())))
case "logs":
    exit(LogsCommand.run(Array(words.dropFirst())))
case "start":
    exit(StartCommand.run(Array(words.dropFirst())))
case "stop":
    exit(StopCommand.run(Array(words.dropFirst())))
case "switch":
    exit(SwitchCommand.run(Array(words.dropFirst()), rollback: false))
case "rollback":
    exit(SwitchCommand.run(Array(words.dropFirst()), rollback: true))
case "lead":
    exit(LeadCommand.run(Array(words.dropFirst())))
case "questions":
    exit(QuestionsCommand.run(Array(words.dropFirst())))
case "board":
    exit(BoardCommand.run(Array(words.dropFirst())))
case "stats":
    exit(StatsCommand.run(Array(words.dropFirst())))
case "answer":
    exit(AnswerCommand.run(Array(words.dropFirst())))
case "hold":
    exit(HoldCommand.run(Array(words.dropFirst())))
case "tell":
    exit(TellCommand.run(Array(words.dropFirst())))
case "push":
    exit(PushCommand.run(Array(words.dropFirst()), approve: true))
case "decline-push":
    exit(PushCommand.run(Array(words.dropFirst()), approve: false))
case "send":
    exit(SendCommand.run(Array(words.dropFirst())))
case "reply":
    exit(ReplyCommand.run(Array(words.dropFirst())))
case "new":
    exit(NewCommand.run(Array(words.dropFirst())))
case "preset":
    exit(PresetEditCommand.run(Array(words.dropFirst())))
case "close-shells":
    exit(CloseShellsCommand.run(Array(words.dropFirst())))
case "presets":
    exit(PresetsCommand.run(Array(words.dropFirst())))
case "end":
    exit(EndCommand.run(Array(words.dropFirst())))
case "rename":
    exit(RenameCommand.run(Array(words.dropFirst())))
case "pause":
    exit(PauseCommand.run(Array(words.dropFirst())))
case "resume":
    exit(ResumeCommand.run(Array(words.dropFirst())))
case "reopen":
    exit(ReopenCommand.run(Array(words.dropFirst())))
case "new-project":
    exit(NewProjectCommand.run(Array(words.dropFirst())))
case "mail":
    exit(MailCommand.run(Array(words.dropFirst())))
case "brief":
    exit(BriefCommand.run(Array(words.dropFirst())))
case "prompt-audit":
    exit(PromptAuditCommand.run(Array(words.dropFirst())))
case "approve":
    exit(ApproveCommand.run(Array(words.dropFirst())))
case "config":
    exit(ConfigCommand.run(Array(words.dropFirst())))
case "base":
    exit(BaseCommand.run(Array(words.dropFirst())))
case "settings":
    exit(SettingsCommand.run(Array(words.dropFirst())))
case "set":
    exit(SetCommand.run(Array(words.dropFirst())))
case "hooks":
    exit(HooksCommand.run(Array(words.dropFirst())))
case "web":
    exit(WebCommand.run(Array(words.dropFirst())))
case "wire-vectors":
    // Not in the usage text: the web client's validators and vectors are written with it (the live plan's LW-D10).
    // The vectors name times (a usage limit's reset): written in UTC, so they read the same on every machine and CI.
    NSTimeZone.default = TimeZone(identifier: "UTC")!
    exit(WireCommand.run(Array(words.dropFirst())))
case "agent-plist":
    // Not in the usage text: `scripts/install-node-mac.sh` runs it from the build it has just installed, and writes what
    // it prints for the user to load (the Mac's LaunchAgent, `NodeAgent`); `start` on the Mac stays refused.
    exit(AgentPlistCommand.run(Array(words.dropFirst())))
case "install-record":
    // Not in the usage text: `scripts/install-node.sh` runs it from the build it has just made (the start plan's ST-D13).
    guard let arguments = BuildRecord.Arguments(Array(words.dropFirst())) else {
        try? FileHandle.standardError.write(contentsOf: Data((BuildRecord.Arguments.usage + "\n").utf8))
        exit(64)
    }
    switch BuildRecord.write(arguments) {
    case .success:
        try? FileHandle.standardOutput.write(contentsOf: Data("recorded \(arguments.folder)/\(BuildInfo.fileName)\n".utf8))
        exit(0)
    case .failure(let refusal):
        try? FileHandle.standardError.write(contentsOf: Data((refusal.text + "\n").utf8))
        exit(refusal.exitCode)
    }
case "help", "-h", "--help":
    try? FileHandle.standardOutput.write(contentsOf: Data((usage + "\n").utf8))
    exit(0)
default:
    try? FileHandle.standardError.write(contentsOf: Data((usage + "\n").utf8))
    exit(64)
}
