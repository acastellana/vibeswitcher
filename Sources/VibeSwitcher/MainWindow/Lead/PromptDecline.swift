import Foundation
import VibeCore

/// Declines the permission prompt a verifier has waited on past `LeadWitness.promptWait` (see
/// `LeadWitness.stuckPrompts`): its screen read, the decline's keys typed (`LeadWitness.declineKeys`), each only while
/// the screen still shows that prompt (a user who answered meanwhile isn't overridden: the keys stop).
enum PromptDecline {
    /// Declines `stuck`'s prompt and tells the lead once, through `tell` on the main thread (a text built where it's
    /// posted: it quotes what was asked, see `LeadWitness.Notice`): what was asked and what the verifier was told, or
    /// that it couldn't be declined.
    static func handle(_ stuck: LeadWitness.StuckPrompt, host: HostClient, tell: @escaping (@escaping @Sendable () -> String) -> Void) {
        guard let id = UUID(uuidString: stuck.session) else { return tell { LeadWitness.undeclinedText(stuck) } }
        decline(id, host: host) { declined in
            DispatchQueue.main.async { tell { declined ? LeadWitness.declinedText(stuck) : LeadWitness.undeclinedText(stuck) } }
        }
    }

    /// `done(true)` once the keys went in; false when the screen shows no permission prompt, or it changed meanwhile.
    static func decline(_ id: UUID, host: HostClient, done: @escaping (Bool) -> Void) {
        host.screen(id) { screen in
            guard let screen, let question = question(screen), let keys = LeadWitness.declineKeys(screen: screen) else { return done(false) }
            host.send(id, writes: keys, gate: { _, go in
                host.screen(id) { now in go(now.flatMap(Self.question) == question) }
            }, confirmed: done)
        }
    }

    /// The prompt's text on `screen` (the command included), when it shows one.
    private static func question(_ screen: String) -> String? {
        ScreenMenu.parse(screen.components(separatedBy: "\n"))?.question
    }
}
