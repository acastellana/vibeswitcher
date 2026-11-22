import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher rename SESSION [NAME]` (the stability lane, 2026-11-20; the app's Rename… and, with no NAME, Reset
/// Name): your name for a session, its headline in `status` and on the page, kept across `--resume`. The user's voice:
/// shown, the typed code, then `session.rename`.
enum RenameCommand {
    static let usage = "usage: vibeswitcher rename SESSION [NAME]  (no NAME: its own name back)"

    static func run(_ arguments: [String]) -> Int32 {
        guard (1...2).contains(arguments.count), !arguments[0].isEmpty, !arguments[0].hasPrefix("--") else { return Say.usage(usage) }
        let name = arguments.count == 2 ? arguments[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return SessionCommand.act(WireKinds.SessionRename.self, lookup: arguments[0], args: { session in
            .init(session: session["id"]?.string ?? arguments[0], name: name)
        }, what: { session in
            name.isEmpty ? "This gives \(SessionCommand.describe(session)) its own name back."
                : "This names \(SessionCommand.describe(session)) \u{201C}\(ConfigSeal.inert(name, limit: SessionMarks.nameLimit))\u{201D}."
        }) { result in
            let short = SessionCommand.short(result.session)
            Say.out(result.name.map { "renamed: session \(short) is \u{201C}\(ConfigSeal.inert($0, limit: SessionMarks.nameLimit))\u{201D}" }
                ?? "renamed: session \(short) has its own name again")
        }
    }
}

/// `vibeswitcher pause SESSION [--hours N | --tomorrow | --off]` (the stability lane, 2026-11-20; the app's Pause menu
/// and Resume Notifications): a session greyed out, nothing reminding or notifying you of it, until you resume it (the
/// default), for N hours, or until tomorrow morning; `--off` resumes it. The user's voice: shown, the typed code, then
/// `session.pause`.
enum PauseCommand {
    static let usage = "usage: vibeswitcher pause SESSION [--hours N | --tomorrow | --off]"

    static func run(_ arguments: [String]) -> Int32 {
        guard let first = arguments.first, !first.isEmpty, !first.hasPrefix("--") else { return Say.usage(usage) }
        var args = WireKinds.SessionPause.Args(session: nil, for: nil)
        let what: String
        switch Array(arguments.dropFirst()) {
        case []: (args.for, what) = ("indefinitely", "until you resume it (`vibeswitcher pause SESSION --off`)")
        case ["--tomorrow"]: (args.for, what) = ("morning", "until tomorrow morning at 9:00")
        case ["--off"]: (args.for, what) = ("off", "")
        case let words where words.count == 2 && words[0] == "--hours":
            guard let hours = Int(words[1]), (1...720).contains(hours) else { return Say.usage(usage + "  (N: 1 to 720)") }
            (args.for, args.hours, what) = ("hours", hours, "for \(hours) hour\(hours == 1 ? "" : "s")")
        default: return Say.usage(usage)
        }
        let resume = args.for == "off"
        return SessionCommand.act(WireKinds.SessionPause.self, lookup: first, args: { session in
            args.session = session["id"]?.string ?? first
            return args
        }, what: { session in
            resume ? "This resumes \(SessionCommand.describe(session)): it's reminded and notified of again."
                : "This pauses \(SessionCommand.describe(session)) \(what): greyed out, nothing reminds or notifies you of it."
        }) { result in
            let short = SessionCommand.short(result.session)
            guard let until = result.until, let date = NodeWire.date(until) else { return Say.out("resumed: session \(short)") }
            Say.out(date > Date(timeIntervalSinceNow: 50 * 365 * 86_400) ? "paused: session \(short), until you resume it"
                : "paused: session \(short), until \(ConfigSeal.inert(until, limit: 40))")
        }
    }
}
