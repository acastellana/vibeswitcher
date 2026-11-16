import Foundation
import Testing

/// `installScript`: a fake command it has just installed runs at once while the process starts children meanwhile, as
/// a full run's other tests do. Linux won't run a file that any process holds open for writing ("Text file busy",
/// ETXTBSY), and a child keeps every descriptor of this process that isn't close-on-exec: a script written here could
/// be held so (LoadHarnessTests' fake xcode-select, linux CI 43840361847). Here each child keeps them for 50 ms.
@Suite struct InstallScriptTests {
    let temp = Scratch()

    @Test func aScriptJustInstalledRunsWhileTheProcessStartsChildren() async throws {
        let folder = temp.url("install-script")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let children = Children()
        let spawning = Thread { children.spawnUntilStopped() }
        spawning.start()
        let refused = await offPool { () -> [String] in
            defer { children.stopAndWait() }
            var refused: [String] = []
            for index in 0..<60 {
                let script = folder.appendingPathComponent("tool-\(index)")
                do {
                    try installScript("#!/bin/sh\necho ran-\(index)\n", at: script)
                    let run = Process()
                    run.executableURL = script
                    let pipe = Pipe()
                    run.standardOutput = pipe
                    try run.run()
                    let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    waitForEnd(run)
                    if run.terminationStatus != 0 || said != "ran-\(index)\n" { refused.append("\(index): said \(said)") }
                } catch {
                    refused.append("\(index): \(error)")
                }
            }
            return refused
        }
        #expect(refused.isEmpty, "\(refused.count) of 60 scripts didn't run, the first: \(refused.first ?? "")")
        #expect(children.started > 0)
    }

    /// Children started with `posix_spawn` and nothing closed: each keeps every descriptor of this process that isn't
    /// close-on-exec, for its 50 ms. At most 64 at once.
    private final class Children: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var live: [pid_t] = []
        private var count = 0
        private let done = DispatchSemaphore(value: 0)
        var started: Int { lock.withLock { count } }

        func spawnUntilStopped() {
            let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("0.05"), nil]
            let environment: [UnsafeMutablePointer<CChar>?] = [nil]
            defer { arguments.forEach { free($0) } }
            while !lock.withLock({ stopped }) {
                reap(blocking: false)
                guard lock.withLock({ live.count }) < 64 else { sched_yield(); continue }
                var pid = pid_t()
                if posix_spawn(&pid, "/bin/sleep", nil, nil, arguments, environment) == 0 {
                    lock.withLock {
                        live.append(pid)
                        count += 1
                    }
                }
            }
            reap(blocking: true)
            done.signal()
        }

        /// Stops the spawning, and returns once every child has ended and been waited for (bounded by the hang guard).
        func stopAndWait() {
            lock.withLock { stopped = true }
            _ = done.wait(timeout: .now() + hangGuard)
        }

        private func reap(blocking: Bool) {
            for pid in lock.withLock({ live }) {
                var status: Int32 = 0
                let got = waitpid(pid, &status, blocking ? 0 : WNOHANG)
                if got == pid || (got < 0 && errno == ECHILD) { lock.withLock { live.removeAll { $0 == pid } } }
            }
        }
    }
}
