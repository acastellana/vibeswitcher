import Foundation

/// A held key's repeats for `ClaudeVoiceRun`: the key every `every` until stopped, timed and sent on a serial queue of
/// their own (`offMain`), so a stalled main thread doesn't hold them back. Claude Code (2.1.312) takes 120 ms with no
/// repeat for the key let go, and app.log counted hundreds of main-thread stalls of seconds; repeats on main-thread
/// timers ended dictations mid-sentence. `onMain` keeps them on the run's own timers instead (a session that can't take
/// keys from another thread, and tests on a clock they move).
///
/// Everything but the repeats is called on the main thread, and runs in step with them (`sync`): once `stop` or `pause`
/// returns, no repeat goes until `start` or `resume`, so what the run sends next (End, Esc, ⌃U) comes after the last.
final class HeldKey: @unchecked Sendable {
    /// Where the repeats are timed and run.
    struct Timing {
        /// `work` after `delay`, in the repeats' context.
        var schedule: (TimeInterval, @escaping () -> Void) -> Void
        /// `body` in the repeats' context, waited for.
        var sync: (() -> Void) -> Void

        /// A serial queue of their own.
        static func offMain(label: String = "vibeswitcher.dictation.held-key") -> Timing {
            let queue = DispatchQueue(label: label, qos: .userInteractive)
            return Timing(schedule: { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) },
                          sync: { body in queue.sync(execute: body) })
        }

        /// The main thread's timers (`schedule`, the run's).
        static func onMain(_ schedule: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void) -> Timing {
            Timing(schedule: { _ = schedule($0, $1) }, sync: { $0() })
        }
    }

    /// What the repeats did: the keys sent (the main thread's too, `sent()`), when the last went, and when a late repeat
    /// paused them (nil: it didn't).
    struct State {
        var count = 0
        var lastAt = Date.distantPast
        var pausedAt: Date?
    }

    private let key: [UInt8]
    private let every: TimeInterval
    private let stallGap: TimeInterval
    private let send: ([UInt8]) -> Bool
    private let now: () -> Date
    private let timing: Timing
    private let failed: () -> Void
    // In the repeats' context only.
    private var current = State()
    private var listening = false
    /// Counts each start: a repeat scheduled before a stop does nothing.
    private var generation = 0
    private var running = false

    /// `send`: the key out to the session, from the repeats' context (false: it didn't go, and they stop: `failed`,
    /// called on the main thread). `stallGap`: while listening, a repeat this late after the one before pauses them
    /// (`pausedAt`), as Claude may have taken the gap for the key let go; `resume` goes on.
    init(key: [UInt8], every: TimeInterval, stallGap: TimeInterval, timing: Timing, now: @escaping () -> Date,
         send: @escaping ([UInt8]) -> Bool, failed: @escaping () -> Void) {
        self.key = key
        self.every = every
        self.stallGap = stallGap
        self.timing = timing
        self.now = now
        self.send = send
        self.failed = failed
    }

    var state: State {
        var state = State()
        timing.sync { state = self.current }
        return state
    }

    /// A key that went from the main thread (the hold's first).
    func sent() {
        timing.sync {
            self.current.count += 1
            self.current.lastAt = self.now()
        }
    }

    /// Claude records: from now on a late repeat pauses them.
    func listen() {
        timing.sync { self.listening = true }
    }

    var isRunning: Bool {
        var running = false
        timing.sync { running = self.running }
        return running
    }

    /// The repeats, the first `after` from now; nothing if they're going.
    func start(after delay: TimeInterval) {
        timing.sync {
            guard !self.running else { return }
            self.current.pausedAt = nil
            self.running = true
            self.generation += 1
            self.next(after: delay, self.generation)
        }
    }

    /// No more repeats (until `start` or `resume`).
    func stop() {
        timing.sync {
            self.running = false
            self.generation += 1
            self.current.pausedAt = nil
        }
    }

    /// No more repeats until `resume`, and none of them late (a read said Claude may have stopped).
    func pause() {
        timing.sync {
            self.running = false
            self.generation += 1
        }
    }

    /// After a pause: a key now, and the repeats on. False when it didn't go (and they stay stopped).
    @discardableResult
    func resume() -> Bool {
        var went = false
        timing.sync {
            self.current.pausedAt = nil
            self.generation += 1
            let at = self.now()
            guard self.send(self.key) else { return }
            went = true
            self.current.count += 1
            self.current.lastAt = at
            self.running = true
            self.next(after: self.every, self.generation)
        }
        return went
    }

    // In the repeats' context.
    private func next(after delay: TimeInterval, _ generation: Int) {
        timing.schedule(delay) { [self] in
            guard running, generation == self.generation else { return }
            if listening, now().timeIntervalSince(current.lastAt) >= stallGap {
                // Late (this queue was held up): Claude may have ended the recording; a read asked from now on says
                // whether to go on (`resume`).
                running = false
                current.pausedAt = now()
                return
            }
            let at = now()
            guard send(key) else {
                running = false
                DispatchQueue.main.async(execute: failed)
                return
            }
            current.count += 1
            current.lastAt = at
            next(after: every, generation)
        }
    }
}
