import Foundation

extension Platform {
    /// `command` run by `/bin/sh -c` with `input` on its stdin; what it printed on stdout (stderr goes nowhere). It
    /// runs on this thread alone (no other thread or queue, so a busy process can't starve it): the input is
    /// written as the pipe takes it and never after the command has exited or closed its end, and a write that
    /// finds the pipe broken all the same is an error here, never a SIGPIPE; its output is read until it ends. Past
    /// `patience` the command is killed and what it printed so far is returned; so it is when one of `stopSignals`
    /// comes to this process, even while this process ignores that signal. It starts in a process group of its
    /// own, and the kill is the whole group's (a pipeline's every program); with SIGPIPE and `stopSignals` at their
    /// defaults, an empty signal mask and no descriptor of this process but its stdin, stdout and stderr. Empty
    /// when it couldn't be started.
    ///
    /// A command that has exited is not killed, nor is what it left behind: while a program it started still holds
    /// its stdout, the output is read until that ends or `patience` is over.
    ///
    /// The Mac's is a kqueue on the pipes, the command's exit and the signals (PipeCommand+Darwin.swift). Linux's
    /// is `poll` on the pipes and on a descriptor of the command (PipeCommand+Linux.swift), and it hears a stop
    /// signal by handling it for as long as a command runs: what the signal did before is put back afterwards, and
    /// the signal, which the Mac's kqueue only watches go by, is then sent to this process again, so it still does
    /// what it would have. Two commands under way in one process there are both stopped by a stop signal of either.
    public static func pipeCommand(_ command: String, input: Data, patience: TimeInterval, stopSignals: [Int32]) -> Data {
        runPiped(command, input: input, patience: patience, stopSignals: stopSignals)
    }
}
