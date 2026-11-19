import Foundation

extension Platform {
    /// A pause of at most a given time on the calling thread, over at once when a process exits: a loop that looks at
    /// a program between pauses (`Shell.run`) ends with it, never up to a whole pause late. It reaps nothing: the
    /// process's parent still collects it. Its exit ends one pause: later ones run their whole time, so a caller that
    /// hasn't collected the process yet never spins. Where the process can't be watched (no such process, nothing to
    /// watch it with), every pause is a plain sleep of its time.
    ///
    /// The Mac's is a kqueue's NOTE_EXIT, one-shot (ExitWait+Darwin.swift); Linux's is `poll` on a descriptor of the
    /// process, `pidfd_open`, closed once it has told (ExitWait+Linux.swift).
    public final class ExitWait {
        private var descriptor: Int32

        public init(_ pid: pid_t) {
            descriptor = pid > 0 ? Self.open(pid) : -1
        }

        deinit { if descriptor >= 0 { close(descriptor) } }

        /// Waits up to `seconds`, less when the process exits. An interrupted wait sleeps out the rest: never a
        /// quicker look than `seconds` but at the exit.
        public func wait(upTo seconds: TimeInterval) {
            let began = Clock.awakeSeconds()
            if descriptor >= 0 {
                switch Self.wait(descriptor, upTo: seconds) {
                case .exited:
                    Self.told(&descriptor)
                    return
                case .timedOut:
                    return
                case .failed:
                    break
                }
            }
            let left = seconds - (Clock.awakeSeconds() - began)
            if left > 0 { usleep(useconds_t(left * 1_000_000)) }
        }

        enum Outcome { case exited, timedOut, failed }
    }
}
