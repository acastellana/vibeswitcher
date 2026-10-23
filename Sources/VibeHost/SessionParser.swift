import Darwin
import Foundation
import SwiftTerm
import VibeCore

/// A session's terminal parser, in a process of its own: `vibeswitcher-host --parse-session COLS ROWS`, started by the
/// host for each running session (see `ParserLink`). It holds the session's headless terminal (screen, scrollback,
/// title, answers to queries, program status) and nothing else: no PTY, no socket, no other session. A trap or a hang
/// while parsing one session's output ends or stalls only that process; the host, which keeps every PTY, its output
/// buffer and its clients, notices (end of the link, or no progress for `ParserOptions.stallLimit`), logs it and starts
/// a new parser from the session's replay, without the bytes it was stuck on.
///
/// The link is one socket on the parser's descriptor 0: frames of a kind byte, a 4-byte length and the payload.
public enum SessionParser {
    /// What the host sends.
    enum ToParser: UInt8 {
        /// The session's output; answered with `parsed`.
        case feed = 1
        /// Earlier output, rebuilding the screen: parsed without answering queries or reporting title, bell or status.
        case feedQuietly = 2
        /// Columns and rows, 4 bytes each.
        case resize = 3
        /// A request number (4 bytes) and how many lines of history (4 bytes, signed; negative: none).
        case view = 4
    }

    /// What the parser sends.
    enum FromParser: UInt8 {
        /// How many bytes of output it parsed so far (8 bytes).
        case parsed = 1
        /// The terminal's answer to a query, for the program's input.
        case reply = 2
        case title = 3
        case bell = 4
        /// An OSC 7501 payload (see `ProgramStatus`).
        case programStatus = 5
        /// A request number (4 bytes), then the `ParserView`'s JSON.
        case view = 6
    }

    /// The private OSC a test hook listens on (with `--parser-test-hooks` only): `stall` hangs the parser mid-parse,
    /// `trap` crashes it.
    static let testHookCode = 7599

    /// The lines a session's parser keeps above its screen: what the host itself reads (an ended session's last lines
    /// come from a `HistoryRead`). A SwiftTerm line costs 3-5 KB, so the 5,000 kept before made each parser 15-55 MB.
    static let scrollback = 200
    /// The lines of history the phone can ask for, read on demand (see `HistoryRead`).
    static let historyScrollback = 5_000

    /// What the parser does with `--parse-session COLS ROWS [--scrollback LINES]`; call it first thing in `main`. Never
    /// returns then.
    public static func runIfAsked(_ arguments: [String]) {
        guard arguments.count >= 4, arguments[1] == "--parse-session", let cols = Int(arguments[2]), let rows = Int(arguments[3]) else { return }
        let scrollback = arguments.firstIndex(of: "--scrollback").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
        signal(SIGPIPE, SIG_IGN)
        // Ends with the host, even while stuck mid-parse (when it would never read the end of the link).
        let host = getppid()
        let watch = DispatchSource.makeProcessSource(identifier: host, eventMask: .exit, queue: .global())
        watch.setEventHandler { _exit(0) }
        watch.resume()
        if getppid() != host || host == 1 { _exit(0) }
        withExtendedLifetime(watch) {
            run(fd: 0, cols: cols, rows: rows, scrollback: scrollback ?? Self.scrollback, testHooks: arguments.contains("--parser-test-hooks"))
        }
        exit(0)
    }

    static func run(fd: Int32, cols: Int, rows: Int, scrollback: Int = SessionParser.scrollback, testHooks: Bool) {
        let delegate = HeadlessDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
        var quiet = false
        let send: (FromParser, Data) -> Void = { kind, payload in writeAll(fd, Wire.frame(kind.rawValue, payload)) }
        delegate.onReply = { data in if !quiet { send(.reply, data) } }
        delegate.onTitle = { title in if !quiet { send(.title, Data(title.utf8)) } }
        delegate.onBell = { if !quiet { send(.bell, Data()) } }
        delegate.onProgramStatus = { payload in if !quiet { send(.programStatus, payload) } }
        delegate.listen(to: terminal)
        if testHooks {
            terminal.registerOscHandler(code: testHookCode) { payload in
                switch String(decoding: payload, as: UTF8.self) {
                case "stall": while true { sleep(3600) }
                case "trap": fatalError("test hook: a trap while parsing")
                default: break
                }
            }
        }
        var parsed: UInt64 = 0
        var reader = Wire.Reader()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            // The host is gone (or let go of this session).
            guard count > 0 else { return }
            reader.append(buffer[0..<count])
            while let (kind, payload) = reader.next() {
                switch ToParser(rawValue: kind) {
                case .feed?, .feedQuietly?:
                    quiet = kind == ToParser.feedQuietly.rawValue
                    terminal.feed(buffer: [UInt8](payload)[...])
                    quiet = false
                    parsed += UInt64(payload.count)
                    send(.parsed, Wire.number(parsed))
                case .resize?:
                    guard payload.count == 8 else { continue }
                    terminal.resize(cols: Int(Wire.int32(payload, at: 0)), rows: Int(Wire.int32(payload, at: 4)))
                case .view?:
                    guard payload.count == 8 else { continue }
                    let lines = Int(Wire.int32(payload, at: 4))
                    let screen = HostedSession.styledScreen(of: terminal)
                    let view = ParserView(screen: screen.text, runs: screen.runs, history: lines < 0 ? nil : history(of: terminal, lines: lines))
                    send(.view, payload.prefix(4) + ((try? JSONEncoder().encode(view)) ?? Data()))
                case nil:
                    continue
                }
            }
        }
    }

    /// The last `lines` lines above the screen (normal buffer).
    static func history(of terminal: Terminal, lines: Int) -> String {
        let all = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self).components(separatedBy: "\n")
        let screenRows = terminal.rows
        let above = all.count > screenRows ? Array(all[0..<(all.count - screenRows - 1)]) : []
        return above.suffix(lines).joined(separator: "\n")
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written } else if written < 0, errno == EINTR { continue } else { return }
            }
        }
    }

    enum Wire {
        static func frame(_ kind: UInt8, _ payload: Data) -> Data {
            var frame = Data([kind])
            frame.append(number(UInt32(payload.count)))
            frame.append(payload)
            return frame
        }

        static func number<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

        static func int32(_ data: Data, at offset: Int) -> Int32 {
            let start = data.startIndex + offset
            return Int32(bitPattern: data[start..<start + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }

        static func uint64(_ data: Data) -> UInt64 { data.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }

        /// Splits a byte stream into frames.
        struct Reader {
            private var buffer = Data()

            mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 { buffer.append(contentsOf: bytes) }

            mutating func next() -> (UInt8, Data)? {
                guard buffer.count >= 5 else { return nil }
                let start = buffer.startIndex
                let length = Int(UInt32(bitPattern: Wire.int32(buffer, at: 1)))
                guard buffer.count >= 5 + length else { return nil }
                let kind = buffer[start]
                let payload = Data(buffer[(start + 5)..<(start + 5 + length)])
                buffer = Data(buffer[(start + 5 + length)...])
                return (kind, payload)
            }
        }
    }
}

/// What the parser shows of a session: its screen as drawn (see `HostedSession.styledScreen(of:)`) and, when asked
/// for, the lines above it.
public struct ParserView: Codable, Equatable, Sendable {
    public var screen: String
    public var runs: [ScreenRun]
    public var history: String?

    static let empty = ParserView(screen: "", runs: [], history: nil)
}

/// How the host runs its sessions' parsers.
public struct ParserOptions: Sendable {
    /// Busy this long with no progress, a parser is stalled: the watchdog ends it and starts another.
    public var stallLimit: TimeInterval = 10
    /// The parser listens on `SessionParser.testHookCode` (scratch hosts in tests only).
    public var testHooks = false

    public init(stallLimit: TimeInterval = 10, testHooks: Bool = false) {
        self.stallLimit = stallLimit
        self.testHooks = testHooks
    }
}

/// The host's end of one session's parser process (see `SessionParser`). Writes never block: what the parser hasn't
/// taken yet waits here. Its messages are read on a queue of its own, then handed to the session's queue, so a
/// session waiting for a view (`viewNow`) never waits on its own queue. Used on the session's queue, except where said.
final class ParserLink {
    let pid: pid_t
    var onReply: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onProgramStatus: ((String) -> Void)?
    /// It parsed more (see `unparsed`).
    var onParsed: (() -> Void)?
    /// It was idle and has work again (output or a request): on the session's queue, after the work was handed over.
    var onBusy: (() -> Void)?
    /// The parser ended without being told to (a trap): its wait status.
    var onGone: ((Int32) -> Void)?

    private let fd: Int32
    private let queue: DispatchQueue
    private let readQueue = DispatchQueue(label: "vibeswitcher.host.parser-link")
    private var readSource: DispatchSourceRead?
    /// Left once the read side is cancelled.
    private let readFinished = DispatchGroup()
    private var writeSource: DispatchSourceWrite?
    private var outbox = Data()
    private var stopped = false

    /// Shared with `readQueue`, under `lock`.
    private let lock = NSLock()
    private var sent = 0
    private var parsed = 0
    private var lastProgress = Date()
    private var nextRequest: UInt32 = 0
    private enum Pending {
        case later((ParserView?) -> Void)
        case now(DispatchSemaphore, Box)
    }
    final class Box { var view: ParserView? }
    private var pending: [UInt32: Pending] = [:]

    private init(pid: pid_t, fd: Int32, queue: DispatchQueue) {
        self.pid = pid
        self.fd = fd
        self.queue = queue
    }

    /// Starts `launcher --parse-session` on a terminal of `cols` × `rows` keeping `scrollback` lines above its screen,
    /// its descriptor 0 the link and 2 the host's standard error (where a trap says why), in a process group of its own,
    /// with default signals and nothing else of the host's (no PTY).
    static func start(launcher: String, cols: Int, rows: Int, scrollback: Int = SessionParser.scrollback, options: ParserOptions,
                      queue: DispatchQueue) -> ParserLink? {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        let (ours, theirs) = (pair[0], pair[1])
        _ = fcntl(ours, F_SETFD, FD_CLOEXEC)
        _ = fcntl(theirs, F_SETFD, FD_CLOEXEC)
        var noSigPipe: Int32 = 1
        setsockopt(ours, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all: sigset_t = ~0
        var none: sigset_t = 0
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, theirs, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 2)

        let arguments = [launcher, "--parse-session", String(cols), String(rows), "--scrollback", String(scrollback)]
            + (options.testHooks ? ["--parser-test-hooks"] : [])
        let argv = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, launcher, &actions, &attributes, argv, envp)
        Darwin.close(theirs)
        guard spawned == 0 else {
            Darwin.close(ours)
            return nil
        }
        _ = fcntl(ours, F_SETFL, fcntl(ours, F_GETFL) | O_NONBLOCK)
        let link = ParserLink(pid: pid, fd: ours, queue: queue)
        link.listen()
        return link
    }

    private func listen() {
        var reader = SessionParser.Wire.Reader()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        readFinished.enter()
        source.setCancelHandler { [readFinished] in readFinished.leave() }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let count = Darwin.read(self.fd, &buffer, buffer.count)
                if count < 0, errno == EAGAIN { break }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    // The link closes in `end`.
                    source.cancel()
                    self.queue.async { self.gone() }
                    break
                }
                reader.append(buffer[0..<count])
            }
            while let (kind, payload) = reader.next() { self.received(kind, payload) }
        }
        source.resume()
        readSource = source
    }

    /// On `readQueue`.
    private func received(_ kind: UInt8, _ payload: Data) {
        locked { lastProgress = Date() }
        switch SessionParser.FromParser(rawValue: kind) {
        case .parsed?:
            let count = Int(SessionParser.Wire.uint64(payload))
            locked { parsed = count }
            queue.async { [weak self] in self?.onParsed?() }
        case .view?:
            guard payload.count >= 4 else { return }
            let number = UInt32(bitPattern: SessionParser.Wire.int32(payload, at: 0))
            let view = try? JSONDecoder().decode(ParserView.self, from: payload.dropFirst(4))
            answer(number, view)
        case .reply?: queue.async { [weak self] in self?.onReply?(payload) }
        case .title?: queue.async { [weak self] in self?.onTitle?(String(decoding: payload, as: UTF8.self)) }
        case .bell?: queue.async { [weak self] in self?.onBell?() }
        case .programStatus?: queue.async { [weak self] in self?.onProgramStatus?(String(decoding: payload, as: UTF8.self)) }
        case nil: break
        }
    }

    /// Any thread.
    private func answer(_ number: UInt32, _ view: ParserView?) {
        guard let waiting = locked({ pending.removeValue(forKey: number) }) else { return }
        switch waiting {
        case .later(let completion): queue.async { completion(view) }
        case .now(let semaphore, let box):
            box.view = view
            semaphore.signal()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Output handed to the parser that it hasn't parsed yet, in bytes.
    var unparsed: Int { locked { sent - parsed } }

    /// Whether it has output or a request it hasn't answered, and when it last moved.
    var busy: (Bool, since: Date) { locked { (sent > parsed || !pending.isEmpty, lastProgress) } }

    func feed(_ bytes: Data, quietly: Bool = false) {
        guard !bytes.isEmpty, !stopped else { return }
        var offset = 0
        // In pieces: each is answered with progress, so a long replay never looks stalled.
        while offset < bytes.count {
            let piece = bytes[(bytes.startIndex + offset)..<(bytes.startIndex + min(bytes.count, offset + 65_536))]
            beginWork { sent += piece.count }
            send(quietly ? .feedQuietly : .feed, Data(piece))
            offset += piece.count
        }
    }

    func resize(cols: Int, rows: Int) {
        send(.resize, SessionParser.Wire.number(Int32(cols)) + SessionParser.Wire.number(Int32(rows)))
    }

    /// The view once the parser got to it (after everything fed before); nil if it ended first.
    func view(historyLines: Int?, _ completion: @escaping (ParserView?) -> Void) {
        guard !stopped else { return queue.async { completion(nil) } }
        let number = beginWork { () -> UInt32 in
            nextRequest &+= 1
            pending[nextRequest] = .later(completion)
            return nextRequest
        }
        requestView(number, historyLines: historyLines)
    }

    /// `view`, waited for (up to `timeout`; nil after that). Never on the host's queue: for tests and sessions that
    /// aren't served.
    func viewNow(historyLines: Int?, timeout: TimeInterval) -> ParserView? {
        guard !stopped else { return nil }
        let semaphore = DispatchSemaphore(value: 0), box = Box()
        let number = beginWork { () -> UInt32 in
            nextRequest &+= 1
            pending[nextRequest] = .now(semaphore, box)
            return nextRequest
        }
        requestView(number, historyLines: historyLines)
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            locked { _ = pending.removeValue(forKey: number) }
            return nil
        }
        return box.view
    }

    private func requestView(_ number: UInt32, historyLines: Int?) {
        send(.view, SessionParser.Wire.number(number) + SessionParser.Wire.number(Int32(historyLines.map { max(0, $0) } ?? -1)))
    }

    /// Work starting while none was waiting: the stall clock starts now, and the session hears it's busy (any thread).
    private func beginWork<T>(_ body: () -> T) -> T {
        let (result, idle) = locked { () -> (T, Bool) in
            let idle = sent == parsed && pending.isEmpty
            if idle { lastProgress = Date() }
            return (body(), idle)
        }
        if idle { queue.async { [weak self] in self?.onBusy?() } }
        return result
    }

    private func send(_ kind: SessionParser.ToParser, _ payload: Data) {
        guard !stopped else { return }
        outbox.append(SessionParser.Wire.frame(kind.rawValue, payload))
        flush()
    }

    private func flush() {
        while !outbox.isEmpty {
            let written = outbox.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                outbox = Data(outbox.dropFirst(written))
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN { break }
            // The parser is gone: `gone` follows from the read side.
            outbox = Data()
        }
        if outbox.isEmpty {
            writeSource?.cancel()
            writeSource = nil
        } else if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.flush() }
            source.resume()
            writeSource = source
        }
    }

    /// The parser closed its end: it ended (a trap) unless it was told to.
    private func gone() {
        guard !stopped else { return }
        let status = end()
        onGone?(status)
    }

    /// Ends the parser and waits for it (a moment: SIGKILL); every waiting view gets nil. Its wait status.
    @discardableResult
    func stop() -> Int32 {
        guard !stopped else { return 0 }
        return end()
    }

    private func end() -> Int32 {
        stopped = true
        outbox = Data()
        // The link closes once both its watchers are done with it.
        let done = DispatchGroup()
        if let writeSource {
            done.enter()
            writeSource.setCancelHandler { done.leave() }
            writeSource.cancel()
        }
        writeSource = nil
        readSource?.cancel()
        done.enter()
        readFinished.notify(queue: readQueue) { done.leave() }
        done.notify(queue: readQueue) { [fd] in Darwin.close(fd) }
        Darwin.kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        for number in locked({ Array(pending.keys) }) { answer(number, nil) }
        return status
    }
}
