import Darwin
import Foundation

/// The app's end of the session host socket. Every call and callback is on `queue`.
public final class HostConnection {
    public var onEvent: ((HostEventEnvelope) -> Void)?
    public var onOutput: ((UUID, Data) -> Void)?
    /// The connection ended (the host quit or crashed, or sent something unreadable). Called once.
    public var onClose: (() -> Void)?

    private let fd: Int32
    private let queue: DispatchQueue
    private var decoder = HostFrameDecoder()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var outgoing = Data()
    private var nextSeq = 1
    private var closed = false

    public init(path: String, queue: DispatchQueue) throws {
        fd = try UnixSocket.connect(path: path)
        self.queue = queue
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    deinit { readSource?.cancel() }

    /// Sends a request; replies carry the returned number as `replyTo`.
    @discardableResult
    public func send(_ request: HostRequest) -> Int {
        let seq = nextSeq
        nextSeq += 1
        guard !closed, let payload = try? HostCoding.encode(HostRequestEnvelope(seq: seq, request: request)),
              payload.count <= HostFrame.maxPayload else { return seq }
        outgoing.append(HostFrame.encode(.control, payload))
        flush()
        return seq
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
            source.resume()
            writeSource = source
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !closed {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                decoder.append(Data(buffer[0..<count]))
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { break }
            deliver()
            return finish(notify: true)
        }
        deliver()
    }

    private func deliver() {
        do {
            while !closed, let frame = try decoder.next() {
                switch frame.kind {
                case .control:
                    // An event this app doesn't know (a newer host) is skipped, not fatal.
                    if let envelope = try? HostCoding.decode(HostEventEnvelope.self, from: frame.payload) { onEvent?(envelope) }
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
    }
}
