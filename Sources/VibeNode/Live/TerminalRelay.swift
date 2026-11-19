import Foundation
import VibeCore

/// A session's terminal in a web page (the live plan's B6, slice 4's spike; the live wire contract's §9): `term.open`
/// and `term.close` on a WebSocket, the host's `attach` through the link (`HostLink.attach`: the server is the app to
/// the host here), and the contract's binary frames both ways. Only a scratch server makes one (LW-D12, I4's
/// `--test-web-terminal`); the user's node answers `term.open` `unknown-kind`.
///
/// - **Frames.** One byte of type, four of stream (big-endian), the payload. To the page: 1, the session's bytes
///   (the host's replay first, then live), cut to `chunk` bytes a frame; 2, the replay is over; 4, `resync`: what the
///   page shows is stale, the replay comes again. From the page: 1, input; 3, a resize (columns and rows, 16 bits
///   each, big-endian). Anything else, or a stream the page doesn't hold, is dropped.
/// - **One attachment a session.** The link carries a session's terminal once, whatever number of pages show it; each
///   page's stream is fed from it. A stream that needs the replay (a new one, one that fell behind) has the session's
///   replay start over (`HostLink.resync`), and every stream that had begun on it gets type 4 first: late, never wrong.
/// - **A slow page.** A stream whose page can't take live bytes (`writable` false) is behind: nothing more is written
///   to it (no buffer grows for it) until its page has read what is queued (the hub's `drained`), and then it starts
///   again from the host's replay with type 4, as the host does to its own clients. The replay itself goes whole
///   (`replayBound`).
/// - **Queries.** Only the host's parser answers a program's terminal queries: what the page's emulator answers is
///   cut out of its input (`TerminalReplies`) before it reaches the host.
/// - **The log** names streams, sessions' short ids and counts, never a byte of the terminal.
///
/// On the hub's queue (the engine's), as the link is.
public final class TerminalRelay: @unchecked Sendable {
    /// A frame's type byte.
    public enum Kind: UInt8, Sendable {
        /// To the page: the session's bytes. From the page: input.
        case bytes = 1
        /// To the page: the replay is over; live bytes follow.
        case replayed = 2
        /// From the page: a resize.
        case resize = 3
        /// To the page: what it shows is stale; the replay comes again.
        case resync = 4
    }

    /// The most bytes of the session in one frame to the page: small enough that a page that stops reading is found
    /// out after little more than the transport's limit.
    public static let chunk = 32 * 1_024
    /// What goes to a page whatever its transport holds already: a resync, the end of a replay, and the replay itself,
    /// which the host keeps to 1 MiB (`HostedSession.replay`). A replay held back by `writable` (1 MiB queued, the
    /// listener's `busyBytes`) would find every page behind as soon as it began; queued whole, it is at most 1 MiB
    /// past that, well inside the listener's limit for a page (4 MiB, `NodeWebListener.limits`), and the stream is
    /// judged on the live bytes after it.
    public static let replayBound = 1 << 20
    /// The sizes a page may ask (`HostClient.realCols` and `realRows`, the app's).
    public static let cols = 10...1_000
    public static let rows = 5...300

    public let queue: DispatchQueue
    private let link: HostLink
    private let note: @Sendable (String) -> Void
    private var nextStream: UInt32 = 1
    private var streams: [UInt32: Stream] = [:]
    private var attachments: [UUID: Attachment] = [:]

    /// One page's view of one session's terminal.
    private final class Stream {
        enum State {
            /// Waiting for its session's replay to start.
            case joining
            /// The replay's bytes go to it.
            case replaying
            case live
            /// Its page couldn't take bytes: nothing is written to it until it drained.
            case behind
        }

        let id: UInt32
        let session: UUID
        let transport: TerminalTransport
        var state = State.joining
        /// It has been sent the session's bytes since it opened or since its last type 4: a new replay needs a type 4.
        var begun = false

        init(id: UInt32, session: UUID, transport: TerminalTransport) {
            self.id = id
            self.session = session
            self.transport = transport
        }
    }

    /// One session's terminal on the link, and the streams it feeds.
    private final class Attachment {
        var streams: Set<UInt32> = []
        /// A replay was asked of the link and hasn't started yet: a stream that needs one waits for it.
        var starting = true
    }

    /// `link`: the server's. `note`: the server's log.
    public init(link: HostLink, note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.link = link
        queue = link.queue
        self.note = note
    }

    /// How many streams are open (tests). On `queue`.
    var streamCount: Int { streams.count }

    // MARK: Requests (from the hub, on `queue`)

    /// `term.open` `{session, cols, rows}`: replies `{stream}` on `transport`, then the stream's frames follow. A
    /// carrier that takes no binary frame (the Unix socket's) is `unknown-kind`; a session the host doesn't run, `gone`.
    func open(_ request: NodeWire.Request, on transport: LiveTransport, rights: LiveRights) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let carrier = transport as? TerminalTransport else {
            return reply(.init(re: request.id, error: .init(.unknownKind, "this connection carries no terminal")), on: transport)
        }
        guard rights.contains(.read) else {
            return reply(.init(re: request.id, error: .init(.voice, "this connection may not read")), on: transport)
        }
        guard let session = request.args?["session"]?.string, let cols = request.args?["cols"]?.int, let rows = request.args?["rows"]?.int else {
            return reply(.init(re: request.id, error: .init(.badArgs, "term.open needs a session, cols and rows")), on: transport)
        }
        guard Self.cols.contains(cols), Self.rows.contains(rows) else {
            return reply(.init(re: request.id, error: .init(.badArgs, "a terminal is \(Self.cols) columns and \(Self.rows) rows")), on: transport)
        }
        guard let hosted = link.sessions.first(where: { NodeIds.session(host: $0.id) == session }) else {
            return reply(.init(re: request.id, error: .init(.gone, "no session the host runs is \(ConfigSeal.inert(session, limit: 80))")), on: transport)
        }
        guard nextStream < UInt32.max else {
            return reply(.init(re: request.id, error: .init(.internal, "no stream number left")), on: transport)
        }
        let id = nextStream
        nextStream += 1
        reply(.init(re: request.id, result: .object(["stream": .int(Int(id))])), on: transport)
        let stream = Stream(id: id, session: hosted.id, transport: carrier)
        streams[id] = stream
        note("terminal stream \(id) opened on \(Self.short(hosted.id)) at \(cols)×\(rows)")
        if let attachment = attachments[hosted.id] {
            attachment.streams.insert(id)
            link.resize(hosted.id, cols: cols, rows: rows)
            replayAgain(hosted.id, attachment)
            return
        }
        let attachment = Attachment()
        attachment.streams.insert(id)
        attachments[hosted.id] = attachment
        let held = hosted.id
        link.attach(held, cols: cols, rows: rows, sink: HostLink.TerminalSink(
            restart: { [weak self] in self?.restarted(held) },
            output: { [weak self] in self?.output(of: held, $0) },
            attached: { [weak self] in self?.attached(held) },
            ended: { [weak self] in self?.ended(held, $0) }))
    }

    /// `term.close` `{stream}`: the stream is closed; the session's attachment goes with its last stream.
    func close(_ request: NodeWire.Request, on transport: LiveTransport) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let number = request.args?["stream"]?.int, let id = UInt32(exactly: number), let stream = streams[id],
              stream.transport === transport else {
            return reply(.init(re: request.id, error: .init(.badArgs, "term.close needs a stream of this connection's")), on: transport)
        }
        drop(stream)
        reply(.init(re: request.id, result: .object([:])), on: transport)
    }

    /// One binary message of `transport`'s: input or a resize, for a stream it holds.
    func binary(_ message: Data, on transport: LiveTransport) {
        dispatchPrecondition(condition: .onQueue(queue))
        let bytes = [UInt8](message)
        guard bytes.count >= 5 else { return note("a terminal frame of \(bytes.count) bytes dropped: too short") }
        let id = bytes[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard let stream = streams[id], stream.transport === transport else {
            return note("a terminal frame for stream \(id) dropped: not this connection's")
        }
        let payload = bytes[5...]
        switch Kind(rawValue: bytes[0]) {
        case .bytes?:
            let typed = TerminalReplies.strip(Array(payload))
            if typed.dropped > 0 { note("terminal stream \(id): \(typed.dropped) bytes of the page's answers to queries dropped") }
            if !typed.kept.isEmpty { link.input(stream.session, bytes: Data(typed.kept)) }
        case .resize?:
            guard payload.count == 4 else { return note("terminal stream \(id): a resize of \(payload.count) bytes dropped") }
            let start = payload.startIndex
            let cols = Int(payload[start]) << 8 | Int(payload[start + 1]), rows = Int(payload[start + 2]) << 8 | Int(payload[start + 3])
            guard Self.cols.contains(cols), Self.rows.contains(rows) else {
                return note("terminal stream \(id): a resize to \(cols)×\(rows) dropped")
            }
            link.resize(stream.session, cols: cols, rows: rows)
        default:
            note("terminal stream \(id): a frame of type \(bytes[0]) dropped")
        }
    }

    /// `transport` can take bytes again: its streams that fell behind start over from the replay.
    func drained(_ transport: LiveTransport) {
        dispatchPrecondition(condition: .onQueue(queue))
        for stream in streams.values.sorted(by: { $0.id < $1.id }) where stream.transport === transport && stream.state == .behind {
            guard let attachment = attachments[stream.session] else { continue }
            note("terminal stream \(stream.id) drained: from the replay again")
            stream.state = .joining
            replayAgain(stream.session, attachment)
        }
    }

    /// `transport` is gone: its streams with it.
    func closed(_ transport: LiveTransport) {
        dispatchPrecondition(condition: .onQueue(queue))
        for stream in streams.values.sorted(by: { $0.id < $1.id }) where stream.transport === transport { drop(stream) }
    }

    // MARK: The link's (on `queue`)

    private func restarted(_ session: UUID) {
        guard let attachment = attachments[session] else { return }
        attachment.starting = false
        for stream in fed(by: attachment) where stream.state != .behind {
            if stream.begun {
                guard send(.resync, [], on: stream) else { continue }
                stream.begun = false
            }
            stream.state = .replaying
        }
    }

    private func output(of session: UUID, _ bytes: Data) {
        guard let attachment = attachments[session] else { return }
        let whole = [UInt8](bytes)
        for stream in fed(by: attachment) where stream.state == .replaying || stream.state == .live {
            var start = 0
            while start < whole.count {
                let end = min(start + Self.chunk, whole.count)
                guard send(.bytes, whole[start..<end], on: stream) else { break }
                stream.begun = true
                start = end
            }
        }
    }

    private func attached(_ session: UUID) {
        guard let attachment = attachments[session] else { return }
        for stream in fed(by: attachment) where stream.state == .replaying {
            guard send(.replayed, [], on: stream) else { continue }
            stream.begun = true
            stream.state = .live
        }
    }

    private func ended(_ session: UUID, _ why: String) {
        guard let attachment = attachments.removeValue(forKey: session) else { return }
        note("terminal of \(Self.short(session)) ended (\(why)): streams \(attachment.streams.sorted()) closed")
        for id in attachment.streams { streams[id] = nil }
    }

    // MARK: Streams

    /// Session `session`'s replay from the start for a stream that needs it, unless one is on its way.
    private func replayAgain(_ session: UUID, _ attachment: Attachment) {
        guard !attachment.starting else { return }
        attachment.starting = true
        link.resync(session)
    }

    private func fed(by attachment: Attachment) -> [Stream] {
        attachment.streams.sorted().compactMap { streams[$0] }
    }

    private func drop(_ stream: Stream) {
        streams[stream.id] = nil
        note("terminal stream \(stream.id) closed")
        guard let attachment = attachments[stream.session] else { return }
        attachment.streams.remove(stream.id)
        guard attachment.streams.isEmpty else { return }
        attachments[stream.session] = nil
        link.detach(stream.session)
    }

    /// One frame to `stream`'s page; false, with the stream behind, when its page can't take it. The live bytes wait
    /// for `writable`; the rest goes whatever is queued (`replayBound`).
    private func send(_ kind: Kind, _ payload: ArraySlice<UInt8>, on stream: Stream) -> Bool {
        let waits = kind == .bytes && stream.state == .live
        guard !waits || stream.transport.writable, stream.transport.send(binary: Self.frame(kind, stream: stream.id, payload)) else {
            if stream.state != .behind { note("terminal stream \(stream.id) fell behind: from the replay again once its page reads") }
            stream.state = .behind
            return false
        }
        return true
    }

    /// A frame: its type, its stream (four bytes, big-endian), its payload.
    public static func frame(_ kind: Kind, stream: UInt32, _ payload: ArraySlice<UInt8> = []) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(kind.rawValue)
        frame.append(contentsOf: [UInt8(stream >> 24), UInt8(stream >> 16 & 0xff), UInt8(stream >> 8 & 0xff), UInt8(stream & 0xff)])
        frame.append(contentsOf: payload)
        return frame
    }

    private func reply(_ reply: NodeWire.Reply, on transport: LiveTransport) {
        transport.send(NodeWire.message(reply))
    }

    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
}

/// A carrier that takes the terminal's binary frames: a WebSocket's (`NodeWebTransport`). False: not queued (the
/// connection is closing).
protocol TerminalTransport: LiveTransport {
    func send(binary: Data) -> Bool
}

extension NodeWebTransport: TerminalTransport {}

/// What a terminal emulator answers to a program's queries, cut out of a page's input (the contract's §9: only the
/// host's parser answers them). The page's emulator answers what it sees in the replay and the live bytes, as any
/// terminal does; typed into the session, those answers would be keys the user never pressed, answering questions the
/// host's parser answered already. What no key makes is cut, wherever it is in the input:
///
/// - every string sequence: OSC (colours, the palette), DCS (DECRQSS, XTVERSION), APC (kitty's graphics), PM, SOS;
/// - the CSI replies: a cursor position (`R`), a device status (`n`), the device attributes (`c`), a mode's report
///   (`$ y`), the kitty keyboard flags (`? u`), a window report (`t`), and the focus reports (`CSI I`, `CSI O`).
///
/// A modified F3 (`CSI 1 ; 5 R`, xterm's form) reads as a cursor position report and is cut too: the spike accepts it.
/// Everything else (keys, a paste, the mouse) goes as it came. An escape sequence cut short at the end of the input is
/// left as it is (an Escape key, or the start of keys the page sends whole anyway).
public enum TerminalReplies {
    /// `input` without the replies in it, and how many bytes were cut.
    public static func strip(_ input: [UInt8]) -> (kept: [UInt8], dropped: Int) {
        var kept: [UInt8] = []
        kept.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            guard input[index] == 0x1b, index + 1 < input.count else {
                kept.append(input[index])
                index += 1
                continue
            }
            switch input[index + 1] {
            case UInt8(ascii: "["):
                var end = index + 2
                while end < input.count, (0x30...0x3f).contains(input[end]) { end += 1 }
                let parameters = input[(index + 2)..<end]
                let intermediateStart = end
                while end < input.count, (0x20...0x2f).contains(input[end]) { end += 1 }
                let intermediates = input[intermediateStart..<end]
                guard end < input.count, (0x40...0x7e).contains(input[end]) else {
                    kept.append(input[index])
                    index += 1
                    continue
                }
                if !isReply(parameters: parameters, intermediates: intermediates, final: input[end]) {
                    kept.append(contentsOf: input[index...end])
                }
                index = end + 1
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"):
                // A string sequence: to its terminator (BEL, or ESC \), or to the input's end.
                let isOSC = input[index + 1] == UInt8(ascii: "]")
                var end = index + 2
                while end < input.count {
                    if isOSC, input[end] == 0x07 { end += 1; break }
                    if input[end] == 0x1b, end + 1 < input.count, input[end + 1] == UInt8(ascii: "\\") { end += 2; break }
                    end += 1
                }
                index = end
            default:
                kept.append(input[index])
                index += 1
            }
        }
        return (kept, input.count - kept.count)
    }

    private static func isReply(parameters: ArraySlice<UInt8>, intermediates: ArraySlice<UInt8>, final: UInt8) -> Bool {
        switch final {
        case UInt8(ascii: "R"), UInt8(ascii: "n"), UInt8(ascii: "c"), UInt8(ascii: "t"):
            return true
        case UInt8(ascii: "y"):
            return intermediates.contains(UInt8(ascii: "$"))
        case UInt8(ascii: "u"):
            return parameters.first == UInt8(ascii: "?")
        case UInt8(ascii: "I"), UInt8(ascii: "O"):
            return parameters.isEmpty && intermediates.isEmpty
        default:
            return false
        }
    }
}
