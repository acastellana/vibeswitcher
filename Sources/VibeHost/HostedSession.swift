import Foundation
import SwiftTerm
import VibeCore

/// One window session: its pseudo-terminal and child process, everything it printed (replay buffer and a
/// headless terminal for title, screen and scrollback text), and input/resize/kill.
/// Not thread-safe: every member is used on `queue`.
public final class HostedSession {
    public enum Failure: Error, Equatable {
        case noSuchFolder(String)
        case spawnFailed
    }

    public private(set) var info: HostSession
    public var id: UUID { info.id }
    /// Each chunk the program printed.
    public var onOutput: ((Data) -> Void)?
    /// Title, size or exit changed.
    public var onChange: ((HostSession) -> Void)?
    public var onBell: (() -> Void)?
    /// While a view is attached it answers terminal queries; the headless terminal's answers are dropped.
    public var clientsAttached = false

    private let masterFD: Int32
    private let queue: DispatchQueue
    private var ring: OutputRing
    private let terminal: Terminal
    private let headless = HeadlessDelegate()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var exitSource: DispatchSourceProcess?
    /// Backs up `exitSource`, which misses a program that exits before it's registered (it's registered
    /// asynchronously, and a process that already exited can't be watched).
    private var exitPoll: DispatchSourceTimer?
    private var pendingInput = Data()
    private var closed = false
    static let maxPendingInput = 1 << 20

    private init(info: HostSession, masterFD: Int32, queue: DispatchQueue, ringCapacity: Int) {
        self.info = info
        self.masterFD = masterFD
        self.queue = queue
        ring = OutputRing(capacity: ringCapacity)
        terminal = Terminal(delegate: headless, options: TerminalOptions(cols: info.cols, rows: info.rows, scrollback: 5_000))
    }

    /// `$SHELL -l -i [-c command]`: an interactive login shell reads both `.zprofile` and `.zshrc`, so the
    /// agent gets the PATH it has in Terminal (nvm, Homebrew…).
    public static func arguments(shell: String, command: String?, keepShell: Bool) -> [String] {
        guard let command else { return [shell, "-l", "-i"] }
        let line = keepShell ? "\(command); exec \(RecentProjects.shellQuote(shell)) -l -i" : command
        return [shell, "-l", "-i", "-c", line]
    }

    public static func environment(base: [String: String], extra: [String: String], id: UUID) -> [String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "VibeSwitcher"
        env["VIBESWITCHER_SESSION"] = id.uuidString
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (name, value) in extra where LaunchPlan.validEnvName(name) { env[name] = value }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// `launcher`: an executable that handles `--pty-exec` (see `PTYSpawn`), normally the host itself.
    public static func spawn(_ request: SpawnRequest, shell: String, launcher: String, baseEnvironment: [String: String],
                             ringCapacity: Int, queue: DispatchQueue) throws -> HostedSession {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.noSuchFolder(request.cwd)
        }
        let id = UUID()
        let cols = max(2, min(request.cols, 1000)), rows = max(2, min(request.rows, 500))
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let args = arguments(shell: shell, command: request.command, keepShell: request.keepShell)
        let env = environment(base: baseEnvironment, extra: request.env, id: id)
        guard let child = PTYSpawn.spawn(launcher: launcher, executable: shell, args: args, env: env, directory: request.cwd, size: &size) else {
            throw Failure.spawnFailed
        }
        let name = ptsname(child.masterFD).map { String(cString: $0) } ?? ""
        let tty = name.hasPrefix("/dev/") ? String(name.dropFirst(5)) : name
        _ = fcntl(child.masterFD, F_SETFL, fcntl(child.masterFD, F_GETFL) | O_NONBLOCK)
        // Not inherited by sessions started later: another session holding this PTY open would keep it alive.
        _ = fcntl(child.masterFD, F_SETFD, FD_CLOEXEC)
        let info = HostSession(id: id, tty: tty, childPID: child.pid, cwd: request.cwd, command: request.command,
                               label: request.label, agent: request.agent, title: "", startedAt: Date(),
                               cols: cols, rows: rows, exit: nil)
        let session = HostedSession(info: info, masterFD: child.masterFD, queue: queue, ringCapacity: ringCapacity)
        session.start()
        return session
    }

    private func start() {
        headless.onReply = { [weak self] data in
            guard let self, !self.clientsAttached else { return }
            self.write(data)
        }
        headless.onTitle = { [weak self] title in
            guard let self, self.info.title != title else { return }
            self.info.title = title
            self.onChange?(self.info)
        }
        headless.onBell = { [weak self] in self?.onBell?() }

        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        read.setEventHandler { [weak self] in self?.drain() }
        read.resume()
        readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: info.childPID, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.reap() }
        exit.resume()
        exitSource = exit

        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now() + 0.05, repeating: 1, leeway: .milliseconds(200))
        poll.setEventHandler { [weak self] in self?.reap() }
        poll.resume()
        exitPoll = poll
    }

    /// Reads what's available; never blocks (the PTY is nonblocking), so the program never waits on us.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<16 {
            let count = Darwin.read(masterFD, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                ring.append(chunk)
                terminal.feed(buffer: buffer[0..<count])
                onOutput?(chunk)
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            // 0 or EIO: the terminal's other side is closed (the program and everything it started are gone).
            readSource?.cancel()
            readSource = nil
            return
        }
    }

    private func reap() {
        var status: Int32 = 0
        guard waitpid(info.childPID, &status, WNOHANG) == info.childPID else { return }
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        exitSource?.cancel()
        exitSource = nil
        exitPoll?.cancel()
        exitPoll = nil
        info.exit = .init(status: code, at: Date())
        onChange?(info)
    }

    /// Replays at most 1 MB: the program redraws its screen on attach anyway (see `OutputRing.replay`).
    public func replay() -> Data { ring.replay(limit: 1 << 20) }

    /// Writes to the program's input; what doesn't fit right now waits (up to 1 MB) for room.
    public func write(_ bytes: Data) {
        guard !closed, !bytes.isEmpty else { return }
        if pendingInput.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
            if written == bytes.count { return }
            let rest = written > 0 ? bytes.dropFirst(written) : bytes[...]
            guard written >= 0 || errno == EAGAIN || errno == EINTR else { return }
            pendingInput = Data(rest)
        } else {
            guard pendingInput.count + bytes.count <= Self.maxPendingInput else { return }
            pendingInput.append(bytes)
        }
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
            source.setEventHandler { [weak self] in self?.flushInput() }
            source.resume()
            writeSource = source
        }
    }

    private func flushInput() {
        let written = pendingInput.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
        if written > 0 { pendingInput = Data(pendingInput.dropFirst(written)) }
        if pendingInput.isEmpty || (written < 0 && errno != EAGAIN && errno != EINTR) {
            pendingInput = Data()
            writeSource?.cancel()
            writeSource = nil
        }
    }

    public func resize(cols: Int, rows: Int) {
        let cols = max(2, min(cols, 1000)), rows = max(2, min(rows, 500))
        guard cols != info.cols || rows != info.rows else { return }
        setWindowSize(cols: cols, rows: rows)
        terminal.resize(cols: cols, rows: rows)
        info.cols = cols
        info.rows = rows
        onChange?(info)
    }

    /// Makes the program repaint: one row smaller, then back (two SIGWINCHes). Claude Code and Codex redraw
    /// their whole screen on a resize, which fixes up an approximate replay.
    public func nudgeRedraw() {
        guard !closed, info.isLive else { return }
        setWindowSize(cols: info.cols, rows: max(2, info.rows - 1))
        queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, !self.closed else { return }
            self.setWindowSize(cols: self.info.cols, rows: self.info.rows)
        }
    }

    private func setWindowSize(cols: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: masterFD, windowSize: &size)
    }

    public func screenText() -> String {
        (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    /// The last `lines` lines above the screen (normal buffer), and the screen itself.
    public func historyText(lines: Int) -> (history: String, screen: String) {
        let all = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
            .components(separatedBy: "\n")
        let screenRows = terminal.rows
        let above = all.count > screenRows ? Array(all[0..<(all.count - screenRows - 1)]) : []
        return (above.suffix(lines).joined(separator: "\n"), screenText())
    }

    /// Like closing a Terminal tab: SIGHUP to the shell's process group and to the job in the foreground
    /// (the agent runs in its own group). Then SIGKILL after 5 s to whichever of those groups still exists:
    /// a program that ignores SIGHUP would otherwise outlive the session, detached, once the shell exits.
    public func terminate() {
        guard info.isLive || readSource != nil else { return }
        let groups = Set([info.childPID, tcgetpgrp(masterFD)].filter { $0 > 0 })
        groups.forEach { Darwin.kill(-$0, SIGHUP) }
        queue.asyncAfter(deadline: .now() + 5) {
            for group in groups where Darwin.kill(-group, 0) == 0 { Darwin.kill(-group, SIGKILL) }
        }
    }

    /// Releases the PTY. Call after the session ended (or when the host quits).
    public func close() {
        guard !closed else { return }
        closed = true
        // The PTY closes once its watchers are done with it (closing first could hand its number to a new
        // session's PTY while an old watcher still looks at it).
        let done = DispatchGroup()
        for source in [readSource as DispatchSourceProtocol?, writeSource].compactMap({ $0 }) where !source.isCancelled {
            done.enter()
            source.setCancelHandler { done.leave() }
            source.cancel()
        }
        exitSource?.cancel()
        exitPoll?.cancel()
        let fd = masterFD
        done.notify(queue: queue) { Darwin.close(fd) }
    }
}

/// The headless terminal's delegate: replies to queries, title, bell.
final class HeadlessDelegate: TerminalDelegate {
    var onReply: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?

    func send(source: Terminal, data: ArraySlice<UInt8>) { onReply?(Data(data)) }
    func setTerminalTitle(source: Terminal, title: String) { onTitle?(title) }
    func bell(source: Terminal) { onBell?() }
}
