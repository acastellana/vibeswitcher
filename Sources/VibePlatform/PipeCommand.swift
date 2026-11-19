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

    /// How long `killAll` goes on killing a stopped command's group: well inside the ~2 s Claude Code gives a status
    /// line after its TERM, and the usage is kept only after it.
    static let groupSweep: TimeInterval = 0.5

    /// Kills `group` again and again until none of it is left (ESRCH), for at most `groupSweep`. One kill isn't enough:
    /// XNU's kill of a group passes over a child its shell is still making (a pipeline's or a `&`'s fork under way), and
    /// that child then runs on in the group with launchd as its parent (StatusLineBinaryTests, 2026-11-18: a `sleep` left
    /// so). EPERM isn't "none left": the group still exists, though nothing in it took the signal (seen while it emptied).
    /// Linux's kill of a group can race a fork the same way, so both arms sweep.
    static func killAll(group: pid_t) {
        let deadline = Clock.awakeSeconds() + groupSweep
        while kill(-group, SIGKILL) == 0 || errno != ESRCH, Clock.awakeSeconds() < deadline {
            usleep(2_000)
        }
    }
}
