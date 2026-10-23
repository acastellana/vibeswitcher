import Foundation

/// A session's long history (the phone's scroll-back), read on demand. Its parser keeps only `SessionParser.scrollback`
/// lines; a request for more feeds all the session's replay buffer holds (past its resets, see `OutputRing.held`) into
/// a parser of its own keeping the lines asked for (at most `SessionParser.historyScrollback`), takes the lines above
/// its screen and ends it, so that memory is held only while a read runs. A parser that can't start, traps or stalls
/// (no progress for the stall limit) gives nil: the caller falls back on its session parser's lines. Its parser is fed
/// and asked on a queue of its own, never the host's.
final class HistoryRead {
    /// Its parser's process id, while it runs (the host's housekeeping leaves it alone, see `HostServer.endOrphans`).
    let pid: pid_t

    private let queue = DispatchQueue(label: "vibeswitcher.host.history-read")
    /// On `queue`, all three; nil once done.
    private var link: ParserLink?
    private var watchdog: DispatchSourceTimer?
    private var completion: ((String?) -> Void)?

    /// Reads the last `lines` lines above the screen `replay` draws on a terminal of `cols` × `rows`; `completion` on
    /// the read's own queue (nil: it couldn't be read). Nil when its parser can't start.
    init?(replay: Data, lines: Int, cols: Int, rows: Int, launcher: String, options: ParserOptions,
          _ completion: @escaping (String?) -> Void) {
        let lines = max(1, min(lines, SessionParser.historyScrollback))
        guard let link = ParserLink.start(launcher: launcher, cols: cols, rows: rows, scrollback: lines, options: options, queue: queue) else {
            return nil
        }
        pid = link.pid
        self.link = link
        self.completion = completion
        queue.async { [self] in
            guard self.link != nil else { return }
            link.feed(replay, quietly: true)
            // Answered once it parsed all of the replay; nil if it ended first.
            link.view(historyLines: lines) { self.finish($0?.history) }
            let interval = max(0.05, min(1, options.stallLimit / 4))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler {
                guard case (true, let since)? = self.link?.busy, Date().timeIntervalSince(since) > options.stallLimit else { return }
                self.finish(nil)
            }
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 250)))
            timer.resume()
            watchdog = timer
        }
    }

    /// Ends the read and its parser (waiting for it to be gone); the completion gets nil unless it had its answer.
    func cancel() { queue.sync { finish(nil) } }

    /// On `queue`.
    private func finish(_ history: String?) {
        watchdog?.cancel()
        watchdog = nil
        link?.stop()
        link = nil
        guard let completion else { return }
        self.completion = nil
        completion(history)
    }
}
