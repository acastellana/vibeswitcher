import AppKit
import SwiftUI
import VibeCore

/// Raw values are what `--settings TAB` takes.
enum SettingsTab: String, CaseIterable { case general, agents, phone, launch, terminal }

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// VibeSwitcher › Settings… (⌘,): every preference. The ⚙︎ menu only repeats a few toggles.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let size = CGSize(width: 660, height: 540)
    private let selection = SettingsSelection()
    private let setup: SetupModel
    private let briefing: BriefingModel?
    /// The window is open (from `open(tab:)` to its closing): what's started for an opening runs once per opening.
    private var watching = false

    init(preferences: Preferences, setup: SetupModel, phoneAccess: PhoneAccess,
         recentProjects: @escaping () -> [String], showWelcome: @escaping () -> Void, host: HostClient? = nil,
         briefing: BriefingModel? = nil, policy: WorkingPolicyEditor? = nil) {
        self.setup = setup
        self.briefing = briefing
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, setup: setup, phoneAccess: phoneAccess,
                                                                  selection: selection, recentProjects: recentProjects,
                                                                  showWelcome: showWelcome, host: host, briefing: briefing,
                                                                  policy: policy))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(tab: SettingsTab) {
        open(tab: tab)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Up front even when macOS doesn't make the app active (opened from the command line, at login).
        window?.orderFrontRegardless()
        NSApp.activate()
    }

    /// Shows `tab`; on an opening (not when it's open already: ⌘, again, a tab switched), watches the setup and looks
    /// where the briefing's key comes from, the login shell's read again. Not on a view appearing: the window is kept
    /// for the whole launch, and the General tab appears again each time it's chosen.
    func open(tab: SettingsTab) {
        selection.tab = tab
        guard !watching else { return }
        watching = true
        setup.watch()
        briefing?.checkKey()
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
    var policy: WorkingPolicyEditor? = nil

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettings(preferences: preferences, setup: setup, showWelcome: showWelcome, host: host, briefing: briefing, policy: policy)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            AgentsSettings(setup: setup)
                .tabItem { Label("Agents", systemImage: "waveform.path.ecg") }.tag(SettingsTab.agents)
            ScrollView { PhoneAccessView(access: phoneAccess).frame(maxWidth: .infinity) }
                .tabItem { Label("Phone", systemImage: "iphone") }.tag(SettingsTab.phone)
            LaunchSettings(preferences: preferences, recentProjects: recentProjects())
                .tabItem { Label("Launch", systemImage: "play.rectangle") }.tag(SettingsTab.launch)
            TerminalSettings(preferences: preferences)
                .tabItem { Label("Terminal", systemImage: "terminal") }.tag(SettingsTab.terminal)
        }
        .padding(20)
        .frame(width: SettingsWindowController.size.width, height: SettingsWindowController.size.height)
    }
}

/// "On battery, pause lead work below 50 %": a field and a stepper (5 at a time, 10–90; below 10 is 0, never).
struct BatteryHoldRow: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        LabeledContent("On battery, pause lead work below") {
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
        }
    }
}

struct GeneralSettings: View {
    /// Under Notifications: what a lead's team notifies about (see `AlertRules`).
    static let teamNote = "A project lead's team notifies you only when all its work is done or you're needed (a question for you, a prompt in the lead's terminal). These settings apply to those too."

    @ObservedObject var preferences: Preferences
    @ObservedObject var setup: SetupModel
    let showWelcome: () -> Void
    var host: HostClient? = nil
    var briefing: BriefingModel? = nil
    var policy: WorkingPolicyEditor? = nil

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { preferences.launchAtLogin },
                                                      set: { preferences.setLaunchAtLogin($0) }))
                Toggle("Open the window when VibeSwitcher starts", isOn: $preferences.openWindowAtLaunch)
                LabeledContent("First-run setup") { Button("Show Welcome…", action: showWelcome) }
            } footer: {
                SettingsFooter("Window sessions keep running when VibeSwitcher quits or updates. Ended sessions stay listed for a day.")
            }
            if let host { HostRestartSection(host: host) }
            Section {
                LabeledContent("Projects folder") {
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
                }
            } header: {
                Text("Projects")
            } footer: {
                SettingsFooter("Home's New Project… makes each new project in a folder here. If this folder isn't there yet, it's made (0755) when you create the first one, and the sheet says so first.")
            }
            Section("Menu bar") {
                Picker("Order sessions", selection: $preferences.sessionOrder) {
                    ForEach(SessionOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Floating dots panel", selection: $preferences.floatingPanel) {
                    ForEach(FloatingPanelMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section("Sidebar") {
                Toggle("Sidebar mode", isOn: $preferences.sidebarMode)
                Toggle("Auto-hide the sidebar (show it at the right edge)", isOn: $preferences.sidebarAutoHide)
                    .disabled(!preferences.sidebarMode)
                Toggle("Show briefly after switching desktops", isOn: $preferences.sidebarFlashOnSwitch)
                    .disabled(!preferences.sidebarMode || !preferences.sidebarAutoHide)
                Toggle("Minimize a session's window when pausing it", isOn: $preferences.minimizeOnPause)
            }
            Section {
                Toggle("Summarize what each agent is doing with AI", isOn: $preferences.aiSummaries)
                Picker("Keep the Mac awake while the team works", selection: $preferences.keepAwake) {
                    ForEach(KeepAwakeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                BatteryHoldRow(preferences: preferences)
            } header: {
                Text("Project lead")
            } footer: {
                SettingsFooter("The Team tab says in plain words what each task's agent is doing and what long decisions mean, written by a small Claude model (claude -p with haiku, no tools) from the task's title, checkpoints and last steps: at most every 3 minutes per task, while the tab is open. Off, it shows the latest checkpoint or activity. While a worker, verifier or merge runs, the Mac doesn't go to sleep on its own (the display still does); on battery only if set to Always. On battery, the lead starts no workers or audits and merges nothing only while the charge is under the level set here (work in flight finishes); above it, it works as on power. 0 never pauses.")
            }
            MacLimitsSection()
            if let policy { WorkingPolicySection(editor: policy) }
            if let briefing { BriefingSettings(preferences: preferences, briefing: briefing) }
            Section {
                LabeledContent("Permission") {
                    HStack {
                        SetupStatusLabel(status: setup.notificationStatus)
                        if setup.notifications != .allowed {
                            Button(setup.notificationButton) { setup.allowNotifications() }.controlSize(.small)
                        }
                    }
                }
                Toggle("Notify when a session needs input", isOn: $preferences.notifyNeedsInput)
                Toggle("Notify when a session finishes", isOn: $preferences.notifyDone)
                Toggle("Play a sound when a session needs input", isOn: $preferences.playSound)
                Toggle("Remind me about waiting or stuck sessions", isOn: $preferences.notifyReminders)
            } header: {
                Text("Notifications")
            } footer: {
                SettingsFooter(Self.teamNote)
            }
        }
        .formStyle(.grouped)
    }
}

/// Hooks per agent, Codex's trust of them, and the permissions the Terminal integration needs.
struct AgentsSettings: View {
    @ObservedObject var setup: SetupModel

    var body: some View {
        Form {
            Section {
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
            } header: {
                Text("Hooks")
            } footer: {
                SettingsFooter("Hooks are how sessions report live status. Installing adds VibeSwitcher's entries beside yours; the "
                               + "first install keeps a copy of each file as …vibeswitcher-backup.")
            }
            Section {
                LabeledContent("Trust VibeSwitcher's hooks") {
                    Button("Trust Now") { setup.trustCodex() }.disabled(setup.working != nil || setup.hooks[.codex] != true)
                }
            } header: {
                Text("Codex")
            } footer: {
                SettingsFooter("Codex skips hooks until they're trusted. Installing trusts them for you (in ~/.codex/config.toml, "
                               + "like Codex's /hooks screen); do it again here if Codex says they changed.")
            }
            Section {
                LabeledContent("Control Terminal") {
                    HStack {
                        SetupStatusLabel(status: setup.terminalStatus)
                        if setup.terminal != .allowed {
                            Button(setup.terminalButton) { setup.allowTerminal() }.controlSize(.small)
                                .disabled(setup.working == .askingTerminal)
                        }
                    }
                }
                LabeledContent("Accessibility") {
                    HStack {
                        SetupStatusLabel(status: setup.tabOrderAllowed ? .ok("Allowed") : .pending("Not allowed"))
                        if !setup.tabOrderAllowed {
                            Button("Allow…") { setup.allowTabOrder() }.controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Terminal")
            } footer: {
                SettingsFooter("Control Terminal reads tab titles and brings a session's tab to the front. Accessibility lets "
                               + "the list follow the tab order when sessions share one window.")
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Presets for", selection: $project) {
                    Text("All projects").tag(String?.none)
                    ForEach(recentProjects, id: \.self) { path in
                        Text(SessionNaming.name(forProjectRoot: path)).tag(Optional(path))
                    }
                }
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
                .frame(width: 220)
                HStack {
                    Button { add() } label: { Image(systemName: "plus").accessibilityLabel("Add preset") }
                        .help("Add a preset")
                    Button { removeSelected() } label: { Image(systemName: "minus").accessibilityLabel("Remove preset") }
                        .help("Remove the selected preset").disabled(selected == nil || list.count <= 1 && project == nil)
                    Spacer()
                    if let project {
                        Menu("Default") {
                            ForEach(preferences.presets.presets(for: project)) { preset in
                                Button(preset.name) { preferences.presets.defaults[project] = preset.id }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            if let id = selected, let binding = binding(for: id) {
                PresetEditor(preset: binding)
            } else {
                Text("Select a preset").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
            TextField("Name", text: $preset.name)
            Picker("Starts", selection: $preset.kind) {
                ForEach(LaunchPreset.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if preset.kind != .shell {
                TextField("Command", text: $preset.command, prompt: Text(preset.kind.rawValue))
                    .font(.system(.body, design: .monospaced))
                Toggle("Keep a shell open after it exits", isOn: $preset.keepShell)
            }
            Picker("Runs in", selection: $preset.place) {
                Text("VibeSwitcher window").tag(LaunchPreset.Place.window)
                Text("Terminal").tag(LaunchPreset.Place.terminal)
            }
            VStack(alignment: .leading) {
                Text("Environment (NAME=value, one per line)")
                TextEditor(text: $envText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70)
                    .onChange(of: envText) { _, text in preset.env = Self.parse(text) }
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
                Picker("Font", selection: $preferences.appearance.fontName) {
                    Text("System Monospaced").tag("")
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Size: \(Int(preferences.appearance.fontSize)) pt",
                        value: $preferences.appearance.fontSize, in: TerminalAppearance.fontSizeRange, step: 1)
            }
            Section("Colors") {
                Picker("Theme", selection: $preferences.appearance.theme) {
                    ForEach(TerminalAppearance.Theme.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if preferences.appearance.theme == .custom {
                    ColorRow(title: "Text", hex: $preferences.appearance.custom.foreground)
                    ColorRow(title: "Background", hex: $preferences.appearance.custom.background)
                    ColorRow(title: "Cursor", hex: $preferences.appearance.custom.cursor)
                    ColorRow(title: "Selection", hex: $preferences.appearance.custom.selection)
                    DisclosureGroup("ANSI colors") {
                        ForEach(0..<16, id: \.self) { index in
                            ColorRow(title: "Color \(index)", hex: $preferences.appearance.custom.ansi[index])
                        }
                    }
                }
            }
            Section("Behavior") {
                Picker("Cursor", selection: $preferences.appearance.cursorShape) {
                    Text("Block").tag(TerminalAppearance.CursorShape.block)
                    Text("Underline").tag(TerminalAppearance.CursorShape.underline)
                    Text("Bar").tag(TerminalAppearance.CursorShape.bar)
                }
                Toggle("Blinking cursor", isOn: $preferences.appearance.cursorBlink)
                Stepper("Scrollback: \(preferences.appearance.scrollbackLines) lines",
                        value: $preferences.appearance.scrollbackLines, in: 1_000...100_000, step: 1_000)
                Toggle("Use Option as Meta key", isOn: $preferences.appearance.optionAsMeta)
                Picker("Bell", selection: $preferences.appearance.bell) {
                    Text("None").tag(TerminalAppearance.Bell.none)
                    Text("Flash").tag(TerminalAppearance.Bell.visual)
                    Text("Sound").tag(TerminalAppearance.Bell.sound)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ColorRow: View {
    let title: String
    @Binding var hex: String

    var body: some View {
        ColorPicker(title, selection: Binding(
            get: {
                let rgb = RGB(hex: hex) ?? RGB(red: 0, green: 0, blue: 0)
                return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
            },
            set: { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                hex = RGB(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent).hex
            }), supportsOpacity: false)
    }
}

/// Settings › General › Briefing: the language the Brief me briefing is written and read in, and the ElevenLabs API
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
            Picker("Language", selection: $preferences.briefingLanguage) {
                ForEach(BriefingLanguage.all) { Text($0.name).tag($0.code) }
            }
            LabeledContent("ElevenLabs API key") {
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
            }
            LabeledContent("Key in use") {
                HStack {
                    Text(text.line).foregroundStyle(.secondary)
                    if text.offersSave {
                        Button("Save to Keychain") { briefing.saveFoundKey() }
                    }
                }
            }
            LabeledContent("Voice") {
                Button("Test voice") { briefing.testVoice() }
            }
            if let notice = briefing.keyNotice { Text(notice).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Briefing")
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
