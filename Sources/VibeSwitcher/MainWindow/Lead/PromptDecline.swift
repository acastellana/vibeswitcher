import Foundation
import VibeCore

/// Declines the permission prompt a verifier has waited on past `LeadWitness.promptWait` (see
/// `LeadWitness.stuckPrompts`): its screen read, and the decline's keys typed (`LeadWitness.declinePlan`), each only once
/// the screen shows that prompt with the cursor where the keys so far put it (`LeadWitness.declineMayGo`). A prompt
/// answered meanwhile, or another one opened since, isn't touched, and Enter never lands on a Yes row. When the No row
/// takes no reason, Esc declines it instead (it only ever rejects).
enum PromptDecline {
    enum Outcome: Equatable { case declined, escaped, notDeclined }

    /// How long each key waits for the screen to show what it expects (the last key's redraw).
    static let keyWait: TimeInterval = 5
    static let lookEvery: TimeInterval = 0.1

    /// Declines `stuck`'s prompt and tells the lead once, through `tell` on the main thread (a text built where it's
    /// posted: it quotes what was asked, see `LeadWitness.Notice`).
    static func handle(_ stuck: LeadWitness.StuckPrompt, host: HostClient, tell: @escaping (@escaping @Sendable () -> String) -> Void) {
        decline(stuck, host: host) { outcome in
            DispatchQueue.main.async {
                switch outcome {
                case .declined: tell { LeadWitness.declinedText(stuck) }
                case .escaped: tell { LeadWitness.escapedText(stuck) }
                case .notDeclined: tell { LeadWitness.undeclinedText(stuck) }
                }
            }
        }
    }

    static func decline(_ stuck: LeadWitness.StuckPrompt, host: HostClient, done: @escaping (Outcome) -> Void) {
        guard let id = UUID(uuidString: stuck.session) else { return done(.notDeclined) }
        host.screen(id) { screen in
            guard let screen, let plan = LeadWitness.declinePlan(screen: screen, prompt: stuck.prompt) else { return done(.notDeclined) }
            host.send(id, writes: plan.writes, gate: { step, go in
                wait(id, host: host, until: { LeadWitness.declineMayGo(plan, step: step, screen: $0) }, go)
            }, confirmed: { ok in
                if ok { return done(.declined) }
                // Stopped short (the No row took no reason, or the prompt changed): Esc, while that prompt still shows.
                host.send(id, writes: [LeadWitness.DeclinePlan.escape], gate: { _, go in
                    wait(id, host: host, until: { LeadWitness.escapeMayGo(plan, screen: $0) }, go)
                }, confirmed: { escaped in done(escaped ? .escaped : .notDeclined) })
            })
        }
    }

    /// Reads the screen until `condition` holds (`go(true)`) or `keyWait` passes (`go(false)`).
    private static func wait(_ id: UUID, host: HostClient, until condition: @escaping (String) -> Bool, _ go: @escaping (Bool) -> Void,
                             since: Date = Date()) {
        host.screen(id) { screen in
            if let screen, condition(screen) { return go(true) }
            guard Date().timeIntervalSince(since) < keyWait else { return go(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + lookEvery) { wait(id, host: host, until: condition, go, since: since) }
        }
    }
}
