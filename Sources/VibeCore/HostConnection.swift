import CryptoKit
import Darwin
import Foundation

/// The app's end of the session host socket. Every call and callback is on `queue`.
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
    private var writeSource: DispatchSourceWrite?
    /// The sources on `fd` not cancelled yet: it's closed once there are none (libdispatch's rule, as the read
    /// source's own cancel handler closing it could while a write source was still on it).
    private let sources = DispatchGroup()
    private var outgoing = Data()
    private var nextSeq = 1
    private var closed = false
    /// The app's key (see `AppProof`): set by the app only, for every connection it makes (its tool calls too).
    nonisolated(unsafe) public static var appKey: SymmetricKey?
    private let appKey: SymmetricKey?
    /// Requests held until the host's challenge is answered (they'd otherwise arrive before the proof): nil once
    /// it was, or with no key to answer it with.
    private var held: Data?

    /// `patience`: how long to retry a refused connect (see `UnixSocket.connect`); the app's own connection, made on
    /// the main thread, doesn't wait.
    public init(path: String, queue: DispatchQueue, appKey: SymmetricKey? = HostConnection.appKey, patience: TimeInterval = 0) throws {
        fd = try UnixSocket.connect(path: path, patience: patience)
        self.queue = queue
        self.appKey = appKey
        held = appKey == nil ? nil : Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        sources.enter()
        source.setCancelHandler { [sources] in sources.leave() }
        sources.notify(queue: queue) { [fd] in Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    deinit {
        writeSource?.cancel()
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
        outgoing.append(HostFrame.encode(.control, payload))
        flush()
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
            if let payload = try? HostCoding.encode(HostRequestEnvelope(seq: seq, request: request)) { outgoing.append(HostFrame.encode(.control, payload)) }
        }
        release()
    }

    private func release() {
        guard let pending = held else { return }
        held = nil
        outgoing.append(pending)
        flush()
    }

    /// A control message as is (tests: what a newer or broken client might send).
    func sendRaw(_ payload: Data) {
        guard !closed else { return }
        outgoing.append(HostFrame.encode(.control, payload))
        flush()
    }

    public func close() { finish(notify: false) }

    private func flush() {
        while !outgoing.isEmpty {
            let written = outgoing.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                outgoing = Data(outgoing.dropFirst(written))
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                return finish(notify: true)
            }
        }
        if outgoing.isEmpty {
            writeSource?.cancel()
            writeSource = nil
        } else if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.flush() }
            sources.enter()
            source.setCancelHandler { [sources] in sources.leave() }
            source.resume()
            writeSource = source
        }
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
                            outgoing.append(hello)
                            flush()
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
        writeSource?.cancel()
        writeSource = nil
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
