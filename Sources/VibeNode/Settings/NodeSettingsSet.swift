import Foundation
import VibeCore

/// Changing one setting (`set`, the user's voice: `Requests` judged the voice and recorded the request before this
/// runs). Each writes where the app writes it, so the leads' tool servers read it at their next call; a project's
/// change carries the words its running lead is told.
extension NodeSettings {
    /// What a change did.
    public struct Applied: Equatable, Sendable {
        public var key: String
        /// The value now, as `settings` shows it.
        public var value: String
        /// The value before.
        public var was: String
        /// What the project's running lead is told (nil: nothing: the node's settings are read at each call, and the
        /// policy is told by the engine's policy watch).
        public var told: String?
    }

    /// Sets one of the node's own settings (`files`, under its root). Reads and writes the disk.
    public static func setNode(_ setting: Setting, to value: String?, files: Files) throws -> Applied {
        precondition(setting.scope == .node)
        let was = node(files: files).first { $0.setting.key == setting.key }?.value ?? ""
        switch setting.home {
        case .limits:
            var limits = MacLimits.load(from: files.limits)
            switch setting.key {
            case "mac_max_sessions": limits.maxSessions = value.flatMap(Int.init) ?? MacLimits.defaultMaxSessions
            case "load_threshold": limits.loadThreshold = value.flatMap(Double.init)
            case "mac_heavy_slots": limits.heavySlots = value.flatMap(Int.init) ?? MacLimits.defaultHeavySlots
            case "ignore_usage_limits": limits.ignoreUsageLimits = value == "on"
            default: throw Refusal("\(setting.key) isn't kept in mac-limits.json")
            }
            // Kept as the leads read it (`MacLimits`'s own bounds).
            try MacLimits(maxSessions: limits.maxSessions, loadThreshold: limits.loadThreshold, heavySlots: limits.heavySlots,
                          ignoreUsageLimits: limits.ignoreUsageLimits, memoryPressure: limits.memoryPressure,
                          swapOutRate: limits.swapOutRate).save(to: files.limits)
        case .preferences:
            guard let store = files.preferences else { throw Refusal("the node's settings file \(files.preferencesDomain).plist can't be opened") }
            switch setting.key {
            case "boost": store.set(value, forKey: "boostMode")
            case "lead_mail": store.set(value.map { $0 == "on" }, forKey: LeadMail.enabledKey)
            case "boost_load_threshold", "boost_max_sessions", "boost_max_workers", "boost_heavy_slots":
                var limits = boostLimits(store)
                let fallback = BoostLimits()
                switch setting.key {
                case "boost_load_threshold": limits.loadThreshold = value.flatMap(Double.init) ?? fallback.loadThreshold
                case "boost_max_sessions": limits.maxSessions = value.flatMap(Int.init) ?? fallback.maxSessions
                case "boost_max_workers": limits.maxWorkers = value.flatMap(Int.init) ?? fallback.maxWorkers
                default: limits.heavySlots = value.flatMap(Int.init) ?? fallback.heavySlots
                }
                let kept = BoostLimits(loadThreshold: limits.loadThreshold, maxSessions: limits.maxSessions, maxWorkers: limits.maxWorkers,
                                       heavySlots: limits.heavySlots)
                store.set(try JSONEncoder().encode(kept), forKey: "boostLimits")
            default: throw Refusal("\(setting.key) isn't kept in settings.plist")
            }
        case .policy:
            try WorkingPolicy.save(value ?? WorkingPolicy.defaultText, to: files.policy)
        case .workflow, .floor:
            throw Refusal("\(setting.key) is a project's")
        }
        let read = node(files: files).first { $0.setting.key == setting.key }
        let now = read?.value ?? ""
        let expected = value ?? read?.defaultValue
        guard now == expected else {
            throw Refusal("wrote \(place(setting, files: files, project: nil)), but \(setting.key) reads back as \"\(now)\", not \"\(expected ?? "")\": check the file")
        }
        return Applied(key: setting.key, value: now, was: was, told: nil)
    }

    /// Sets one of `root`'s settings: its workflow.md's, under the lead's own lock and read back, a guard rail's hash then
    /// recorded in `vault` as the user's; or its review rules' floor, in `vault`. `workerModel`: the model the workers
    /// start with (the floor's verifier check, and the floor shown before one is recorded). Asks the vault: never on the
    /// engine's queue.
    public static func setProject(_ setting: Setting, to value: String?, root: String, vault: LeadVault, workerModel: String?,
                                  files: Files) throws -> Applied {
        precondition(setting.scope == .project)
        let path = workflowPath(project: root)
        guard FileManager.default.fileExists(atPath: path) else {
            throw Refusal("no lead has worked in \(ConfigSeal.inert(root, limit: 300)) yet (it has no .vibeswitcher/workflow.md): "
                          + "`vibeswitcher lead FOLDER` starts one")
        }
        switch setting.home {
        case .workflow: return try setWorkflow(setting, to: value, root: root, path: path, vault: vault, workerModel: workerModel, files: files)
        case .floor: return try setFloor(setting, to: value, root: root, path: path, vault: vault, workerModel: workerModel, files: files)
        default: throw Refusal("\(setting.key) is the node's, not a project's")
        }
    }

    private static func setWorkflow(_ setting: Setting, to value: String?, root: String, path: String, vault: LeadVault, workerModel: String?,
                                    files: Files) throws -> Applied {
        let key = setting.key
        // The floor holds the user too: lower it first (configure's `checkFloor`, for the one rule a workflow key here has).
        if key == "verifier_model", let given = value {
            let floor: LeadReviewFloor?
            do { floor = try vault.reviewFloor(root: root) } catch {
                throw Refusal("nothing was changed: the session host couldn't say what the review rules' floor is (\(error)), "
                              + "so verifier_model can't be checked against it: try again")
            }
            if let why = floor?.refusal(key: key, value: given, workerModel: workerModel) {
                throw Refusal("nothing was changed: \(why). `vibeswitcher set FOLDER floor_verifier_different off` lowers the floor first")
            }
        }
        let wasShown = project(root: root, workflow: LeadWorkflow.load(from: path), floor: nil, files: files).first { $0.setting.key == key }?.value ?? ""
        try exclusively(root: root) {
            let current = FileManager.default.contents(atPath: path) ?? Data(LeadWorkflow.template.utf8)
            let before = LeadWorkflow.load(from: path)
            try LeadWorkflow.write(LeadWorkflow.updating(current, with: [(key, value ?? "")]), to: path)
            let after = LeadWorkflow.load(from: path)
            let read = project(root: root, workflow: after, floor: nil, files: files).first { $0.setting.key == key }
            let expected = value ?? read?.defaultValue
            guard let read, read.value == expected else {
                throw Refusal("wrote workflow.md, but \(key) reads back as \"\(read?.value ?? "")\", not \"\(expected ?? "")\": check the file")
            }
            // The guard rail set here is the user's; the others stay as recorded (any not recorded yet, as they were),
            // as configure records the lead's.
            guard setting.guardRail else { return }
            do {
                let recorded = try vault.guardedSettings(root: root) ?? [:]
                let given = LeadVault.guardedHashes(after).filter { $0.key == key }
                let hashes = LeadVault.guardedHashes(before).filter { recorded[$0.key] == nil }.merging(given) { $1 }
                try vault.setGuardedSettings(hashes, root: root)
            } catch {
                throw Refusal("wrote workflow.md, but the session host didn't record \(key) as yours (\(error)): merge and start_worker "
                              + "refuse it until it does. Run the same `vibeswitcher set` again")
            }
        }
        let now = project(root: root, workflow: LeadWorkflow.load(from: path), floor: nil, files: files).first { $0.setting.key == key }?.value ?? ""
        let effect: String
        switch key {
        case "lead_model", "lead_advisor": effect = "it takes effect when the project's lead next starts (this session keeps its own)"
        case "worker_advisor": effect = "workers started from now on get it"
        case "verifier_model", "security_audit_model": effect = "audits started from now on run on it"
        default: effect = "it holds from your next start_worker"
        }
        let told = "The user set \(key) to \(now) in this project's workflow.md with `vibeswitcher set`"
            + (setting.guardRail ? ", recorded in the vault as theirs" : "") + ": \(effect). Don't change it back with configure unless they ask."
        return Applied(key: key, value: now, was: wasShown, told: told)
    }

    private static func setFloor(_ setting: Setting, to value: String?, root: String, path: String, vault: LeadVault, workerModel: String?,
                                 files: Files) throws -> Applied {
        let workflow = LeadWorkflow.load(from: path)
        let recorded: LeadReviewFloor?
        do { recorded = try vault.reviewFloor(root: root) } catch {
            throw Refusal("nothing was changed: the session host couldn't say what the review rules' floor is (\(error)): try again")
        }
        let shown = { (floor: LeadReviewFloor?) in
            project(root: root, workflow: workflow, floor: floor, workerModel: workerModel, files: files).first { $0.setting.key == setting.key }?.value ?? ""
        }
        var floor = recorded ?? LeadReviewFloor.starting(from: workflow, workerModel: workerModel)
        let none = LeadReviewFloor()
        let globs = { (text: String) in text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        switch setting.key {
        case "floor_sensitive_paths": floor.sensitivePaths = value.map(globs) ?? none.sensitivePaths
        case "floor_strict_paths": floor.strictPaths = value.map(globs) ?? none.strictPaths
        case "floor_audit_finders": floor.auditFinders = value.flatMap(Int.init) ?? none.auditFinders
        case "floor_merge_policy": floor.mergePolicy = value.flatMap(LeadWorkflow.MergePolicy.init(text:)) ?? none.mergePolicy
        case "floor_risk_lines": floor.riskLines = value.flatMap(Int.init) ?? none.riskLines
        case "floor_risk_model": floor.riskModel = value.map { $0 == "on" } ?? none.riskModel
        case "floor_audit_sample_percent": floor.auditSamplePercent = value.flatMap(Int.init) ?? none.auditSamplePercent
        case "floor_verifier_different": floor.verifierDifferent = value.map { $0 == "on" } ?? none.verifierDifferent
        default: throw Refusal("\(setting.key) isn't a rule of the floor")
        }
        // Kept as the vault keeps it (`LeadReviewFloor`'s own bounds).
        floor = LeadReviewFloor(sensitivePaths: floor.sensitivePaths, strictPaths: floor.strictPaths, auditFinders: floor.auditFinders,
                                mergePolicy: floor.mergePolicy, riskLines: floor.riskLines, riskModel: floor.riskModel,
                                verifierDifferent: floor.verifierDifferent, auditSamplePercent: floor.auditSamplePercent)
        let recordedNow: LeadReviewFloor?
        do { recordedNow = try vault.setReviewFloor(floor, root: root) } catch {
            throw Refusal("the session host didn't record the floor (\(error)): nothing was changed")
        }
        guard let saved = recordedNow else { throw Refusal("the session host recorded no floor: nothing was changed. Try again") }
        let now = shown(saved)
        let rule = setting.key.dropFirst("floor_".count)
        let told = "The user set this project's review rules' floor with `vibeswitcher set`: \(rule) is now \(now). configure may raise a rule "
            + "above the floor, never lower one below it; status shows what's in force."
        return Applied(key: setting.key, value: now, was: shown(recorded), told: told)
    }

    /// Runs `body` holding the lead's configure lock (`LeadToolset.exclusively("configure")`: `.vibeswitcher/run/configure.lock`),
    /// so a configure and a `set` don't each write over the other's line.
    static func exclusively(root: String, _ body: () throws -> Void) throws {
        let folder = (BoardStore(root: root).folder as NSString).appendingPathComponent("run")
        try? VibePaths.ensurePrivate(URL(fileURLWithPath: folder, isDirectory: true))
        let path = (folder as NSString).appendingPathComponent("configure.lock")
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Refusal("couldn't open \(path) to take its lock: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Refusal("couldn't take the lock \(path): \(String(cString: strerror(errno)))") }
        }
        defer { flock(fd, LOCK_UN) }
        try body()
    }
}
