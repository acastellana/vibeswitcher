import AppKit
import SwiftUI
import VibeCore

enum SettingsTab: String { case general, launch, terminal }

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// VibeSwitcher › Settings…: General, Launch presets, Terminal.
final class SettingsWindowController: NSWindowController {
    private let selection = SettingsSelection()

    init(preferences: Preferences, recentProjects: @escaping () -> [String]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, selection: selection,
                                                                  recentProjects: recentProjects))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(tab: SettingsTab) {
        selection.tab = tab
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var selection: SettingsSelection
    let recentProjects: () -> [String]

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettings(preferences: preferences)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            LaunchSettings(preferences: preferences, recentProjects: recentProjects())
                .tabItem { Label("Launch", systemImage: "play.rectangle") }.tag(SettingsTab.launch)
            TerminalSettings(preferences: preferences)
                .tabItem { Label("Terminal", systemImage: "terminal") }.tag(SettingsTab.terminal)
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}

struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Toggle("Open the window when VibeSwitcher starts", isOn: $preferences.openWindowAtLaunch)
            Toggle("Launch at login", isOn: Binding(get: { preferences.launchAtLogin },
                                                    set: { preferences.setLaunchAtLogin($0) }))
            Text("Window sessions keep running when VibeSwitcher quits or updates. Ended sessions stay listed for a day.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
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
                    Button { add() } label: { Image(systemName: "plus") }
                    Button { removeSelected() } label: { Image(systemName: "minus") }.disabled(selected == nil || list.count <= 1 && project == nil)
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
