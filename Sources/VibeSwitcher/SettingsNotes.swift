import SwiftUI
import VibeCore

/// What Settings says under a section: `text`, at most two short sentences for someone who doesn't know the code, and
/// `help`, the detail behind the section's "?" button. `SettingsFooter` takes only one of these, so every footer is
/// here and `SettingsNoteTests` holds them all to that.
enum SettingsNote: String, CaseIterable {
    case startup, projects, notifications, team, workingPolicy, reviewFloor, boost, macLimits, usageLimits, power
    case dictation, briefing, shells, hooks, codex, walletManager, passage
    case hostCurrent, hostRefused, hostHandOver, hostNoSessions, hostEndsSessions

    var text: String { content.text }
    var help: String? { content.help }
    /// The section's heading, as the catalog has it: what the "?" button is about.
    var section: String { content.section }

    private var content: (section: String, text: String, help: String?) {
        switch self {
        case .startup:
            return ("Startup", "Window sessions keep running when VibeSwitcher quits or updates. Ended sessions stay listed for a day.", nil)
        case .projects:
            return ("Projects", "If this folder doesn't exist yet, it's created with your first project, and you're told first.", nil)
        case .notifications:
            return ("Banners and sounds", "A project lead's team notifies you only when all its work is done or it needs you. These settings apply to those too.",
                    "It needs you when it has a question for you, or when a prompt is waiting in the lead's terminal.")
        case .team:
            return ("Team", "Summaries come from a small Claude model that sees only each task's title and progress. Messages between leads show in the lead's Team tab.",
                    "Each summary is written by Claude's small Haiku model with no tools, from the task's title, checkpoints and last steps: "
                        + "at most every 3 minutes per task, and only while the Team tab is open. With summaries off, the tab shows the latest "
                        + "checkpoint or activity.\n\nMessages between leads, sent or refused, are in the lead's Team tab, under Between leads.")
        case .workingPolicy:
            return ("Working policy", "Every project's lead and workers follow these rules. When you save a change, each running lead is told once and applies it from then on.",
                    "Verifiers get these rules in their prompts too. They're kept in ~/.vibeswitcher/policy.md.")
        case .reviewFloor:
            return ("Review rules floor", "The least strict each project's review rules may be. A project's lead can make a rule stricter, never looser.",
                    "A lead raises a rule with its configure tool. What's in force is this floor combined with the project's workflow.md: "
                        + "for paths, both lists count; for everything else, the stricter value does.\n\n"
                        + "The floor is kept in the session host's vault, and only VibeSwitcher writes it.")
        case .boost:
            return ("Boost", "Boost lets more work run at once. Automatic boosts only while you're away and plugged in; on battery it stays off unless Also on battery is on.",
                    "Away means the screen is locked or there's been no input for 5 minutes. Boost drops back within \(BoostWatch.every) seconds of "
                        + "either changing: new work stops starting above the normal limits, and running work finishes.\n\n"
                        + "With Also on battery on, Boost runs until the charge drops below \(Boost.batteryFloor) %. The battery limit further down still pauses lead work.\n\n"
                        + "While boosted, room freed on the Mac goes first to the project you last worked in, and projects set to batch merges "
                        + "during Boost (merge_batching: boost in workflow.md) test several passed tasks with one run, splitting failures to find the task that breaks it. Boost stays off once an account "
                        + "limit reaches \(MacLoad.number(Boost.vetoPercent)) %, unless Ignore usage limits is on.")
        case .macLimits:
            return ("Mac-wide limits", "Every project shares these limits: at one, leads start nothing new until there's room. Merges wait while the load is high.",
                    "Load is the greater of the Mac's 1- and 5-minute averages. A lead that was refused is told once there's room.\n\n"
                        + "Each build or full test run takes one slot. A project can set its own slots with heavy_slots in its workflow.md; "
                        + "load_threshold and mac_max_sessions there are ignored.\n\n"
                        + "A job using more than 3 cores for at least 5 minutes outside the shared slots is reported once to its project's lead, "
                        + "or to you when no lead runs. The report explains how to run it under vs-heavy; it stops nothing.\n\n"
                        + "These limits are kept in ~/.vibeswitcher/mac-limits.json.")
        case .usageLimits:
            return ("Usage limits", "On, leads keep starting work at any share of a Claude limit. A session that reaches a limit still stops, and its lead is told.",
                    "The usage watch reads Claude Code's account usage when available and shows known limits and reset times in the lead's status. "
                        + "Normally leads stop starting workers and audits at \(Int(AccountUsage.threshold)) % of a limit; running work finishes. With this on, Boost isn't held off "
                        + "for usage, and projects set to agent: auto stay on Claude until Claude refuses at a limit. "
                        + "Usage still shows, marked \(AccountUsage.ignoredMark).")
        case .power:
            return ("Power", "The Mac stays awake while a worker, verifier or merge runs; on battery, only if set to Always. At the battery limit, running work finishes and nothing new starts.",
                    "Above the battery limit, leads work just as they do on power. The display can still sleep.\n\n"
                        + "Keep the Mac awake stops only idle sleep. To keep work running overnight, leave the Mac on AC power "
                        + "with the lid open, or with an external display connected. A closed lid sleeps whatever this setting says, "
                        + "and so does a battery that runs out.\n\n"
                        + "On waking from \(Int(SleepCost.noticeAfter / 60)) minutes of sleep or more with tasks in flight, you're told which ones "
                        + "it paused. Each day's app-health digest and the lead's status say how many task-hours sleep paused.")
        case .dictation:
            return ("Dictation", "Your recording goes to OpenAI and the text lands in the box for you to check. Your key stays on this Mac, in your login Keychain.",
                    "Hold the mic in the composer, on the Mac or the phone, and speak; when you let go, the recording goes to OpenAI with this key. "
                        + "It goes with the project's, its branches' and recent files' names, to spell them right; nothing else, and no recording is kept. "
                        + "The phone's recordings are transcribed on this Mac.\n\n\(OpenAITranscription.defaultModel) is OpenAI's most accurate.")
        case .briefing:
            return ("Spoken briefing", "With a key, the briefing's text goes to ElevenLabs only when you press the button; without one, the Mac's own voice reads it. A key typed here stays in your login Keychain.",
                    "Brief me (in the window's toolbar and the menu bar) writes 30 seconds on what happened lately across the projects VibeSwitcher leads, "
                        + "with headless Claude, and reads it aloud. Brief me on <project>, at the top of a lead's Team tab or with ⌥⇧⌘B, does the same for that one project.\n\n"
                        + "Without a key in your Keychain, ELEVENLABS_API_KEY from your shell or ~/.config/elevenlabs/key.env is used, held in memory only.")
        case .shells:
            return ("Shells", "Off, nothing runs until you press Run on the agent's card. On, any agent in a session you opened can run any command as you, with no click.",
                    AgentsSettings.openShellsHelp)
        case .hooks:
            return ("Hooks", "Installing adds VibeSwitcher's hooks beside yours. The first install keeps a copy of each file, named …vibeswitcher-backup.", nil)
        case .codex:
            return ("Codex", "Installing the hooks trusts them for you, as Codex's own hooks screen does.", "The trust is recorded in ~/.codex/config.toml.")
        case .walletManager:
            return ("Wallet Manager's Mac", "A request goes to the Wallet Manager only when you press Send on its card, and you sign there on the hardware wallet. VibeSwitcher never signs.",
                    "An agent asks for a transaction with vs-wallet request (on every session's PATH; vs-wallet help says how), and the request shows as a card in its chat. "
                        + "Only when you press Send to Wallet Manager does it go through Passage to the Wallet Manager on its Mac (or, with "
                        + "\(WalletSettingsTab.onThisMacTitle) chosen, through a folder only you can use), which checks it; you sign there on the hardware wallet.\n\n"
                        + "The Wallet Manager's answers go back to the agent as messages.")
        case .passage:
            return ("Passage", "Leave this empty unless VibeSwitcher can't find Passage on its own.",
                    "It can be a passage link, Passage.app or its binary. Left empty, VibeSwitcher uses passage on your PATH, else Passage.app in /Applications or ~/Applications.")
        case .hostCurrent:
            return ("Session host", "Runs the window's sessions; it's updated with the app.", nil)
        case .hostRefused:
            return ("Session host", "It doesn't recognise this app, so it shows none of its sessions.", nil)
        case .hostHandOver:
            return ("Session host", "Restarting updates it to this app's version; the sessions keep running.", nil)
        case .hostNoSessions:
            return ("Session host", "Restarting updates it to this app's version; no session is running.", nil)
        case .hostEndsSessions:
            return ("Session host", "It's older than this app and can't keep its sessions across a restart: restarting it ends every running session, in all projects.", nil)
        }
    }

    /// The session host's footer, by what it can do now.
    static func sessionHost(offer: HostClient.RestartPlan?, refused: Bool) -> SettingsNote {
        switch offer {
        case .handOver?: return .hostHandOver
        case .endAndReplace(0)?: return .hostNoSessions
        case .endAndReplace?: return .hostEndsSessions
        case nil: return refused ? .hostRefused : .hostCurrent
        }
    }
}

extension EnvironmentValues {
    /// The note whose "?" the sandbox has opened, so a shot can show it; nil in the app.
    @Entry var settingsOpenHelp: SettingsNote? = nil
}

/// The small text under a form's section.
struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A section's explanation, under it and aligned with its rows, with a "?" for the detail when there's more to say.
struct SettingsFooter: View {
    let note: SettingsNote
    /// What only the moment knows (the cores each slot gets now, why the host refused), after the note's help.
    var detail: String? = nil
    @State private var showingHelp = false
    @Environment(\.settingsOpenHelp) private var openHelp

    init(_ note: SettingsNote, detail: String? = nil) {
        self.note = note
        self.detail = detail
    }

    /// The popover's words: the note's help and then the live detail; nil when there's neither.
    var helpText: String? {
        let parts = [note.help, detail].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            FooterText(note.text)
            if let helpText {
                Button { showingHelp = true } label: {
                    Image(systemName: "questionmark.circle").accessibilityLabel("More about \(note.section)")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("More about \(note.section)")
                .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                    Text(helpText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 340, alignment: .leading)
                        .padding(14)
                }
            }
        }
        .onChange(of: openHelp) { _, open in if open == note { showingHelp = true } }
    }
}
