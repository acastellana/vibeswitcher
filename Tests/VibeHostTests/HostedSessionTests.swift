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
}

struct HostedSessionTests {
    func start(_ command: String?, keepShell: Bool = false, cwd: String = "/tmp", probe: SessionProbe) throws -> HostedSession {
        let request = SpawnRequest(cwd: cwd, command: command, env: ["PROBE": "yes"], cols: 80, rows: 24,
                                   keepShell: keepShell, label: "Test", agent: nil)
        return try probe.queue.sync {
            let session = try HostedSession.spawn(request, shell: "/bin/sh", baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
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
        #expect(eventually { probe.text.contains("out:yes") })
        let tty = probe.queue.sync { session.info.tty }
        #expect(tty.hasPrefix("ttys"))
        #expect(eventually { probe.text.contains("/dev/\(tty)") })   // the PTY is its terminal
        #expect(eventually { probe.lastChange?.exit?.status == 3 })
        probe.queue.sync { session.close() }
    }

    @Test func inputReachesTheProgram() throws {
        let probe = SessionProbe()
        let session = try start("read line; echo got:$line", probe: probe)
        Thread.sleep(forTimeInterval: 0.3)
        probe.queue.sync { session.write(Data("hello\r".utf8)) }
        #expect(eventually { probe.text.contains("got:hello") })
        probe.queue.sync { session.close() }
    }

    @Test func resizeAndRedrawNudgeSendSIGWINCH() throws {
        let probe = SessionProbe()
        // The interactive shell gives the terminal to its foreground job, as it will to the agent: that job
        // gets the SIGWINCH (a shell `trap` wouldn't fire while `sleep` holds the terminal).
        let script = "perl -e '$|=1; $SIG{WINCH}=sub{print qq(winch\\n)}; print qq(ready\\n); sleep 1 while 1'"
        let session = try start(script, probe: probe)
        #expect(eventually { probe.text.contains("ready") })
        probe.queue.sync { session.resize(cols: 100, rows: 30) }
        #expect(eventually { probe.text.contains("winch") })
        #expect(probe.queue.sync { (session.info.cols, session.info.rows) } == (100, 30))
        probe.queue.sync { session.terminate() }
        #expect(eventually(timeout: 8) { probe.lastChange?.exit != nil })
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
        #expect(eventually { probe.text.contains("end") })
        #expect(probe.text.contains("mask=0"))
        #expect(!probe.text.contains("pipe-ignored"))
        #expect(!probe.text.contains("hup-ignored"))
        probe.queue.sync { session.close() }
    }

    @Test func titleAndScreenComeFromTheHeadlessTerminal() throws {
        let probe = SessionProbe()
        let session = try start("printf '\\033]0;My Title\\007line one\\nline two\\n'; sleep 5", probe: probe)
        #expect(eventually { probe.lastChange?.title == "My Title" })
        #expect(eventually { probe.queue.sync { session.screenText() }.contains("line two") })
        let history = probe.queue.sync { session.historyText(lines: 100) }
        #expect((history.history + "\n" + history.screen).contains("line one"))
        probe.queue.sync { session.terminate(); session.close() }
    }

    @Test func headlessAnswersQueriesOnlyWhenNoClient() throws {
        // A device-status query (ESC[6n) expects a cursor report (ESC[row;colR) on the program's input.
        let probe = SessionProbe()
        let script = "stty raw -echo; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -c | head -1; stty sane; sleep 5"
        let session = try start(script, probe: probe)
        #expect(eventually { probe.text.contains("033") })   // od printed the reply's ESC: answered
        probe.queue.sync { session.terminate(); session.close() }

        let probe2 = SessionProbe()
        let attached = try start("stty raw -echo; sleep 0.5; printf '\\033[6n'; dd bs=1 count=1 2>/dev/null | od -c; stty sane", probe: probe2)
        probe2.queue.sync { attached.clientsAttached = true }   // a view would answer; the host must not
        Thread.sleep(forTimeInterval: 1.5)
        #expect(!probe2.text.contains("033"))
        probe2.queue.sync { attached.terminate(); attached.close() }
    }

    @Test func replayHoldsEarlierOutput() throws {
        let probe = SessionProbe()
        let session = try start("echo first; sleep 5", probe: probe)
        #expect(eventually { probe.text.contains("first") })
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
