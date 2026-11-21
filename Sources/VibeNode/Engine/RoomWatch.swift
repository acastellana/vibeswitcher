import Foundation
import VibeCore

/// The room watch (the engine plan's E7; the app's `watchRoom` and `lookAtRoom`, `LeadController.swift` 1698-1717):
/// a lead whose `start_worker`, audit, merge or `auto_advance` was refused for the machine's room or load (its tool
/// server records the wait under the node's root, `LeadWitness.RoomWaits`) is told once there's room again, as the
/// lead's instructions promise (`LeadWorkflow.swift:1116`): one message a project, as the witness, whichever project's
/// sessions ended to make it. A 60 s client on the engine's clock, the engine plan's one timer besides the refresh and
/// the scan; the waits, the sleep ledger and the memory are read on `reads`, never the engine's queue.
extension LeadEngine {
    /// Looks once a minute from now on for leads refused for the room or load that have room now. `waits`: the node's
    /// (`<root>/room-waits`, where the leads' tool servers record them) by default. From any thread.
    public func watchRoom() { watchRoom(LeadWitness.RoomWaits(folder: root.appendingPathComponent("room-waits", isDirectory: true))) }

    func watchRoom(_ waits: LeadWitness.RoomWaits) {
        queue.async { [self] in
            roomWaits = waits
            // The settings' watches look on the same minute (`SettingsWatch.swift`): the policy, then boost, then the room.
            let files = settingsFiles
            policyWatch = LeadWitness.PolicyWatch(read: { WorkingPolicy.load(from: files.policy) }, file: files.policyTold)
            roomTimer = clock?.every(60) { [weak self] in
                guard let engine = self else { return }
                engine.queue.async {
                    engine.lookAtPolicy()
                    engine.lookAtBoost { [weak engine] _ in engine?.lookAtRoom() }
                    engine.lookAtToolchainIfDue()
                }
            }
            // Shell requests (`ShellCards.swift`): the folder looked at every 15 s.
            shellTimer = clock?.every(Self.shellLookEvery) { [weak self] in self?.queue.async { self?.lookAtShellRequests() } }
        }
    }

    /// The machine has room again: one message to each lead that was refused for it, as the witness, against every
    /// project's team sessions the host lists and the limits under the node's root (`mac-limits.json`, `boost.json`,
    /// as the leads' tool servers read them). On `queue`.
    func lookAtRoom(limits given: MacLimits? = nil) {
        guard let roomWaits else { return }
        let mac = MacLoad.count(link.sessions.map { ($0.label, $0.cwd, $0.isLive) }, load: macLoad())
        let (memory, root) = (self.memory, self.root)
        // The wait files and the sleep ledger (and its lock) are read on `reads`.
        reads.async({ _ -> [(root: String, text: String)] in
            var mac = mac
            mac.memory = memory()
            let limits = given ?? MacLimits.current(file: root.appendingPathComponent("mac-limits.json"),
                                                    boostFile: root.appendingPathComponent("boost.json"))
            return roomWaits.look(mac: mac, limits: limits)
        }) { [weak self] due in
            for (root, text) in due { self?.deliver(built: { text }, from: .system("witness"), root: root, action: nil) }
        }
    }
}
