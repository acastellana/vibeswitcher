import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Ending a session ends what its agent started (`SessionStrays`), and nothing else: on a scratch host, with its
/// sessions' programs and processes this test started only.
struct EndingASessionTests {
    /// The built tool server waiting on its input, with `environment` and nothing else (not this test's own
    /// `VIBESWITCHER_SESSION`, if it runs in a session). It's the user's program, not Apple's, so its environment can be
    /// read, as a dev server's (node) can.
    static func waiter(environment: [String: String]) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: OrphanSweepTests.built)
        process.environment = environment.merging(["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]) { mine, _ in mine }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, input)
    }

    static func pid(_ name: String, in text: String) -> pid_t? {
        text.components(separatedBy: "\(name)=").dropFirst().first.flatMap { pid_t($0.prefix { $0.isNumber }) }
    }

    @Test func endingASessionEndsWhatItStartedOnly() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        // A setsid'd child (launchd's once the shell ends; forked first, since the job it's in leads its group and a
        // group's leader can't start a session), and a job in a group of its own that ignores SIGHUP: neither is in a
        // group the session's SIGHUP reaches. Apple's perl: its environment can't be read.
        let session = try client.spawn("perl -MPOSIX -e 'if (fork) { wait; exit } POSIX::setsid() == $$ or die; $|=1; print qq(s=$$\\n); sleep 300' & "
            + "perl -e 'setpgrp(0, 0); $SIG{HUP} = q(IGNORE); $|=1; print qq(b=$$\\n); sleep 300' & \(keepRunning)")
        client.attach(session.id)
        #expect(eventually { Self.pid("s", in: client.text(session.id)) != nil && Self.pid("b", in: client.text(session.id)) != nil },
                "\(client.text(session.id).debugDescription)")
        let setsid = try #require(Self.pid("s", in: client.text(session.id)))
        let job = try #require(Self.pid("b", in: client.text(session.id)))
        // A group of its own (the setsid'd one printed only once it leads a session of its own, which getsid can't
        // tell from another session): the shell's SIGHUP reaches neither.
        #expect(getpgid(job) == job)
        // Started by the test, not by the session: one carrying its id (as a server a Bash command left behind does),
        // one another session's, one with none, and Apple's sleep, whose environment can't be read.
        let (carrying, carryingInput) = try Self.waiter(environment: ["VIBESWITCHER_SESSION": session.id.uuidString])
        let (other, otherInput) = try Self.waiter(environment: ["VIBESWITCHER_SESSION": UUID().uuidString])
        let (none, noneInput) = try Self.waiter(environment: [:])
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["300"]
        try sleep.run()
        let spared = [other, none, sleep]
        defer {
            (spared + [carrying]).forEach { $0.terminate() }
            [carryingInput, otherInput, noneInput].forEach { try? $0.fileHandleForWriting.close() }
            [setsid, job].forEach { kill($0, SIGKILL) }
        }
        #expect(eventually { SessionStrays.carrying(session: session.id).map(\.pid) == [carrying.processIdentifier] })

        let ended = Date()
        client.send(.kill(id: session.id))
        #expect(eventually(timeout: 10) { kill(setsid, 0) != 0 && kill(job, 0) != 0 && !carrying.isRunning },
                "setsid \(kill(setsid, 0) == 0), job \(kill(job, 0) == 0), carrying \(carrying.isRunning)")
        // Asked first, not killed: the 5 s mark is for what doesn't end on that.
        // (Read only once it ended: a running process's raise.)
        if !carrying.isRunning { #expect(carrying.terminationReason == .uncaughtSignal && carrying.terminationStatus == SIGTERM) }
        // Past the 5 s mark too, the others run.
        Thread.sleep(until: ended.addingTimeInterval(6))
        for process in spared { #expect(process.isRunning, "\(process.executableURL?.path ?? "") was signalled") }
    }
}
