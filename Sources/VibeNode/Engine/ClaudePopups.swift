import Foundation
import VibeCore

/// Claude Code's own popups over an agent's input that ask nothing of the work, and the dialogs nothing here can read.
/// A popup on a team session (a lead, a worker, a verifier) is declined with Esc, the popup's own cancel, never by
/// choosing a row (2026-11-20, the acceptance run: 2.1.329's "Teach auto mode about your environment?" sat over a
/// scratch lead's box, and its worker's report and the user's `tell` waited behind it; its "Continue" would scan the
/// user's shell history and other repositories). On the user's own sessions a popup is left alone: it shows as the
/// session's `prompt` (`SessionPrompt`), for `reply` or the terminal. A dialog on a team session that is neither one
/// of these nor a question `SessionPrompt` reads is an unknown dialog: `status` says so while it blocks what waits.
public enum ClaudePopup: String, Equatable, Sendable, CaseIterable {
    /// 2.1.329: "Teach auto mode about your environment?", its rows toggles (shell history, other repositories) and a
    /// Continue, its footer `↑/↓ to navigate · Space to toggle · Esc to cancel`.
    case autoModeSetup = "Teach auto mode about your environment?"

    /// The popup open on `screen`: its title on a line of its own among the last 30, and the last line its footer
    /// saying Esc cancels it. Nil when none is.
    public static func on(_ screen: String) -> ClaudePopup? {
        var lines = Platform.lines(screen.replacingOccurrences(of: "\u{0}", with: " ")).map { $0.trimmingCharacters(in: .whitespaces) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard let footer = lines.last, footer.contains("Esc to cancel") else { return nil }
        let recent = Set(lines.suffix(30).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│┃║ ")) })
        return allCases.first { recent.contains($0.rawValue) }
    }

    /// Its key: Esc.
    static let decline = HostInput.Write(bytes: [27], delay: 0)
}

extension LeadEngine {
    /// How long a dialog nothing here reads must stay on a team session's screen before `status` says so (a read taken
    /// mid-redraw isn't one).
    static let unknownDialogAfter: TimeInterval = 4

    /// A screen of a hosted session read just now (by the session scan, or by delivery before it types), with the
    /// session's role: a known popup on a team session is declined; a dialog nothing reads is noted for `status` while
    /// it stays; anything else clears what was noted. `deliver`: what to look at again once a popup is declined (the
    /// delivery that read it). On `queue`.
    func lookAt(screen: String?, of session: HostSession, deliver: (() -> Void)? = nil) {
        let id = session.id
        guard let screen, let role = LeadTeams.role(label: session.label) else {
            dialogs[id] = nil
            return
        }
        if let popup = ClaudePopup.on(screen) {
            dialogs[id] = nil
            decline(popup, on: session, role: role, then: deliver)
            return
        }
        guard case .dialog(let shown) = LeadDelivery.box(in: screen), SessionPrompt.menu(on: screen) == nil else {
            dialogs[id] = nil
            return
        }
        let now = dialogNow()
        if let seen = dialogs[id], seen.shown == shown {
            if !seen.told, now.timeIntervalSince(seen.since) >= Self.unknownDialogAfter {
                dialogs[id]?.told = true
                note("session \(id.uuidString.prefix(8)) (\(role.rawValue)) shows a dialog VibeSwitcher can't read: \(ConfigSeal.inert(shown, limit: 200))")
            }
        } else {
            dialogs[id] = UnknownDialog(shown: shown, since: now, label: session.label ?? role.rawValue)
        }
    }

    /// Esc into `session` while `popup` still shows (the gate reads the screen again right before the key), once at a
    /// time per session; then `then`, so what waited behind it goes. On `queue`.
    private func decline(_ popup: ClaudePopup, on session: HostSession, role: LeadLaunch.Role, then: (() -> Void)?) {
        let id = session.id
        guard declining.insert(id).inserted else { return }
        let (link, queue) = (self.link, self.queue)
        link.type([ClaudePopup.decline], into: id, gate: { _, go in
            link.screen(id) { now in go(now.flatMap(ClaudePopup.on) == popup) }
        }, confirmed: { [weak self] typed in
            queue.async {
                guard let self else { return }
                self.declining.remove(id)
                self.popupsDeclined.append((id, popup))
                self.note("declined Claude Code's popup “\(popup.rawValue)” with Esc on session \(id.uuidString.prefix(8)) "
                          + "(\(role.rawValue)): \(typed ? "Esc typed" : "not typed: it closed meanwhile, or the host didn't take it")")
                // What waited behind it, looked at again once the popup has had time to close.
                queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    then?()
                    self?.look()
                }
            }
        })
    }

    /// What `status` says of each team session a dialog nothing here reads has blocked for `unknownDialogAfter`, while
    /// the session lives. On `queue`.
    var unknownDialogNotices: [String] {
        let live = Set(link.sessions.filter(\.isLive).map(\.id))
        let now = dialogNow()
        return dialogs.filter { live.contains($0.key) && now.timeIntervalSince($0.value.since) >= Self.unknownDialogAfter }
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { id, dialog in
                "session \(id.uuidString.prefix(8)) (\(ConfigSeal.inert(dialog.label, limit: 80))) shows a dialog VibeSwitcher can't read, "
                    + "so nothing waiting for it is typed until it's answered in its terminal: "
                    + ConfigSeal.inert(dialog.shown, limit: 300)
            }
    }

    /// A dialog nothing here reads on a team session: its last lines as shown, since when, the session's label, and
    /// whether the log said so yet.
    struct UnknownDialog: Equatable {
        var shown: String
        var since: Date
        var label: String
        var told = false
    }
}
