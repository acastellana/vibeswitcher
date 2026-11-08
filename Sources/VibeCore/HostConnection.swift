import CryptoKit
import Darwin
import Foundation

/// The app's end of the session host socket. Every call and callback is on `queue` (a serial one), but `send`, which may
/// be called from any thread (a held key's repeats go from a queue of their own, never waiting on the main thread:
/// `ClaudeVoiceRun`); its writes are on the writer's (see `Writer`). What the host sends is read and decoded on a queue
/// of its own, never `queue`: the app's connection is on the main thread, where decoding its events took 255 of 1396
/// samples (hang-20261107-115721). Only the decoded events are handed to `queue`, in the order they arrived; the
/// host's challenge is answered there too, so a busy main thread doesn't hold up the proof.
public final class HostConnection: @unchecked Sendable {
    // The handlers are `queue`'s: set, called and let go of there only.
    public var onEvent: ((HostEventEnvelope) -> Void)?
    public var onOutput: ((UUID, Data) -> Void)?
    /// The connection ended (the host quit or crashed, or sent something unreadable). Called once.
    public var onClose: (() -> Void)?
    /// The host didn't take this connection as the app's (see `AppProof`): its reason.
    public var onProofRefused: ((String) -> Void)?
    private var proofSeq: Int?
    /// Why a connection with no key (`appKey`) isn't the app's, when the host asks it to prove it is.
    public static let noKey = "This app has no key to prove itself with: VibeSwitcher couldn't read it from the Keychain."
    /// The compatibility hello may precede proof. Repeat it after proof and expose only that welcome.
    private var helloForProof: Data?
    private var proofFinished = false

    private let fd: Int32
    private let queue: DispatchQueue
    /// Where the socket is read and its frames decoded; `decoder` is its only.
    private let reading = DispatchQueue(label: "vibeswitcher.host-connection.reader", qos: .userInitiated)
    private var decoder = HostFrameDecoder()
    /// Cancelled once closed (from either queue: cancelling is safe from any thread, and again).
    private let readSource: DispatchSourceRead
    /// What the reader did, on its queue (tests: where decoding runs, when the reader saw the end).
    enum ReaderTap { case decoded(HostEventEnvelope), ended }
    private let tap: ((ReaderTap) -> Void)?
    /// The sources on `fd` not cancelled yet, and the writes still to make on it: it's closed once there are none
    /// (libdispatch's rule, as the read source's own cancel handler closing it could while a write source was still on it).
    private let sources = DispatchGroup()
    private let writer: Writer
    private var nextSeq = 1
    private var closed = false
    /// What sending touches (the next number, the held requests, the proof's state, `closed`), and the handing over
    /// to the writer, under one lock: requests sent from any thread get their numbers in the order they go out.
    private let sending = NSLock()
    /// The app's key (see `AppProof`): set by the app only, for every connection it makes (its tool calls too).
    nonisolated(unsafe) public static var appKey: SymmetricKey?
    private let appKey: SymmetricKey?
    /// Requests held until the host's challenge is answered (they'd otherwise arrive before the proof): nil once
    /// it was, or with no key to answer it with.
    private var held: Data?

    /// The write(2) each send ends in (tests: one that notes where it runs, or stalls as one does on a loaded Mac).
    typealias Write = (Int32, UnsafeRawPointer?, Int) -> Int

    /// `patience`: how long to retry a refused connect (see `UnixSocket.connect`); the app's own connection, made on
    /// the main thread, doesn't wait.
    public convenience init(path: String, queue: DispatchQueue, appKey: SymmetricKey? = HostConnection.appKey, patience: TimeInterval = 0) throws {
        try self.init(path: path, queue: queue, appKey: appKey, patience: patience, write: { Darwin.write($0, $1, $2) })
    }

    init(path: String, queue: DispatchQueue, appKey: SymmetricKey?, patience: TimeInterval = 0, write: @escaping Write,
         tap: ((ReaderTap) -> Void)? = nil) throws {
        fd = try UnixSocket.connect(path: path, patience: patience)
        self.queue = queue
        self.tap = tap
        writer = Writer(fd: fd, write: write, sources: sources)
        self.appKey = appKey
        held = appKey == nil ? nil : Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: reading)
        readSource = source
        source.setEventHandler { [weak self] in self?.readAvailable() }
        sources.enter()
        source.setCancelHandler { [sources] in sources.leave() }
        sources.notify(queue: reading) { [fd] in Darwin.close(fd) }
        source.resume()
        writer.failed = { [weak self, queue] in queue.async { self?.finish(notify: true) } }
    }

    deinit {
        writer.stop()
        readSource.cancel()
    }

    /// Why a request didn't go out: none of it was sent.
    public enum SendFailure: Error, Equatable, CustomStringConvertible {
        case closed
        /// Its message would be this many bytes, over `HostFrame.maxPayload` (or it couldn't be encoded: 0).
        case tooLarge(Int)

        public var description: String {
            switch self {
            case .closed: return "The connection to the session host is closed."
            case .tooLarge(let count):
                return "The request is too large for the session host (\(count > 0 ? "\(count) bytes, " : "")at most \(HostFrame.maxPayload) a message): none of it was sent."
            }
        }
    }

    /// Sends a request; replies carry the returned number as `replyTo`. Throws when it can't go out (closed, too
    /// large for a frame): nothing of it was sent, and nothing will answer it.
    @discardableResult
    public func send(_ request: HostRequest) throws -> Int {
        sending.lock()
        defer { sending.unlock() }
        guard !closed else { throw SendFailure.closed }
        let seq = nextSeq
        nextSeq += 1
        guard let payload = try? HostCoding.encode(HostRequestEnvelope(seq: seq, request: request)) else { throw SendFailure.tooLarge(0) }
        guard payload.count <= HostFrame.maxPayload else { throw SendFailure.tooLarge(payload.count) }
        if Self.isHello(request), appKey != nil, !proofFinished {
            helloForProof = HostFrame.encode(.control, payload)
        }
        // The hello goes at once: an older host sends no challenge, only its welcome.
        if held != nil, !Self.isHello(request) {
            held?.append(HostFrame.encode(.control, payload))
            return seq
        }
        enqueue(HostFrame.encode(.control, payload))
        return seq
    }

    private static func isHello(_ request: HostRequest) -> Bool {
        if case .hello = request { return true }
        return false
    }

    /// The host's challenge, answered (and the key given first to a host that holds none); then what was held.
    private func answer(_ challenge: Data, keyless: Bool) {
        sending.lock()
        defer { sending.unlock() }
        guard let appKey, held != nil else { return }
        let proof = keyless ? [HostRequest.enrollApp(key: appKey.data), .proveApp(answer: AppProof.answer(challenge, key: appKey))]
            : [.proveApp(answer: AppProof.answer(challenge, key: appKey))]
        for request in proof {
            let seq = nextSeq
            nextSeq += 1
            if case .proveApp = request { proofSeq = seq }
            if let payload = try? HostCoding.encode(HostRequestEnvelope(seq: seq, request: request)) { enqueue(HostFrame.encode(.control, payload)) }
        }
        release()
    }

    /// Under `sending`.
    private func release() {
        guard let pending = held else { return }
        held = nil
        enqueue(pending)
    }

    /// A control message as is (tests: what a newer or broken client might send).
    func sendRaw(_ payload: Data) {
        sending.lock()
        defer { sending.unlock() }
        enqueue(HostFrame.encode(.control, payload))
    }

    /// On `queue`. Nothing is called after it, not even an `onClose` for an end the reader saw first.
    public func close() { finish(notify: false) }

    /// Hands `bytes` to the writer, after everything handed to it before; nothing once the connection is closed. Under
    /// `sending`.
    private func enqueue(_ bytes: Data) {
        guard !closed, !bytes.isEmpty else { return }
        writer.enqueue(bytes)
    }

    /// What the reader hands `queue`, in the order it came.
    private enum Delivery {
        case event(HostEventEnvelope)
        case output(UUID, Data)
        case proofRefused(String)
    }

    /// On `reading`.
    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var received = 0
        while !isClosed, received < 256 * 1024 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                received += count
                decoder.append(Data(buffer[0..<count]))
                if !decodeAndHand() { return ended() }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            _ = decodeAndHand()
            return ended()
        }
        // The rest on another turn, so a host that sends without pause doesn't hold this queue's thread for good.
        if !isClosed { reading.async { [weak self] in self?.readAvailable() } }
    }

    /// The frames whole so far, decoded and handed to `queue` in one go. False when the stream can't be read on (a
    /// broken frame): what came before it is still handed over. On `reading`.
    private func decodeAndHand() -> Bool {
        var batch: [Delivery] = []
        var readable = true
        do {
            while !isClosed, let frame = try decoder.next() {
                switch frame.kind {
                case .control:
                    // An event this app doesn't know (a newer host) is skipped, not fatal.
                    guard let envelope = try? HostCoding.decode(HostEventEnvelope.self, from: frame.payload) else { break }
                    tap?(.decoded(envelope))
                    if let proofSeq = sendingState({ proofSeq }), envelope.replyTo == proofSeq {
                        if case .error(let reason) = envelope.event { batch.append(.proofRefused(reason)) }
                        sendingState {
                            proofFinished = true
                            if let hello = helloForProof {
                                helloForProof = nil
                                enqueue(hello)
                            }
                        }
                    }
                    if case .challenge(let challenge, let keyless) = envelope.event {
                        // No key to answer with: the host takes this connection for no one, as it would a wrong proof.
                        if appKey == nil { batch.append(.proofRefused(Self.noKey)) }
                        answer(challenge, keyless: keyless)
                    } else if case .welcome = envelope.event {
                        if sendingState({ proofSeq != nil && !proofFinished }) { continue }
                        // A host that sent no challenge first (older than it) won't send one.
                        sendingState {
                            helloForProof = nil
                            proofFinished = true
                            release()
                        }
                    }
                    batch.append(.event(envelope))
                case .output:
                    if let (id, bytes) = HostFrame.parseOutput(frame.payload) { batch.append(.output(id, bytes)) }
                }
            }
        } catch {
            readable = false
        }
        hand(batch)
        return readable
    }

    /// `batch` to the handlers, on `queue`, after what was handed before. A handler that closes the connection lets go
    /// of them all, so nothing after that is called.
    private func hand(_ batch: [Delivery]) {
        guard !batch.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for delivery in batch {
                switch delivery {
                case .event(let envelope): onEvent?(envelope)
                case .output(let id, let bytes): onOutput?(id, bytes)
                case .proofRefused(let reason): onProofRefused?(reason)
                }
            }
        }
    }

    private var isClosed: Bool { sendingState { closed } }

    /// `body` under `sending`.
    private func sendingState<T>(_ body: () -> T) -> T {
        sending.lock()
        defer { sending.unlock() }
        return body()
    }

    /// Closed now, by this call (false: it already was): nothing more is sent or read.
    private func markClosed() -> Bool {
        let closing = sendingState { () -> Bool in
            guard !closed else { return false }
            closed = true
            writer.stop()
            return true
        }
        if closing { readSource.cancel() }
        return closing
    }

    /// On `queue`.
    private func finish(notify: Bool) {
        if markClosed() || !notify { letGo(notify: notify) }
    }

    /// The host ended the connection or sent something unreadable: on `reading`. `onClose` is called on `queue` after
    /// every event handed over before, unless `close` came first.
    private func ended() {
        guard markClosed() else { return }
        tap?(.ended)
        queue.async { [self] in letGo(notify: true) }
    }

    /// On `queue`.
    private func letGo(notify: Bool) {
        if notify { onClose?() }
        // Handlers that hold the connection (`HostCall`'s send on it) would keep it, and all they captured, for good:
        // each of the app's one-shot calls did, several a second with a few leads (10-26). Nothing is delivered now.
        onEvent = nil
        onOutput = nil
        onClose = nil
        onProofRefused = nil
    }
}

extension HostConnection {
    /// Writes a connection's requests on a queue of its own, never its caller's: the app's connection is on the main
    /// thread, where a write(2) to a host slow to read (a loaded Mac) held it for seconds (hang-20261031-182840: 363
    /// of 968 samples). Bytes go out in the order handed over, what the socket can't take yet when it has room. Holds
    /// no reference to the connection, which is freed as before once closed; `fd` stays open while it has work.
    final class Writer {
        private let queue = DispatchQueue(label: "vibeswitcher.host-connection.writer", qos: .userInitiated)
        private let fd: Int32
        private let write: Write
        private let sources: DispatchGroup
        // On `queue` only.
        private var outgoing = Data()
        private var source: DispatchSourceWrite?
        private var stopped = false
        /// A write failed (the host went away): called once, on the writer's queue. Set before the first `enqueue`.
        var failed: (() -> Void)?

        init(fd: Int32, write: @escaping Write, sources: DispatchGroup) {
            self.fd = fd
            self.write = write
            self.sources = sources
        }

        /// Under the connection's `sending` lock while it isn't closed (so while `fd` is open): each pending write counts
        /// as a source, so it stays open.
        func enqueue(_ bytes: Data) {
            sources.enter()
            queue.async { [self] in
                if !stopped {
                    outgoing.append(bytes)
                    flush()
                }
                sources.leave()
            }
        }

        /// Nothing more goes out: what's queued before this still gets its write, what the socket didn't take is dropped.
        func stop() {
            queue.async { [self] in halt() }
        }

        private func halt() {
            stopped = true
            outgoing = Data()
            source?.cancel()
            source = nil
        }

        private func flush() {
            while !stopped, !outgoing.isEmpty {
                let written = outgoing.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if written > 0 {
                    outgoing = Data(outgoing.dropFirst(written))
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN {
                    break
                } else {
                    halt()
                    failed?()
                    failed = nil
                    return
                }
            }
            if outgoing.isEmpty || stopped {
                source?.cancel()
                source = nil
            } else if source == nil {
                // Cancelled by `halt` or once all is out, which frees it and the reference its handler holds.
                let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [self] in flush() }
                sources.enter()
                source.setCancelHandler { [sources] in sources.leave() }
                source.resume()
                self.source = source
            }
        }
    }
}
