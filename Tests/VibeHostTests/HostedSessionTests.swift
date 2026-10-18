import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Real PTYs, scratch programs only (`/bin/sh -c …`). Never point these at a real agent session.
final class SessionProbe {
    let queue = DispatchQueue(label: "probe")
    private let lock = NSLock()
    private var buffer = Data()
    private var changes: [HostSession] = []

    func attach(_ session: HostedSession) {
        session.onOutput = { [weak self] data in self?.locked { $0.buffer.append(data) } }
        session.onChange = { [weak self] info in self?.locked { $0.changes.append(info) } }
    }
    func locked(_ body: (SessionProbe) -> Void) { lock.lock(); body(self); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buffer, as: UTF8.self) }
    var lastChange: HostSession? { lock.lock(); defer { lock.unlock() }; return changes.last }

    /// What was going on in a session, for failure messages.
    func diagnosis(_ session: HostedSession) -> String {
        let info = queue.sync { session.info }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "pid,ppid,pgid,stat,wchan,command", "-t", info.tty]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        ps.waitUntilExit()
        return "info=\(info) output=\(text.debugDescription) ps=\n\(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))"
    }
}

struct HostedSessionTests {
    func start(_ command: String?, keepShell: Bool = false, cwd: String = "/tmp", shell: String = "/bin/sh",
               probe: SessionProbe) throws -> HostedSession {
        let request = SpawnRequest(cwd: cwd, command: command, env: ["PROBE": "yes"], cols: 80, rows: 24,
                                   keepShell: keepShell, label: "Test", agent: nil)
        return try probe.queue.sync {
            let session = try HostedSession.spawn(request, shell: shell, launcher: hostLauncher, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                                  ringCapacity: 1 << 20, queue: probe.queue)
            probe.attach(session)
            return session
        }
    }

    @Test func argumentsUseAnInteractiveLoginShell() {
        #expect(HostedSession.arguments(shell: "/bin/zsh", command: "claude", keepShell: false)
                == ["/bin/zsh", "-l", "-i", "-c", "claude"])
        #expect(HostedSession.arguments(shell: "/bin/zsh", command: nil, keepShell: false) == ["/bin/zsh", "-l", "-i"])
        #expect(HostedSession.arguments(shell: "/bin/zsh", command: "codex", keepShell: true)
                == ["/bin/zsh", "-l", "-i", "-c", "codex; exec '/bin/zsh' -l -i"])
    }

    @Test func environmentAddsTerminalVariablesAndExtras() {
        let id = UUID()
        let env = HostedSession.environment(base: ["PATH": "/bin", "TERM": "dumb"], extra: ["FOO": "bar", "1BAD": "x"], id: id)
        #expect(env.contains("TERM=xterm-256color"))
        #expect(env.contains("COLORTERM=truecolor"))
        #expect(env.contains("TERM_PROGRAM=VibeSwitcher"))
        #expect(env.contains("VIBESWITCHER_SESSION=\(id.uuidString)"))
        #expect(env.contains("FOO=bar"))
        #expect(!env.contains { $0.hasPrefix("1BAD=") })
        #expect(env.contains { $0.hasPrefix("LANG=") })
    }

    @Test func runsTheCommandInThePTYAndRecordsTheExit() throws {
        let probe = SessionProbe()
        let session = try start("echo out:$PROBE; tty; exit 3", probe: probe)
        #expect(eventually { probe.text.contains("out:yes") }, "\(probe.diagnosis(session))")
        let tty = probe.queue.sync { session.info.tty }
        #expect(tty.hasPrefix("ttys"))
        #expect(eventually { probe.text.contains("/dev/\(tty)") }, "\(probe.diagnosis(session))")   // the PTY is its terminal
        #expect(eventually { probe.lastChange?.exit?.status == 3 })
        probe.queue.sync { session.close() }
    }

    /// The session scan finds agents by their controlling terminal: the PTY must be it, not just stdin.
    @Test func thePTYIsTheControllingTerminal() throws {
        let probe = SessionProbe()
        // zsh, the usual login shell, doesn't claim a terminal itself (bash does).
        let session = try start("echo ctty=$(ps -o tty= -p $$) tpgid=$(ps -o tpgid= -p $$ | tr -d ' ')", shell: "/bin/zsh",
                                probe: probe)
        let tty = probe.queue.sync { session.info.tty }
        #expect(eventually { probe.text.contains("tpgid=") }, "\(probe.diagnosis(session))")
        #expect(probe.text.contains("ctty=\(tty)"), "\(probe.diagnosis(session))")
        #expect(!probe.text.contains("tpgid=0"))
        probe.queue.sync { session.close() }
    }

    @Test func inputReachesTheProgram() throws {
        let probe = SessionProbe()
        // Typed once it's reading (what's typed while the shell starts up may be flushed).
        let session = try start("echo reading; read line; echo got:$line", probe: probe)
        #expect(eventually { probe.text.contains("reading") }, "\(probe.diagnosis(session))")
        probe.queue.sync { session.write(Data("hello\r".utf8)) }
        #expect(eventually { probe.text.contains("got:hello") }, "\(probe.diagnosis(session))")
        probe.queue.sync { session.close() }
    }

    @Test func resizeAndRedrawNudgeSendSIGWINCH() throws {
        let probe = SessionProbe()
        // The interactive shell gives the terminal to its foreground job, as it will to the agent: that job
        // gets the SIGWINCH (a shell `trap` wouldn't fire while `sleep` holds the terminal).
        let script = "perl -e '$|=1; $SIG{WINCH}=sub{print qq(winch\\n)}; print qq(ready\\n); sleep 1 while 1'"
        let session = try start(script, probe: probe)
        #expect(eventually { probe.text.contains("ready") }, "output: \(probe.text.debugDescription) change: \(String(describing: probe.lastChange))")
        probe.queue.sync { session.resize(cols: 100, rows: 30) }
        #expect(eventually { probe.text.contains("winch") }, "\(probe.diagnosis(session))")
        #expect(probe.queue.sync { (session.info.cols, session.info.rows) } == (100, 30))
        probe.queue.sync { session.terminate() }
        #expect(eventually { probe.lastChange?.exit != nil })
        probe.queue.sync { session.close() }
    }

    /// The host ignores SIGPIPE/SIGHUP and runs on GCD threads (which block most signals); programs it starts
    /// must get neither: a blocked SIGWINCH means no redraw on resize, an ignored SIGHUP means End can't stop them.
    @Test func spawnedProgramsGetDefaultSignals() throws {
        let oldPipe = signal(SIGPIPE, SIG_IGN), oldHup = signal(SIGHUP, SIG_IGN)
        defer { signal(SIGPIPE, oldPipe); signal(SIGHUP, oldHup) }
        let probe = SessionProbe()
        let script = "echo mask=$(ps -o sigmask= -p $$ | tr -d ' '); sh -c 'kill -PIPE $$; echo pipe-ignored'; "
            + "sh -c 'kill -HUP $$; echo hup-ignored'; echo end"
        let session = try start(script, probe: probe)
        #expect(eventually { probe.text.contains("end") }, "\(probe.diagnosis(session))")
        #expect(probe.text.contains("mask=0"))
        #expect(!probe.text.contains("pipe-ignored"))
        #expect(!probe.text.contains("hup-ignored"))
        probe.queue.sync { session.close() }
    }

    /// Ending a session stops what runs in it even if that ignores SIGHUP (the shell exits on it, the program
    /// in its own foreground group may not): it must not keep running with the terminal after "ended".
    @Test func endingStopsAProgramThatIgnoresSIGHUP() throws {
        let probe = SessionProbe()
        // It would run for longer than the test waits: gone means stopped.
        let session = try start("perl -e '$SIG{HUP}=q(IGNORE); $|=1; print qq(pid=$$\\n); sleep 3600'; echo after", probe: probe)
        #expect(eventually { probe.text.contains("pid=") }, "\(probe.diagnosis(session))")
        let pid = probe.text.components(separatedBy: "pid=").last.flatMap { Int32($0.prefix { $0.isNumber }) } ?? 0
        #expect(pid > 0)
        probe.queue.sync { session.terminate() }
        #expect(eventually { kill(pid, 0) != 0 }, "pid \(pid) still running")
        probe.queue.sync { session.close() }
    }

    @Test func titleAndScreenComeFromTheHeadlessTerminal() throws {
        let probe = SessionProbe()
        let session = try start("printf '\\033]0;My Title\\007line one\\nline two\\n'; \(keepRunning)", probe: probe)
        #expect(eventually { probe.lastChange?.title == "My Title" }, "output: \(probe.text.debugDescription) change: \(String(describing: probe.lastChange))")
        #expect(eventually { probe.queue.sync { session.screenText() }.contains("line two") })
        let history = probe.queue.sync { session.historyText(lines: 100) }
        #expect((history.history + "\n" + history.screen).contains("line one"))
        probe.queue.sync { session.terminate(); session.close() }
    }

    @Test func headlessAnswersQueriesOnlyWhenNoClient() throws {
        // A device-status query (ESC[6n) expects a cursor report (ESC[row;colR) on the program's input.
        let probe = SessionProbe()
        let script = "stty raw -echo; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -c | head -1; stty sane; \(keepRunning)"
        let session = try start(script, probe: probe)
        #expect(eventually { probe.text.contains("033") }, "\(probe.diagnosis(session))")   // od printed the reply's ESC: answered
        probe.queue.sync { session.terminate(); session.close() }

        // Asks once it's told to go (with a view attached by then), then reads one byte: the host's answer if it gave
        // one, else the Z typed after the question showed (the headless terminal answers as it takes the question in).
        let probe2 = SessionProbe()
        let attached = try start("stty raw -echo; printf 'go?'; dd bs=1 count=1 2>/dev/null >/dev/null; printf '\\033[6n'; "
            + "dd bs=1 count=1 2>/dev/null | od -c; stty sane; \(keepRunning)", probe: probe2)
        probe2.queue.sync { attached.clientsAttached = true }   // a view would answer; the host must not
        #expect(eventually { probe2.text.contains("go?") }, "\(probe2.diagnosis(attached))")
        probe2.queue.sync { attached.write(Data("g".utf8)) }
        #expect(eventually { probe2.text.contains("\u{1B}[6n") }, "\(probe2.diagnosis(attached))")
        probe2.queue.sync { attached.write(Data("Z".utf8)) }
        #expect(eventually { probe2.text.contains("Z") }, "\(probe2.diagnosis(attached))")
        #expect(!probe2.text.contains("033"))
        probe2.queue.sync { attached.terminate(); attached.close() }
    }

    /// Claude Code 2.1.295+ reports its status over OSC 7501 only to a terminal that answers `OSC 7501 ; ?`. Views don't
    /// speak it, so the host answers even with one attached, and keeps the program's own record (not its tasks').
    @Test func answersProgramStatusQueriesAndKeepsTheStatus() throws {
        let probe = SessionProbe()
        // It asks once the test says a view is attached (a byte), and runs until the test ends it.
        let script = "stty raw -echo; echo ready; dd bs=1 count=1 >/dev/null 2>&1; "
            + "printf '\\033]7501;?\\033\\\\'; dd bs=1 count=10 2>/dev/null | od -c | head -1; stty sane; "
            + "printf '\\033]7501;state=working:app=claude-code\\007'; "
            + "printf '\\033]7501;state=blocked:app=claude-code:kind=permission:msg=QmFzaA\\033\\\\'; "
            + "printf '\\033]7501;state=done:id=task-1\\007'; printf 'reported\\n'; read line; printf '\\033]7501;state=clear\\007'; \(keepRunning)"
        let session = try start(script, probe: probe)
        #expect(eventually { probe.text.contains("ready") }, "\(probe.diagnosis(session))")
        probe.queue.sync {
            session.clientsAttached = true
            session.write(Data("g".utf8))
        }
        #expect(eventually { probe.text.contains("]   7   5   0   1   ;   ?") }, "\(probe.diagnosis(session))")
        #expect(eventually { probe.lastChange?.programStatus?.state == .working || probe.lastChange?.programStatus?.state == .blocked },
                "\(probe.diagnosis(session))")
        #expect(eventually { probe.text.contains("reported") && probe.lastChange?.programStatus?.state == .blocked },
                "\(probe.diagnosis(session))")
        let blocked = try #require(probe.lastChange?.programStatus)
        #expect(blocked.kind == "permission" && blocked.message == "Bash" && blocked.app == "claude-code")
        probe.queue.sync { session.write(Data("\r".utf8)) }
        #expect(eventually { probe.lastChange?.programStatus == nil }, "\(probe.diagnosis(session))")
        // Cleared by the program, which is still running.
        #expect(probe.lastChange?.exit == nil)
        probe.queue.sync { session.terminate(); session.close() }
    }

    @Test func aProgramThatEndsWithoutClearingItsStatusHasNone() throws {
        let probe = SessionProbe()
        // It ends once the test has seen its status.
        let session = try start("printf '\\033]7501;state=working:app=claude-code\\007'; read line; exit 1", probe: probe)
        #expect(eventually { probe.lastChange?.programStatus?.state == .working }, "\(probe.diagnosis(session))")
        probe.queue.sync { session.write(Data("\r".utf8)) }
        #expect(eventually { probe.lastChange?.exit != nil }, "\(probe.diagnosis(session))")
        #expect(probe.lastChange?.programStatus == nil)
        probe.queue.sync { session.close() }
    }

    @Test func replayHoldsEarlierOutput() throws {
        let probe = SessionProbe()
        let session = try start("echo first; \(keepRunning)", probe: probe)
        #expect(eventually { probe.text.contains("first") }, "\(probe.diagnosis(session))")
        #expect(String(decoding: probe.queue.sync { session.replay() }, as: UTF8.self).contains("first"))
        probe.queue.sync { session.terminate(); session.close() }
    }

    @Test func spawnRejectsMissingFolder() {
        let probe = SessionProbe()
        #expect(throws: HostedSession.Failure.noSuchFolder("/no/such/folder")) {
            _ = try start("true", cwd: "/no/such/folder", probe: probe)
        }
    }
}
