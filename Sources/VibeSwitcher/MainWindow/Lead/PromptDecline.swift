import Foundation
import VibeCore

/// Declines the permission prompt a verifier has waited on past `LeadWitness.promptWait` (see
/// `LeadWitness.stuckPrompts`): its screen read, the decline's keys typed (`LeadWitness.declineKeys`), each only while
/// the screen still shows that prompt (a user who answered meanwhile isn't overridden: the keys stop).
enum PromptDecline {
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
