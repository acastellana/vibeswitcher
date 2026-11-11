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
    static func waiter(_ executable: String = OrphanSweepTests.built, environment: [String: String]) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
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

    @Test func endingASessionEndsWhatItStartedOnly() async throws {
        let host = try TestHost()
        let client = try TestClient(host)
        // A setsid'd child (launchd's once the shell ends; forked first, since the job it's in leads its group and a
        // group's leader can't start a session), and a job in a group of its own that ignores SIGHUP: neither is in a
        // group the session's SIGHUP reaches. Apple's perl: its environment can't be read.
        let session = try await client.spawn("perl -MPOSIX -e 'if (fork) { wait; exit } POSIX::setsid() == $$ or die; $|=1; print qq(s=$$\\n); sleep 300' & "
            + "perl -e 'setpgrp(0, 0); $SIG{HUP} = q(IGNORE); $|=1; print qq(b=$$\\n); sleep 300' & \(keepRunning)")
        await client.attach(session.id)
        #expect(await eventually { Self.pid("s", in: client.text(session.id)) != nil && Self.pid("b", in: client.text(session.id)) != nil },
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
        #expect(await eventually { SessionStrays.carrying(session: session.id).map(\.pid) == [carrying.processIdentifier] })

        let ended = Date()
        client.send(.kill(id: session.id))
        #expect(await eventually(timeout: 10) { kill(setsid, 0) != 0 && kill(job, 0) != 0 && !carrying.isRunning },
                "setsid \(kill(setsid, 0) == 0), job \(kill(job, 0) == 0), carrying \(carrying.isRunning)")
        // Asked first, not killed: the 5 s mark is for what doesn't end on that. The tool server ends on SIGTERM by
        // itself (exit 0, as on its input's end) once it has set that up, a few ms after it started, and by the signal
        // before: which one depends on how soon the session's SIGTERM comes, 17 ms after at a load of 16 (2026-10-23),
        // and either is ending when asked. (Read only once it ended: a running process's raise.)
        if !carrying.isRunning {
            let reason = carrying.terminationReason, status = carrying.terminationStatus
            #expect(reason == .uncaughtSignal ? status == SIGTERM : status == 0, "ended by \(reason == .uncaughtSignal ? "signal" : "exit") \(status)")
        }
        // Past the 5 s mark too, the others run.
        await pause(max(0, ended.addingTimeInterval(6).timeIntervalSinceNow))
        for process in spared { #expect(process.isRunning, "\(process.executableURL?.path ?? "") was signalled") }
    }

    /// The app carries a session's id when something run in that session launched it: `open` hands its caller's
    /// environment to the app, so the app an install run in a shell relaunched carried that shell's id, and ending that
    /// shell made the host ask the app to quit with the shell's strays (2026-11-10 22:00: "app: quitting"). The app
    /// (here a stand-in at the path the host knows as the app's, through a symlink as /tmp is) isn't what the session
    /// started: it's neither asked to end nor killed after the grace, while a stray carrying the same id is.
    @Test func theAppCarryingASessionsIdIsNotEndedWithThatSession() async throws {
        let scratch = Scratch()
        let folder = scratch.url("app-carrying-a-session")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let appPath = folder.appendingPathComponent("VibeSwitcher").path
        try FileManager.default.copyItem(atPath: OrphanSweepTests.built, toPath: appPath)
        let link = folder.appendingPathComponent("linked").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: folder.path)
        let id = UUID()
        let (app, appInput) = try Self.waiter(appPath, environment: ["VIBESWITCHER_SESSION": id.uuidString])
        let (stray, strayInput) = try Self.waiter(environment: ["VIBESWITCHER_SESSION": id.uuidString])
        defer {
            [app, stray].forEach { $0.terminate() }
            [appInput, strayInput].forEach { try? $0.fileHandleForWriting.close() }
        }
        #expect(await eventually { Set(SessionStrays.carrying(session: id).map(\.pid)) == [app.processIdentifier, stray.processIdentifier] })

        // On a thread of its own, as `end` runs it (it waits out the grace); back once the SIGKILLs are sent.
        let asked: [pid_t] = await withCheckedContinuation { done in
            Thread.detachNewThread {
                done.resume(returning: SessionStrays.endNow(session: id, started: [], keeping: link + "/VibeSwitcher", grace: 0.5).map(\.pid))
            }
        }
        #expect(asked == [stray.processIdentifier])
        #expect(await eventually { !stray.isRunning })
        #expect(app.isRunning, "the app was ended with the session whose id it carries")
        // Without an app to keep, it's a stray like any other.
        #expect(SessionStrays.carrying(session: id).map(\.pid) == [app.processIdentifier])
    }

    /// A lead that ends a session itself (the host didn't, see `LeadToolset.endItself`) ends what carries its id, and
    /// never the app that does (see above): the tool server knows the app as the program beside its own.
    @Test func whatALeadEndsItselfLeavesOutTheAppCarryingTheSessionsId() async throws {
        let scratch = Scratch()
        let folder = scratch.url("app-carrying-a-session")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let appPath = folder.appendingPathComponent("VibeSwitcher").path
        try FileManager.default.copyItem(atPath: OrphanSweepTests.built, toPath: appPath)
        let id = UUID()
        let (app, appInput) = try Self.waiter(appPath, environment: ["VIBESWITCHER_SESSION": id.uuidString])
        let (stray, strayInput) = try Self.waiter(environment: ["VIBESWITCHER_SESSION": id.uuidString])
        defer {
            [app, stray].forEach { $0.terminate() }
            [appInput, strayInput].forEach { try? $0.fileHandleForWriting.close() }
        }
        #expect(await eventually { SessionStrays.carrying(session: id).count == 2 })
        #expect(SessionStrays.carrying(session: id, keeping: appPath).map(\.pid) == [stray.processIdentifier])
        #expect(Set(SessionStrays.carrying(session: id, keeping: nil).map(\.pid)) == [app.processIdentifier, stray.processIdentifier])
        // The built tool server's own app: the VibeSwitcher beside the program asking (here the test runner's).
        let beside = try #require(SessionStrays.appBesideThisProgram)
        let runner = try #require(HostServer.executable(of: getpid()))
        #expect(beside == ((runner as NSString).deletingLastPathComponent as NSString).appendingPathComponent("VibeSwitcher"))
    }
}
