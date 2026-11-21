import Foundation
import VibeCore

/// Two reads of a session's own transcript beside its chat (the parity table's Inspector and Images rows, 2026-11-21),
/// answered by the hub as `chat.page` is: a page that reads may ask (no voice, nothing changes), and the client names a
/// session and, for an image, the image's id in that session's chat: never a path.
///
/// - **Which file.** The session's `transcriptPath` checked by `TranscriptReader.checkedURL` (a regular `.jsonl` inside
///   the agents' own folders of the node's home, after links and `..`), the chat's own: a session with no transcript,
///   or one outside them, is `gone`.
/// - **`session.usage`.** Its tokens and cost as the app's inspector reads them (`ActivityFeed`: Claude's per-message
///   `usage` and `costUSD`, Codex's `token_count`), from the last `usageTailBytes` of it, read off the queue: `partial`
///   says the conversation began before them, so the totals are of the turns read.
/// - **`chat.image`.** The bytes of an image the session's chat shows (a prompt's, a tool result's), found by its id in
///   the chat as read (`TranscriptFollow.image`): an id the chat doesn't hold is `gone`, whatever it spells. Only a PNG,
///   JPEG, GIF or WebP whose bytes are that format (`ChatImageBytes.sniff`) is served, under the type its bytes say,
///   at most `ChatImageBytes.most` bytes, in parts of `ChatImageBytes.part` (base64), so no reply passes a socket's
///   queue. The page shows them as `blob:` URLs, which its CSP's `img-src` allows and nothing else.
extension ChatStore {
    /// How much of a transcript's end `session.usage` reads.
    static let usageTailBytes = 2 << 20
    /// How many turns its reply lists.
    static let usageTurnsKept = 40

    /// What a read found: the reply's result, or why there is none.
    enum Read {
        case value(NodeWire.Value)
        case refused(NodeWire.Failure)
    }

    /// How long a session's usage answers a later ask without a read, in seconds.
    static let usageKeep: TimeInterval = 5

    /// `session.usage`'s result for `session`. One read a session at a time (the security review of 2026-11-21): an ask
    /// while one runs waits for it and shares its answer, and an answer `usageKeep` old or newer is given again with no
    /// read. On `queue`; `reply` on `queue`.
    func usage(_ session: String, reply: @escaping (Read) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let path = sessionsValues[session]?.transcriptPath, let (url, format) = TranscriptReader.checkedURL(path, home: homeFolder) else {
            return reply(.refused(.init(.gone, "no such session, or it has no transcript in the agents' own folders")))
        }
        if let kept = usageKept[session], clock - kept.at < Self.usageKeep { return reply(kept.read) }
        if usageWaiting[session] != nil { return usageWaiting[session]?.append(reply) ?? () }
        usageWaiting[session] = [reply]
        usageReadsRun += 1
        let queue = self.queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let value = Self.usageValue(url: url, format: format)
            queue.async { [weak self] in
                guard let self else { return }
                let read = value.map(Read.value) ?? .refused(.init(.gone, "that session's transcript couldn't be read"))
                self.usageKept = self.usageKept.filter { self.clock - $0.value.at < Self.usageKeep }
                self.usageKept[session] = (self.clock, read)
                let waiting = self.usageWaiting.removeValue(forKey: session) ?? []
                waiting.forEach { $0(read) }
            }
        }
    }


    /// The usage of the transcript at `url`, from its last `tailBytes`; nil when it can't be read.
    static func usageValue(url: URL, format: TranscriptReader.Format, tailBytes: Int = usageTailBytes) -> NodeWire.Value? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let plan = TranscriptWindow.plan(fileSize: Int(size), after: nil, sameFile: false, tailBytes: tailBytes)
        guard (try? handle.seek(toOffset: UInt64(plan.start))) != nil, let data = try? handle.readToEnd() else { return nil }
        let feed = ActivityFeed.read(data, format: format, startsMidFile: plan.start > 0, limit: .max)
        let turns = feed.rows.compactMap { row -> ActivityFeed.Turn? in
            if case .turn(let turn) = row { return turn }
            return nil
        }
        return usageValue(turns, partial: plan.start > 0)
    }

    /// `turns` as the reply carries them: the newest `usageTurnsKept`, and the totals of all of them (`tokens` null when
    /// no turn carried any; `cost` null when none carried one, `costPartial` when some did and some didn't).
    static func usageValue(_ turns: [ActivityFeed.Turn], partial: Bool) -> NodeWire.Value {
        func tokens(_ tokens: ActivityFeed.Tokens) -> NodeWire.Value {
            .object(["input": .int(tokens.input), "cached": .int(tokens.cached), "output": .int(tokens.output)])
        }
        let counted = turns.compactMap(\.tokens)
        let total = counted.isEmpty ? nil : ActivityFeed.Tokens(input: counted.map(\.input).reduce(0, +),
                                                                cached: counted.map(\.cached).reduce(0, +),
                                                                output: counted.map(\.output).reduce(0, +))
        let costs = turns.compactMap(\.cost)
        let listed = turns.suffix(usageTurnsKept).map { turn -> NodeWire.Value in
            .object(["id": .string(turn.id), "at": turn.at.map(NodeWire.Value.date) ?? .null, "partial": .bool(turn.partial),
                     "tokens": turn.tokens.map(tokens) ?? .null, "cost": turn.cost.map(NodeWire.Value.double) ?? .null])
        }
        return .object(["turns": .array(Array(listed)), "count": .int(turns.count), "partial": .bool(partial),
                        "tokens": total.map(tokens) ?? .null, "cost": costs.isEmpty ? .null : .double(costs.reduce(0, +)),
                        "costPartial": .bool(!costs.isEmpty && costs.count < turns.count)])
    }

    /// `chat.image`'s result: the part of image `id` of `session`'s chat that starts at byte `offset`, once the chat is
    /// read (opened for it if no client follows it, and dropped after, as any stream nobody follows). On `queue`;
    /// `reply` on `queue`.
    func image(_ session: String, id: String, offset: Int, reply: @escaping (Read) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard offset >= 0 else { return reply(.refused(.init(.badArgs, "chat.image's offset is a byte of the image"))) }
        switch open(session) {
        case .refused(let failure): reply(.refused(failure))
        case .opened(let stream):
            stream.whenLoaded { [weak self] in
                guard let self, let follow = self.follow(of: session) else {
                    return reply(.refused(.init(.gone, "that session's chat is no longer held")))
                }
                let queue = self.queue
                self.readsQueue.async {
                    let found = follow.image(id)
                    queue.async { reply(ChatImageBytes.part(of: found, offset: offset)) }
                }
            }
        }
    }
}

/// What `chat.image` serves of an image (the parity table's Images row, 2026-11-21).
enum ChatImageBytes {
    /// The largest image served: the transcript reader's own limit (`ChatReader.imageLimit`).
    static let most = 8 << 20
    /// The bytes of one part, before base64 (a quarter of a socket's queue at most once encoded).
    static let part = 192 << 10

    /// The image types served, by what their first bytes say. Never SVG or anything else a browser might run.
    static func sniff(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if bytes.count == 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }

    /// The part of `image` from `offset`, or why none is served.
    static func part(of image: ChatImage?, offset: Int) -> ChatStore.Read {
        part(bytes: image.map { ($0.data, $0.mediaType) }, offset: offset)
    }

    /// The part of an image's bytes (`data`, said to be `mediaType`) from `offset`, or why none is served.
    static func part(bytes image: (data: Data, mediaType: String)?, offset: Int) -> ChatStore.Read {
        guard let image else { return .refused(.init(.gone, "no such image in that session's chat")) }
        guard image.data.count <= most else { return .refused(.init(.refused, "that image is over \(most >> 20) MB")) }
        guard let type = sniff(image.data), type == image.mediaType.lowercased() else {
            return .refused(.init(.refused, "that image isn't a PNG, JPEG, GIF or WebP its bytes agree with"))
        }
        guard offset < image.data.count || (offset == 0 && image.data.isEmpty) else {
            return .refused(.init(.badArgs, "chat.image's offset is past the image's end"))
        }
        let start = image.data.startIndex + offset
        let end = min(start + part, image.data.endIndex)
        return .value(.object(["mediaType": .string(type), "bytes": .int(image.data.count), "offset": .int(offset),
                               "data": .string(image.data[start..<end].base64EncodedString())]))
    }
}

extension TranscriptFollow {
    /// The image `id` of the chat as last read: a prompt's or a tool result's. Nil for any id it doesn't hold. On the
    /// store's `reads` queue.
    func image(_ id: String) -> ChatImage? {
        for item in items {
            switch item {
            case .prompt(let entry):
                if case .prompt(_, let images) = entry.kind, let found = images.first(where: { $0.id == id }) { return found }
            case .tools(_, let tools):
                for tool in tools { if let found = tool.result?.images.first(where: { $0.id == id }) { return found } }
            default:
                continue
            }
        }
        return nil
    }
}
