import Darwin
import Foundation
import VibeCore

/// One connected app, on the server's queue. Writes never block: they queue up to `maxQueued` bytes;
/// output beyond that means the app fell behind (the server detaches it from that session and says resync).
final class ClientConnection {
    /// More than a full replay (8 MB ring) plus room for live output.
    static let maxQueued = 16 << 20

    let fd: Int32
    var attached: Set<UUID> = []
    var onFrame: ((HostFrame.Kind, Data) -> Void)?
    var onClose: (() -> Void)?

    private let queue: DispatchQueue
    private var decoder = HostFrameDecoder()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private struct Pending {
        var data: Data
        /// Output of this session (droppable on resync); nil for control frames.
        var session: UUID?
    }
    private var pending: [Pending] = []
    /// Bytes of `pending[0]` already written.
    private var headWritten = 0
    private(set) var queuedBytes = 0
    private(set) var closed = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    func send(_ envelope: HostEventEnvelope) {
        guard let payload = try? HostCoding.encode(envelope), payload.count <= HostFrame.maxPayload else { return }
        // A client that stopped reading (a hung app) would collect status changes forever: let it go; it
        // reconnects and gets a fresh welcome.
        guard queuedBytes <= Self.maxQueued * 4 else { return close() }
        enqueue(Pending(data: HostFrame.encode(.control, payload), session: nil))
    }

    /// False when this would exceed the queue limit: nothing was queued.
    func sendOutput(_ id: UUID, frames: [Data]) -> Bool {
        let size = frames.reduce(0) { $0 + $1.count }
        guard queuedBytes + size <= Self.maxQueued else { return false }
        frames.forEach { enqueue(Pending(data: $0, session: id)) }
        return true
    }

    /// Drops queued output of `id`, except a frame already partly written (cutting it would corrupt the stream).
    func dropQueuedOutput(of id: UUID) {
        var kept: [Pending] = []
        for (index, item) in pending.enumerated() {
            if item.session == id, !(index == 0 && headWritten > 0) { queuedBytes -= item.data.count } else { kept.append(item) }
        }
        pending = kept
    }

    func close() {
        guard !closed else { return }
        closed = true
        writeSource?.cancel()
        writeSource = nil
        readSource?.cancel()
        readSource = nil
        onClose?()
    }

    private func enqueue(_ item: Pending) {
        guard !closed else { return }
        pending.append(item)
        queuedBytes += item.data.count
        flush()
    }

    private func flush() {
        while let head = pending.first {
            let written = head.data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + headWritten, raw.count - headWritten)
            }
            if written > 0 {
                headWritten += written
                if headWritten == head.data.count {
                    pending.removeFirst()
                    queuedBytes -= head.data.count
                    headWritten = 0
                }
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                return close()
            }
        }
        if pending.isEmpty {
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
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                return close()
            }
        }
        do {
            while !closed, let frame = try decoder.next() { onFrame?(frame.kind, frame.payload) }
        } catch {
            close()
        }
    }
}
