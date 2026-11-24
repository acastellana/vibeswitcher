import Foundation
import VibeCore

/// The node's settings (the parity table's gap 9): what the app's Settings changes, read and set without editing a
/// file by hand. `vibeswitcher settings [FOLDER]` shows them (`settings`, a read) and `vibeswitcher set [FOLDER] KEY
/// VALUE` changes one (`set`, the user's voice). Which keys exist, their defaults and limits follow the app's panes
/// (Sources/VibeSwitcher: `MacLimitsSettings.swift`, `WorkingPolicySettings.swift`, `ReviewFloorSettings.swift`,
/// `SettingsWindow.swift`'s Project lead and Boost rows) and the lead's `configure` (`LeadToolset.swift`).
///
/// - The node's own, under its root, as the leads' tool servers read them at each call: the machine-wide limits and
///   Ignore usage limits (`node-limits.json`, `MacLimits`), Boost's mode and limits and whether leads message each other
///   (`settings.plist`, the app's defaults' keys: `boostMode`, `boostLimits`, `leadMail`), the working policy
///   (`policy.md`, `WorkingPolicy`).
/// - A project's: the models and max_workers in its `.vibeswitcher/workflow.md`, written as configure writes them (the
///   lead's lock, the read back), with a guard rail's hash recorded in the vault as the user's (as the app's
///   `vault.setGuardedSettings`), so merge and start_worker don't refuse it as a worker's edit; and the review rules'
///   floor, kept in the host's vault (`LeadVault.setReviewFloor`, as the app's floor editor).
///
/// What the app has and a node doesn't is in `leftOut`, with why.
public enum NodeSettings {
    public enum Scope: String, Sendable { case node, project }

    /// How a value is written.
    public enum Form: String, Sendable {
        /// on or off.
        case flag
        /// A whole number in `range`.
        case count
        /// A number above 0 (and at most `ceiling`).
        case number
        /// One of `choices`.
        case choice
        /// A model's name as `claude --model` takes it.
        case model
        /// Globs, comma-separated.
        case paths
        /// Free text, lines and all.
        case text
        /// A folder: a full path, or one under `~`.
        case folder
    }

    /// Where a setting is kept.
    public enum Home: String, Sendable {
        /// `<node root>/node-limits.json` (`MacLimits.fileName`; the Mac's `mac-limits.json` its alias).
        case limits
        /// `<node root>/settings.plist`.
        case preferences
        /// `<node root>/policy.md`.
        case policy
        /// `<project>/.vibeswitcher/workflow.md`.
        case workflow
        /// The session host's vault.
        case floor
        /// The session host's vault, a feature plugin's (`PluginRegistry`): listed while its plugin is on.
        case plugin
        /// The session host's vault: acting from the page (`ActingPages`), which no file may say.
        case acting
    }

    /// Whether an acting page may set a setting.
    public enum Page: Equatable, Sendable {
        case sets
        /// Only lower than it is now (its choices lowest first; default the lowest): raising it is the terminal's, why.
        case lowersOnly(String)
        /// The terminal's alone: why.
        case terminalOnly(String)
    }

    public struct Setting: Equatable, Sendable {
        public let key: String
        public let title: String
        /// One plain sentence: what it does.
        public let about: String
        /// The heading it sits under, as the app's pane says it.
        public let section: String
        public let scope: Scope
        public let form: Form
        public let home: Home
        /// Whether an acting page may set it (acting from the page, the web UI design's step 2): every setting says, so a
        /// new one can't be a page's by being left out; `Requests.pageSetRefusal` asks it of the setting `set` resolves.
        public let page: Page
        public var choices: [String] = []
        /// A count's least and most.
        public var range: ClosedRange<Int>? = nil
        /// A number's most.
        public var ceiling: Double? = nil
        /// One of workflow.md's guard rails (`LeadVault.guardedKeys`): its hash is recorded in the vault as the user's.
        public var guardRail: Bool { home == .workflow && LeadVault.guardedKeys.contains(key) }
    }

    // MARK: The catalog

    /// Every setting, in the order the page and the command line show them.
    public static var all: [Setting] {
        let cores = MacLoad.processors
        return [
            Setting(key: "projects_folder", title: "Projects folder",
                    about: "Where `vibeswitcher new-project` makes a project when --in names no other place.",
                    section: "General", scope: .node, form: .folder, home: .preferences, page: .sets),
            Setting(key: "web_acts", title: "Act from the page",
                    about: "How far a page on this machine, its pairing confirmed in a terminal, may act as you: off (it reads and drafts), confirm (each act asks for your passkey; not built yet), trust (each click acts as you). "
                        + "Trust risks this: whatever holds the page's two secrets while it is open acts as you, a team's own session included. Raised from a terminal only.",
                    section: "General", scope: .node, form: .choice, home: .acting, page: .lowersOnly("acting from the page is raised from a terminal"),
                    choices: ActingPages.levels),
            Setting(key: "node_max_sessions", title: "Team sessions on this node, at most",
                    about: "How many workers and verifiers, across every project, may run at once.",
                    section: "Machine-wide limits", scope: .node, form: .count, home: .limits, page: .sets, range: 1...99),
            Setting(key: "load_threshold", title: "Start nothing above a load of",
                    about: "Leads start nothing while the load is above this; default means twice the cores (\(2 * cores)).",
                    section: "Machine-wide limits", scope: .node, form: .number, home: .limits, page: .sets),
            Setting(key: "node_heavy_slots", title: "Test and build slots at once",
                    about: "How many builds and full test runs may run at once on this node.",
                    section: "Machine-wide limits", scope: .node, form: .count, home: .limits, page: .sets, range: 1...MacLimits.heavySlotsCeiling),
            Setting(key: "ignore_usage_limits", title: "Ignore usage limits",
                    about: "Leads keep starting work at any share of a Claude limit, instead of stopping at \(Int(AccountUsage.threshold)) %.",
                    section: "Usage limits", scope: .node, form: .flag, home: .limits, page: .sets),
            Setting(key: "boost", title: "Boost",
                    about: "Raises the machine-wide limits for more throughput. On a node Automatic acts as Off: it can't tell whether you're away.",
                    section: "Boost", scope: .node, form: .choice, home: .preferences, page: .sets, choices: BoostMode.allCases.map(\.rawValue)),
            Setting(key: "boost_load_threshold", title: "Start nothing above a load of, while boosted",
                    about: "While boosted, leads start nothing once the load is above this.",
                    section: "Boost", scope: .node, form: .number, home: .preferences, page: .sets, ceiling: BoostLimits.loadCeiling),
            Setting(key: "boost_max_sessions", title: "Team sessions while boosted, at most",
                    about: "How many workers and verifiers may run at once across every project while boosted.",
                    section: "Boost", scope: .node, form: .count, home: .preferences, page: .sets, range: 1...BoostLimits.countCeiling),
            Setting(key: "boost_max_workers", title: "Workers per project while boosted, at most",
                    about: "The most workers any one project may run at once while boosted.",
                    section: "Boost", scope: .node, form: .count, home: .preferences, page: .sets, range: 1...BoostLimits.countCeiling),
            Setting(key: "boost_heavy_slots", title: "Test and build slots while boosted",
                    about: "How many builds and full test runs may run at once while boosted.",
                    section: "Boost", scope: .node, form: .count, home: .preferences, page: .sets, range: 1...BoostLimits.slotCeiling),
            Setting(key: "lead_mail", title: "Let project leads message each other",
                    about: "Lets one project's lead send messages to another's (tell_lead).",
                    section: "Leads", scope: .node, form: .flag, home: .preferences, page: .terminalOnly("it opens one project's lead to another's messages")),
            Setting(key: "prompt_audit", title: "Remind me to run a prompt audit",
                    about: "Says in status when a project's lead should run /doctor prompt-audit: after the days below, or when its model changes.",
                    section: "Leads", scope: .node, form: .flag, home: .preferences, page: .sets),
            Setting(key: "prompt_audit_days", title: "Days between prompt audits",
                    about: "How many days after a project's last prompt audit its reminder shows.",
                    section: "Leads", scope: .node, form: .count, home: .preferences, page: .sets, range: PromptAudit.intervalRange),
            Setting(key: "ai_summaries", title: "AI summaries",
                    about: "A small model (Haiku) writes one plain line of what each worker and verifier is doing, for the board; at most one an agent every 3 minutes.",
                    section: "Leads", scope: .node, form: .flag, home: .preferences, page: .sets),
            Setting(key: "policy", title: "Working policy",
                    about: "The rules every project's lead, workers and verifiers get in their prompts; running leads are told when it changes.",
                    section: "Working policy", scope: .node, form: .text, home: .policy, page: .terminalOnly("the rules every agent works under: a page's token would loosen its own")),
            Setting(key: "lead_model", title: "The lead's model",
                    about: "The model the project's lead runs on (Opus in Fable's place while Fable is held back); from its next start.",
                    section: "Models", scope: .project, form: .model, home: .workflow, page: .sets),
            Setting(key: "lead_advisor", title: "The lead's advisor",
                    about: "The lead's advisor while it runs on Opus: fable, opus or none; from its next start.",
                    section: "Models", scope: .project, form: .choice, home: .workflow, page: .sets, choices: LeadLaunch.advisorChoices),
            Setting(key: "worker_advisor", title: "Workers' advisor",
                    about: "Every worker's advisor when its task sets none: none, fable or opus.",
                    section: "Models", scope: .project, form: .choice, home: .workflow, page: .sets, choices: ["none", "fable", "opus"]),
            Setting(key: "verifier_model", title: "Verifier's model",
                    about: "The model audits run on; default means another model than the workers', at least as capable.",
                    section: "Models", scope: .project, form: .model, home: .workflow, page: .terminalOnly("what reviews the work: a page's token would choose a weaker review of its own")),
            Setting(key: "security_audit_model", title: "Security audits' model",
                    about: "The model a sensitive or security audit runs on, whatever the verifier's model is.",
                    section: "Models", scope: .project, form: .model, home: .workflow, page: .terminalOnly("what audits sensitive work (a guard rail): a page's token would choose its own audit")),
            Setting(key: "lead_rotation", title: "Start a fresh lead session",
                    about: "When the lead's session is started anew, so it keeps working with a clear context: daily, when its context is large, or never.",
                    section: "Models", scope: .project, form: .choice, home: .workflow, page: .sets, choices: LeadRotationMode.allCases.map(\.rawValue)),
            Setting(key: "max_workers", title: "Workers at once, at most",
                    about: "How many workers the project's lead may run at once.",
                    section: "Team", scope: .project, form: .count, home: .workflow, page: .terminalOnly("a guard rail, recorded in the vault as yours"), range: 1...99),
            Setting(key: "floor_sensitive_paths", title: "Sensitive paths",
                    about: "Paths whose changes always count as sensitive; a lead can add to these, never remove them.",
                    section: "Review rules floor", scope: .project, form: .paths, home: .floor, page: .terminalOnly("a review rule's floor: a page's token would lower what holds its own merge")),
            Setting(key: "floor_strict_paths", title: "Strict paths",
                    about: "Paths whose changes get the strictest review; a lead can add to these, never remove them.",
                    section: "Review rules floor", scope: .project, form: .paths, home: .floor, page: .terminalOnly("a review rule's floor: a page's token would lower what holds its own merge")),
            Setting(key: "floor_audit_finders", title: "Audit finders, at least",
                    about: "The fewest independent checkers an audit may use in this project.",
                    section: "Review rules floor", scope: .project, form: .count, home: .floor, page: .terminalOnly("a review rule's floor: a page's token would lower what holds its own merge"), range: 1...LeadWorkflow.maxFinders),
            Setting(key: "floor_merge_policy", title: "Merge policy, at least",
                    about: "How much approval a merge needs at minimum, from automatic to asking you every time.",
                    section: "Review rules floor", scope: .project, form: .choice, home: .floor, page: .terminalOnly("a review rule's floor: a page's token would lower what holds its own merge"),
                    choices: LeadWorkflow.MergePolicy.allCases.map(\.rawValue)),
            Setting(key: "floor_risk_lines", title: "Risk lines, at most",
                    about: "A change bigger than this many lines counts as risky; 0 sets no floor, and the project's own limit applies.",
                    section: "Review rules floor", scope: .project, form: .count, home: .floor, page: .terminalOnly("a review rule's floor: a page's token would lower what holds its own merge"), range: 0...1_000_000),
            Setting(key: "floor_risk_model", title: "Risk check's model pass",
                    about: "Keeps the model's second look at a change's risk switched on.",
                    section: "Review rules floor", scope: .project, form: .flag, home: .floor, page: .terminalOnly("a review rule's floor: a page's token would lower what holds its own merge")),
            Setting(key: "floor_audit_sample_percent", title: "Audit sample, at least",
                    about: "The smallest share of finished work, in percent, that gets audited.",
                    section: "Review rules floor", scope: .project, form: .count, home: .floor, page: .terminalOnly("a review rule's floor: a page's token would lower what holds its own merge"), range: 0...100),
            Setting(key: "floor_verifier_different", title: "Verifier never on the workers' model",
                    about: "Keeps audits on a different model from the one the workers use.",
                    section: "Review rules floor", scope: .project, form: .flag, home: .floor, page: .terminalOnly("a review rule's floor: a page's token would lower what holds its own merge")),
        ]
    }

    public static func setting(_ key: String) -> Setting? {
        let key = aliases[key] ?? key
        return all.first { $0.key == key }
    }

    /// The app's names for the machine-wide limits (`mac_max_sessions`, `mac_heavy_slots`, as workflow.md, the lead's
    /// tools and the Mac's Settings say them), taken as the node's (`node_…`): `set` takes either. The file is
    /// `node-limits.json` on a node (`MacLimits.fileName`), the Mac's `mac-limits.json` read while it isn't there and
    /// written with it while that is there.
    public static let aliases = ["mac_max_sessions": "node_max_sessions", "mac_heavy_slots": "node_heavy_slots"]

    /// The app's settings a node leaves out, and why.
    public static let leftOut: [(title: String, why: String)] = [
        ("Also on battery (Boost)", "a node runs on mains: it reads no battery"),
        ("Battery hold, keep awake, memory benches", "the Mac's power and the app's own process"),
        ("Notifications (banners, sound, reminders)", "the page's own: This node's toggle, in each browser"),
        ("Let agents open shells without asking", "a node has none: every agent's shell request is a card the user answers in a terminal (the shell plugin, `ShellPlugin`)"),
        ("Appearance, sidebar, launch presets, dictation, phone, wallet", "the Mac app's window and devices"),
        ("Hooks, open at login", "`vibeswitcher hooks install`, `vibeswitcher start --at-login`"),
        ("Mac permissions, the session host", "macOS only; the node's host is `vibeswitcher start` and `stop`"),
    ]

    /// The words that put a setting back to its default.
    public static let resetWords: Set<String> = ["default", ""]

    /// The app's defaults' key for the projects folder (Settings › General), kept as given: a tilde path or a full one.
    public static let projectsFolderKey = "projectsFolder"

    /// Where `new-project` makes a project when `--in` names no other place: the node's `projects_folder`, as kept (a
    /// tilde path or a full one), else the app's default, `~/dev`. Reads the disk.
    public static func projectsFolder(files: Files) -> String {
        let kept = files.preferences?.string(forKey: projectsFolderKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return kept.isEmpty ? ProjectCreation.defaultLocation : kept
    }

    /// The longest working policy taken, in characters.
    public static let policyLimit = 32_000

    // MARK: Where

    /// The node's files, under its root.
    public struct Files: Sendable {
        public var root: URL
        public init(root: URL) { self.root = root }
        public var limits: URL { root.appendingPathComponent(MacLimits.fileName) }
        public var boost: URL { root.appendingPathComponent("boost.json") }
        public var policy: URL { root.appendingPathComponent("policy.md") }
        public var policyTold: URL { root.appendingPathComponent("policy-told.json") }
        public var usage: URL { root.appendingPathComponent("account-usage.json") }
        /// `settings.plist`: what the leads' tool servers read through `Platform.settings` with the node's root as
        /// `VIBESWITCHER_HOME` (the user's node: `~/.vibeswitcher`).
        public var preferencesDomain: String { root.appendingPathComponent("settings").path }
        public var preferences: (any SettingsStore)? { Platform.settings(domain: preferencesDomain) }
    }

    public static func workflowPath(project root: String) -> String { BoardStore(root: root).folder + "/workflow.md" }

    /// Where a setting is kept, as shown.
    public static func place(_ setting: Setting, files: Files, project: String?) -> String {
        switch setting.home {
        case .limits: return files.limits.path
        case .preferences: return files.root.appendingPathComponent("settings.plist").path
        case .policy: return files.policy.path
        case .workflow: return project.map(workflowPath(project:)) ?? ".vibeswitcher/workflow.md"
        case .floor: return "the session host's vault"
        case .plugin: return "the session host's vault (a plugin's setting)"
        case .acting: return "the session host's vault (acting from the page)"
        }
    }

    // MARK: Reading

    /// A setting as it is now.
    public struct Shown: Equatable, Sendable {
        public var setting: Setting
        /// As `set` takes it back.
        public var value: String
        public var defaultValue: String
        public var place: String
        /// Something to know about the value (a floor not recorded yet, the file that couldn't be read).
        public var note: String?

        public var isDefault: Bool { value == defaultValue }
    }

    /// The node's settings as its files have them now. Reads the disk.
    public static func node(files: Files) -> [Shown] {
        let limits = MacLimits.load(from: files.limits)
        let store = files.preferences
        let boost = boostLimits(store)
        // Boost's defaults as this machine keeps them: on a small one the ceilings (4× the cores) are under them.
        let boostDefault = BoostLimits()
        return all.filter { $0.scope == .node }.map { setting in
            let (value, fallback): (String, String) = {
                switch setting.key {
                case "node_max_sessions": return (String(limits.maxSessions), String(MacLimits.defaultMaxSessions))
                case "load_threshold": return (limits.loadThreshold.map(MacLoad.number) ?? "default", "default")
                case "node_heavy_slots": return (String(limits.heavySlots), String(MacLimits.defaultHeavySlots))
                case "ignore_usage_limits": return (flag(limits.ignoreUsageLimits), "off")
                case "boost": return (boostMode(store).rawValue, BoostMode.off.rawValue)
                case "boost_load_threshold": return (MacLoad.number(boost.loadThreshold), MacLoad.number(boostDefault.loadThreshold))
                case "boost_max_sessions": return (String(boost.maxSessions), String(boostDefault.maxSessions))
                case "boost_max_workers": return (String(boost.maxWorkers), String(boostDefault.maxWorkers))
                case "boost_heavy_slots": return (String(boost.heavySlots), String(boostDefault.heavySlots))
                case "lead_mail": return (flag(LeadMail.isOn(store)), "on")
                case "ai_summaries": return (flag(NodeSummaries.isOn(store)), "on")
                case "prompt_audit": return (flag(store.map(PromptAudit.isOn) ?? true), "on")
                case "prompt_audit_days": return (String(store.map(PromptAudit.intervalDays) ?? PromptAudit.defaultIntervalDays), String(PromptAudit.defaultIntervalDays))
                case "policy": return (WorkingPolicy.load(from: files.policy), WorkingPolicy.defaultText)
                case "projects_folder": return (projectsFolder(files: files), ProjectCreation.defaultLocation)
                // Kept in the vault, never a file: `settings` puts in what the vault says (`ActingPages.state`).
                case "web_acts": return ("off", "off")
                default: return ("", "")
                }
            }()
            return Shown(setting: setting, value: value, defaultValue: fallback, place: place(setting, files: files, project: nil))
        }
    }

    /// A project's settings: its workflow.md's (`workflow`) and its floor (`floor`: the vault's; nil while none is
    /// recorded, when the project's values show, as the app's editor shows them; `floorProblem`: why the vault couldn't
    /// say). `workerModel`: the model the workers start with, for the floor shown before one is recorded.
    public static func project(root: String, workflow: LeadWorkflow, floor: LeadReviewFloor?, floorProblem: String? = nil,
                               workerModel: String? = nil, files: Files) -> [Shown] {
        let shownFloor = floor ?? LeadReviewFloor.starting(from: workflow, workerModel: workerModel)
        let none = LeadReviewFloor()
        let floorNote = floorProblem.map { "the session host couldn't say what the floor is (\($0)): the project's values" }
            ?? (floor == nil ? "not recorded yet: the project's values, recorded when you set one or accept its config" : nil)
        return all.filter { $0.scope == .project }.map { setting in
            let (value, fallback): (String, String) = {
                switch setting.key {
                case "lead_model": return (workflow.leadModel, LeadWorkflow.defaultLeadModel)
                case "lead_advisor": return (workflow.leadAdvisor ?? "none", LeadWorkflow.defaultLeadAdvisor)
                case "worker_advisor": return (workflow.workerAdvisor ?? "none", "none")
                case "verifier_model": return ((workflow.verifierModel ?? "").isEmpty ? "default" : workflow.verifierModel ?? "", "default")
                case "security_audit_model": return (workflow.securityAuditModel, LeadWorkflow.defaultSecurityAuditModel)
                case "max_workers": return (String(workflow.maxWorkers), String(LeadWorkflow().maxWorkers))
                case "lead_rotation": return (LeadEngine.rotationMode(workflow).rawValue, LeadRotationMode.context.rawValue)
                default: return floorValue(setting.key, shownFloor, none)
                }
            }()
            return Shown(setting: setting, value: value, defaultValue: fallback, place: place(setting, files: files, project: root),
                         note: setting.home == .floor ? floorNote : nil)
        }
    }

    static func floorValue(_ key: String, _ floor: LeadReviewFloor, _ none: LeadReviewFloor) -> (String, String) {
        let paths = { (globs: [String]) in globs.isEmpty ? "none" : globs.joined(separator: ", ") }
        switch key {
        case "floor_sensitive_paths": return (paths(floor.sensitivePaths), paths(none.sensitivePaths))
        case "floor_strict_paths": return (paths(floor.strictPaths), paths(none.strictPaths))
        case "floor_audit_finders": return (String(floor.auditFinders), String(none.auditFinders))
        case "floor_merge_policy": return (floor.mergePolicy.rawValue, none.mergePolicy.rawValue)
        case "floor_risk_lines": return (String(floor.riskLines), String(none.riskLines))
        case "floor_risk_model": return (flag(floor.riskModel), flag(none.riskModel))
        case "floor_audit_sample_percent": return (String(floor.auditSamplePercent), String(none.auditSamplePercent))
        case "floor_verifier_different": return (flag(floor.verifierDifferent), flag(none.verifierDifferent))
        default: return ("", "")
        }
    }

    static func flag(_ on: Bool) -> String { on ? "on" : "off" }

    static func boostMode(_ store: (any SettingsStore)?) -> BoostMode {
        BoostMode(rawValue: store?.string(forKey: "boostMode") ?? "") ?? .off
    }

    static func boostLimits(_ store: (any SettingsStore)?) -> BoostLimits {
        (store?.object(forKey: "boostLimits") as? Data).flatMap { try? JSONDecoder().decode(BoostLimits.self, from: $0) } ?? BoostLimits()
    }

    // MARK: Taking a value

    /// Why a value isn't taken.
    public struct Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// A value `set` takes for `setting`, in the form it is kept (nil: back to the default).
    public static func parse(_ setting: Setting, _ given: String) -> Result<String?, Refusal> {
        let text = setting.form == .text ? given : given.trimmingCharacters(in: .whitespacesAndNewlines)
        if resetWords.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return .success(nil) }
        switch setting.form {
        case .flag:
            guard let on = LeadWorkflow.flag(text) else {
                return .failure(Refusal("\(setting.key) is on or off"))
            }
            return .success(flag(on))
        case .count:
            let range = setting.range ?? 0...Int.max
            guard let count = Int(text), range.contains(count) else {
                return .failure(Refusal("\(setting.key) is a whole number from \(range.lowerBound) to \(range.upperBound)"))
            }
            return .success(String(count))
        case .number:
            let ceiling = setting.ceiling ?? .greatestFiniteMagnitude
            guard let number = Double(text), number.isFinite, number > 0, number <= ceiling else {
                return .failure(Refusal("\(setting.key) is a number above 0" + (setting.ceiling.map { " and at most \(MacLoad.number($0))" } ?? "")))
            }
            return .success(MacLoad.number(number))
        case .choice:
            let word = setting.key == "floor_merge_policy" ? LeadWorkflow.MergePolicy(text: text)?.rawValue : text.lowercased()
            guard let word, setting.choices.contains(word) else {
                return .failure(Refusal("\(setting.key) is one of \(setting.choices.joined(separator: ", "))"))
            }
            return .success(word)
        case .model:
            // As configure takes a model (`LeadToolset.modelArgument`): one word of claude --model's.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_[]:"))
            guard text.count <= 100, text.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else {
                return .failure(Refusal("\(setting.key) is one word, a model's name as claude --model takes it (fable, opus, sonnet, claude-opus-5-5)"))
            }
            let model = setting.key == "verifier_model" ? text : text.lowercased()
            if setting.key == "security_audit_model", !LeadReviewFloor.knownModel(model) {
                return .failure(Refusal("security_audit_model \(model) doesn't say which model it is (name one: mythos, fable, opus, sonnet, haiku, or its claude-… id)"))
            }
            return .success(model)
        case .paths:
            let globs = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if globs.map({ $0.lowercased() }) == ["none"] { return .success("") }
            guard !globs.contains(where: { $0.contains(where: \.isNewline) }) else { return .failure(Refusal("\(setting.key) is one line")) }
            return .success(globs.joined(separator: ", "))
        case .folder:
            // As the app's field takes it: a full path or a tilde one (`ProjectCreation.expand`), on one line; `~user` isn't.
            guard text.count <= 1_000, !text.contains(where: { $0.isNewline || $0 == "\0" }),
                  text.hasPrefix("/") || text == "~" || text.hasPrefix("~/") else {
                return .failure(Refusal("\(setting.key) is a folder, a full path or one under ~ (~/dev)"))
            }
            return .success(text)
        case .text:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= policyLimit else { return .failure(Refusal("\(setting.key) is at most \(policyLimit) characters")) }
            return .success(trimmed)
        }
    }
}
