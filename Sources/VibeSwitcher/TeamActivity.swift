import Foundation
import VibeCore

/// Keeps the app responsive while teams work, without preventing idle system sleep.
/// Called on the main thread at each team refresh; the clock and activity provider are injectable.
final class TeamActivity {
    static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private let now: () -> TimeInterval
    private let delay: TimeInterval
    private var token: NSObjectProtocol?
    private var idleSince: TimeInterval?

    init(delay: TimeInterval = 180, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         begin: @escaping () -> NSObjectProtocol = {
             ProcessInfo.processInfo.beginActivity(options: TeamActivity.options, reason: "a project's team is working")
         }, end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.delay = delay
        self.now = now
        self.begin = begin
        self.end = end
    }

    deinit { release() }

    static func working(hosted: [HostSession], sessions: [Session], heavy: Bool) -> Bool {
        if heavy { return true }
        let census = HostCensus.count(hosted.map { ($0.label, $0.cwd, $0.isLive) })
        if census.contains(where: { $0.role != .lead && $0.sessions > 0 }) { return true }
        let leads = Set(hosted.filter { $0.isLive && LeadTeams.role(label: $0.label) == .lead }.map(\.id))
        return sessions.contains { $0.hostID.map(leads.contains) == true && $0.status == .working }
    }

    private func release() {
        guard let token else { return }
        end(token)
        self.token = nil
        idleSince = nil
        Breadcrumbs.shared.note("team activity: ended App Nap exemption")
    }

    func update(working: Bool) {
        if working {
            idleSince = nil
            if token == nil {
                token = begin()
                Breadcrumbs.shared.note("team activity: began App Nap exemption")
            }
        } else if token != nil {
            let time = now()
            if idleSince == nil { idleSince = time }
            if time - idleSince! >= delay {
                release()
            }
        }
    }
}
