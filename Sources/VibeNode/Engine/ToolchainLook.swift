import Foundation
import VibeCore

/// The developer tools notice (`NodeToolchain`; the app's `lookAtToolchain` and `tellToolchainReports`,
/// `LeadController.swift` 1686-1731): on the room watch's minute, every `NodeToolchain.interval` (the first at the first
/// minute with a lead running), each running lead's project's tools are asked their versions on `toolchainReads`, never
/// the engine's queue; a change is told to that project's lead as the witness, and the problems and the day's changes are
/// `status` notices. The record is the node's own, `<node root>/toolchain.json`.
extension LeadEngine {
    var toolchainFile: URL { root.appendingPathComponent("toolchain.json") }

    /// A look when none ran yet, or the last is `NodeToolchain.interval` old. On `queue`.
    func lookAtToolchainIfDue() {
        if let last = toolchainLookedAt, toolchainNow().timeIntervalSince(last) < TimeInterval(NodeToolchain.interval) { return }
        lookAtToolchain()
    }

    /// Looks at each running lead's project's tools now, tells each lead what changed and keeps the notices; `done` once
    /// they're in (a look under way, or no lead running: at once). On `queue`.
    func lookAtToolchain(done: (() -> Void)? = nil) {
        let roots = leadRoots.map { ($0 as NSString).standardizingPath }
        guard !toolchainLooking, !roots.isEmpty else { done?(); return }
        toolchainLooking = true
        toolchainLookedAt = toolchainNow()
        let home = self.home
        let (file, now, tools, queue, note) = (toolchainFile, toolchainNow(), toolchainTools ?? { NodeToolchain.node(home: home) }, self.queue, self.note)
        Self.toolchainReads.async { [weak self] in
            let seen = NodeToolchain.observe(NodeToolchain.Book.load(from: file), roots: roots, now: now, tools: tools())
            do { try seen.book.save(to: file) } catch { note("developer tools: \(file.path) not written: \(error)") }
            queue.async {
                guard let self else { return }
                self.toolchainLooking = false
                self.toolchainNotices = seen.notices
                for (root, text) in seen.told.sorted(by: { $0.key < $1.key }) {
                    note("lead: told \(LeadMail.project(of: root))'s lead its developer tools changed")
                    self.deliver(built: { text }, from: .system("witness"), root: root, action: nil)
                }
                done?()
            }
        }
    }

    /// The tools are asked one look at a time, off every engine's queue (each asks for up to 15 s a tool).
    static let toolchainReads = DispatchQueue(label: "vibenode.lead-engine.toolchain", qos: .utility)
}
