import SwiftUI
import VibeCore

/// A category in Settings' sidebar. Written by hand so `--settings TAB` keeps working for the old tab name
/// (`terminal`, now Appearance) while `allCases` and `rawValue` are the new names.
enum SettingsTab: RawRepresentable, CaseIterable, Hashable {
    case general, notifications, appearance, sessions, launch, agents, lead, performance, dictation, phone, wallet, advanced

    init?(rawValue: String) {
        guard let tab = Self.names[rawValue] else { return nil }
        self = tab
    }

    /// What `--settings TAB` and the sandbox's `settings TAB` take, and the names the old tabs had.
    private static let names: [String: SettingsTab] = [
        "general": .general, "notifications": .notifications, "appearance": .appearance, "terminal": .appearance,
        "sessions": .sessions, "launch": .launch, "agents": .agents, "lead": .lead, "performance": .performance,
        "dictation": .dictation, "phone": .phone, "wallet": .wallet, "advanced": .advanced,
    ]

    var rawValue: String {
        switch self {
        case .general: return "general"
        case .notifications: return "notifications"
        case .appearance: return "appearance"
        case .sessions: return "sessions"
        case .launch: return "launch"
        case .agents: return "agents"
        case .lead: return "lead"
        case .performance: return "performance"
        case .dictation: return "dictation"
        case .phone: return "phone"
        case .wallet: return "wallet"
        case .advanced: return "advanced"
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .notifications: return "Notifications"
        case .appearance: return "Appearance"
        case .sessions: return "Sessions & Sidebar"
        case .launch: return "Launch Presets"
        case .agents: return "Agents"
        case .lead: return "Project lead"
        case .performance: return "Performance"
        case .dictation: return "Dictation & Briefing"
        case .phone: return "Phone"
        case .wallet: return "Wallet"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notifications: return "bell"
        case .appearance: return "paintpalette"
        case .sessions: return "sidebar.right"
        case .launch: return "play.rectangle"
        case .agents: return "waveform.path.ecg"
        case .lead: return "person.2"
        case .performance: return "bolt"
        case .dictation: return "mic"
        case .phone: return "iphone"
        case .wallet: return "lock.shield"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

/// One option in Settings: what search finds and what its row says.
struct SettingsOption: Identifiable, Equatable {
    let id: String
    let title: String
    /// One plain sentence: what it does and when you'd change it.
    let description: String
    var keywords: [String] = []
    let category: SettingsTab
    /// The heading it sits under, as its pane says it.
    let section: String
    /// An option that shows only in some states (a Custom theme, phone access on): the one always shown that leads
    /// to it, revealed as well so a pick always lands somewhere.
    var parent: String? = nil
}

/// Every option in Settings, in the order the panes show them: the one source for search and for each row's
/// description. `SettingsCatalogTests` fails when a control in a pane has no row here.
enum SettingsCatalog {
    private static func entries(_ category: SettingsTab, _ section: String, _ options: [Entry]) -> [SettingsOption] {
        options.map { SettingsOption(id: $0.id, title: $0.title, description: $0.description, keywords: $0.keywords,
                                     category: category, section: section, parent: $0.parent) }
    }

    private struct Entry {
        let id: String, title: String, description: String
        var keywords: [String] = []
        var parent: String? = nil
        init(_ id: String, _ title: String, _ description: String, keywords: [String] = [], parent: String? = nil) {
            self.id = id; self.title = title; self.description = description; self.keywords = keywords; self.parent = parent
        }
    }

    static let all: [SettingsOption] = general + notifications + appearance + sessions + launch + agents + lead + performance
        + dictation + phone + wallet + advanced

    private static let general = entries(.general, "Startup", [
        Entry("open-at-login", "Open at login", "Starts VibeSwitcher when you log in to this Mac.", keywords: ["startup", "launch", "boot"]),
        Entry("open-window", "Open the window when VibeSwitcher starts", "Shows the main window at launch, instead of only the menu bar icon.", keywords: ["startup", "launch"]),
        Entry("show-welcome", "First-run setup", "Opens the welcome guide again, to go through hooks and permissions.", keywords: ["onboarding", "welcome", "setup"]),
    ]) + entries(.general, "Projects", [
        Entry("projects-folder", "Projects folder", "Where New Project… creates new projects.", keywords: ["directory", "path", "new project"]),
    ])

    private static let notifications = entries(.notifications, "Banners and sounds", [
        Entry("notify-permission", "Permission", "Whether macOS lets VibeSwitcher show banners; you change it in System Settings.", keywords: ["allow", "banner", "alerts"]),
        Entry("notify-needs-input", "Notify when a session needs input", "Shows a banner when a session is waiting for your answer.", keywords: ["alert", "banner", "question"]),
        Entry("notify-done", "Notify when a session finishes", "Shows a banner when a session finishes its work.", keywords: ["alert", "banner", "done"]),
        Entry("play-sound", "Play a sound when a session needs input", "Plays a sound with the banner, so you notice without looking.", keywords: ["audio", "alert", "chime"]),
        Entry("notify-reminders", "Remind me about waiting or stuck sessions", "Reminds you once when a session has waited 10 minutes or shown no progress for 15.", keywords: ["alert", "stuck", "nag"]),
    ])

    private static let appearance = entries(.appearance, "Text", [
        Entry("font", "Font", "The typeface used for text in terminals.", keywords: ["typeface", "monospaced"]),
        Entry("font-size", "Size", "How large terminal text is drawn.", keywords: ["font", "zoom", "text size", "points"]),
    ]) + entries(.appearance, "Colors", [
        Entry("theme", "Theme", "The terminal's color scheme; choose Custom to set each color yourself.", keywords: ["colors", "dark", "light", "solarized"]),
        Entry("color-text", "Text color", "The color of ordinary terminal text in the Custom theme.", keywords: ["foreground"], parent: "theme"),
        Entry("color-background", "Background color", "The terminal's background in the Custom theme.", parent: "theme"),
        Entry("color-cursor", "Cursor color", "The color of the cursor in the Custom theme.", parent: "theme"),
        Entry("color-selection", "Selection color", "The highlight behind selected text in the Custom theme.", parent: "theme"),
        Entry("color-ansi", "ANSI colors", "The 16 colors programs use for their output in the Custom theme.", keywords: ["palette"], parent: "theme"),
    ]) + entries(.appearance, "Behavior", [
        Entry("cursor-shape", "Cursor", "The shape of the terminal's cursor: block, underline or bar.", keywords: ["caret"]),
        Entry("cursor-blink", "Blinking cursor", "Makes the terminal's cursor blink.", keywords: ["caret"]),
        Entry("scrollback", "Scrollback", "How many past lines each terminal keeps so you can scroll back.", keywords: ["history", "lines", "buffer"]),
        Entry("option-as-meta", "Use Option as Meta key", "Makes Option act as Meta in terminal programs, instead of typing special characters.", keywords: ["alt", "keyboard", "emacs"]),
        Entry("bell", "Bell", "What the terminal does when a program rings its bell: nothing, a flash or a sound.", keywords: ["beep", "flash", "audio"]),
    ])

    private static let sessions = entries(.sessions, "Menu bar", [
        Entry("session-order", "Order sessions", "The order sessions appear in the menu bar list.", keywords: ["sort", "arrange"]),
        Entry("floating-panel", "Floating dots panel", "A small floating panel of session dots, for when the menu bar is crowded or under the notch.", keywords: ["pill", "notch"]),
    ]) + entries(.sessions, "Sidebar", [
        Entry("sidebar-mode", "Sidebar mode", "Docks the session list at the right of the screen; picking a session shows only its window.", keywords: ["docked", "dock"]),
        Entry("sidebar-auto-hide", "Auto-hide the sidebar (show it at the right edge)", "Hides the sidebar until you move the pointer to the right edge of the screen.", keywords: ["slide", "hidden"]),
        Entry("sidebar-flash", "Show briefly after switching desktops", "After you switch desktops, the hidden sidebar appears for a moment and slides away.", keywords: ["spaces", "flash"]),
        Entry("minimize-on-pause", "Minimize a session's window when pausing it", "Minimizes the window when you pause a session (if it's the only tab there); resuming restores it.", keywords: ["pause", "dock"]),
    ])

    private static let launch = entries(.launch, "Presets", [
        Entry("presets-for", "Presets for", "Shows the presets for all projects, or for one project.", keywords: ["project", "launch"]),
        Entry("preset-list", "Presets", "The commands New Session can start; add or remove them here.", keywords: ["launch", "new session", "add", "remove"]),
        Entry("preset-default", "Default", "Which preset a project starts with when you open a new session there.", keywords: ["project"], parent: "preset-list"),
        Entry("preset-name", "Name", "What the preset is called in menus.", parent: "preset-list"),
        Entry("preset-kind", "Starts", "What the session runs: Claude, Codex or a plain shell.", keywords: ["agent", "claude", "codex", "shell"], parent: "preset-list"),
        Entry("preset-command", "Command", "The exact command to run, with any flags.", keywords: ["claude", "codex", "flags", "arguments"], parent: "preset-list"),
        Entry("preset-keep-shell", "Keep a shell open after it exits", "Leaves a shell open in the session when the command ends.", parent: "preset-list"),
        Entry("preset-place", "Runs in", "Whether the session opens in VibeSwitcher's window or in Terminal.", keywords: ["window", "terminal"], parent: "preset-list"),
        Entry("preset-env", "Environment", "Variables set for the session, one NAME=value per line.", keywords: ["env", "variables"], parent: "preset-list"),
    ])

    private static let agents = entries(.agents, "Shells", [
        Entry("open-shells", "Let agents open shells without asking", "Lets an agent start a terminal session running any command, with no click from you.", keywords: ["vs-shell", "permission", "run", "security"]),
    ]) + entries(.agents, "Hooks", [
        Entry("hooks", "Hooks", "Lets sessions report their live status to VibeSwitcher; installs beside any hooks you already have.", keywords: ["install", "uninstall", "status", "claude", "codex"]),
    ]) + entries(.agents, "Codex", [
        Entry("codex-trust", "Trust VibeSwitcher's hooks", "Codex ignores hooks until they're trusted; do this again if Codex says they changed.", keywords: ["codex", "hooks"]),
    ])

    private static let lead = entries(.lead, "Team", [
        Entry("ai-summaries", "Summarize what each agent is doing with AI", "The Team tab describes each agent's work in plain words, written by a small Claude model.", keywords: ["haiku", "team tab", "plain words"]),
        Entry("lead-rotation", "Start a fresh lead session", "When a lead's session has grown long, starts a new one so it keeps working with a clear context.", keywords: ["rotation", "context", "compact"]),
        Entry("lead-mail", "Let project leads message each other", "Lets one project's lead send messages to another's; every message shows in the Team tab.", keywords: ["tell_lead", "mail", "between leads"]),
    ]) + entries(.lead, "Working policy", [
        Entry("working-policy", "Working policy", "The rules every project's lead, workers and verifiers get in their prompts.", keywords: ["rules", "prompt", "policy.md", "instructions"]),
    ]) + entries(.lead, "Review rules floor", [
        Entry("floor-project", "Project", "Which project's review rules floor you're editing.", keywords: ["review floor"]),
        Entry("floor-sensitive", "Sensitive paths", "Paths whose changes always count as sensitive; a lead can add to these, never remove them.", keywords: ["review", "globs", "security", "floor"], parent: "floor-project"),
        Entry("floor-strict", "Strict paths", "Paths whose changes get the strictest review; a lead can add to these, never remove them.", keywords: ["review", "globs", "floor"], parent: "floor-project"),
        Entry("floor-finders", "Audit finders, at least", "The fewest independent checkers an audit may use in this project.", keywords: ["review", "audit", "verifier", "floor"], parent: "floor-project"),
        Entry("floor-merge", "Merge policy, at least", "How much approval a merge needs at minimum, from automatic to asking you every time.", keywords: ["review", "approve", "auto", "floor"], parent: "floor-project"),
        Entry("floor-risk-lines", "Risk lines, at most", "A change bigger than this many lines counts as risky; 0 sets no floor, and the project's own limit applies.", keywords: ["review", "size", "floor"], parent: "floor-project"),
        Entry("floor-risk-model", "Risk check's model pass", "Keeps the model's second look at a change's risk switched on.", keywords: ["review", "floor"], parent: "floor-project"),
        Entry("floor-sample", "Audit sample, at least", "The smallest share of finished work that gets audited.", keywords: ["review", "percent", "floor"], parent: "floor-project"),
        Entry("floor-verifier", "Verifier", "Keeps audits on a different model from the one the workers use.", keywords: ["review", "model", "floor"], parent: "floor-project"),
        Entry("floor-save", "Save or revert", "Saves this project's floor, or goes back to what's recorded.", keywords: ["review", "floor"], parent: "floor-project"),
    ])

    private static let performance = entries(.performance, "Boost", [
        Entry("boost-mode", "Boost", "Raises the Mac-wide limits for more throughput: always, or only while you're away on AC power.", keywords: ["speed", "faster", "automatic", "throughput"]),
        Entry("boost-on-battery", "Also on battery", "Lets Boost run on battery until the charge drops below \(Boost.batteryFloor) %.", keywords: ["battery", "power", "charge"]),
        Entry("boost-load", "Start nothing above a load of, while boosted", "While boosted, leads start nothing once the Mac's load is above this.", keywords: ["cpu", "load", "limit"]),
        Entry("boost-sessions", "Team sessions on this Mac while boosted, at most", "How many workers and verifiers may run at once across every project while boosted.", keywords: ["limit", "workers"]),
        Entry("boost-workers", "Workers per project while boosted, at most", "The most workers any one project may run at once while boosted.", keywords: ["limit"]),
        Entry("boost-slots", "Test and build slots while boosted", "How many builds and full test runs may run at once while boosted.", keywords: ["vs-heavy", "cpu", "limit"]),
    ]) + entries(.performance, "Mac-wide limits", [
        Entry("max-sessions", "Team sessions on this Mac, at most", "How many workers and verifiers, across every project, may run at once.", keywords: ["limit", "workers", "concurrency"]),
        Entry("load-threshold", "Start nothing above a load of", "Leads start nothing while the Mac's load is above this; empty means twice the cores.", keywords: ["cpu", "load", "limit"]),
        Entry("heavy-slots", "Test and build slots at once", "How many builds and full test runs may run at once on this Mac.", keywords: ["vs-heavy", "cpu", "limit", "concurrency"]),
    ]) + entries(.performance, "Usage limits", [
        Entry("ignore-usage-limits", "Ignore usage limits", "Leads keep starting work at any share of a Claude limit, instead of stopping at \(Int(AccountUsage.threshold)) %.", keywords: ["quota", "usage", "claude", "account"]),
    ]) + entries(.performance, "Power", [
        Entry("keep-awake", "Keep the Mac awake while the team works", "Stops the Mac going to sleep on its own while a lead's team works; the display can still sleep.", keywords: ["sleep", "caffeinate", "battery", "power"]),
        Entry("battery-hold", "On battery, pause lead work below", "On battery, leads start no new work and merge nothing while the charge is under this level; 0 means never.", keywords: ["battery", "power", "charge"]),
    ])

    private static let dictation = entries(.dictation, "Dictation", [
        Entry("dictation-key", "OpenAI API key for dictation", "The key that turns your speech into text; kept only in your login Keychain.", keywords: ["dictation", "speech", "voice", "microphone", "keychain", "token", "secret"]),
        Entry("dictation-key-in-use", "Key in use", "Which dictation key is in use, and an offer to import one found on this Mac.", keywords: ["dictation", "keychain", "import"]),
        Entry("dictation-model", "Model", "Which OpenAI model transcribes your speech.", keywords: ["dictation", "transcription", "whisper"]),
        Entry("dictation-hold-space", "Hold Space to dictate", "Hold the Space bar in the composer to dictate; holding it to type many spaces stops working.", keywords: ["dictation", "keyboard", "shortcut", "voice"]),
        Entry("dictation-silence", "Silence the Mac while dictating", "Mutes the Mac's sound while you hold the mic, so it isn't recorded.", keywords: ["dictation", "mute", "audio"]),
    ]) + entries(.dictation, "Spoken briefing", [
        Entry("briefing-language", "Language", "The language the Brief me briefing is written and read in.", keywords: ["briefing", "brief me", "translate"]),
        Entry("briefing-key", "ElevenLabs API key", "Reads the briefing in a natural voice; kept only in your login Keychain.", keywords: ["briefing", "voice", "keychain", "token", "secret"]),
        Entry("briefing-key-in-use", "Key in use", "Which ElevenLabs key is in use: from your Keychain, your shell or its key file.", keywords: ["briefing", "keychain", "elevenlabs"]),
        Entry("briefing-voice", "Voice", "Plays one sentence, to check how the briefing will sound.", keywords: ["briefing", "test", "speech", "audio"]),
    ])

    private static let phone = entries(.phone, "Phone access", [
        Entry("phone-access", "Phone access over Tailscale", "See your sessions, their screens and notifications on your phone, from paired devices on your tailnet.", keywords: ["mobile", "tailscale", "iphone", "remote"]),
        Entry("phone-pair", "Pair a phone", "Connects a new phone with a one-time code.", keywords: ["pairing", "qr", "code", "mobile"], parent: "phone-access"),
        Entry("phone-replies", "Allow replies and key presses from the phone", "Lets the phone type into your sessions: remote control of this Mac, with every input logged.", keywords: ["input", "keyboard", "mobile", "security"], parent: "phone-access"),
        Entry("phone-dev-pages", "Allow opening dev pages", "Lets your paired phone open localhost pages that are open in Chrome on this Mac.", keywords: ["localhost", "chrome", "browser"], parent: "phone-access"),
        Entry("phone-chrome", "Chrome access", "Whether macOS lets VibeSwitcher read Chrome's tabs, which opening dev pages needs.", keywords: ["automation", "permission", "chrome"], parent: "phone-access"),
        Entry("phone-push-away", "Phone notifications only while I'm away from the Mac", "Sends notifications to the phone only when you aren't at this Mac.", keywords: ["alert", "push", "away"], parent: "phone-access"),
        Entry("phone-devices", "Paired devices", "The phones that can connect; remove one to revoke its access.", keywords: ["revoke", "mobile"], parent: "phone-access"),
        Entry("phone-activity", "Activity log", "What your phones have looked at and done.", keywords: ["log", "audit", "mobile"], parent: "phone-access"),
    ])

    private static let wallet = entries(.wallet, "Wallet Manager's Mac", [
        Entry("wallet-manager", "Wallet Manager", "Which Mac receives a transaction request once you press Send on its card.", keywords: ["passage", "peer", "transaction", "signing", "trezor"]),
    ]) + entries(.wallet, "Passage", [
        Entry("wallet-passage", "Command path", "The passage command requests go through; leave empty to find it automatically.", keywords: ["passage", "path", "binary"]),
    ])

    private static let advanced = entries(.advanced, "Mac permissions", [
        Entry("control-terminal", "Control Terminal", "Reads Terminal's tab titles and brings a session's tab to the front.", keywords: ["automation", "permission", "apple events"]),
        Entry("accessibility", "Accessibility", "Lets the session list follow the tab order when sessions share one window.", keywords: ["permission", "tab order"]),
    ]) + entries(.advanced, "Session host", [
        Entry("session-host", "Session host", "The background process that runs window sessions; it's updated with the app.", keywords: ["restart", "daemon", "background", "update"]),
    ])

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func option(_ id: String) -> SettingsOption? { byID[id] }

    /// The options in a category, as its pane shows them.
    static func options(in category: SettingsTab) -> [SettingsOption] { all.filter { $0.category == category } }

    /// Search: every word of `query` found, ignoring case and accents, in an option's title, description, keywords,
    /// section or category. A title match first, then a keyword, then a heading, then the description; else in
    /// catalog order. Nothing for an empty query: the sidebar shows the categories then.
    static func search(_ query: String) -> [SettingsOption] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return all.compactMap { option -> (Int, SettingsOption)? in
            var worst = 0
            for word in words {
                guard let rank = rank(of: word, in: option) else { return nil }
                worst = max(worst, rank)
            }
            return (worst, option)
        }
        .enumerated()
        .sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        .map(\.element.1)
    }

    private static func rank(of word: String, in option: SettingsOption) -> Int? {
        if fold(option.title).contains(word) { return 0 }
        if option.keywords.contains(where: { fold($0).contains(word) }) { return 1 }
        if fold(option.section).contains(word) || fold(option.category.title).contains(word) { return 2 }
        return fold(option.description).contains(word) ? 3 : nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// A place in Settings that's opened from elsewhere in the app; `option` is the row it lands on.
enum SettingsSection: String {
    case boost, reviewFloor = "review-floor", dictationKey = "dictation-key"

    var option: String {
        switch self {
        case .boost: return "boost-mode"
        case .reviewFloor: return "floor-project"
        case .dictationKey: return "dictation-key"
        }
    }
}

/// Which category Settings shows, what's typed in its search, and the option to scroll to and highlight.
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
    /// A new search starts with nothing picked, so a row picked in an earlier one can be picked again.
    @Published var query = "" { didSet { if query != oldValue { picked = nil } } }
    /// The option to scroll to once its category shows; nil again after.
    @Published var reveal: String?
    /// The result picked in the search list.
    @Published var picked: String?
    /// The rows drawn highlighted just now: the option revealed and, when it may not be showing, its parent.
    @Published private(set) var highlighted: Set<String> = []
    /// The note whose "?" the sandbox has opened, for a shot (`settings-help`); nil in the app.
    @Published var openHelp: SettingsNote?
    /// How long a revealed row stays highlighted.
    static let highlightTime: TimeInterval = 1.6
    /// Runs the work after the delay, on the main thread (a test runs it when it chooses).
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private var highlights = 0

    var results: [SettingsOption] { SettingsCatalog.search(query) }
    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Opens the option's category and asks it to reveal the option.
    func reveal(_ option: SettingsOption) {
        tab = option.category
        reveal = option.id
    }

    /// A search result picked: as `reveal`, and the search stays so another result is one click away.
    func pick(_ option: SettingsOption) {
        picked = option.id
        reveal(option)
    }

    /// Draws the option's row (and its parent's) highlighted for `highlightTime`.
    func highlight(_ option: SettingsOption) {
        highlighted = Set([option.id] + (option.parent.map { [$0] } ?? []))
        highlights += 1
        let mine = highlights
        schedule(Self.highlightTime) { [weak self] in
            guard let self, self.highlights == mine else { return }
            self.highlighted = []
        }
    }
}

extension EnvironmentValues {
    /// The ids of the rows highlighted just now (`SettingsSelection.highlighted`).
    @Entry var settingsHighlight: Set<String> = []
}

/// A row's label: its title with the catalog's description under it, as a form row draws two `Text`s.
struct SettingLabel: View {
    let option: SettingsOption

    var body: some View {
        Text(option.title)
        Text(option.description)
    }

    /// The same two lines for a row laid out by hand, outside a form's own label layout.
    var stacked: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(option.title)
            Text(option.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One option in a settings pane: gives `content` the option's label, is what search scrolls to, and draws the
/// highlight. Every control in a pane sits in one (`SettingsCatalogTests`).
struct SettingRow<Content: View>: View {
    let option: SettingsOption
    let content: (SettingLabel) -> Content
    @Environment(\.settingsHighlight) private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ id: String, @ViewBuilder content: @escaping (SettingLabel) -> Content) {
        option = SettingsCatalog.option(id) ?? SettingsOption(id: id, title: id, description: "", category: .general, section: "")
        self.content = content
    }

    var body: some View {
        let lit = highlight.contains(option.id)
        content(SettingLabel(option: option))
            .id(option.id)
            .background(RoundedRectangle(cornerRadius: 6).fill(lit ? Color.accentColor.opacity(0.22) : .clear).padding(-5))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: lit)
    }
}

/// Settings' sidebar: the search field above the categories, or above what the search found.
struct SettingsSidebar: View {
    @ObservedObject var selection: SettingsSelection
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField.padding(10)
            if selection.searching { results } else { categories }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search", text: $selection.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search settings")
                .accessibilityHint("Shows matching options from every category")
                .onSubmit { if let first = selection.results.first { selection.pick(first) } }
            if !selection.query.isEmpty {
                Button { selection.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
        .background(Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0)
            .accessibilityHidden(true))
        .onExitCommand { selection.query = "" }
    }

    private var categories: some View {
        List(selection: Binding(get: { Optional(selection.tab) }, set: { if let tab = $0 { selection.tab = tab } })) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(Optional(tab)).listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset).scrollContentBackground(.hidden)
        .accessibilityLabel("Settings categories")
    }

    @ViewBuilder private var results: some View {
        let found = selection.results
        if found.isEmpty {
            Text("No options match “\(selection.query)”.")
                .foregroundStyle(.secondary).font(.callout)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            List(found, selection: Binding(get: { selection.picked }, set: { id in
                if let option = id.flatMap(SettingsCatalog.option) { selection.pick(option) }
            })) { option in
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).lineLimit(2)
                    Text("\(option.category.title) › \(option.section)").font(.caption).foregroundStyle(.secondary)
                    Text(option.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(option.title), \(option.category.title), \(option.section)")
                .accessibilityHint(option.description)
                .tag(option.id)
                // A click on the row already picked changes no selection: it goes to the option again all the same.
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { selection.pick(option) })
                .listRowSeparator(.hidden)
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            .accessibilityLabel("Search results")
        }
    }
}
