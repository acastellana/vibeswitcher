import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// Settings' catalog (`SettingsCatalog`): every option named and described once, every control in a pane a catalog
/// row, and search finding options by title, description and keyword.
struct SettingsCatalogTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The views that hold Settings' controls, by file. A new pane goes here, and in `SettingsView.pane` (checked below).
    static let panes: [(file: String, views: [String])] = [
        ("Sources/VibeSwitcher/SettingsWindow.swift", ["GeneralSettings", "NotificationSettings", "SessionsSettings", "ProjectLeadSettings",
                                                       "PerformanceSettings", "DictationBriefingSettings", "AdvancedSettings", "AgentsSettings",
                                                       "LaunchSettings", "PresetEditor", "TerminalSettings", "BriefingSettings", "BatteryHoldRow"]),
        ("Sources/VibeSwitcher/MacLimitsSettings.swift", ["MacLimitsSection", "BoostSection"]),
        ("Sources/VibeSwitcher/ReviewFloorSettings.swift", ["ReviewFloorSection", "ReviewFloorRows"]),
        ("Sources/VibeSwitcher/WorkingPolicySettings.swift", ["WorkingPolicySection"]),
        ("Sources/VibeSwitcher/Wallet/WalletSettingsTab.swift", ["WalletSettingsTab"]),
        ("Sources/VibeSwitcher/Dictation/DictationViews.swift", ["DictationSettings"]),
        ("Sources/VibeSwitcher/HostRestart.swift", ["HostRestartSection"]),
        ("Sources/VibeSwitcher/PhoneAccessView.swift", ["PhoneAccessView"]),
    ]

    /// The controls a person changes; a new kind goes here.
    static let controls = "Toggle|Picker|Stepper|TextField|SecureField|TextEditor|ColorPicker|ColorRow|DisclosureGroup|Menu|LabeledContent|BoostStepper|Button"

    static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// `source` with what's inside strings and comments blanked (same length): brackets and names in them don't count.
    static func blanked(_ source: String) -> [Character] {
        var out = Array(source)
        var i = 0
        func at(_ text: String, _ from: Int) -> Bool {
            let t = Array(text)
            return from + t.count <= out.count && Array(out[from..<from + t.count]) == t
        }
        func blank(_ from: Int, _ to: Int) { for j in from..<min(to, out.count) where out[j] != "\n" { out[j] = " " } }
        func skipString(_ start: Int) -> Int {
            let triple = at("\"\"\"", start)
            let quote = triple ? "\"\"\"" : "\""
            var j = start + quote.count
            while j < out.count {
                if out[j] == "\\", j + 1 < out.count, out[j + 1] == "(" {
                    var depth = 0
                    var k = j + 1
                    repeat {
                        if out[k] == "(" { depth += 1 } else if out[k] == ")" { depth -= 1 }
                        k += 1
                    } while depth > 0 && k < out.count
                    j = k
                } else if out[j] == "\\" {
                    j += 2
                } else if at(quote, j) {
                    return j + quote.count
                } else if !triple && out[j] == "\n" {
                    return j
                } else { j += 1 }
            }
            return j
        }
        while i < out.count {
            if at("//", i) {
                var j = i
                while j < out.count, out[j] != "\n" { j += 1 }
                blank(i, j); i = j
            } else if at("/*", i) {
                var j = i + 2
                while j < out.count, !at("*/", j) { j += 1 }
                blank(i, j + 2); i = j + 2
            } else if out[i] == "\"" {
                let end = skipString(i)
                blank(i + 1, max(i + 1, end - 1)); i = end
            } else { i += 1 }
        }
        return out
    }

    /// The range of the balanced bracket opening at `open`.
    static func block(_ code: [Character], from open: Int) -> Range<Int> {
        let pairs: [Character: Character] = ["(": ")", "{": "}", "[": "]"]
        var stack = [pairs[code[open]]!]
        var i = open + 1
        while i < code.count, !stack.isEmpty {
            if let close = pairs[code[i]] { stack.append(close) } else if code[i] == stack.last { stack.removeLast() }
            i += 1
        }
        return open..<i
    }

    /// The body of each named view in `source`; records names it couldn't find.
    static func bodies(of names: [String], in code: [Character], missing: inout [String]) -> [String: Range<Int>] {
        let text = String(code)
        var found: [String: Range<Int>] = [:]
        for name in names {
            guard let range = text.range(of: #"struct \#(name)\b"#, options: .regularExpression),
                  let brace = text[range.upperBound...].firstIndex(of: "{") else { missing.append(name); continue }
            let open = text.distance(from: text.startIndex, to: brace)
            found[name] = block(code, from: open)
        }
        return found
    }

    @Test func everyOptionIsNamedDescribedAndInOneCategory() {
        let all = SettingsCatalog.all
        #expect(all.count >= 70)
        #expect(Set(all.map(\.id)).count == all.count, "an id used twice")
        for option in all {
            #expect(!option.title.trimmingCharacters(in: .whitespaces).isEmpty, "\(option.id): no title")
            #expect(!option.description.trimmingCharacters(in: .whitespaces).isEmpty, "\(option.id): no description")
            #expect(!option.description.contains("\n") && option.description.count <= 130, "\(option.id): not one short line")
            #expect(!option.section.isEmpty, "\(option.id): no section")
            #expect(SettingsCatalog.options(in: option.category).contains(option), "\(option.id): not in its category")
            if let parent = option.parent {
                #expect(SettingsCatalog.option(parent)?.category == option.category, "\(option.id): parent \(parent) elsewhere")
            }
        }
        // Each category has options and the sidebar lists them all.
        for tab in SettingsTab.allCases {
            #expect(!SettingsCatalog.options(in: tab).isEmpty, "\(tab.rawValue) has no options")
            #expect(SettingsTab(rawValue: tab.rawValue) == tab)
        }
    }

    /// The lint that keeps search complete: every control inside a pane sits in a `SettingRow` with a catalog id,
    /// every catalog id has one row, and a row or control left out of the panes fails here.
    @Test func everyControlInAPaneHasACatalogRow() throws {
        var problems: [String] = []
        var rowIDs: [String] = []
        var missing: [String] = []
        let controlPattern = try NSRegularExpression(pattern: #"(?<![\w.])(\#(Self.controls))\s*[({]"#)
        let rowPattern = try NSRegularExpression(pattern: #"SettingRow\(""#)
        for (file, views) in Self.panes {
            let source = try Self.read(file)
            let chars = Array(source)
            let code = Self.blanked(source)
            let bodies = Self.bodies(of: views, in: code, missing: &missing)
            for (name, body) in bodies {
                let text = String(code[body]) as NSString
                let original = String(chars[body])
                var rows: [Range<Int>] = []
                for match in rowPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                    let quote = match.range.location + match.range.length - 1
                    let idStart = original.index(original.startIndex, offsetBy: quote + 1)
                    guard let idEnd = original[idStart...].firstIndex(of: "\"") else { continue }
                    let id = String(original[idStart..<idEnd])
                    rowIDs.append(id)
                    if SettingsCatalog.option(id) == nil { problems.append("\(name): SettingRow(\"\(id)\") isn't in the catalog") }
                    // The row reaches to its closing bracket: its trailing closure.
                    var j = quote + 1 + original.distance(from: idStart, to: idEnd) + 1
                    let bodyCode = Array(code[body])
                    while j < bodyCode.count, bodyCode[j] != "{" { j += 1 }
                    if j < bodyCode.count { rows.append(Self.block(bodyCode, from: j)) }
                }
                // ReviewFloorRows' row helper: the LabeledContent every floor row, each inside its SettingRow, is drawn with.
                let bodyCode = Array(code[body])
                var skip: [Range<Int>] = []
                if let helper = text.range(of: "func row<").location as Int?, helper != NSNotFound,
                   let brace = bodyCode[helper...].firstIndex(of: "{") { skip.append(Self.block(bodyCode, from: brace)) }
                for match in controlPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                    if skip.contains(where: { $0.contains(match.range.location) }) { continue }
                    if !rows.contains(where: { $0.contains(match.range.location) }) {
                        let kind = text.substring(with: match.range(at: 1))
                        let line = String(chars[body.lowerBound..<(body.lowerBound + match.range.location)]).split(separator: "\n", omittingEmptySubsequences: false).count
                        problems.append("\(name): \(kind) at its line \(line) sits in no SettingRow: wrap it, and add it to SettingsCatalog")
                    }
                }
            }
        }
        #expect(missing.isEmpty, "views not found: \(missing)")
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        // Every catalog id has exactly one row; nothing extra.
        #expect(rowIDs.count == Set(rowIDs).count, "a catalog id with two rows: \(rowIDs.sorted())")
        #expect(Set(rowIDs) == Set(SettingsCatalog.all.map(\.id)), "difference: \(Set(rowIDs).symmetricDifference(SettingsCatalog.all.map(\.id)))")
    }

    /// `SettingsView.pane` shows only views this test scans, so a new pane can't slip past the lint above.
    @Test func everyPaneShownIsScanned() throws {
        let source = try Self.read("Sources/VibeSwitcher/SettingsWindow.swift")
        let code = Self.blanked(source)
        var missing: [String] = []
        let body = try #require(Self.bodies(of: ["SettingsView"], in: code, missing: &missing)["SettingsView"])
        let text = String(code[body])
        let scanned = Set(Self.panes.flatMap(\.views))
        let cases = try #require(text.range(of: "switch selection.tab"))
        let shown = text[cases.lowerBound...].matches(of: #/case \.\w+:[^\n]*?([A-Z]\w+)\(/#).map { String($0.output.1) }.filter { $0 != "ScrollView" }
        #expect(shown.count == SettingsTab.allCases.count - 1 || shown.count == SettingsTab.allCases.count, "\(shown)")
        for view in shown where view != "PhoneAccessView" { #expect(scanned.contains(view), "\(view) isn't scanned") }
    }

    /// Search's words: in a title, in a description, in keywords, in any case.
    @Test func searchFindsAnOptionByTitleDescriptionAndKeyword() {
        func ids(_ query: String) -> [String] { SettingsCatalog.search(query).map(\.id) }
        // A word in the title only.
        #expect(ids("Scrollback").contains("scrollback"))
        // A word only in the description.
        #expect(!(SettingsCatalog.option("floating-panel")!.title.lowercased().contains("crowded")))
        #expect(ids("crowded") == ["floating-panel"])
        // Not a keyword (the glossary's lint refuses that word alone), and still found through its description.
        #expect(ids("waiting").contains("notify-needs-input"))
        // Keywords, as the contract names them.
        #expect(ids("quota").contains("ignore-usage-limits"))
        #expect(ids("dictation").contains("dictation-key"))
        #expect(ids("keychain").contains("briefing-key") && ids("keychain").contains("dictation-key"))
        #expect(Set(ids("battery")).isSuperset(of: ["battery-hold", "boost-on-battery", "keep-awake"]))
        // Case and accents don't matter; every word has to match.
        #expect(ids("QuOtA") == ids("quota"))
        #expect(ids("DICTÁTION") == ids("dictation"))
        #expect(ids("boost battery") == ["boost-on-battery"] || ids("boost battery").contains("boost-on-battery"))
        #expect(ids("boost nothingmatches").isEmpty)
        // The empty query shows the categories, not results.
        #expect(ids("").isEmpty && ids("   ").isEmpty)
        let selection = SettingsSelection()
        #expect(!selection.searching && selection.results.isEmpty)
        selection.query = "quota"
        #expect(selection.searching && !selection.results.isEmpty)
        selection.query = "   "
        #expect(!selection.searching)
    }

    @Test func aTitleMatchRanksFirst() {
        let results = SettingsCatalog.search("boost")
        #expect(results.first?.id == "boost-mode", "\(results.map(\.id))")
    }

    @Test func pickingAResultOpensItsCategoryAndAsksItToRevealIt() throws {
        let selection = SettingsSelection()
        selection.query = "quota"
        let option = try #require(SettingsCatalog.option("ignore-usage-limits"))
        selection.pick(option)
        #expect(selection.tab == .performance)
        #expect(selection.reveal == "ignore-usage-limits")
        #expect(selection.picked == "ignore-usage-limits")
        // The results stay, so another is one click away.
        #expect(selection.query == "quota")
    }

    /// A row picked before can be picked again: a new search forgets the pick, and picking the same option once more
    /// asks for it to be revealed again.
    @Test func aResultCanBePickedAgain() throws {
        let selection = SettingsSelection()
        let option = try #require(SettingsCatalog.option("boost-mode"))
        selection.query = "boost"
        selection.pick(option)
        selection.reveal = nil
        selection.pick(option)
        #expect(selection.reveal == "boost-mode" && selection.picked == "boost-mode")
        selection.query = ""
        #expect(selection.picked == nil)
        selection.tab = .appearance
        selection.query = "boost"
        #expect(selection.picked == nil)
        // The row reacts to a click whatever the list's selection says.
        let source = try Self.read("Sources/VibeSwitcher/SettingsCatalog.swift")
        #expect(source.contains("simultaneousGesture(TapGesture().onEnded { selection.pick(option) })"))
    }

    @Test func aRevealedRowIsHighlightedBrieflyAndAParentWithIt() throws {
        var fire: [() -> Void] = []
        let selection = SettingsSelection()
        selection.schedule = { _, work in fire.append(work) }
        let child = try #require(SettingsCatalog.option("phone-replies"))
        selection.highlight(child)
        #expect(selection.highlighted == ["phone-replies", "phone-access"])
        // A later highlight stands: the earlier one's clock clears nothing.
        selection.highlight(try #require(SettingsCatalog.option("boost-mode")))
        fire[0]()
        #expect(selection.highlighted == ["boost-mode"])
        fire[1]()
        #expect(selection.highlighted.isEmpty)
    }

    /// Links from elsewhere land on their option, whatever tab they name, and clear a leftover search.
    @MainActor @Test func deepLinksStillLandOnTheirOption() throws {
        let temp = Scratch()
        let defaults = temp.defaults("settings-catalog")
        let preferences = Preferences(defaults: defaults, presetsFile: temp.url("settings-presets"))
        let setup = SetupModel(preferences: preferences, system: .fixed(hooks: [.claude: true], terminal: .notAsked, notifications: .off))
        let controller = SettingsWindowController(preferences: preferences, setup: setup, phoneAccess: PhoneAccess(store: SessionStore()),
                                                  recentProjects: { [] }, showWelcome: {})
        let selection = controller.searchSelection
        selection.query = "battery"
        controller.open(tab: .general, reveal: .boost)
        #expect(selection.tab == .performance && selection.reveal == "boost-mode" && selection.query.isEmpty)
        selection.reveal = nil
        controller.open(tab: .general, reveal: .reviewFloor)
        #expect(selection.tab == .lead && selection.reveal == "floor-project")
        selection.reveal = nil
        controller.open(tab: .wallet)
        #expect(selection.tab == .wallet && selection.reveal == nil)
        // The composer's Open Settings… when dictation has no key: at the key, and both apps wire it so.
        selection.reveal = nil
        controller.open(tab: .general, reveal: .dictationKey)
        #expect(selection.tab == .dictation && selection.reveal == "dictation-key")
        for file in ["AppDelegate.swift", "Sandbox.swift"] {
            let source = try Self.read("Sources/VibeSwitcher/" + file)
            let line = try #require(source.split(separator: "\n").first { $0.contains("controller.openSettings = ") }, "\(file)")
            #expect(line.contains(".dictation") && line.contains("reveal: .dictationKey"), "\(file): \(line)")
        }
        // --settings TAB: the new names, and the old one renamed.
        #expect(SettingsTab(rawValue: "terminal") == .appearance && SettingsTab(rawValue: "appearance") == .appearance)
        #expect(SettingsTab(rawValue: "nonsense") == nil)
        #expect(SettingsSection(rawValue: "boost")?.option == "boost-mode" && SettingsSection(rawValue: "review-floor")?.option == "floor-project")
    }

    /// VoiceOver: the sidebar, search field and results are named.
    @Test func theSidebarSearchAndResultsAreLabelled() throws {
        let source = try Self.read("Sources/VibeSwitcher/SettingsCatalog.swift")
        for label in ["accessibilityLabel(\"Search settings\")", "accessibilityLabel(\"Settings categories\")",
                      "accessibilityLabel(\"Search results\")", "accessibilityLabel(\"Clear search\")"] {
            #expect(source.contains(label), "\(label)")
        }
        #expect(source.contains(".accessibilityHint(option.description)"))
    }

    /// `scripts/product-inventory.sh` lists every option in the catalog.
    @Test func theInventoryListsEveryOption() {
        let run = Shell.run(executable: "/bin/bash", args: [Self.root.path + "/scripts/product-inventory.sh"], in: Self.root.path)
        #expect(run.ok, "\(run.error)")
        var missing: [String] = []
        for option in SettingsCatalog.all where !run.output.contains("- \(option.section): \(option.title) — ") { missing.append(option.id) }
        #expect(missing.isEmpty, "not in the inventory: \(missing)")
        for tab in SettingsTab.allCases {
            #expect(run.output.contains("\n### \(tab.title)\n- Settings › \(tab.title) — "), "\(tab.title)")
        }
        #expect(!run.output.contains("not found"))
    }
}

/// What Settings says under its sections (`SettingsNote`): short, plain, and with the safety facts still there.
struct SettingsNoteTests {
    static let maxLength = 200
    /// Words from the code that mean nothing to someone reading Settings, matched at the start of a word in any case.
    static let internalTerms = ["VS_HEAVY", "merge_batching", "0755", "sealed", "gate", "heavy_slots", "load_threshold", "mac_max_sessions", "workflow.md", "claude -p"]

    /// Why `text` can't be a footer; empty when it can.
    static func problems(_ text: String) -> [String] {
        var found: [String] = []
        if text.count > maxLength { found.append("\(text.count) characters") }
        if text.contains("\n") { found.append("more than one line") }
        let sentences = text.matches(of: #/[.!?](\s|$)/#).count
        if sentences > 2 { found.append("\(sentences) sentences") }
        for term in internalTerms where text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: term), options: [.regularExpression, .caseInsensitive]) != nil {
            found.append("says \(term)")
        }
        if text.contains("~/") { found.append("names a file path") }
        return found
    }

    @Test func everyFooterIsShortAndPlain() {
        for note in SettingsNote.allCases {
            #expect(Self.problems(note.text).isEmpty, "\(note.rawValue): \(Self.problems(note.text))")
            #expect(!note.text.trimmingCharacters(in: .whitespaces).isEmpty, "\(note.rawValue): nothing to say")
            #expect(SettingsCatalog.all.contains { $0.section == note.section }, "\(note.rawValue): no section \(note.section) in the catalog")
        }
    }

    /// The check itself: last release's Boost footer fails it, and a word that merely contains a term doesn't.
    @Test func theCheckRefusesWhatItIsFor() {
        #expect(Self.problems("VS_HEAVY_CORES follows the slots.") == ["says VS_HEAVY"])
        #expect(Self.problems("Projects whose merge_batching is boost.") == ["says merge_batching"])
        #expect(Self.problems("It's made (0755) for you.") == ["says 0755"])
        #expect(Self.problems("Kept sealed.") == ["says sealed"])
        #expect(Self.problems("A gate holds it.") == ["says gate"])
        #expect(Self.problems("Leads delegate the work.").isEmpty)
        #expect(Self.problems(String(repeating: "a", count: 201)) == ["201 characters"])
        #expect(Self.problems("One. Two. Three.") == ["3 sentences"])
        #expect(Self.problems("Kept in ~/.vibeswitcher/policy.md") == ["names a file path"])
    }

    /// A footer in a pane is a note by construction (`SettingsFooter` takes nothing else); every note is shown somewhere.
    @Test func everyNoteIsShownInAPane() throws {
        let files = SettingsCatalogTests.panes.map(\.file)
        let source = try (files + ["Sources/VibeSwitcher/SettingsNotes.swift"]).map(SettingsCatalogTests.read).joined(separator: "\n")
        for note in SettingsNote.allCases where note.section != "Session host" {
            #expect(source.contains("SettingsFooter(.\(note.rawValue)"), "\(note.rawValue) isn't shown")
        }
        #expect(source.contains("SettingsFooter(.sessionHost("))
        #expect(!source.contains("SettingsFooter(\""))
        // A footer written some other way (FooterText, a plain Text) would slip past the checks above.
        let panes = try files.map(SettingsCatalogTests.read).joined(separator: "\n")
        let footers = panes.matches(of: #/footer:\s*\{\s*(\w+)/#).map { String($0.output.1) }
        #expect(!footers.isEmpty && footers.allSatisfy { $0 == "SettingsFooter" }, "\(footers)")
    }

    /// Every state of the session host has a footer, and the restart that ends sessions says so.
    @Test func theSessionHostsFooterFollowsItsState() {
        #expect(SettingsNote.sessionHost(offer: nil, refused: false) == .hostCurrent)
        #expect(SettingsNote.sessionHost(offer: nil, refused: true) == .hostRefused)
        #expect(SettingsNote.sessionHost(offer: .handOver, refused: false) == .hostHandOver)
        #expect(SettingsNote.sessionHost(offer: .endAndReplace(live: 0), refused: false) == .hostNoSessions)
        #expect(SettingsNote.sessionHost(offer: .endAndReplace(live: 3), refused: false) == .hostEndsSessions)
        #expect(SettingsNote.hostEndsSessions.text.contains("ends every running session"))
        #expect(SettingsNote.hostHandOver.text.contains("keep running"))
    }

    /// The "?" shows the note's help, then what only the moment knows; a note with neither has no button.
    @Test func helpIsTheNotesDetailThenTheLiveOne() {
        #expect(SettingsFooter(.startup).helpText == nil)
        #expect(SettingsFooter(.codex).helpText == SettingsNote.codex.help)
        #expect(SettingsFooter(.hostRefused, detail: "bad proof").helpText == "bad proof")
        #expect(SettingsFooter(.boost, detail: "Live.").helpText == SettingsNote.boost.help! + "\n\nLive.")
    }

    /// Where keys are kept, what Boost does on battery, what a limit holds back, what reaches other services and who
    /// signs: each still said in a footer, a description or a "?".
    @Test func safetyFactsStayReachable() throws {
        func description(_ id: String) throws -> String { try #require(SettingsCatalog.option(id)).description }
        func help(_ note: SettingsNote) throws -> String { try #require(note.help) }
        // Where keys are kept.
        #expect(SettingsNote.dictation.text.contains("login Keychain"))
        #expect(SettingsNote.briefing.text.contains("login Keychain"))
        #expect(try description("dictation-key").contains("login Keychain"))
        #expect(try description("briefing-key").contains("login Keychain"))
        #expect(try help(.briefing).contains("ELEVENLABS_API_KEY") && help(.briefing).contains("held in memory only"))
        // What leaves the Mac.
        #expect(SettingsNote.dictation.text.contains("goes to OpenAI"))
        #expect(try help(.dictation).contains("no recording is kept"))
        #expect(SettingsNote.briefing.text.contains("goes to ElevenLabs"))
        // Boost on battery.
        #expect(SettingsNote.boost.text.contains("on battery it stays off"))
        #expect(try help(.boost).contains("\(Boost.batteryFloor) %") && help(.boost).contains("battery limit"))
        #expect(try description("boost-on-battery").contains("\(Boost.batteryFloor) %"))
        // What a limit holds back.
        #expect(SettingsNote.macLimits.text.contains("start nothing new") && SettingsNote.macLimits.text.contains("Merges wait"))
        #expect(try help(.usageLimits).contains("\(Int(AccountUsage.threshold)) %"))
        #expect(SettingsNote.usageLimits.text.contains("still stops"))
        #expect(SettingsNote.power.text.contains("nothing new starts"))
        // What keeps work running overnight, and what doesn't whatever Keep Awake says.
        #expect(try help(.power).contains("on AC power with the lid open, or with an external display connected"))
        #expect(try help(.power).contains("A closed lid sleeps whatever this setting says"))
        #expect(try description("battery-hold").contains("start no new work and merge nothing"))
        // What only you can do.
        #expect(SettingsNote.shells.text.contains("nothing runs until you press Run") && SettingsNote.shells.text.contains("any command as you"))
        #expect(try help(.shells) == AgentsSettings.openShellsHelp)
        #expect(SettingsNote.walletManager.text.contains("VibeSwitcher never signs"))
        #expect(SettingsNote.reviewFloor.text.contains("never looser"))
    }

    /// The "?" is a named button, for VoiceOver and for the pointer.
    @Test func theHelpButtonIsLabelled() throws {
        let source = try SettingsCatalogTests.read("Sources/VibeSwitcher/SettingsNotes.swift")
        #expect(source.contains(#".accessibilityLabel("More about \(note.section)")"#) && source.contains(#".help("More about \(note.section)")"#))
    }
}

/// The stored keys behind Settings' controls, named so a rename or a move can't change them unnoticed.
struct SettingsStoredKeysTests {
    let temp = Scratch()

    /// (key in the app's defaults, what changing the control stores) for every Preferences-backed control.
    static let keys: [(key: String, change: (Preferences) -> Void)] = [
        ("notifyNeedsInput", { $0.notifyNeedsInput = false }),
        ("notifyDone", { $0.notifyDone = false }),
        ("playSound", { $0.playSound = false }),
        ("notifyReminders", { $0.notifyReminders = false }),
        ("minimizeOnPause", { $0.minimizeOnPause = false }),
        ("sidebarMode", { $0.sidebarMode = true }),
        ("sidebarAutoHide", { $0.sidebarAutoHide = false }),
        ("sidebarFlashOnSwitch", { $0.sidebarFlashOnSwitch = false }),
        ("sessionOrder", { $0.sessionOrder = SessionOrder.allCases.last! }),
        ("floatingPanel", { $0.floatingPanel = .always }),
        ("terminalAppearance", { $0.appearance.fontSize = 18 }),
        ("openWindowAtLaunch", { $0.openWindowAtLaunch = true }),
        ("aiSummaries", { $0.aiSummaries = false }),
        ("leadRotation", { $0.leadRotation = .never }),
        ("leadMail", { $0.leadMail = false }),
        ("keepAwake", { $0.keepAwake = .always }),
        ("batteryHoldBelow", { $0.batteryHoldBelow = 20 }),
        ("boostMode", { $0.boostMode = .on }),
        ("boostOnBattery", { $0.boostOnBattery = true }),
        ("boostLimits", { $0.boostLimits.maxWorkers = 3 }),
        ("projectsFolder", { $0.projectsFolder = "~/elsewhere" }),
        ("briefingLanguage", { $0.briefingLanguage = "es" }),
        ("walletPeerID", { $0.walletPeerID = "0a1b2c3d" }),
        ("walletPassagePath", { $0.walletPassagePath = "/bin/ls" }),
        ("letAgentsOpenShells", { $0.letAgentsOpenShells = true }),
    ]

    @Test func eachControlStillReadsAndWritesItsKey() throws {
        for (key, change) in Self.keys {
            let defaults = temp.defaults("settings-keys-\(key)")
            let preferences = Preferences(defaults: defaults, presetsFile: temp.url("presets-\(key)"))
            let before = defaults.object(forKey: key)
            change(preferences)
            let after = try #require(defaults.object(forKey: key), "\(key): nothing written")
            #expect(String(describing: before) != String(describing: after), "\(key): not changed")
            // A fresh Preferences on the same defaults reads it back.
            let again = Preferences(defaults: defaults, presetsFile: temp.url("presets-\(key)"))
            #expect(String(describing: again.storedValue(key)) == String(describing: preferences.storedValue(key)), "\(key)")
        }
        // The lead tool server reads this key by name.
        #expect(LeadMail.enabledKey == "leadMail")
    }

    @Test func theDefaultsAreUnchanged() {
        let preferences = Preferences(defaults: temp.defaults("settings-defaults"), presetsFile: temp.url("settings-defaults-presets"), reduceMotion: false)
        #expect(preferences.notifyNeedsInput && preferences.notifyDone && preferences.playSound && preferences.notifyReminders)
        #expect(preferences.minimizeOnPause && preferences.sidebarAutoHide && preferences.sidebarFlashOnSwitch && preferences.aiSummaries && preferences.leadMail)
        #expect(!preferences.sidebarMode && !preferences.openWindowAtLaunch && !preferences.boostOnBattery && !preferences.letAgentsOpenShells)
        #expect(preferences.sessionOrder == .screen && preferences.floatingPanel == .automatic)
        #expect(preferences.keepAwake == .onPower && preferences.leadRotation == .context && preferences.boostMode == .off)
        #expect(preferences.batteryHoldBelow == PowerWatch.defaultLimit && preferences.projectsFolder == ProjectCreation.defaultLocation)
        #expect(preferences.walletPeerID.isEmpty && preferences.walletPassagePath.isEmpty)
    }

    /// Phone access keeps its four keys; it writes them in the app's own defaults, so they're checked by name in the source.
    @Test func phoneAccessKeepsItsKeys() throws {
        let source = try SettingsCatalogTests.read("Sources/VibeSwitcher/PhoneAccess.swift")
        for (property, key) in [("enabled", "phoneAccessEnabled"), ("inputAllowed", "phoneInputAllowed"),
                                ("devPagesAllowed", "phoneDevPagesAllowed"), ("pushOnlyWhenAway", "phonePushOnlyWhenAway")] {
            #expect(source.contains("defaults.set(\(property), forKey: \"\(key)\")"), "\(key): not written")
            #expect(source.contains("\(property) = defaults.bool(forKey: \"\(key)\")"), "\(key): not read")
        }
    }

    /// Dictation's controls write these keys, by these names, and read them back.
    @Test func dictationKeepsItsKeys() throws {
        let defaults = temp.defaults("settings-dictation-keys")
        func controller() -> DictationController {
            DictationController(keyStore: AppProof.MemorySecret(), recorder: SandboxRecorder(), microphone: SandboxMicrophone(),
                                defaults: defaults, findKey: { nil })
        }
        let first = controller()
        let model = try #require(OpenAITranscription.models.first { $0 != first.model })
        first.model = model
        first.holdSpace = false
        first.silenceMac = false
        #expect(defaults.string(forKey: "dictationModel") == model)
        #expect(defaults.object(forKey: "dictationHoldSpace") as? Bool == false)
        #expect(defaults.object(forKey: "dictationSilenceMac") as? Bool == false)
        let again = controller()
        #expect(again.model == model && !again.holdSpace && !again.silenceMac)
    }

    /// mac-limits.json's keys, and values set by hand in the file (the memory holds have no control) kept when another is changed in Settings.
    @Test func macLimitsKeepTheirKeysAndWhatWasSetByHand() throws {
        let file = temp.url("limits").appendingPathComponent("mac-limits.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"heavySlots":1,"ignoreUsageLimits":true,"loadThreshold":17.5,"maxSessions":33,"memoryPressure":"off","swapOutRate":12.5}"#.utf8).write(to: file)
        let editor = MacLimitsEditor(file: file)
        #expect(editor.maxSessions == 33 && editor.loadThreshold == 17.5 && editor.heavySlots == 1 && editor.ignoreUsageLimits)
        editor.maxSessions = 34
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Set(stored.keys) == ["maxSessions", "loadThreshold", "heavySlots", "ignoreUsageLimits", "memoryPressure", "swapOutRate"])
        #expect(stored["memoryPressure"] as? String == "off" && stored["swapOutRate"] as? Double == 12.5)
        #expect(stored["maxSessions"] as? Int == 34 && stored["loadThreshold"] as? Double == 17.5)
        #expect(stored["heavySlots"] as? Int == 1 && stored["ignoreUsageLimits"] as? Bool == true)
        // Validation stays: 0 sessions is 1.
        editor.maxSessions = 0
        #expect(editor.maxSessions == 1)
    }

    /// The floor's rows edit the same fields the vault keeps, and what Save stores is what the rows say.
    @Test func theFloorRowsStillEditTheFloorsFields() {
        let editor = ReviewFloorEditor(projects: { [] }, inline: true)
        editor.sensitive = "src/, docs/"
        editor.strict = "keys/"
        editor.finders = 2
        editor.policy = .askAll
        editor.riskLines = 50
        editor.riskModel = true
        editor.verifierDifferent = false
        editor.samplePercent = 25
        let floor = editor.edited
        #expect(floor.sensitivePaths == ["src/", "docs/"] && floor.strictPaths == ["keys/"])
        #expect(floor.auditFinders == 2 && floor.mergePolicy == .askAll && floor.riskLines == 50)
        #expect(floor.riskModel && !floor.verifierDifferent && floor.auditSamplePercent == 25)
    }
}

private extension Preferences {
    /// What a key holds, read through the property its control binds.
    func storedValue(_ key: String) -> Any {
        switch key {
        case "notifyNeedsInput": return notifyNeedsInput
        case "notifyDone": return notifyDone
        case "playSound": return playSound
        case "notifyReminders": return notifyReminders
        case "minimizeOnPause": return minimizeOnPause
        case "sidebarMode": return sidebarMode
        case "sidebarAutoHide": return sidebarAutoHide
        case "sidebarFlashOnSwitch": return sidebarFlashOnSwitch
        case "sessionOrder": return sessionOrder
        case "floatingPanel": return floatingPanel
        case "terminalAppearance": return appearance.fontSize
        case "openWindowAtLaunch": return openWindowAtLaunch
        case "aiSummaries": return aiSummaries
        case "leadRotation": return leadRotation
        case "leadMail": return leadMail
        case "keepAwake": return keepAwake
        case "batteryHoldBelow": return batteryHoldBelow
        case "boostMode": return boostMode
        case "boostOnBattery": return boostOnBattery
        case "boostLimits": return boostLimits.maxWorkers
        case "projectsFolder": return projectsFolder
        case "briefingLanguage": return briefingLanguage
        case "walletPeerID": return walletPeerID
        case "walletPassagePath": return walletPassagePath
        case "letAgentsOpenShells": return letAgentsOpenShells
        default: return ""
        }
    }
}
