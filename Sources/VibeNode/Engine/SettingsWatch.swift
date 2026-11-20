import Foundation
import VibeCore

/// What the engine does with the node's settings (the parity table's gap 9), on the room watch's minute
/// (`RoomWatch.swift`) and at once after a `set`:
///
/// - The working policy is told to each running lead once when it changes (`LeadWitness.PolicyWatch`, the app's
///   `lookAtPolicy`, `LeadController.swift` 1814-1840): as the witness, again once after a compaction the lead's
///   transcript shows, and not to a lead started with it in its prompt (`policyPrompted`). What was told is kept in
///   `<root>/policy-told.json`.
/// - Boost is decided for the leads (`BoostState` in `<root>/boost.json`, which every lead's tool server reads with the
///   limits at each call), as the app's `BoostWatch` decides, from what a node can read: On boosts unless the account's
///   usage holds it off (`Boost.veto`, the usage file under the root); Automatic acts as Off, since a node reads neither
///   the power source nor whether you're away (the design's word for WSL); Off writes off once over a boost.
/// - A change to a project's setting is told to its running lead (`NodeSettings.Applied.told`), from VibeSwitcher.
extension LeadEngine {
    /// The node's files under its root.
    var settingsFiles: NodeSettings.Files { NodeSettings.Files(root: root) }

    /// The working policy to each running lead that hasn't got it. The leads' transcripts (their compactions) and the
    /// told file are read on `reads`. On `queue`.
    func lookAtPolicy() {
        guard let watch = policyWatch else { return }
        let running = Dictionary(leads.leads.values.compactMap { lead in lead.session.map { ($0.uuidString, lead.root) } }) { first, _ in first }
        guard !running.isEmpty else { return }
        let transcripts = Dictionary((sessions?.sessions ?? []).compactMap { session in
            session.hostID.flatMap { id in running[id.uuidString] != nil ? session.transcriptPath.map { (id.uuidString, $0) } : nil }
        }) { first, _ in first }
        reads.async({ _ -> (text: String, leads: [String])? in
            let compactions = transcripts.compactMapValues { TranscriptTail.lastCompaction(url: URL(fileURLWithPath: $0)) }
            return watch.look(running: Array(running.keys), compactions: compactions)
        }) { [weak self] news in
            guard let self, let news else { return }
            for lead in news.leads {
                guard let root = running[lead] else { continue }
                self.note("lead: told \(LeadMail.project(of: root))'s lead the working policy (changed, or not told since its last compaction)")
                self.deliver(built: { news.text }, from: .system("witness"), root: root, action: nil)
            }
        }
    }

    /// The lead on `session` started with the policy in its prompt (a fresh start, not a reopened conversation): it
    /// isn't told it again until it changes. On `queue`.
    func policyPrompted(_ session: UUID) {
        guard let watch = policyWatch else { return }
        let policy = settingsFiles.policy
        reads.async({ _ in watch.started(session.uuidString, with: WorkingPolicy.load(from: policy)) }) { _ in }
    }

    /// Boost as a node decides it: `mode` as set, `veto` the usage limit that holds it off (nil: none).
    static func boostDecision(mode: BoostMode, veto: AccountUsage.Limit?) -> (on: Bool, why: String) {
        switch mode {
        case .off: return (false, "off in Settings")
        case .automatic: return (false, "automatic acts as off on a node: it can't tell whether you're away")
        case .on:
            if let veto { return (false, "held off by the usage watch: \(veto.text)") }
            return (true, "on in Settings")
        }
    }

    /// Decides boost from the node's settings and writes `boost.json` when the decision changed or was written
    /// `BoostState.refresh` ago; nothing while it's off and no boost was ever written on. Read and written on `reads`.
    /// `then` hears on `queue` what was decided. On `queue`.
    func lookAtBoost(then: @escaping (BoostState?) -> Void = { _ in }) {
        let (files, home, now, written) = (settingsFiles, self.home, boostNow(), boostWritten)
        reads.async({ _ -> (state: BoostState?, wrote: Bool, problem: String?) in
            let store = files.preferences
            let mode = NodeSettings.boostMode(store)
            let ignoring = MacLimits.load(from: files.limits).ignoreUsageLimits
            let veto = mode == .on ? Boost.veto(AccountUsageStore(file: files.usage, home: home).load(), now: now, ignoring: ignoring) : nil
            let decided = Self.boostDecision(mode: mode, veto: veto)
            let state = BoostState(on: decided.on, why: decided.why, limits: NodeSettings.boostLimits(store), at: now.timeIntervalSince1970)
            // Off, and nothing on to undo: no file to write (none reads as off).
            if !state.on, written?.state.on != true, BoostState.active(from: files.boost, now: now) == nil { return (state, false, nil) }
            if state.sameAs(written?.state), let at = written?.at, now.timeIntervalSince(at) < BoostState.refresh { return (state, false, nil) }
            do {
                try state.save(to: files.boost)
                return (state, true, nil)
            } catch {
                return (state, false, "\(error)")
            }
        }) { [weak self] result in
            guard let self else { return }
            if result.wrote, let state = result.state {
                if self.boostWritten?.state.on != state.on { self.note("boost: \(state.text)") }
                self.boostWritten = (state, now)
            }
            if let problem = result.problem { self.note("boost: \(files.boost.path) couldn't be written (\(problem)): the leads read the normal limits") }
            then(result.state)
        }
    }

    /// After a `set` of `key`: the policy told at once, boost decided again and the room looked at with the new limits,
    /// a project's change told to its running lead. `then` hears on `queue` whether a lead was told. From any thread.
    public func settingChanged(_ key: String, root: String?, told: String?, then: @escaping (Bool) -> Void = { _ in }) {
        queue.async { [self] in
            switch key {
            case "policy":
                lookAtPolicy()
                return then(!leads.leads.values.allSatisfy { $0.session == nil })
            case _ where key.hasPrefix("boost") || NodeSettings.setting(key)?.home == .limits:
                lookAtBoost { [weak self] _ in self?.lookAtRoom() }
                return then(false)
            default:
                guard let root, let told else { return then(false) }
                leads.update(sessions: link.sessions, holders: holders)
                // A lead that doesn't run reads the file when it starts: nothing is held for it.
                guard leads.leads[NodeIds.project(root: root)]?.session != nil else { return then(false) }
                deliver(built: { told }, from: .system("settings"), root: root, action: nil)
                then(true)
            }
        }
    }
}
