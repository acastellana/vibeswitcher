import Foundation
import SwiftTerm
import VibeCore

/// One window session: its pseudo-terminal and child process, everything it printed (replay buffer, and a headless
/// terminal for title, screen and scrollback text, parsed in a process of its own: see `SessionParser`), and
/// input/resize/kill. Not thread-safe: every member is used on `queue`.
public final class HostedSession {
    public enum Failure: Error, Equatable {
        case noSuchFolder(String)
        case spawnFailed
        /// The launcher couldn't be started: what posix_spawn's errno says of it (see `LaunchPreflight.couldntStart`).
        case couldntStart(String)
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
    /// The session's parser stalled or ended, and what was done about it: a line for the host's log.
    public var onParserTrouble: ((String) -> Void)?
    /// Its PTY changed size: a line for the host's log (see `resize`).
    public var onResized: ((String) -> Void)?
    /// When `onResized` last had a line, and the newest resize since, held until a second after it (see `logResize`).
    private var resizeLogged = Date.distantPast
    private var heldResize: (line: String, count: Int)?
    /// The resize log's clock, and how it writes a held line later (nil: on `queue`); a test's own instead.
    var resizeClock: () -> Date = Date.init
    var resizeLater: ((TimeInterval, @escaping () -> Void) -> Void)?

    private let masterFD: Int32
    private let queue: DispatchQueue
    /// Both let go once the session ended (see `release`).
    private var ring: OutputRing?
    /// The headless terminal, in its own process. Nil once the session ended, or after it failed too often.
    private var parser: ParserLink?
    /// Starts the parser (the host's executable, like `PTYSpawn`'s launcher).
    private let launcher: String
    private let parserOptions: ParserOptions
    /// What the parser showed last: what a view falls back on when there's no parser to ask.
    private var lastView = ParserView.empty
    /// Whether its program asked for focus events (see `FocusEvents`), read off its output as it's read. On `queue`.
    private var focus = FocusEvents()
    public var focusEvents: Bool { focus.on }
    /// When its parser failed lately (see `replaceParser`).
    private var parserFailures: [Date] = []
    static let maxParserFailures = 5
    /// Ends a stalled parser (see `checkParser`).
    private var watchdog: SessionTimer?
    /// Makes the exit poll's and the watchdog's timers: dispatch's on `queue`, a test's on a clock of its own.
    private let timers: SessionTimers
    /// Reading the PTY waits while the parser is this far behind, as the program used to wait on the parse.
    static let maxUnparsed = 4 << 20
    private var readingPaused = false
    /// While reading is paused, a look every `exitingCheckInterval` at whether the program is exiting (see
    /// `checkExiting`).
    private var exitingCheck: SessionTimer?
    static let exitingCheckInterval: TimeInterval = 0.5
    /// The program is exiting, not reaped yet: reading doesn't pause (see `checkExiting`).
    private var exiting = false
    /// It ended, and its last screen is on its way from the parser: what's left to do then (see `finish`).
    private var finishing: (() -> Void)?
    /// What an ended session keeps: its last screen, how it was drawn, and the last lines above it.
    private var ended: (screen: String, runs: [ScreenRun], history: String)?
    static let endedHistoryLines = 500
    /// Reads of more history than the parser keeps, under way (see `longView`).
    private var historyReads: [HistoryRead] = []
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var exitSource: DispatchSourceProcess?
    /// Backs up `exitSource`, which misses a program that exits before it's registered (it's registered
    /// asynchronously, and a process that already exited can't be watched): a look 50 ms in, then less and less often
    /// (see `exitPollDelays`), not every second for the session's life (30 sessions woke the host 30 times a second).
    private var exitPoll: SessionTimer?
    /// The looks' spacing, the last one repeated: a program the source missed is seen ended within 30 s at worst, and
    /// one ending once the source is registered (all but those that end in their first moments) at once.
    static let exitPollDelays: [TimeInterval] = [0.05, 1, 5, 30]
    private var exitPolls = 0
    private var pendingInput = Data()
    /// The client that asked to end it (see `terminate`): its process id and name.
    private var killer: (pid: pid_t, name: String?)?
    /// Input was refused for lack of room: more is refused until what waits went in, so none lands out of order.
    private var refusingInput = false
    private var closed = false
    static let maxPendingInput = 1 << 20
    /// Told once the input waiting for room has all gone in (or can't: the session closed). See `whenInputWent`.
    private var inputWaiters: [() -> Void] = []

    private init(info: HostSession, masterFD: Int32, queue: DispatchQueue, ringCapacity: Int, launcher: String, parser: ParserOptions,
                 timers: SessionTimers = .dispatch) {
        self.info = info
        self.masterFD = masterFD
        self.queue = queue
        self.launcher = launcher
        parserOptions = parser
        self.timers = timers
        ring = OutputRing(capacity: ringCapacity)
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

    /// `launcher`: an executable that handles `--pty-exec` (see `PTYSpawn`) and `--parse-session` (see `SessionParser`),
    /// normally the host itself.
    public static func spawn(_ request: SpawnRequest, shell: String, launcher: String, baseEnvironment: [String: String],
                             ringCapacity: Int, queue: DispatchQueue, parser: ParserOptions = ParserOptions()) throws -> HostedSession {
        try spawn(request, shell: shell, launcher: launcher, baseEnvironment: baseEnvironment, ringCapacity: ringCapacity, queue: queue,
                  parser: parser, timers: .dispatch)
    }

    /// `timers`: a test's, on its own clock (see `SessionTimers`).
    static func spawn(_ request: SpawnRequest, shell: String, launcher: String, baseEnvironment: [String: String],
                      ringCapacity: Int, queue: DispatchQueue, parser: ParserOptions, timers: SessionTimers) throws -> HostedSession {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.noSuchFolder(request.cwd)
        }
        let id = UUID()
        let cols = max(2, min(request.cols, 1000)), rows = max(2, min(request.rows, 500))
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let args = arguments(shell: shell, command: request.command, keepShell: request.keepShell)
        let env = environment(base: baseEnvironment, extra: request.env, id: id)
        var code: Int32 = 0
        guard let child = PTYSpawn.spawn(launcher: launcher, executable: shell, args: args, env: env, directory: request.cwd, size: &size,
                                         failure: &code) else {
            throw code == 0 ? Failure.spawnFailed : Failure.couldntStart(LaunchPreflight.couldntStart(launcher, in: request.cwd, code: code))
        }
        // ptsname_r: ptsname's buffer is shared between threads, and sessions start from several at once.
        var buffer = [CChar](repeating: 0, count: 128)
        let name = ptsname_r(child.masterFD, &buffer, buffer.count) == 0 ? String(cString: buffer) : ""
        let tty = name.hasPrefix("/dev/") ? String(name.dropFirst(5)) : name
        _ = fcntl(child.masterFD, F_SETFL, fcntl(child.masterFD, F_GETFL) | O_NONBLOCK)
        // Not inherited by sessions started later: another session holding this PTY open would keep it alive.
        _ = fcntl(child.masterFD, F_SETFD, FD_CLOEXEC)
        let info = HostSession(id: id, tty: tty, childPID: child.pid, cwd: request.cwd, command: request.command,
                               label: request.label, agent: request.agent, title: "", startedAt: Date(),
                               cols: cols, rows: rows, exit: nil)
        let session = HostedSession(info: info, masterFD: child.masterFD, queue: queue, ringCapacity: ringCapacity, launcher: launcher,
                                    parser: parser, timers: timers)
        session.startParser(replay: Data())
        session.start()
        return session
    }

    /// What a new host build needs to carry this session on (see `HostHandover`): the PTY's descriptor survives the
    /// exec, the rest is copied.
    func saved() -> HostHandover.Session {
        var saved = HostHandover.Session(info: info, masterFD: closed ? nil : masterFD, output: ring?.replay() ?? Data(), pendingInput: pendingInput,
                                         ended: ended.map { .init(screen: $0.screen, runs: $0.runs, history: $0.history) })
        saved.focusEvents = focus.on
        return saved
    }

    /// The session as the host build before this one left it. The screen and scrollback are rebuilt from the replay
    /// (fed quietly: queries in old output were answered back then). A PTY that didn't survive the exec means the
    /// session's terminal hung up: it's restored as ended.
    static func restore(_ saved: HostHandover.Session, launcher: String, parser: ParserOptions, ringCapacity: Int,
                        queue: DispatchQueue) -> HostedSession {
        var info = saved.info
        let fd = saved.masterFD.flatMap { HostHandover.isOpen($0) ? $0 : nil }
        if fd == nil, saved.masterFD != nil, info.isLive { info.exit = .init(status: -1, at: Date()) }
        let session = HostedSession(info: info, masterFD: fd ?? -1, queue: queue, ringCapacity: ringCapacity, launcher: launcher, parser: parser)
        if let ended = saved.ended {
            // Released already: only its last screen.
            session.ended = (ended.screen, ended.runs, ended.history)
            session.ring = nil
        } else {
            session.ring?.append(saved.output)
            if let on = saved.focusEvents { session.focus = FocusEvents(on: on) } else { session.focus.feed(saved.output) }
            session.startParser(replay: saved.output)
        }
        guard let fd else {
            session.closed = true
            // Ended with its terminal gone: what it keeps of an ended session, from the rebuilt screen.
            if saved.ended == nil { session.finish {} }
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

    /// A parser for this session, rebuilt from `replay` (fed quietly), and the watchdog over it.
    private func startParser(replay: Data) {
        guard let link = ParserLink.start(launcher: launcher, cols: info.cols, rows: info.rows, options: parserOptions, queue: queue) else {
            onParserTrouble?("couldn't start a parser: its screen is the last one shown")
            return
        }
        link.onReply = { [weak self] data in
            guard let self, !self.clientsAttached else { return }
            self.write(data)
        }
        link.onTitle = { [weak self] title in
            guard let self, self.info.title != title else { return }
            self.info.title = title
            self.onChange?(self.info)
        }
        link.onBell = { [weak self] in self?.onBell?() }
        link.onProgramStatus = { [weak self] payload in
            guard let report = ProgramStatus.parse(payload, at: Date()) else { return }
            self?.programStatus(report)
        }
        link.onParsed = { [weak self] in self?.resumeReadingIfCaughtUp() }
        link.onBusy = { [weak self, weak link] in
            guard let self, let link, self.parser === link else { return }
            self.startWatchdog()
        }
        link.onGone = { [weak self, weak link] status in
            guard let self, let link, self.parser === link else { return }
            self.replaceParser(link, because: "ended (\(HostLog.waitStatus(status)))")
        }
        link.feed(replay, quietly: true)
        parser = link
        startWatchdog()
    }

    /// A parser that stalled or ended is replaced by a new one, rebuilt from the replay without the bytes it hadn't
    /// parsed yet: they may be what it can't parse (the program redraws its screen anyway, see `nudgeRedraw`). One
    /// that keeps failing (more than `maxParserFailures` times in a minute) isn't: the session runs on without one,
    /// its screen the last one shown.
    private func replaceParser(_ link: ParserLink, because reason: String) {
        let unparsed = link.unparsed
        link.stop()
        parser = nil
        defer { resumeReading() }
        let now = Date()
        parserFailures = parserFailures.filter { now.timeIntervalSince($0) < 60 } + [now]
        let what = "parser (pid \(link.pid)) \(reason) with \(unparsed) bytes unparsed"
        guard parserFailures.count <= Self.maxParserFailures, let ring else {
            let count = parserFailures.count
            onParserTrouble?("\(what); \(ring == nil ? "it ended" : "failed \(count) times in a minute"): no parser now, its screen stays the last one shown")
            return
        }
        let replay = ring.replay()
        startParser(replay: replay.count > unparsed ? Data(replay.dropLast(unparsed)) : Data())
        onParserTrouble?("\(what): started another (pid \(parser?.pid ?? 0)) without those bytes")
        nudgeRedraw()
    }

    /// Runs while the parser has work (output it hasn't parsed, a view it hasn't given): a parser with none can't be
    /// stalled, and 30 idle sessions would otherwise wake the host 30 times a second for nothing. It stops at the
    /// first look that finds the parser idle; the parser's next work starts it again (`ParserLink.onBusy`).
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let interval = max(0.05, min(1, parserOptions.stallLimit / 4))
        let timer = timers.make(.parserWatchdog, queue) { [weak self] in self?.checkParser() }
        timer.schedule(after: interval, repeating: interval, leeway: .milliseconds(Int(interval * 250)))
        watchdog = timer
    }

    /// Output or a request waiting on the parser for longer than `ParserOptions.stallLimit`, with no progress: it's
    /// stalled. A parser with nothing to do: the watchdog stops until it has.
    private func checkParser() {
        guard let parser, case (true, let since) = parser.busy else {
            watchdog?.cancel()
            watchdog = nil
            return
        }
        let waited = Date().timeIntervalSince(since)
        guard waited > parserOptions.stallLimit else { return }
        replaceParser(parser, because: "stalled for \(String(format: "%.1f", waited)) s")
    }

    private func pauseReading() {
        guard !readingPaused, let readSource else { return }
        readSource.suspend()
        readingPaused = true
        let check = timers.make(.exitingCheck, queue) { [weak self] in self?.checkExiting() }
        check.schedule(after: Self.exitingCheckInterval, repeating: Self.exitingCheckInterval, leeway: .milliseconds(100))
        exitingCheck = check
    }

    /// The kernel holds a session leader's exit until its terminal's output is read: killed (or ending with output
    /// still queued) while reading is paused, the program would stay unreaped until its parser caught up, or the
    /// watchdog replaced a stalled one. Exiting, it's read to the end, no pausing.
    private func checkExiting() {
        guard readingPaused, info.isLive, Self.isExiting(info.childPID) else { return }
        exiting = true
        resumeReading()
    }

    /// Whether `pid` is on its way out (or a zombie already).
    static func isExiting(_ pid: pid_t) -> Bool {
        var short = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 1, &short, size) == size else { return false }
        return short.pbsi_status == SZOMB || short.pbsi_flags & UInt32(PROC_FLAG_INEXIT) != 0
    }

    private func resumeReadingIfCaughtUp() {
        guard readingPaused, (parser?.unparsed ?? 0) < Self.maxUnparsed / 4 else { return }
        resumeReading()
    }

    private func resumeReading() {
        guard readingPaused else { return }
        readingPaused = false
        exitingCheck?.cancel()
        exitingCheck = nil
        readSource?.resume()
    }

    private func start() {
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

        let poll = timers.make(.exitPoll, queue) { [weak self] in
            guard let self else { return }
            self.reap()
            guard let poll = self.exitPoll else { return }
            self.exitPolls += 1
            let delay = Self.exitPollDelays[min(self.exitPolls, Self.exitPollDelays.count - 1)]
            poll.schedule(after: delay, repeating: nil, leeway: .milliseconds(Int(delay * 100)))
        }
        poll.schedule(after: Self.exitPollDelays[0], repeating: nil, leeway: .milliseconds(20))
        exitPoll = poll
    }

    /// Reads what's available, up to `reads` × 64 KB; never blocks (the PTY is nonblocking), so the program never
    /// waits on us, only on its parser once that's `maxUnparsed` behind (unless `pausing` is false).
    private func drain(reads: Int = 16, pausing: Bool = true) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<reads {
            let count = Darwin.read(masterFD, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                ring?.append(chunk)
                focus.feed(chunk)
                parser?.feed(chunk)
                onOutput?(chunk)
                if pausing, !exiting, let parser, parser.unparsed > Self.maxUnparsed { return pauseReading() }
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            // 0 or EIO: the terminal's other side is closed (the program and everything it started are gone).
            // A suspended watcher can't be let go (reap's drain reads with it paused).
            resumeReading()
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
        exiting = false
        info.exit = .init(status: code, at: Date(), signal: signal == 0 ? nil : signal, core: signal == 0 ? nil : status & 0x80 != 0,
                          killedBy: killer?.pid, killedByName: killer?.name)
        // A program that died without `state=clear` isn't still working.
        info.programStatus = nil
        // What it printed last is still in the PTY.
        if readSource != nil { drain(reads: 256, pausing: false) }
        finish { [weak self] in
            guard let self else { return }
            self.onEnd?(status)
            self.onChange?(self.info)
        }
    }

    /// Once the parser got through everything the session printed, its last screen is kept and the rest let go
    /// (see `release`); then `done`.
    private func finish(then done: @escaping () -> Void) {
        guard ended == nil, finishing == nil else { return done() }
        finishing = done
        view(historyLines: Self.endedHistoryLines) { [weak self] view in
            guard let self, let done = self.finishing else { return }
            self.finishing = nil
            self.release(with: view)
            done()
        }
    }

    /// A session ending now gets there without waiting for its parser (the screen it showed last): a handover is
    /// about to replace this process.
    func finishNow() {
        guard let done = finishing else { return }
        finishing = nil
        release(with: lastView)
        done()
    }

    /// Lets go of what only a running session needs: the PTY (from the system's pool, shared with Terminal), the
    /// replay buffer and the parser with its lines. Kept: the last screen and the lines just above it.
    /// Whatever the program left running on the terminal loses it, as when a Terminal tab closes.
    private func release(with view: ParserView) {
        guard ended == nil else { return }
        ended = (view.screen, view.runs, view.history ?? "")
        stopParser()
        ring = nil
        pendingInput = Data()
        close()
    }

    /// Ends the parser and its watchdog, and any history read under way (its view falls back on the parser's lines).
    private func stopParser() {
        parser?.stop()
        parser = nil
        watchdog?.cancel()
        watchdog = nil
        historyReads.forEach { $0.cancel() }
    }

    /// The parser goes before a handover's exec (the new build starts its own): no parser process is left behind
    /// for it. `resumeParser` brings it back if the exec fails.
    func suspendParser() { stopParser() }

    func resumeParser() {
        guard parser == nil, !closed, ended == nil, let ring else { return }
        startParser(replay: ring.replay())
    }

    /// Whether it still holds a running session's PTY, replay buffer or parser.
    var holdsLiveResources: Bool { !closed || parser != nil || ring != nil || !historyReads.isEmpty }

    /// Its parsers' process ids: the parser's and those of its history reads under way.
    var parserPIDs: [pid_t] { (parser.map { [$0.pid] } ?? []) + historyReads.map(\.pid) }

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
    public func write(_ bytes: Data) -> Bool { put(bytes, taken: false) }

    /// As `write(_:)`, for input the host already said it has (it waited behind a unit, see `InputOrder`, its room
    /// counted then): it waits for room whatever waits already.
    func writeTaken(_ bytes: Data) -> Bool { put(bytes, taken: true) }

    private func put(_ bytes: Data, taken: Bool) -> Bool {
        guard !bytes.isEmpty else { return true }
        guard !closed else { return false }
        if pendingInput.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
            if written == bytes.count { return true }
            let rest = written > 0 ? bytes.dropFirst(written) : bytes[...]
            guard written >= 0 || errno == EAGAIN || errno == EINTR else { return false }
            pendingInput = Data(rest)
        } else {
            guard taken || (!refusingInput && pendingInput.count + bytes.count <= Self.maxPendingInput) else {
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
            tellInputWent()
        }
    }

    /// Input waiting for room, in bytes, and whether more is refused until it went in (see `write`).
    var inputWaiting: (bytes: Int, refusing: Bool) { (pendingInput.count, refusingInput) }

    /// Calls `body` (on `queue`) once what was written has all reached the program's terminal: at once when nothing
    /// waits for room, or the session is closed.
    func whenInputWent(_ body: @escaping () -> Void) {
        guard !closed, !pendingInput.isEmpty else { return body() }
        inputWaiters.append(body)
    }

    private func tellInputWent() {
        let waiters = inputWaiters
        inputWaiters = []
        waiters.forEach { $0() }
    }

    /// `reason`: for the log line, "initial" (a view attached at its size) or "client" (a view's resize; the app's log
    /// says why).
    public func resize(cols: Int, rows: Int, reason: String = "client") {
        let cols = max(2, min(cols, 1000)), rows = max(2, min(rows, 500))
        guard ended == nil, cols != info.cols || rows != info.rows else { return }
        setWindowSize(cols: cols, rows: rows)
        parser?.resize(cols: cols, rows: rows)
        info.cols = cols
        info.rows = rows
        onChange?(info)
        logResize("resize \(id.uuidString.prefix(8)) to \(cols)×\(rows) (\(reason))")
    }

    /// One line a second at most: a resize within a second of the last line is held, and only the newest held one is
    /// written, a second after that line, with how many it stands for.
    private func logResize(_ line: String) {
        let wait = 1 - resizeClock().timeIntervalSince(resizeLogged)
        guard wait > 0 else {
            resizeLogged = resizeClock()
            onResized?(line)
            return
        }
        if heldResize == nil {
            let later = resizeLater ?? { [queue] wait, write in queue.asyncAfter(deadline: .now() + wait, execute: write) }
            later(wait) { [weak self] in
                guard let self, let held = self.heldResize else { return }
                self.heldResize = nil
                self.resizeLogged = self.resizeClock()
                self.onResized?(held.count > 1 ? "\(held.line), the last of \(held.count) within a second" : held.line)
            }
        }
        heldResize = (line, (heldResize?.count ?? 0) + 1)
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

    /// The screen, the lines above it when `historyLines` isn't nil (at most `endedHistoryLines` once the session
    /// ended; more than the parser keeps are read from the replay buffer, see `longView`) and how the screen is drawn,
    /// once the parser got through everything printed before. Without a parser to ask (or once it failed), what it
    /// showed last.
    public func view(historyLines: Int?, _ completion: @escaping (ParserView) -> Void) {
        if let ended = endedView(historyLines: historyLines) { return completion(ended) }
        guard let asked = parser else { return completion(fallbackView(historyLines: historyLines)) }
        if let lines = historyLines, lines > SessionParser.scrollback, let ring {
            return longView(lines: lines, replay: ring.held(), completion)
        }
        asked.view(historyLines: historyLines) { [weak self] view in
            guard let self else { return }
            guard let view else {
                // Replaced meanwhile: the new one is asked.
                if let parser = self.parser, parser !== asked { return self.view(historyLines: historyLines, completion) }
                return completion(self.endedView(historyLines: historyLines) ?? self.fallbackView(historyLines: historyLines))
            }
            self.lastView = ParserView(screen: view.screen, runs: view.runs, history: nil)
            completion(view)
        }
    }

    /// More lines than the parser keeps: the screen and the lines it keeps from the parser, and the rest from a
    /// `HistoryRead` of all the replay buffer holds now (past its resets: lines before a clear or a pager count), which the parser's view also reflects (it answers after
    /// everything fed before). The parser's lines when the read fails or has fewer (a replay buffer that lost its start).
    private func longView(lines: Int, replay: Data, _ completion: @escaping (ParserView) -> Void) {
        var short: ParserView?, long: String?
        let both = DispatchGroup()
        both.enter()
        both.enter()
        let read = HistoryRead(replay: replay, lines: lines, cols: info.cols, rows: info.rows, launcher: launcher, options: parserOptions) { history in
            long = history
            both.leave()
        }
        if let read { historyReads.append(read) } else { both.leave() }
        view(historyLines: SessionParser.scrollback) { view in
            short = view
            both.leave()
        }
        both.notify(queue: queue) { [weak self] in
            if let read { self?.historyReads.removeAll { $0 === read } }
            completion(Self.longer(short ?? .empty, long, lines: lines))
        }
    }

    /// `short` with the read's `long` history instead when that has as many lines or more, its last `lines` lines.
    static func longer(_ short: ParserView, _ long: String?, lines: Int) -> ParserView {
        func count(_ text: String?) -> Int { text.map { $0.isEmpty ? 0 : $0.split(separator: "\n", omittingEmptySubsequences: false).count } ?? -1 }
        guard let long, count(long) >= count(short.history) else { return short }
        var view = short
        view.history = long.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        return view
    }

    /// `view`, waited for (up to 2 s, then what the parser showed last; a long one as long as its history read takes).
    /// Never on a host's queue, which `view` keeps free: for tests.
    func viewNow(historyLines: Int?) -> ParserView {
        if let ended = endedView(historyLines: historyLines) { return ended }
        if let lines = historyLines, lines > SessionParser.scrollback, parser != nil, let ring {
            let short = viewNow(historyLines: SessionParser.scrollback)
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var long: String?
            let read = HistoryRead(replay: ring.held(), lines: lines, cols: info.cols, rows: info.rows, launcher: launcher, options: parserOptions) {
                long = $0
                done.signal()
            }
            if read != nil { done.wait() }
            return Self.longer(short, long, lines: lines)
        }
        guard let view = parser?.viewNow(historyLines: historyLines, timeout: 2) else { return fallbackView(historyLines: historyLines) }
        lastView = ParserView(screen: view.screen, runs: view.runs, history: nil)
        return view
    }

    private func endedView(historyLines: Int?) -> ParserView? {
        guard let ended else { return nil }
        let history = historyLines.map { ended.history.split(separator: "\n", omittingEmptySubsequences: false).suffix($0).joined(separator: "\n") }
        return ParserView(screen: ended.screen, runs: ended.runs, history: history)
    }

    private func fallbackView(historyLines: Int?) -> ParserView {
        ParserView(screen: lastView.screen, runs: lastView.runs, history: historyLines.map { _ in "" })
    }

    /// See `viewNow`: for tests.
    public func screenText() -> String { viewNow(historyLines: nil).screen }

    /// `screenText`, and how its characters are drawn (see `ScreenRun`). See `viewNow`: for tests.
    public func styledScreen() -> (text: String, runs: [ScreenRun]) {
        let view = viewNow(historyLines: nil)
        return (view.screen, view.runs)
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
                // The terminal's: a cell's own `getCharacter()` reads a cluster (an emoji with VS16, ⏱️) as a space.
                let character = terminal.getCharacter(for: line[cell])
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
    /// `endedHistoryLines` once the session ended. See `viewNow`: for tests.
    public func historyText(lines: Int) -> (history: String, screen: String) {
        let view = viewNow(historyLines: lines)
        return (view.history ?? "", view.screen)
    }

    /// Like closing a Terminal tab: SIGHUP to the shell's process group and to the job in the foreground
    /// (the agent runs in its own group), and SIGTERM to the rest of the session's processes (`SessionStrays`, by its
    /// id): a Bash-tool command in a group of its own, a server run in the background, a setsid'd child launchd took
    /// over. Then SIGKILL after 5 s to whichever of those groups still exists and to whatever of the session's still
    /// runs: a program that ignores SIGHUP would otherwise outlive the session, detached, once the shell exits.
    /// `by`: the client that asked (its process id), which its exit names.
    public func terminate(by client: pid_t? = nil) {
        guard info.isLive || readSource != nil else { return }
        if let client, info.isLive, killer == nil { killer = (client, ProcessTable.info(pid: client)?.comm) }
        let groups = Set([info.childPID, tcgetpgrp(masterFD)].filter { $0 > 0 })
        // Before the shell is asked to end: once it has, what it started is launchd's.
        let started = info.isLive ? SessionStrays.descendants(of: info.childPID) : []
        groups.forEach { Darwin.kill(-$0, SIGHUP) }
        SessionStrays.end(session: id, started: started, sparing: groups)
        queue.asyncAfter(deadline: .now() + 5) {
            for group in groups where Darwin.kill(-group, 0) == 0 { Darwin.kill(-group, SIGKILL) }
        }
    }

    /// Releases the PTY. Call after the session ended (or when the host quits).
    public func close() {
        stopParser()
        guard !closed else { return }
        closed = true
        tellInputWent()
        // A suspended watcher can't be cancelled.
        resumeReading()
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

/// The headless terminal's delegate (in the parser, see `SessionParser`): replies to queries, title, bell, program
/// status (OSC 7501, its payload).
final class HeadlessDelegate: TerminalDelegate {
    var onReply: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onProgramStatus: ((Data) -> Void)?

    /// SwiftTerm leaves OSC 7501 alone otherwise.
    func listen(to terminal: Terminal) {
        terminal.registerOscHandler(code: ProgramStatus.code) { [weak self] payload in self?.onProgramStatus?(Data(payload)) }
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) { onReply?(Data(data)) }
    func setTerminalTitle(source: Terminal, title: String) { onTitle?(title) }
    func bell(source: Terminal) { onBell?() }
}

/// A timer of a session's (its exit poll, its parser's watchdog, its exiting check): scheduled again at will, on the session's queue.
protocol SessionTimer: AnyObject {
    /// Fires `after` from now, then every `repeating` (nil: once).
    func schedule(after delay: TimeInterval, repeating: TimeInterval?, leeway: DispatchTimeInterval)
    func cancel()
}

/// How a session makes its timers: dispatch's, or a test's whose clock it moves itself (HostedSessionTimerTests).
struct SessionTimers {
    enum Purpose { case exitPoll, parserWatchdog, exitingCheck }
    /// A timer for `purpose` firing its handler on the queue.
    var make: (Purpose, DispatchQueue, @escaping () -> Void) -> SessionTimer

    static let dispatch = SessionTimers { _, queue, fire in DispatchSessionTimer(queue: queue, fire: fire) }
}

private final class DispatchSessionTimer: SessionTimer {
    private let source: DispatchSourceTimer
    private var resumed = false

    init(queue: DispatchQueue, fire: @escaping () -> Void) {
        source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler(handler: fire)
    }

    func schedule(after delay: TimeInterval, repeating: TimeInterval?, leeway: DispatchTimeInterval) {
        if let repeating {
            source.schedule(deadline: .now() + delay, repeating: repeating, leeway: leeway)
        } else {
            source.schedule(deadline: .now() + delay, leeway: leeway)
        }
        guard !resumed else { return }
        resumed = true
        source.resume()
    }

    func cancel() { source.cancel() }

    // A source released while never resumed is a crash in dispatch.
    deinit { if !resumed { source.resume() } }
}
