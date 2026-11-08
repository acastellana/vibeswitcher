import AppKit
import SwiftUI
import VibeCore

/// VibeSwitcher › Settings… (⌘,): every preference. The ⚙︎ menu only repeats a few toggles.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let size = CGSize(width: 880, height: 640)
    private let selection = SettingsSelection()
    private let setup: SetupModel
    private let briefing: BriefingModel?
    private let dictation: DictationController?
    /// The window is open (from `open(tab:)` to its closing): what's started for an opening runs once per opening.
    private var watching = false

    init(preferences: Preferences, setup: SetupModel, phoneAccess: PhoneAccess,
         recentProjects: @escaping () -> [String], showWelcome: @escaping () -> Void, host: HostClient? = nil,
         briefing: BriefingModel? = nil, dictation: DictationController? = nil, policy: WorkingPolicyEditor? = nil,
         boost: BoostWatch? = nil, floor: ReviewFloorEditor? = nil,
         walletPeers: WalletPeerList = WalletPeerList(load: { _ in WalletPeerList.Read(passage: nil, peers: []) })) {
        self.setup = setup
        self.briefing = briefing
        self.dictation = dictation
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, setup: setup, phoneAccess: phoneAccess,
                                                                  selection: selection, recentProjects: recentProjects,
                                                                  showWelcome: showWelcome, host: host, briefing: briefing,
                                                                  dictation: dictation, policy: policy, boost: boost, floor: floor, walletPeers: walletPeers))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The sandbox's search and pick: what's typed, and what it found.
    var searchSelection: SettingsSelection { selection }

    func show(tab: SettingsTab, reveal: SettingsSection? = nil) {
        open(tab: tab, reveal: reveal)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Up front even when macOS doesn't make the app active (opened from the command line, at login).
        window?.orderFrontRegardless()
        NSApp.activate()
    }

    /// Shows `tab`; on an opening (not when it's open already: ⌘, again, a tab switched), watches the setup and looks
    /// where the briefing's key comes from, the login shell's read again. Not on a view appearing: the window is kept
    /// for the whole launch, and a category's pane appears again each time it's chosen.
    func open(tab: SettingsTab, reveal: SettingsSection? = nil) {
        open(tab: tab, option: reveal?.option)
    }

    /// Opens on `tab`, or on the category of `option` (an id in `SettingsCatalog`) scrolled to that option.
    func open(tab: SettingsTab, option: String?) {
        selection.query = ""
        selection.picked = nil
        selection.tab = tab
        if let option = option.flatMap(SettingsCatalog.option) { selection.reveal(option) }
        guard !watching else { return }
        watching = true
        setup.watch()
        briefing?.checkKey()
        dictation?.lookForKeys()
    }

    func windowWillClose(_ notification: Notification) {
        if watching { setup.unwatch(); watching = false }
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let setup: SetupModel
    let phoneAccess: PhoneAccess
    @ObservedObject var selection: SettingsSelection
    let recentProjects: () -> [String]
    let showWelcome: () -> Void
    var host: HostClient? = nil
    var briefing: BriefingModel? = nil
    var dictation: DictationController? = nil
    var policy: WorkingPolicyEditor? = nil
    var boost: BoostWatch? = nil
    var floor: ReviewFloorEditor? = nil
    var walletPeers = WalletPeerList(load: { _ in WalletPeerList.Read(passage: nil, peers: []) })

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: selection).frame(width: 250)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(selection.tab.title).font(.title2.bold()).padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ScrollViewReader { proxy in
                    pane.id(selection.tab)
                        .onAppear { reveal(in: proxy) }
                        .onChange(of: selection.reveal) { reveal(in: proxy) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.settingsHighlight, selection.highlighted)
        .frame(width: SettingsWindowController.size.width, height: SettingsWindowController.size.height)
    }

    /// The chosen category's options.
    @ViewBuilder private var pane: some View {
        switch selection.tab {
        case .general: GeneralSettings(preferences: preferences, showWelcome: showWelcome)
        case .notifications: NotificationSettings(preferences: preferences, setup: setup)
        case .appearance: TerminalSettings(preferences: preferences)
        case .sessions: SessionsSettings(preferences: preferences)
        case .launch: LaunchSettings(preferences: preferences, recentProjects: recentProjects())
        case .agents: AgentsSettings(setup: setup, preferences: preferences)
        case .lead: ProjectLeadSettings(preferences: preferences, policy: policy, floor: floor)
        case .performance: PerformanceSettings(preferences: preferences, boost: boost)
        case .dictation: DictationBriefingSettings(preferences: preferences, briefing: briefing, dictation: dictation)
        case .phone: ScrollView { PhoneAccessView(access: phoneAccess).frame(maxWidth: .infinity) }
        case .wallet: WalletSettingsTab(preferences: preferences, peerList: walletPeers)
        case .advanced: AdvancedSettings(setup: setup, host: host)
        }
    }

    /// Scrolls to the option asked for once its pane is laid out (its rows exist only then), lights it up, and forgets it.
    private func reveal(in proxy: ScrollViewProxy) {
        guard let id = selection.reveal, let option = SettingsCatalog.option(id) else { return }
        DispatchQueue.main.async {
            // The parent first: a row that isn't showing (phone access off, a theme that isn't Custom) has no place to go.
            if let parent = option.parent { proxy.scrollTo(parent, anchor: .center) }
            proxy.scrollTo(id, anchor: .center)
            selection.highlight(option)
            selection.reveal = nil
        }
    }
}

/// "On battery, pause lead work below 50 %": a field and a stepper (5 at a time, 10–90; below 10 is 0, never).
struct BatteryHoldRow: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        SettingRow("battery-hold") { label in
            LabeledContent {
                HStack(spacing: 4) {
                    TextField("Battery limit", value: $preferences.batteryHoldBelow, format: .number)
                        .labelsHidden().accessibilityLabel("On battery, pause lead work below, in percent")
                        .multilineTextAlignment(.trailing).frame(width: 44)
                    Text("%")
                    Stepper("Battery limit",
                            onIncrement: { preferences.batteryHoldBelow = Preferences.batteryHoldStep(preferences.batteryHoldBelow, up: true) },
                            onDecrement: { preferences.batteryHoldBelow = Preferences.batteryHoldStep(preferences.batteryHoldBelow, up: false) })
                        .labelsHidden()
                    if preferences.batteryHoldBelow == 0 { Text("(never)").foregroundStyle(.secondary) }
                }
            } label: { label }
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences
    let showWelcome: () -> Void

    var body: some View {
        Form {
            Section {
                SettingRow("open-at-login") { label in
                    Toggle(isOn: Binding(get: { preferences.launchAtLogin }, set: { preferences.setLaunchAtLogin($0) })) { label }
                }
                SettingRow("open-window") { label in Toggle(isOn: $preferences.openWindowAtLaunch) { label } }
                SettingRow("show-welcome") { label in
                    LabeledContent { Button("Show Welcome…", action: showWelcome) } label: { label }
                }
            } header: {
                Text("Startup")
            } footer: {
                SettingsFooter("Window sessions keep running when VibeSwitcher quits or updates. Ended sessions stay listed for a day.")
            }
            Section {
                SettingRow("projects-folder") { label in
                    LabeledContent {
                        HStack {
                            TextField("Projects folder", text: $preferences.projectsFolder, prompt: Text(ProjectCreation.defaultLocation))
                                .labelsHidden().accessibilityLabel("Projects folder")
                                .font(.system(.body, design: .monospaced))
                            Button("Choose…") {
                                if let folder = ProjectsFolderPanel.choose(startingAt: preferences.projectsFolderPath) {
                                    preferences.projectsFolder = ProjectCreation.tildePath(folder)
                                }
                            }
                            .accessibilityLabel("Choose the projects folder")
                        }
                    } label: { label }
                }
            } header: {
                Text("Projects")
            } footer: {
                SettingsFooter("If this folder isn't there yet, it's made (0755) when you create the first project, and the sheet says so first.")
            }
        }
        .formStyle(.grouped)
    }
}

struct NotificationSettings: View {
    /// What a lead's team notifies about (see `AlertRules`).
    static let teamNote = "A project lead's team notifies you only when all its work is done or you're needed (a question for you, a prompt in the lead's terminal). These settings apply to those too."

    @ObservedObject var preferences: Preferences
    @ObservedObject var setup: SetupModel

    var body: some View {
        Form {
            Section {
                SettingRow("notify-permission") { label in
                    LabeledContent {
                        HStack {
                            SetupStatusLabel(status: setup.notificationStatus)
                            if setup.notifications != .allowed {
                                Button(setup.notificationButton) { setup.allowNotifications() }.controlSize(.small)
                            }
                        }
                    } label: { label }
                }
                SettingRow("notify-needs-input") { label in Toggle(isOn: $preferences.notifyNeedsInput) { label } }
                SettingRow("notify-done") { label in Toggle(isOn: $preferences.notifyDone) { label } }
                SettingRow("play-sound") { label in Toggle(isOn: $preferences.playSound) { label } }
                SettingRow("notify-reminders") { label in Toggle(isOn: $preferences.notifyReminders) { label } }
            } header: {
                Text("Banners and sounds")
            } footer: {
                SettingsFooter(Self.teamNote)
            }
        }
        .formStyle(.grouped)
    }
}

/// The menu bar's session list and the docked sidebar.
struct SessionsSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Menu bar") {
                SettingRow("session-order") { label in
                    Picker(selection: $preferences.sessionOrder) {
                        ForEach(SessionOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: { label }
                }
                SettingRow("floating-panel") { label in
                    Picker(selection: $preferences.floatingPanel) {
                        ForEach(FloatingPanelMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: { label }
                }
            }
            Section("Sidebar") {
                SettingRow("sidebar-mode") { label in Toggle(isOn: $preferences.sidebarMode) { label } }
                SettingRow("sidebar-auto-hide") { label in
                    Toggle(isOn: $preferences.sidebarAutoHide) { label }.disabled(!preferences.sidebarMode)
                }
                SettingRow("sidebar-flash") { label in
                    Toggle(isOn: $preferences.sidebarFlashOnSwitch) { label }
                        .disabled(!preferences.sidebarMode || !preferences.sidebarAutoHide)
                }
                SettingRow("minimize-on-pause") { label in Toggle(isOn: $preferences.minimizeOnPause) { label } }
            }
        }
        .formStyle(.grouped)
    }
}

/// What a project lead's team does, the rules it works under, and how far they may go.
struct ProjectLeadSettings: View {
    @ObservedObject var preferences: Preferences
    var policy: WorkingPolicyEditor? = nil
    var floor: ReviewFloorEditor? = nil

    var body: some View {
        Form {
            Section {
                SettingRow("ai-summaries") { label in Toggle(isOn: $preferences.aiSummaries) { label } }
                SettingRow("lead-rotation") { label in
                    Picker(selection: $preferences.leadRotation) {
                        ForEach(LeadRotationMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: { label }
                }
                SettingRow("lead-mail") { label in
                    Toggle(isOn: $preferences.leadMail) { label }
                        .accessibilityHint("Off, a lead's message to another project's lead is refused and nothing is sent")
                }
            } header: {
                Text("Team")
            } footer: {
                SettingsFooter("Summaries are written by claude -p with haiku and no tools, from the task's title, checkpoints and last steps: at most every 3 minutes per task, while the Team tab is open. Off, it shows the latest checkpoint or activity. Messages between leads, sent or refused, are in the lead's Team tab, under Between leads.")
            }
            if let policy { WorkingPolicySection(editor: policy) }
            if let floor { ReviewFloorSection(editor: floor) }
        }
        .formStyle(.grouped)
    }
}

/// How much the Mac runs at once: Boost, the Mac-wide limits, usage limits and power.
struct PerformanceSettings: View {
    @ObservedObject var preferences: Preferences
    var boost: BoostWatch? = nil

    var body: some View {
        Form {
            BoostSection(preferences: preferences, watch: boost)
            MacLimitsSection()
            Section {
                SettingRow("keep-awake") { label in
                    Picker(selection: $preferences.keepAwake) {
                        ForEach(KeepAwakeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: { label }
                }
                BatteryHoldRow(preferences: preferences)
            } header: {
                Text("Power")
            } footer: {
                SettingsFooter("While a worker, verifier or merge runs, the Mac doesn't go to sleep on its own; on battery only if set to Always. Work in flight finishes when the battery limit is reached; above it, leads work as on power.")
            }
        }
        .formStyle(.grouped)
    }
}

struct DictationBriefingSettings: View {
    @ObservedObject var preferences: Preferences
    var briefing: BriefingModel? = nil
    var dictation: DictationController? = nil

    var body: some View {
        Form {
            if let dictation { DictationSettings(dictation: dictation) }
            if let briefing { BriefingSettings(preferences: preferences, briefing: briefing) }
        }
        .formStyle(.grouped)
    }
}

/// What most people never need: macOS permissions and the session host.
struct AdvancedSettings: View {
    @ObservedObject var setup: SetupModel
    var host: HostClient? = nil

    var body: some View {
        Form {
            Section {
                SettingRow("control-terminal") { label in
                    LabeledContent {
                        HStack {
                            SetupStatusLabel(status: setup.terminalStatus)
                            if setup.terminal != .allowed {
                                Button(setup.terminalButton) { setup.allowTerminal() }.controlSize(.small)
                                    .disabled(setup.working == .askingTerminal)
                            }
                        }
                    } label: { label }
                }
                SettingRow("accessibility") { label in
                    LabeledContent {
                        HStack {
                            SetupStatusLabel(status: setup.tabOrderAllowed ? .ok("Allowed") : .pending("Not allowed"))
                            if !setup.tabOrderAllowed {
                                Button("Allow…") { setup.allowTabOrder() }.controlSize(.small)
                            }
                        }
                    } label: { label }
                }
            } header: {
                Text("Mac permissions")
            }
            if let host { HostRestartSection(host: host) }
        }
        .formStyle(.grouped)
    }
}

/// Hooks per agent, Codex's trust of them, and the permissions the Terminal integration needs.
struct AgentsSettings: View {
    /// What the shells setting allows, said plainly (`vs-shell run`, `ShellDesk`).
    static let openShellsHelp = "An agent can ask for a new shell session that runs a command in a folder (vs-shell run). Off, "
        + "its card shows the exact command and nothing runs until you press Run. On, any agent in a session you opened can start "
        + "a terminal session running any command as you, with no click; wallet requests from it still wait for your Send."

    @ObservedObject var setup: SetupModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                SettingRow("open-shells") { label in Toggle(isOn: $preferences.letAgentsOpenShells) { label } }
            } header: {
                Text("Shells")
            } footer: {
                SettingsFooter(Self.openShellsHelp)
            }
            Section {
                SettingRow("hooks") { label in
                    VStack(alignment: .leading, spacing: 8) {
                        label.stacked
                        ForEach(Agent.allCases, id: \.self) { agent in
                            LabeledContent {
                                SetupStatusLabel(status: setup.hookStatus(agent))
                            } label: {
                                Text(agent.displayName)
                                Text(Self.tildePath(HookInstaller.configURL(for: agent).path))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        HStack {
                            Button(setup.allHooksInstalled ? "Reinstall Hooks" : "Install Hooks") { setup.installHooks() }
                            Button("Uninstall") { setup.uninstallHooks() }.disabled(!setup.anyHooksInstalled)
                            if setup.working == .installing || setup.working == .uninstalling || setup.working == .trusting {
                                ProgressView().controlSize(.small)
                            }
                            Spacer()
                        }
                        .disabled(setup.working != nil)
                        if let outcome = setup.outcome {
                            Text(outcome.text).font(.caption).foregroundStyle(outcome.failed ? .red : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("Hooks")
            } footer: {
                SettingsFooter("Installing adds VibeSwitcher's entries beside yours; the first install keeps a copy of each file as …vibeswitcher-backup.")
            }
            Section {
                SettingRow("codex-trust") { label in
                    LabeledContent {
                        Button("Trust Now") { setup.trustCodex() }.disabled(setup.working != nil || setup.hooks[.codex] != true)
                    } label: { label }
                }
            } header: {
                Text("Codex")
            } footer: {
                SettingsFooter("Installing trusts them for you (in ~/.codex/config.toml, like Codex's /hooks screen).")
            }
        }
        .formStyle(.grouped)
    }

    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// A section's explanation, under it and aligned with its rows.
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Presets: global ones, and ones for a project (with that project's default).
struct LaunchSettings: View {
    @ObservedObject var preferences: Preferences
    let recentProjects: [String]
    /// nil: global presets.
    @State private var project: String?
    @State private var selected: UUID?

    private var list: [LaunchPreset] {
        project.map { preferences.presets.byProject[$0] ?? [] } ?? preferences.presets.global
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Presets").font(.headline).accessibilityAddTraits(.isHeader)
            SettingRow("presets-for") { label in
                HStack(alignment: .top) {
                    label.stacked
                    Spacer()
                    Picker("Presets for", selection: $project) {
                        Text("All projects").tag(String?.none)
                        ForEach(recentProjects, id: \.self) { path in
                            Text(SessionNaming.name(forProjectRoot: path)).tag(Optional(path))
                        }
                    }
                    .labelsHidden().accessibilityLabel("Presets for").fixedSize()
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow("preset-list") { label in
                        VStack(alignment: .leading, spacing: 6) {
                            label.stacked
                            List(selection: $selected) {
                                ForEach(list) { preset in
                                    HStack {
                                        Text(preset.name)
                                        Spacer()
                                        if let project, preferences.presets.defaults[project] == preset.id {
                                            Text("Default").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .tag(Optional(preset.id))
                                }
                            }
                            HStack {
                                Button { add() } label: { Image(systemName: "plus").accessibilityLabel("Add preset") }
                                    .help("Add a preset")
                                Button { removeSelected() } label: { Image(systemName: "minus").accessibilityLabel("Remove preset") }
                                    .help("Remove the selected preset").disabled(selected == nil || list.count <= 1 && project == nil)
                                Spacer()
                            }
                        }
                    }
                    if let project {
                        SettingRow("preset-default") { label in
                            VStack(alignment: .leading, spacing: 4) {
                                label.stacked
                                Menu("Default") {
                                    ForEach(preferences.presets.presets(for: project)) { preset in
                                        Button(preset.name) { preferences.presets.defaults[project] = preset.id }
                                    }
                                }
                                .fixedSize()
                            }
                        }
                    }
                }
                .frame(width: 240)
                if let id = selected, let binding = binding(for: id) {
                    PresetEditor(preset: binding)
                } else {
                    Text("Select a preset").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func binding(for id: UUID) -> Binding<LaunchPreset>? {
        guard list.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { preferences.presets.preset(id: id) ?? list[0] },
            set: { updated in update { presets in
                if let index = presets.firstIndex(where: { $0.id == id }) { presets[index] = updated }
            } })
    }

    private func update(_ change: (inout [LaunchPreset]) -> Void) {
        if let project {
            var presets = preferences.presets.byProject[project] ?? []
            change(&presets)
            preferences.presets.byProject[project] = presets.isEmpty ? nil : presets
        } else {
            change(&preferences.presets.global)
        }
    }

    private func add() {
        let preset = LaunchPreset(name: "New Preset", kind: .claude, command: "claude")
        update { $0.append(preset) }
        selected = preset.id
    }

    private func removeSelected() {
        guard let id = selected else { return }
        update { $0.removeAll { $0.id == id } }
        preferences.presets.defaults = preferences.presets.defaults.filter { $0.value != id }
        selected = nil
    }
}

struct PresetEditor: View {
    @Binding var preset: LaunchPreset
    @State private var envText = ""

    var body: some View {
        Form {
            SettingRow("preset-name") { label in TextField(text: $preset.name) { label } }
            SettingRow("preset-kind") { label in
                Picker(selection: $preset.kind) {
                    ForEach(LaunchPreset.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { label }
            }
            if preset.kind != .shell {
                SettingRow("preset-command") { label in
                    TextField(text: $preset.command, prompt: Text(preset.kind.rawValue)) { label }
                        .font(.system(.body, design: .monospaced))
                }
                SettingRow("preset-keep-shell") { label in Toggle(isOn: $preset.keepShell) { label } }
            }
            SettingRow("preset-place") { label in
                Picker(selection: $preset.place) {
                    Text("VibeSwitcher window").tag(LaunchPreset.Place.window)
                    Text("Terminal").tag(LaunchPreset.Place.terminal)
                } label: { label }
            }
            SettingRow("preset-env") { label in
                VStack(alignment: .leading) {
                    label.stacked
                    TextEditor(text: $envText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 70)
                        .accessibilityLabel("Environment, one NAME=value per line")
                        .onChange(of: envText) { _, text in preset.env = Self.parse(text) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { envText = Self.format(preset.env) }
        .onChange(of: preset.id) { _, _ in envText = Self.format(preset.env) }
    }

    static func format(_ env: [String: String]) -> String {
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            if LaunchPlan.validEnvName(name) { env[name] = String(line[line.index(after: equals)...]) }
        }
        return env
    }
}

struct TerminalSettings: View {
    @ObservedObject var preferences: Preferences

    private var fonts: [String] {
        let fixed = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return Array(Set(fixed.compactMap { NSFont(name: $0, size: 12)?.familyName })).sorted()
    }

    var body: some View {
        Form {
            Section("Text") {
                SettingRow("font") { label in
                    Picker(selection: $preferences.appearance.fontName) {
                        Text("System Monospaced").tag("")
                        ForEach(fonts, id: \.self) { Text($0).tag($0) }
                    } label: { label }
                }
                SettingRow("font-size") { label in
                    LabeledContent {
                        Stepper("\(Int(preferences.appearance.fontSize)) pt",
                                value: $preferences.appearance.fontSize, in: TerminalAppearance.fontSizeRange, step: 1)
                    } label: { label }
                }
            }
            Section("Colors") {
                SettingRow("theme") { label in
                    Picker(selection: $preferences.appearance.theme) {
                        ForEach(TerminalAppearance.Theme.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: { label }
                }
                if preferences.appearance.theme == .custom {
                    SettingRow("color-text") { label in ColorRow(hex: $preferences.appearance.custom.foreground) { label } }
                    SettingRow("color-background") { label in ColorRow(hex: $preferences.appearance.custom.background) { label } }
                    SettingRow("color-cursor") { label in ColorRow(hex: $preferences.appearance.custom.cursor) { label } }
                    SettingRow("color-selection") { label in ColorRow(hex: $preferences.appearance.custom.selection) { label } }
                    SettingRow("color-ansi") { label in
                        DisclosureGroup {
                            ForEach(0..<16, id: \.self) { index in
                                ColorRow(hex: $preferences.appearance.custom.ansi[index]) { Text("Color \(index)") }
                            }
                        } label: { label }
                    }
                }
            }
            Section("Behavior") {
                SettingRow("cursor-shape") { label in
                    Picker(selection: $preferences.appearance.cursorShape) {
                        Text("Block").tag(TerminalAppearance.CursorShape.block)
                        Text("Underline").tag(TerminalAppearance.CursorShape.underline)
                        Text("Bar").tag(TerminalAppearance.CursorShape.bar)
                    } label: { label }
                }
                SettingRow("cursor-blink") { label in Toggle(isOn: $preferences.appearance.cursorBlink) { label } }
                SettingRow("scrollback") { label in
                    LabeledContent {
                        Stepper("\(preferences.appearance.scrollbackLines) lines",
                                value: $preferences.appearance.scrollbackLines, in: 1_000...100_000, step: 1_000)
                    } label: { label }
                }
                SettingRow("option-as-meta") { label in Toggle(isOn: $preferences.appearance.optionAsMeta) { label } }
                SettingRow("bell") { label in
                    Picker(selection: $preferences.appearance.bell) {
                        Text("None").tag(TerminalAppearance.Bell.none)
                        Text("Flash").tag(TerminalAppearance.Bell.visual)
                        Text("Sound").tag(TerminalAppearance.Bell.sound)
                    } label: { label }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ColorRow<Title: View>: View {
    @Binding var hex: String
    @ViewBuilder let title: () -> Title

    var body: some View {
        ColorPicker(selection: Binding(
            get: {
                let rgb = RGB(hex: hex) ?? RGB(red: 0, green: 0, blue: 0)
                return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
            },
            set: { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                hex = RGB(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent).hex
            }), supportsOpacity: false, label: title)
    }
}

/// Settings › Dictation & Briefing › Spoken briefing: the language the Brief me briefing is written and read in, and the ElevenLabs API
/// key: where it comes from (`BriefingKey`: the Keychain, your shell, the key file; named, never shown), and one typed
/// here, kept in the login Keychain only (never in the defaults, a log or the phone).
struct BriefingSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var briefing: BriefingModel
    /// What's typed into the key field, until Save: then it goes to the Keychain and the field empties.
    @State private var key = ""

    /// What the section says about the key, made from where it comes from alone (it never has the key): the field's
    /// prompt, the 'Key in use' line, and whether Save to Keychain is offered.
    struct KeyText: Equatable {
        var prompt: String
        var line: String
        var offersSave: Bool
    }

    var body: some View {
        let text = KeyText(briefing.keySource)
        Section {
            SettingRow("briefing-language") { label in
                Picker(selection: $preferences.briefingLanguage) {
                    ForEach(BriefingLanguage.all) { Text($0.name).tag($0.code) }
                } label: { label }
            }
            SettingRow("briefing-key") { label in
                LabeledContent {
                    HStack {
                        SecureField("ElevenLabs API key", text: $key, prompt: Text(text.prompt))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit(save)
                        Button("Save", action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        if briefing.keySaved == true {
                            Button("Remove") { briefing.saveKey(nil) }
                        }
                    }
                } label: { label }
            }
            SettingRow("briefing-key-in-use") { label in
                LabeledContent {
                    HStack {
                        Text(text.line).foregroundStyle(.secondary)
                        if text.offersSave {
                            Button("Save to Keychain") { briefing.saveFoundKey() }
                        }
                    }
                } label: { label }
            }
            SettingRow("briefing-voice") { label in
                LabeledContent {
                    Button("Test voice") { briefing.testVoice() }
                } label: { label }
            }
            if let notice = briefing.keyNotice { Text(notice).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Spoken briefing")
        } footer: {
            SettingsFooter("Brief me (in the window's toolbar and the menu bar) writes 30 seconds on what happened lately across the projects VibeSwitcher leads, with headless Claude, and reads it aloud. Brief me on <project>, at the top of a lead's Team tab or with ⌥⇧⌘B, does the same for that one project. With a key, the text goes to ElevenLabs to be read, only when you press the button; without one, the Mac's own voice reads it. A key typed here is kept in your login Keychain, nowhere else; without one, ELEVENLABS_API_KEY from your shell or ~/.config/elevenlabs/key.env is used, held in memory only.")
        }
    }

    private func save() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        briefing.saveKey(value)
        key = ""
    }
}

extension BriefingSettings.KeyText {
    init(_ source: BriefingKeySource?) {
        switch source {
        case .keychain: prompt = "Saved in your Keychain"
        case .shell, .file: prompt = "Paste one to use instead"
        case .absent, nil: prompt = "Not set"
        }
        line = source?.line ?? "Looking…"
        offersSave = source?.canSave == true
    }
}
