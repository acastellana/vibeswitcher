import Foundation
import VibeCore

/// One client's WebSocket, as `WebListener.onSocket` hands it over. Set its handlers there, before the call returns:
/// each is called on the listener's queue, and none after `onClose`, which is called once however the connection
/// ends (the client's close frame, `close`, a frame the protocol forbids, the connection lost, the listener stopped).
///
/// `send` and `close` may be called from any thread. A message is queued, never written by the caller's thread, and
/// the queue has a limit (`WebLimits.maxQueuedBytes`): a client that doesn't read fast enough never makes the server
/// keep more than that for it.
public final class WebSocketConnection: @unchecked Sendable {
    /// The request that opened it: its path, its Host and Origin, its other fields.
    public let request: WebRequest
    /// The subprotocol agreed on: the first of the listener's that the client offered; nil when none.
    public let subprotocol: String?

    public var onText: ((String) -> Void)?
    public var onBinary: ((Data) -> Void)?
    /// The code and the reason the connection ended with: the client's (1005 when its close frame carried none), the
    /// ones given to `close`, 1002, 1007 or 1009 for what the protocol forbids, 1001 when the listener stopped, 1006
    /// when it ended with no close frame.
    public var onClose: ((_ code: UInt16, _ reason: String) -> Void)?
    /// The client fell behind: a message didn't fit the queue and was dropped. Called once each time it happens.
    /// Under `WebLimits.Overflow.drop` every message from that one on is dropped until `resume()`; under `.close`
    /// the connection is closed right after this (`onClose`, 1006).
    public var onFellBehind: (() -> Void)?
    /// Everything queued has been written. Called once each time the client fell behind (the moment to `resume()`
    /// and send whatever brings the client up to date), and once for each `awaitDrain()`.
    public var onDrained: (() -> Void)?
    /// A last text message for a client the listener itself is about to close, given the close code: 1009 (a message
    /// too big), 1002 or 1007 (a frame the protocol forbids), 1001 (the listener is stopping). Nil, or a nil answer:
    /// only the close frame. For a protocol above this one whose clients are told why in its own words.
    public var lastWords: ((_ code: UInt16) -> String?)?

    private let queue: DispatchQueue
    private let overflow: WebLimits.Overflow
    let out: WebOutbound
    weak var listener: WebListener?
    weak var connection: WebConnection?
    /// Whether a frame came since the last ping, and the pings in a row that none came after. On the queue, as
    /// `reported`.
    var heard = true
    var missed = 0
    private var reported = false

    init(request: WebRequest, subprotocol: String?, queue: DispatchQueue, overflow: WebLimits.Overflow, out: WebOutbound) {
        self.request = request
        self.subprotocol = subprotocol
        self.queue = queue
        self.overflow = overflow
        self.out = out
    }

    /// The bytes of messages queued and not yet written.
    public var queuedBytes: Int { out.queuedBytes }

    /// Queues a text message. False when it wasn't queued: the connection is closed or closing, or the client has
    /// fallen behind and `resume()` hasn't been called since.
    @discardableResult
    public func send(text: String) -> Bool {
        offer(WebSocketFrame.encode(.text, Data(text.utf8)))
    }

    /// Queues a binary message. False as `send(text:)`.
    @discardableResult
    public func send(binary: Data) -> Bool {
        offer(WebSocketFrame.encode(.binary, binary))
    }

    /// Closes the connection: what is queued is written, then a close frame with `code` (1000 in place of one that
    /// may not travel: 1005, 1006, 1015, anything outside 1000 to 4999) and `reason` (its first 123 bytes), and the
    /// connection ends once the client has closed its side, or `WebLimits.closeSeconds` later. Nothing is sent or
    /// delivered after the call. `onClose` follows, with the code sent.
    public func close(code: UInt16 = WebSocketClose.normal, reason: String = "") {
        let sent = WebSocketClose.isSendable(code) ? code : WebSocketClose.normal
        guard out.seal(last: WebSocketFrame.close(code: sent, reason: reason), dropUnsent: false) else { return }
        queue.async { [self] in listener?.closed(by: self, code: sent, reason: reason) }
    }

    /// Messages are taken again after the client fell behind (`WebLimits.Overflow.drop`). The caller says when,
    /// not the queue: nothing follows the messages that were dropped but what the caller sends knowing of them, so
    /// a caller whose messages come from several threads calls this and sends what brings the client up to date
    /// where no other message of its own can come between. Usually from `onDrained`; before it, messages are taken
    /// as far as the queue has room.
    public func resume() {
        out.resume()
    }

    /// Asks for `onDrained` once everything queued now has been written (at once, on the queue, when nothing is):
    /// for a caller that holds its own messages back while `queuedBytes` is high, and wants to know when to go on.
    public func awaitDrain() {
        guard out.awaitDrain() else { return }
        queue.async { [self] in
            if let connection { listener?.flush(connection) }
        }
    }

    private func offer(_ frame: Data) -> Bool {
        switch out.offer(frame) {
        case .taken(let kick):
            if kick {
                queue.async { [self] in
                    if let connection { listener?.flush(connection) }
                }
            }
            return true
        case .refused(let first):
            if first { queue.async { [self] in fellBehind() } }
            return false
        case .closed:
            return false
        }
    }

    private func fellBehind() {
        guard !reported else { return }
        onFellBehind?()
        guard let connection else { return }
        if overflow == .close {
            listener?.drop(connection, code: WebSocketClose.abnormal, reason: "fell behind")
        } else {
            // A message refused with nothing queued (one over the limit by itself): the queue is told to look, and
            // finds it has drained.
            listener?.flush(connection)
        }
    }

    /// `onClose`, once; then no handler is kept (one that holds this connection would keep it for good). On the queue.
    func reportClosed(_ code: UInt16, _ reason: String) {
        guard !reported else { return }
        reported = true
        let handler = onClose
        onText = nil
        onBinary = nil
        onClose = nil
        onFellBehind = nil
        onDrained = nil
        lastWords = nil
        handler?(code, reason)
    }
}

/// What waits to be written to one connection, under a lock: messages are offered from any thread, and written on
/// the listener's queue. Messages count against the limit; a response, the handshake's answer and control frames
/// don't, and there is never more than one ping, one pong and one close frame waiting.
final class WebOutbound: @unchecked Sendable {
    enum Offer: Equatable {
        /// Queued. `kick`: nothing is writing yet, so the caller asks the queue to.
        case taken(kick: Bool)
        /// Not queued, the queue being full: `first` for the message that found it so.
        case refused(first: Bool)
        /// Not queued: nothing more is taken.
        case closed
    }

    enum Wrote: Equatable {
        /// Everything went. `drained`: the handler is to be told so (the client had fallen behind and this is the
        /// first time since that nothing is left, or the handler asked).
        case empty(drained: Bool)
        /// The socket takes no more for now.
        case blocked
        case failed
    }

    private let lock = NSLock()
    private let cap: Int
    private let overflow: WebLimits.Overflow
    private var waiting: [(bytes: Data, counted: Bool)] = []
    /// The first of `waiting` not yet started.
    private var next = 0
    /// What is being written, and how much of it has gone: never left half written, whatever is dropped.
    private var current: (bytes: Data, counted: Bool)?
    private var gone = 0
    private var pong: Data?
    private var ping: Data?
    /// The unwritten bytes of what is counted.
    private var queued = 0
    private var sealed = false
    /// A message was refused, and the caller hasn't resumed since: every message is refused.
    private var behind = false
    /// `.empty(drained: true)` has been answered since the client fell behind.
    private var toldDrained = false
    /// The caller asked to be told when nothing is left (`awaitDrain`).
    private var drainAwaited = false
    /// A write has been asked for, or waits for the socket: nobody needs to ask again.
    private var kicked = false

    init(cap: Int, overflow: WebLimits.Overflow) {
        self.cap = cap
        self.overflow = overflow
    }

    var queuedBytes: Int { lock.withLock { queued } }
    var isSealed: Bool { lock.withLock { sealed } }

    private func kick() -> Bool {
        defer { kicked = true }
        return !kicked
    }

    /// A message's frame, against the limit. Once one is refused every one is, until `resume()` (`.drop`), or for
    /// good (`.close`: nothing more is taken, and what hadn't started is dropped).
    func offer(_ frame: Data) -> Offer {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed else { return .closed }
        guard !behind else { return .refused(first: false) }
        guard queued + frame.count <= cap else {
            behind = true
            if overflow == .close {
                sealed = true
                dropUnstarted()
            }
            return .refused(first: true)
        }
        waiting.append((frame, true))
        queued += frame.count
        return .taken(kick: kick())
    }

    /// The next time nothing is left is `.empty(drained: true)`. True when nothing is writing, so the caller asks the
    /// queue to look.
    func awaitDrain() -> Bool {
        lock.withLock {
            guard !sealed else { return false }
            drainAwaited = true
            return kick()
        }
    }

    /// Messages are taken again.
    func resume() {
        lock.withLock {
            behind = false
            toldDrained = false
        }
    }

    /// Bytes that aren't a message's (the handshake's answer), after what is queued. False when nothing more is taken.
    @discardableResult
    func push(_ bytes: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed else { return false }
        waiting.append((bytes, false))
        _ = kick()
        return true
    }

    /// A pong, or a ping, to go before the next message: the latest replaces one not yet written.
    func control(pong frame: Data) {
        lock.withLock {
            guard !sealed else { return }
            pong = frame
            _ = kick()
        }
    }

    func control(ping frame: Data) {
        lock.withLock {
            guard !sealed else { return }
            ping = frame
            _ = kick()
        }
    }

    /// Nothing more is taken. `last` (a close frame, a response) goes after what is queued, or with `dropUnsent` in
    /// place of all that hasn't started. False, and nothing changed, when it was sealed already.
    @discardableResult
    func seal(last: Data?, dropUnsent: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed else { return false }
        sealed = true
        if dropUnsent { dropUnstarted() }
        pong = nil
        ping = nil
        if let last {
            waiting.append((last, false))
            _ = kick()
        }
        return true
    }

    /// Nothing more is taken, and nothing is kept.
    func discard() {
        lock.withLock {
            sealed = true
            dropUnstarted()
            current = nil
            queued = 0
        }
    }

    /// Under the lock.
    private func dropUnstarted() {
        for entry in waiting[next...] where entry.counted { queued -= entry.bytes.count }
        waiting.removeAll()
        next = 0
        pong = nil
        ping = nil
    }

    /// Writes what waits to `fd` until nothing is left or the socket takes no more: a pong and a ping before the next
    /// message, never inside one. On the listener's queue.
    func flush(to fd: Int32) -> Wrote {
        lock.lock()
        defer { lock.unlock() }
        while true {
            if current == nil {
                if let frame = pong {
                    current = (frame, false)
                    pong = nil
                } else if let frame = ping {
                    current = (frame, false)
                    ping = nil
                } else if next < waiting.count {
                    current = waiting[next]
                    next += 1
                    if next == waiting.count {
                        waiting.removeAll(keepingCapacity: waiting.count <= 64)
                        next = 0
                    } else if next >= 256 {
                        waiting.removeFirst(next)
                        next = 0
                    }
                } else {
                    kicked = false
                    let drained = !sealed && (drainAwaited || (behind && !toldDrained))
                    drainAwaited = false
                    if behind { toldDrained = true }
                    return .empty(drained: drained)
                }
                gone = 0
            }
            guard let writing = current else { continue }
            let rest = writing.bytes.count - gone
            let (wrote, code) = writing.bytes.withUnsafeBytes { bytes -> (Int, Int32) in
                let wrote = Platform.Sockets.send(fd, bytes.baseAddress.map { $0 + gone }, rest)
                return (wrote, errno)
            }
            if wrote > 0 {
                gone += wrote
                if writing.counted { queued -= wrote }
                if gone == writing.bytes.count { current = nil }
            } else if rest == 0 {
                current = nil
            } else if wrote < 0, code == EINTR {
                continue
            } else if wrote < 0, code == EAGAIN || code == EWOULDBLOCK {
                return .blocked
            } else {
                return .failed
            }
        }
    }
}

/// One accepted connection: its socket and the sources on it, where it is (a request's head being read, a WebSocket
/// open, the last bytes leaving, the client's close awaited), and how long it has been there. On the listener's
/// queue.
final class WebConnection {
    enum Phase {
        /// The request's head is being read: `WebLimits.headSeconds` for all of it.
        case head
        /// A WebSocket, open.
        case open
        /// The last bytes (a response; what was queued and a close frame) are leaving; what comes is read and dropped.
        case finishing
        /// All has been written and the writes ended: the client's own end is awaited, what comes read and dropped.
        case lingering
        case closed

        /// Whether a connection may stay only so long in it.
        var isTimed: Bool { self == .head || self == .finishing || self == .lingering }
    }

    let fd: Int32
    let out: WebOutbound
    var phase = Phase.head
    var head = HTTPHead()
    var decoder: WebSocketDecoder
    var socket: WebSocketConnection?
    /// The clock's seconds since the phase began, and how many it may last.
    var seconds = 0
    var allowed: Int
    /// The client has ended its side while the last bytes were leaving.
    var peerEnded = false
    var reading: DispatchSourceRead?
    var writing: DispatchSourceWrite?
    /// The sources on `fd` not yet ended (their cancel handlers, on the queue, count them down).
    var sources = 0
    private var descriptorClosed = false
    /// Called once, as the socket is closed.
    var onDescriptorClosed: (() -> Void)?

    init(fd: Int32, limits: WebLimits) {
        self.fd = fd
        out = WebOutbound(cap: limits.maxQueuedBytes, overflow: limits.overflow)
        decoder = WebSocketDecoder(maxMessageBytes: limits.maxMessageBytes)
        allowed = limits.headSeconds
    }

    func enter(_ phase: Phase, for seconds: Int = 0) {
        self.phase = phase
        self.seconds = 0
        allowed = seconds
    }

    func sourceEnded() {
        sources -= 1
        closeWhenUnwatched()
    }

    /// The socket closed, once the connection is closed and the last source on it has ended (a descriptor closed
    /// under a live source could be another's by the time the source lets it go).
    func closeWhenUnwatched() {
        guard phase == .closed, sources == 0, !descriptorClosed else { return }
        descriptorClosed = true
        Sys.close(fd)
        onDescriptorClosed?()
        onDescriptorClosed = nil
    }
}
