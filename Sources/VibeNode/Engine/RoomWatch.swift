import Foundation
import VibeCore

/// The room watch (the engine plan's E7; the app's `watchRoom` and `lookAtRoom`, `LeadController.swift` 1698-1717):
/// a lead whose `start_worker`, audit, merge or `auto_advance` was refused for the machine's room or load (its tool
/// server records the wait under the node's root, `LeadWitness.RoomWaits`) is told once there's room again, as the
/// lead's instructions promise (`LeadWorkflow.swift:1116`): one message a project, as the witness, whichever project's
/// sessions ended to make it. A 60 s client on the engine's clock, the engine plan's one timer besides the refresh and
/// the scan; the waits, the sleep ledger and the memory are read on `reads`, never the engine's queue.
extension LeadEngine: RoomLeads {
    /// Looks once a minute from now on for leads refused for the room or load that have room now. `waits`: the node's
    /// (`<root>/room-waits`, where the leads' tool servers record them) by default. From any thread.
    public func watchRoom() { watchRoom(LeadWitness.RoomWaits(folder: root.appendingPathComponent("room-waits", isDirectory: true))) }

    func watchRoom(_ waits: LeadWitness.RoomWaits) {
        queue.async { [self] in
            room.start(waits)
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
            // The feature plugins (`Plugins/PluginEngine.swift`): each that is on looks every 15 s.
            pluginTimer = clock?.every(Self.pluginLookEvery) { [weak self] in self?.queue.async { self?.lookAtPlugins() } }
        }
    }

    /// The machine has room again (`RoomWatch.look`). On `queue`.
    func lookAtRoom(limits given: MacLimits? = nil) { room.look(limits: given) }

    func roomFound(_ text: String, root: String) { deliver(built: { text }, from: .system("witness"), root: root, action: nil) }
}

/// What the room watch needs of the engine: telling a lead there's room.
protocol RoomLeads: AnyObject {
    /// `text` told to `root`'s lead as the witness. On the engine's queue.
    func roomFound(_ text: String, root: String)
}

/// The room watch's state (the waits, the machine's load and memory as it reads them), its own, on the engine's queue;
/// the waits, the sleep ledger and the memory are read on `reads`.
final class RoomWatch {
    private let queue: DispatchQueue
    private let reads: BoardReads
    private let link: HostLink
    private let root: URL
    /// Who hears there's room: the engine, held weakly.
    weak var leads: RoomLeads?
    /// The leads refused for the machine's room or load (`LeadWitness.RoomWaits`); none until it's started.
    private var waits: LeadWitness.RoomWaits?
    /// The machine's load as the room watch reads it, as the leads' tools judge it (`MacLoad.steady`); faked in tests.
    var load: () -> Double? = MacLoad.steady
    /// Each look's read of the machine's memory (`MacMemory.read`), on the reads queue; faked in tests.
    var memory: () -> MacMemory? = { MacMemory.read() }

    init(queue: DispatchQueue, reads: BoardReads, link: HostLink, root: URL) {
        self.queue = queue
        self.reads = reads
        self.link = link
        self.root = root
    }

    /// The waits looked at from now on. On the engine's queue.
    func start(_ waits: LeadWitness.RoomWaits) {
        EngineWatch.assertOn(queue)
        self.waits = waits
    }

    /// The machine has room again: one message to each lead that was refused for it, as the witness, against every
    /// project's team sessions the host lists and the limits under the node's root (`mac-limits.json`, `boost.json`,
    /// as the leads' tool servers read them). On the engine's queue.
    func look(limits given: MacLimits? = nil) {
        EngineWatch.assertOn(queue)
        guard let waits else { return }
        let mac = MacLoad.count(link.sessions.map { ($0.label, $0.cwd, $0.isLive) }, load: load())
        let (memory, root) = (self.memory, self.root)
        // The wait files and the sleep ledger (and its lock) are read on `reads`.
        reads.async({ _ -> [(root: String, text: String)] in
            var mac = mac
            mac.memory = memory()
            let limits = given ?? MacLimits.current(file: root.appendingPathComponent(MacLimits.fileName),
                                                    boostFile: root.appendingPathComponent("boost.json"))
            return waits.look(mac: mac, limits: limits)
        }) { [weak self] due in
            guard let leads = self?.leads else { return }
            for (root, text) in due { leads.roomFound(text, root: root) }
        }
    }
}
