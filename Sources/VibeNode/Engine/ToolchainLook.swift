import Foundation
import VibeCore

/// What the developer tools watch needs of the engine: telling a project's lead what changed.
protocol ToolchainLeads: AnyObject {
    /// `text` told to `root`'s lead as the witness. On the engine's queue.
    func toolchainChanged(_ text: String, root: String)
}

/// The developer tools notice (`NodeToolchain`; the app's `lookAtToolchain` and `tellToolchainReports`,
/// `LeadController.swift` 1686-1731): on the room watch's minute, every `NodeToolchain.interval` (the first at the first
/// minute with a lead running), each running lead's project's tools are asked their versions on `reads`, never the
/// engine's queue; a change is told to that project's lead as the witness, and the problems and the day's changes are
/// `status` notices. The record is the node's own, `<node root>/toolchain.json`. Its state is its own, on the engine's
/// queue.
final class ToolchainWatch {
    /// The tools are asked one look at a time, off every engine's queue (each asks for up to 15 s a tool).
    static let reads = DispatchQueue(label: "vibenode.lead-engine.toolchain", qos: .utility)

    private let queue: DispatchQueue
    private let file: URL
    private let home: String
    private let note: (String) -> Void
    /// Who hears a change: the engine, held weakly.
    weak var leads: ToolchainLeads?
    /// The node's tools as a look asks them (nil: `NodeToolchain.node(home:)` in the engine's home); a test's stand-in.
    var tools: (@Sendable () -> NodeToolchain.Tools)?
    /// The clock a look's interval is judged by (a test's).
    var now: () -> Date = Date.init
    private var lookedAt: Date?
    private var looking = false
    private var found: [String] = []

    init(queue: DispatchQueue, file: URL, home: String, note: @escaping (String) -> Void) {
        self.queue = queue
        self.file = file
        self.home = home
        self.note = note
    }

    /// The notices the last look found. On the engine's queue.
    var notices: [String] {
        EngineWatch.assertOn(queue)
        return found
    }

    /// A look when none ran yet, or the last is `NodeToolchain.interval` old. On the engine's queue.
    func lookIfDue(roots: Set<String>) {
        EngineWatch.assertOn(queue)
        if let last = lookedAt, now().timeIntervalSince(last) < TimeInterval(NodeToolchain.interval) { return }
        look(roots: roots)
    }

    /// Looks at each of `roots` (the running leads' projects) now, tells each lead what changed and keeps the notices;
    /// `done` once they're in (a look under way, or no lead running: at once). On the engine's queue.
    func look(roots given: Set<String>, done: (() -> Void)? = nil) {
        EngineWatch.assertOn(queue)
        let roots = given.map { ($0 as NSString).standardizingPath }
        guard !looking, !roots.isEmpty else { done?(); return }
        looking = true
        lookedAt = now()
        let home = self.home
        let (file, now, tools, note) = (file, now(), tools ?? { NodeToolchain.node(home: home) }, note)
        Self.reads.async { [weak self] in
            let seen = NodeToolchain.observe(NodeToolchain.Book.load(from: file), roots: roots, now: now, tools: tools())
            do { try seen.book.save(to: file) } catch { note("developer tools: \(file.path) not written: \(error)") }
            self?.queue.async {
                guard let self else { return }
                self.looking = false
                self.found = seen.notices
                if let leads = self.leads {
                    for (root, text) in seen.told.sorted(by: { $0.key < $1.key }) { leads.toolchainChanged(text, root: root) }
                }
                done?()
            }
        }
    }
}

extension LeadEngine: ToolchainLeads {
    /// The notices the developer tools watch's last look found (`status`).
    public var toolchainNotices: [String] { toolchain.notices }

    /// A look at the running leads' tools when one is due (the room watch's minute). On `queue`.
    func lookAtToolchainIfDue() { toolchain.lookIfDue(roots: leadRoots) }

    /// A look at the running leads' tools now; `done` once its notices are in. On `queue`.
    func lookAtToolchain(done: (() -> Void)? = nil) { toolchain.look(roots: leadRoots, done: done) }

    func toolchainChanged(_ text: String, root: String) {
        note("lead: told \(LeadMail.project(of: root))'s lead its developer tools changed")
        deliver(built: { text }, from: .system("witness"), root: root, action: nil)
    }
}
