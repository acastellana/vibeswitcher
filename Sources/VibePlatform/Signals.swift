import Foundation

extension Platform {
    /// Signal handlers, installed with `sigaction`: the structure's handler field has a name of its own on the Mac
    /// (`__sigaction_u`), on glibc (`__sigaction_handler`) and on musl (`__sa_handler`), and so has the way to the
    /// sender's pid in what a handler is told.
    public enum Signals {
        /// `handler` for each of `signals`, once: the system puts the signal's default back as the handler starts
        /// (`SA_RESETHAND`), so a handler that raises the signal again ends the process as the signal would have.
        /// The handler runs wherever the signal lands: it may call only what a signal handler may (write(2), not
        /// malloc), and it captures nothing.
        public static func onFatal(_ signals: [Int32], _ handler: @escaping @convention(c) (Int32) -> Void) {
            for number in signals {
                var action = sigaction()
                #if canImport(Darwin)
                action.__sigaction_u.__sa_handler = handler
                #elseif canImport(Glibc)
                action.__sigaction_handler.sa_handler = handler
                #else
                action.__sa_handler.sa_handler = handler
                #endif
                action.sa_flags = Int32(truncatingIfNeeded: SA_RESETHAND)
                sigemptyset(&action.sa_mask)
                sigaction(number, &action, nil)
            }
        }

        /// What a handler installed with `onSignal` is called with: the signal, what the system says of it (for
        /// `sender`), and the interrupted context.
        public typealias InformedHandler = @convention(c) (Int32, UnsafeMutablePointer<siginfo_t>?, UnsafeMutableRawPointer?) -> Void

        /// `handler` for each of `signals`, told what the system knows of the signal (`SA_SIGINFO`: `sender` reads
        /// who sent it), and staying installed: the form for a signal that is noted in the handler and acted on
        /// outside it, as the session host does with SIGTERM and SIGINT. The same limits on the handler as
        /// `onFatal`'s.
        public static func onSignal(_ signals: [Int32], _ handler: @escaping InformedHandler) {
            for number in signals {
                var action = sigaction()
                #if canImport(Darwin)
                action.__sigaction_u.__sa_sigaction = handler
                #elseif canImport(Glibc)
                action.__sigaction_handler.sa_sigaction = handler
                #else
                action.__sa_handler.sa_sigaction = handler
                #endif
                action.sa_flags = Int32(truncatingIfNeeded: SA_SIGINFO)
                sigaction(number, &action, nil)
            }
        }

        /// The pid of the process that sent the signal `info` tells of; 0 when there is no `info`. It is there for a
        /// signal a process sent (kill); one the kernel raised itself (a terminal's Ctrl-C) reads 0, and for a fault
        /// (SIGSEGV, SIGBUS) the same bytes hold an address. A plain read of a field: a handler may call it.
        public static func sender(_ info: UnsafeMutablePointer<siginfo_t>?) -> Int32 {
            #if canImport(Darwin)
            return info?.pointee.si_pid ?? 0
            #else
            return info.map { vibe_signal_sender($0) } ?? 0
            #endif
        }

        /// `note` is called with the name of an Objective-C exception nobody caught, as the process is about to end
        /// by it (`NSSetUncaughtExceptionHandler`). On Linux there is no such exception, and this does nothing: what
        /// ends a Swift process there comes as a signal (`onFatal`).
        public static func onUncaughtException(_ note: @escaping @Sendable (String) -> Void) {
            #if canImport(Darwin)
            exceptionNote.set(note)
            NSSetUncaughtExceptionHandler { exception in Platform.Signals.exceptionNote.say(exception.name.rawValue) }
            #endif
        }

        #if canImport(Darwin)
        /// What `onUncaughtException` was last given: the system's handler is a C function, which holds nothing.
        private final class ExceptionNote: @unchecked Sendable {
            private let lock = NSLock()
            private var note: (@Sendable (String) -> Void)?

            func set(_ note: @escaping @Sendable (String) -> Void) {
                lock.lock()
                self.note = note
                lock.unlock()
            }

            func say(_ name: String) {
                lock.lock()
                let note = self.note
                lock.unlock()
                note?(name)
            }
        }

        private static let exceptionNote = ExceptionNote()
        #endif
    }
}
