import Foundation
import VibeCore

/// What `vs switch` waits for once the host handed over, before it returns (2026-11-24: the user's first switch on the
/// real node; `vibeswitcher web` run right after it reached the outgoing server, which printed its own build, opened a
/// page on itself, and ended a moment later: "the page stays loading").
///
/// - **The server that stays.** A switch to a build whose server's bytes differ from the running server's ends that
///   server once idle and starts the new build's (`ServerChild.replaceWhenIdle`, about `ServerChild.idleLimit` after the
///   handover). Whether that's due is read from the two builds' `build-info` (`serverDue`): the running server's (the
///   folder its hello's commit names) and the target's. Due, the command line waits for a server whose hello names the
///   target's commit under another pid (`serverSettled`); not due, the server that answered stays; unknown (a record
///   that can't be read), it says so and doesn't wait.
/// - **The web listener.** When a page held a token before the switch (`status`'s `web`: listening, tokens above 0),
///   the server that stays is waited for until its `web` says listening on the same port again (the host holds the
///   socket across the handover, H1); a page that was paired then reconnects with its token (kept at rest).
///
/// Each wait polls until what it waits for answers, bounded (`serverWait`, `webWait`); past it the command line says
/// what didn't come and how to look, and goes on: the handover happened (`slowServer`).
public enum SwitchSettle {
    /// The longest a replacement takes: the reconnect's grace, the idle limit, the end's limit, and a start.
    public static let serverWait: TimeInterval = 120
    /// How long the web listener is waited for once the server answers.
    public static let webWait: TimeInterval = 30

    /// What a switch says when the new build's server hasn't answered in its wait (`why`: what answered instead): the
    /// handover happened, so it goes on.
    public static func slowServer(target: String, after seconds: Int, why: String) -> String {
        "handed over to \(target); its server hasn't answered yet after \(seconds) s (\(ConfigSeal.inert(why, limit: 200))): "
            + "`vibeswitcher status` shows when it does"
    }

    /// Whether the switch to `target` replaces a server running `running`'s build, from their `build-info` under
    /// `installRoot`: the server's recorded SHA-256 differ. Nil when either can't be read (a server that names no
    /// installed build, a record that doesn't read).
    public static func serverDue(installRoot: String?, running: String, target: String) -> Bool? {
        guard let installRoot, NodeUnit.isCommit(running), NodeUnit.isCommit(target) else { return nil }
        if running == target { return false }
        func server(_ commit: String) -> String? {
            guard case .success(let info) = BuildInfo.read(buildFolder: NodeFolders.join(installRoot, commit)) else { return nil }
            return info.binaries[BuildInfo.server]
        }
        guard let before = server(running), let after = server(target) else { return nil }
        return before != after
    }

    /// The web as `status` gives it: whether a page held a token, and the port.
    public struct Web: Equatable, Sendable {
        public var listening: Bool
        public var port: Int?
        public var tokens: Int

        public init(listening: Bool, port: Int?, tokens: Int) {
            self.listening = listening
            self.port = port
            self.tokens = tokens
        }

        public init?(_ value: NodeWire.Value?) {
            guard let value, value.object != nil else { return nil }
            self.init(listening: value["state"]?.string == "listening", port: value["port"]?.int, tokens: value["tokens"]?.int ?? 0)
        }

        /// A paired page reconnects to it by itself: the server's listener must come back on this port.
        public var awaited: Bool { listening && tokens > 0 && port != nil }
    }

    /// Whether the server that answered (`pid`, `commit`) is the one that stays after a switch from the server `before`
    /// (its pid) to `target`, with a replacement `due` (nil: not known, not waited for).
    public static func serverSettled(pid: Int32, commit: String, before: Int32, target: String, due: Bool?) -> Bool {
        guard due == true else { return true }
        return pid != before && commit == target
    }

    /// Whether `now` is the listener a page held before the switch (`before`), back.
    public static func webSettled(before: Web?, now: Web?) -> Bool {
        guard let before, before.awaited else { return true }
        guard let now else { return false }
        return now.listening && now.port == before.port
    }
}
