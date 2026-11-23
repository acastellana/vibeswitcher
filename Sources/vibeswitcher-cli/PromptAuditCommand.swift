import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher prompt-audit FOLDER snooze|off|on` (the stability lane, 2026-11-20): the reminder `status` gives to
/// run `/doctor prompt-audit` in a project's lead session, snoozed for a week, turned off there, or back on (the app's
/// card's Remind me in a week and Not for this project). The user's voice: shown, the typed code, then the request.
enum PromptAuditCommand {
    static let usage = "usage: vibeswitcher prompt-audit FOLDER snooze|off|on"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2, !arguments[0].hasPrefix("--"), ["snooze", "off", "on"].contains(arguments[1]) else { return Say.usage(usage) }
        let folder = CardCommand.absolute(arguments[0])
        let what: String
        switch arguments[1] {
        case "snooze": what = "This snoozes the prompt-audit reminder for the project in \(ConfigSeal.inert(folder, limit: 200)) for a week."
        case "off": what = "This stops the prompt-audit reminders for the project in \(ConfigSeal.inert(folder, limit: 200))."
        default: what = "This turns the prompt-audit reminders for the project in \(ConfigSeal.inert(folder, limit: 200)) back on."
        }
        return SessionCommand.act(WireKinds.PromptAudit.self, args: { _ in .init(folder: folder, do: arguments[1]) }, what: { _ in what }) { result in
            let project = ConfigSeal.inert(result.project ?? "?", limit: 80)
            switch result.do {
            case "snooze": Say.out("snoozed: no prompt-audit reminder for \(project) until \(ConfigSeal.inert(result.until ?? "?", limit: 40))")
            case "off": Say.out("off: no more prompt-audit reminders for \(project) (`vibeswitcher prompt-audit FOLDER on` brings them back)")
            default: Say.out("on: prompt-audit reminders for \(project) again")
            }
        }
    }
}
