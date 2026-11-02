import CryptoKit
import Darwin
import Foundation

/// The app's end of the session host socket. Every call and callback is on `queue`; its writes aren't (see `Writer`).
public final class HostConnection {
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
    private var decoder = HostFrameDecoder()
    private var readSource: DispatchSourceRead?
    /// The sources on `fd` not cancelled yet, and the writes still to make on it: it's closed once there are none
    /// (libdispatch's rule, as the read source's own cancel handler closing it could while a write source was still on it).
    private let sources = DispatchGroup()
    private let writer: Writer
    private var nextSeq = 1
    private var closed = false
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

    init(path: String, queue: DispatchQueue, appKey: SymmetricKey?, patience: TimeInterval = 0, write: @escaping Write) throws {
        fd = try UnixSocket.connect(path: path, patience: patience)
        self.queue = queue
        writer = Writer(fd: fd, write: write, sources: sources)
        self.appKey = appKey
        held = appKey == nil ? nil : Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        sources.enter()
        source.setCancelHandler { [sources] in sources.leave() }
        sources.notify(queue: queue) { [fd] in Darwin.close(fd) }
        readSource = source
        source.resume()
        writer.failed = { [weak self, queue] in queue.async { self?.finish(notify: true) } }
    }

    deinit {
        writer.stop()
        readSource?.cancel()
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
        guard !closed else { throw SendFailure.closed }
        let seq = nextSeq
        nextSeq += 1
        guard let payload = try? HostCoding.encode(HostRequestEnvelope(seq: seq, request: request)) else { throw SendFailure.tooLarge(0) }
        guard payload.count <= HostFrame.maxPayload else { throw SendFailure.tooLarge(payload.count) }
        if appKey != nil, !proofFinished, Self.isHello(request) {
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

    private func release() {
        guard let pending = held else { return }
        held = nil
        enqueue(pending)
    }

    /// A control message as is (tests: what a newer or broken client might send).
    func sendRaw(_ payload: Data) {
        enqueue(HostFrame.encode(.control, payload))
    }

    public func close() { finish(notify: false) }

    /// Hands `bytes` to the writer, after everything handed to it before; nothing once the connection is closed.
    private func enqueue(_ bytes: Data) {
        guard !closed, !bytes.isEmpty else { return }
        writer.enqueue(bytes)
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var received = 0
        while !closed, received < 256 * 1024 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                received += count
                decoder.append(Data(buffer[0..<count]))
                deliver()
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            deliver()
            return finish(notify: true)
        }
        if !closed { queue.async { [weak self] in self?.readAvailable() } }
    }

    private func deliver() {
        do {
            while !closed, let frame = try decoder.next() {
                switch frame.kind {
                case .control:
                    // An event this app doesn't know (a newer host) is skipped, not fatal.
                    guard let envelope = try? HostCoding.decode(HostEventEnvelope.self, from: frame.payload) else { break }
                    if let proofSeq, envelope.replyTo == proofSeq {
                        proofFinished = true
                        if case .error(let reason) = envelope.event { onProofRefused?(reason) }
                        if let hello = helloForProof {
                            helloForProof = nil
                            enqueue(hello)
                        }
                    }
                    if case .challenge(let challenge, let keyless) = envelope.event {
                        // No key to answer with: the host takes this connection for no one, as it would a wrong proof.
                        if appKey == nil { onProofRefused?(Self.noKey) }
                        answer(challenge, keyless: keyless)
                    } else if case .welcome = envelope.event {
                        if proofSeq != nil, !proofFinished { continue }
                        // A host that sent no challenge first (older than it) won't send one.
                        helloForProof = nil
                        proofFinished = true
                        release()
                    }
                    onEvent?(envelope)
                case .output:
                    if let (id, bytes) = HostFrame.parseOutput(frame.payload) { onOutput?(id, bytes) }
                }
            }
        } catch {
            finish(notify: true)
        }
    }

    private func finish(notify: Bool) {
        guard !closed else { return }
        closed = true
        writer.stop()
        readSource?.cancel()
        readSource = nil
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

        /// From the connection's queue while `fd` is open: each pending write counts as a source, so it stays open.
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
