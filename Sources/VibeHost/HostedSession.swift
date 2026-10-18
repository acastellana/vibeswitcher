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
    /// It ended: its raw wait status (before `onChange` says so).
    public var onEnd: ((Int32) -> Void)?
    /// While a view is attached it answers terminal queries; the headless terminal's answers are dropped.
    public var clientsAttached = false

    private let masterFD: Int32
    private let queue: DispatchQueue
    /// Both let go once the session ended (see `release`).
    private var ring: OutputRing?
    private var terminal: Terminal?
    /// What an ended session keeps: its last screen, how it was drawn, and the last lines above it.
    private var ended: (screen: String, runs: [ScreenRun], history: String)?
    static let endedHistoryLines = 500
    private let headless = HeadlessDelegate()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var exitSource: DispatchSourceProcess?
    /// Backs up `exitSource`, which misses a program that exits before it's registered (it's registered
    /// asynchronously, and a process that already exited can't be watched).
    private var exitPoll: DispatchSourceTimer?
    private var pendingInput = Data()
    /// The client that asked to end it (see `terminate`): its process id and name.
    private var killer: (pid: pid_t, name: String?)?
    /// Input was refused for lack of room: more is refused until what waits went in, so none lands out of order.
    private var refusingInput = false
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

    /// What a new host build needs to carry this session on (see `HostHandover`): the PTY's descriptor survives the
    /// exec, the rest is copied.
    func saved() -> HostHandover.Session {
        HostHandover.Session(info: info, masterFD: closed ? nil : masterFD, output: ring?.replay() ?? Data(), pendingInput: pendingInput,
                             ended: ended.map { .init(screen: $0.screen, runs: $0.runs, history: $0.history) })
    }

    /// The session as the host build before this one left it. The screen and scrollback are rebuilt from the replay
    /// (fed before the terminal's answers are wired up: queries in old output were answered back then). A PTY that
    /// didn't survive the exec means the session's terminal hung up: it's restored as ended.
    static func restore(_ saved: HostHandover.Session, ringCapacity: Int, queue: DispatchQueue) -> HostedSession {
        var info = saved.info
        let fd = saved.masterFD.flatMap { HostHandover.isOpen($0) ? $0 : nil }
        if fd == nil, saved.masterFD != nil, info.isLive { info.exit = .init(status: -1, at: Date()) }
        let session = HostedSession(info: info, masterFD: fd ?? -1, queue: queue, ringCapacity: ringCapacity)
        if let ended = saved.ended {
            // Released already: only its last screen.
            session.ended = (ended.screen, ended.runs, ended.history)
            session.ring = nil
            session.terminal = nil
        } else {
            session.ring?.append(saved.output)
            session.terminal?.feed(buffer: [UInt8](saved.output)[...])
        }
        guard let fd else {
            session.closed = true
            // Ended with its terminal gone: what it keeps of an ended session, from the rebuilt screen.
            if saved.ended == nil { session.release() }
            return session
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        session.start()
        // A redraw the build before was halfway through (one row smaller) is put right; full-screen programs then
        // repaint the rebuilt screen.
        session.setWindowSize(cols: info.cols, rows: info.rows)
        session.nudgeRedraw()
        session.write(saved.pendingInput)
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
        headless.onProgramStatus = { [weak self] report in self?.programStatus(report) }
        if let terminal { headless.listen(to: terminal) }

        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        read.setEventHandler { [weak self] in self?.drain() }
        read.resume()
        readSource = read

        // Ended (and reaped) already: its pid may belong to someone else now.
        guard info.isLive else { return }
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

    /// Reads what's available, up to `reads` × 64 KB; never blocks (the PTY is nonblocking), so the program never
    /// waits on us.
    private func drain(reads: Int = 16) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<reads {
            let count = Darwin.read(masterFD, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                ring?.append(chunk)
                terminal?.feed(buffer: buffer[0..<count])
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

    /// The host answers the OSC 7501 query even while a view is attached (views don't speak it), and keeps the
    /// program's own record; its tasks' (reports with an `id`) are left out.
    private func programStatus(_ report: ProgramStatus.Report) {
        let status: ProgramStatus?
        switch report {
        case .query:
            write(ProgramStatus.queryReply)
            return
        case .clear(let id):
            guard id == nil else { return }
            status = nil
        case .status(let id, let reported):
            guard id == nil else { return }
            status = reported
        }
        // A repeated report keeps its `since`: the state didn't change then.
        var previous = info.programStatus
        if let status { previous?.since = status.since }
        guard status != previous else { return }
        info.programStatus = status
        onChange?(info)
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
        info.exit = .init(status: code, at: Date(), signal: signal == 0 ? nil : signal, core: signal == 0 ? nil : status & 0x80 != 0,
                          killedBy: killer?.pid, killedByName: killer?.name)
        // A program that died without `state=clear` isn't still working.
        info.programStatus = nil
        // What it printed last is still in the PTY.
        if readSource != nil { drain(reads: 256) }
        release()
        onEnd?(status)
        onChange?(info)
    }

    /// Lets go of what only a running session needs: the PTY (from the system's pool, shared with Terminal), the
    /// replay buffer and the terminal with its 5,000 lines. Kept: the last screen and the lines just above it.
    /// Whatever the program left running on the terminal loses it, as when a Terminal tab closes.
    private func release() {
        guard let terminal else { return }
        let history = historyText(lines: Self.endedHistoryLines).history
        let screen = Self.styledScreen(of: terminal)
        ended = (screen.text, screen.runs, history)
        self.terminal = nil
        ring = nil
        pendingInput = Data()
        close()
    }

    /// Whether it still holds a running session's PTY, replay buffer or terminal.
    var holdsLiveResources: Bool { !closed || terminal != nil || ring != nil }

    /// Replays at most 1 MB: the program redraws its screen on attach anyway (see `OutputRing.replay`). An ended
    /// session's replay draws its last screen (see `drawing`).
    public func replay() -> Data {
        if let ring { return ring.replay(limit: 1 << 20) }
        return ended.map { Self.drawing(history: $0.history, screen: $0.screen, runs: $0.runs) } ?? Data()
    }

    /// The lines above the screen, then the screen as it was drawn (`styledScreen`'s text and runs).
    static func drawing(history: String, screen: String, runs: [ScreenRun]) -> Data {
        var out = history.isEmpty ? "" : history.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
        let byRow = Dictionary(grouping: runs, by: \.row)
        for (row, line) in screen.components(separatedBy: "\n").enumerated() {
            if row > 0 { out += "\r\n" }
            // A wide character's second cell is an empty character in the text; the wide one fills both cells.
            let characters = Array(line)
            var column = 0
            for run in (byRow[row] ?? []).sorted(by: { $0.column < $1.column }) where run.column >= column {
                let start = min(run.column, characters.count), end = min(run.column + run.length, characters.count)
                out += String(characters[column..<start]) + sgr(run) + String(characters[start..<end]) + "\u{1b}[0m"
                column = end
            }
            out += String(characters[min(column, characters.count)...])
        }
        return Data(out.replacingOccurrences(of: "\u{0}", with: "").utf8)
    }

    private static func sgr(_ run: ScreenRun) -> String {
        var codes: [String] = []
        if run.faint { codes.append("2") }
        if run.inverse { codes.append("7") }
        switch run.color {
        case .palette(let code)?: codes.append("38;5;\(code)")
        case .rgb(let red, let green, let blue)?: codes.append("38;2;\(red);\(green);\(blue)")
        case nil: break
        }
        return "\u{1b}[\(codes.joined(separator: ";"))m"
    }

    /// Writes to the program's input; what doesn't fit right now waits (up to 1 MB) for room. False: none of it went
    /// in (no room, the session ended or its terminal failed).
    @discardableResult
    public func write(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return true }
        guard !closed else { return false }
        if pendingInput.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
            if written == bytes.count { return true }
            let rest = written > 0 ? bytes.dropFirst(written) : bytes[...]
            guard written >= 0 || errno == EAGAIN || errno == EINTR else { return false }
            pendingInput = Data(rest)
        } else {
            guard !refusingInput, pendingInput.count + bytes.count <= Self.maxPendingInput else {
                refusingInput = true
                return false
            }
            pendingInput.append(bytes)
        }
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
            source.setEventHandler { [weak self] in self?.flushInput() }
            source.resume()
            writeSource = source
        }
        return true
    }

    private func flushInput() {
        let written = pendingInput.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
        if written > 0 { pendingInput = Data(pendingInput.dropFirst(written)) }
        if pendingInput.isEmpty || (written < 0 && errno != EAGAIN && errno != EINTR) {
            pendingInput = Data()
            refusingInput = false
            writeSource?.cancel()
            writeSource = nil
        }
    }

    public func resize(cols: Int, rows: Int) {
        let cols = max(2, min(cols, 1000)), rows = max(2, min(rows, 500))
        guard let terminal, cols != info.cols || rows != info.rows else { return }
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
        guard !closed else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: masterFD, windowSize: &size)
    }

    public func screenText() -> String {
        guard let terminal else { return ended?.screen ?? "" }
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    /// `screenText`, and how its characters are drawn (see `ScreenRun`).
    public func styledScreen() -> (text: String, runs: [ScreenRun]) {
        guard let terminal else { return (ended?.screen ?? "", ended?.runs ?? []) }
        return Self.styledScreen(of: terminal)
    }

    /// The text matches `screenText`'s (one character per cell, trimmed on the right); runs cover what isn't plain.
    /// Read cell by cell: a wide character's second cell is an empty character of its own, and a cell that joins
    /// the character before it (a mark drawn in its own cell) adds to that character, so runs never drift.
    public static func styledScreen(of terminal: Terminal) -> (text: String, runs: [ScreenRun]) {
        var lines: [String] = []
        var runs: [ScreenRun] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            var text = ""
            var column = -1
            for cell in 0..<min(line.count, line.getTrimmedLength()) {
                let character = line[cell].getCharacter()
                text.append(character)
                // Else it joined the character before it.
                if text.last == character { column += 1 }
                let attribute = line[cell].attribute
                let style = (faint: attribute.style.contains(.dim), inverse: attribute.style.contains(.inverse), color: color(attribute.fg))
                guard style.faint || style.inverse || style.color != nil else { continue }
                if let last = runs.last, last.row == row, last.column + last.length >= column,
                   (last.faint, last.inverse, last.color) == style {
                    runs[runs.count - 1].length = column + 1 - last.column
                } else {
                    runs.append(ScreenRun(row: row, column: column, length: 1, faint: style.faint, inverse: style.inverse, color: style.color))
                }
            }
            lines.append(text)
        }
        return (lines.joined(separator: "\n"), runs)
    }

    private static func color(_ color: Attribute.Color) -> ScreenRun.Color? {
        switch color {
        case .ansi256(let code): return .palette(Int(code))
        case .trueColor(let red, let green, let blue): return .rgb(Int(red), Int(green), Int(blue))
        case .defaultColor, .defaultInvertedColor: return nil
        }
    }

    /// The last `lines` lines above the screen (normal buffer), and the screen itself. At most
    /// `endedHistoryLines` once the session ended.
    public func historyText(lines: Int) -> (history: String, screen: String) {
        guard let terminal else {
            let history = ended?.history.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines) ?? []
            return (history.joined(separator: "\n"), screenText())
        }
        let all = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
            .components(separatedBy: "\n")
        let screenRows = terminal.rows
        let above = all.count > screenRows ? Array(all[0..<(all.count - screenRows - 1)]) : []
        return (above.suffix(lines).joined(separator: "\n"), screenText())
    }

    /// Like closing a Terminal tab: SIGHUP to the shell's process group and to the job in the foreground
    /// (the agent runs in its own group). Then SIGKILL after 5 s to whichever of those groups still exists:
    /// a program that ignores SIGHUP would otherwise outlive the session, detached, once the shell exits.
    /// `by`: the client that asked (its process id), which its exit names.
    public func terminate(by client: pid_t? = nil) {
        guard info.isLive || readSource != nil else { return }
        if let client, info.isLive, killer == nil { killer = (client, ProcessTable.info(pid: client)?.comm) }
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

/// The headless terminal's delegate: replies to queries, title, bell, program status (OSC 7501).
final class HeadlessDelegate: TerminalDelegate {
    var onReply: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onProgramStatus: ((ProgramStatus.Report) -> Void)?

    /// SwiftTerm leaves OSC 7501 alone otherwise.
    func listen(to terminal: Terminal) {
        terminal.registerOscHandler(code: ProgramStatus.code) { [weak self] payload in
            guard let report = ProgramStatus.parse(String(decoding: payload, as: UTF8.self), at: Date()) else { return }
            self?.onProgramStatus?(report)
        }
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) { onReply?(Data(data)) }
    func setTerminalTitle(source: Terminal, title: String) { onTitle?(title) }
    func bell(source: Terminal) { onBell?() }
}
