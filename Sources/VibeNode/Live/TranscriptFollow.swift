import Foundation
import VibeCore

/// One transcript as a chat follows it, in a tail window (the architecture review's row 13): the newest items only, at
/// most `windowItems` of them and `windowBytes` of the file's lines (the fewer, never under `minItems`), each read once.
/// What is older stays in the file and is read from it on demand (`older`, for `chat.page`; `image`, for `chat.image`).
/// On the store's `reads` queue only.
///
/// - **First read.** The file's last `windowBytes` (one line longer when a single line is: a screenshot), from a line's
///   start; the first item of a read that began mid-file is left out (a tool run may have begun before it, and its id is
///   its first tool's), so the window always starts at an item's first line (`earliest`).
/// - **Appends.** Only the lines written since: their entries go into the log, and the items are made again from the
///   one holding the first entry they touched (a new entry, or the tool a result completes) to the end: a tail, not the
///   whole window. The change says how many items went from the front, where the tail starts and the tail itself.
/// - **The window kept.** Past a quarter over either bound, items go from the front, whole, down to the bounds; the
///   log is made again from the entries kept (their results in them). Each item that went is bookmarked (its id, where
///   its first line starts) and so is each image in it (where its line starts), so a page or an image a client still
///   names is found in the file.
final class TranscriptFollow: @unchecked Sendable {
    static let windowItems = ChatStore.windowItems
    static let windowBytes = ChatStore.windowBytes
    static let minItems = 20
    /// The bytes an older read starts with, doubled until it holds enough items (a screenshot's line can be bigger).
    static let olderChunk = 2 << 20
    /// The most bytes one older read takes.
    static let olderMost = 256 << 20
    /// The bookmarks kept (items that went from the window, the pages' first items, images outside the window).
    static let bookmarksKept = 8192

    let url: URL
    let format: TranscriptReader.Format
    let windowItems: Int
    let windowBytes: Int

    /// Where the bytes read so far end, and where the window's first item starts in the file.
    private var offset = 0
    private(set) var earliest = 0
    /// The file read (its device and inode): another one at the path is read from its window again.
    private var file: (device: UInt64, inode: UInt64)?
    private var log = ChatLog()
    /// Each entry's index in the log, where its line starts, and the bytes of the lines it holds (its own, its result's).
    private var entryIndex: [String: Int] = [:]
    private var entryOffset: [String: Int] = [:]
    private var entryBytes: [String: Int] = [:]
    /// Where each tool's result line starts (its images are there).
    private var resultOffset: [String: Int] = [:]
    private var heldBytes = 0
    /// The window's items that have a wire value, the index of each one's first entry, and their values.
    private(set) var items: [ChatItem] = []
    private var itemStart: [Int] = []
    private var values: [(id: String, value: NodeWire.Value)] = []
    private var readOnce = false
    /// The messages VibeSwitcher handed over that are long enough for a TL;DR (`TeamMessage.needsSummary`), oldest first.
    private(set) var long: [(id: String, message: TeamMessage)] = []
    /// Items no longer in the window, by id: where their first line starts. Images likewise: where their line starts.
    private var bookmarks: [String: Int] = [:]
    private var bookmarkOrder: [String] = []
    private var imageLines: [String: Int] = [:]
    private var imageOrder: [String] = []

    init(url: URL, format: TranscriptReader.Format, windowItems: Int = TranscriptFollow.windowItems, windowBytes: Int = TranscriptFollow.windowBytes) {
        self.url = url
        self.format = format
        self.windowItems = max(Self.minItems, windowItems)
        self.windowBytes = max(1, windowBytes)
    }

    /// What a read changed: the whole window (`reset`, `tail` all of it), or `dropped` items gone from the front and the
    /// items from `from` on (counted after the drop) made again as `tail`. `older`: the file holds items before the window.
    struct Change {
        var reset: Bool
        var dropped: Int
        var from: Int
        var tail: [(id: String, value: NodeWire.Value)]
        var older: Bool
    }

    /// The window's items as they stand (each with its wire value), oldest first.
    var window: [(id: String, value: NodeWire.Value)] { values }

    // MARK: Reading

    /// The change since the last read; nil when nothing new was read (the first read always says the window, empty when
    /// the file can't be read).
    func read() -> Change? {
        let first = !readOnce
        readOnce = true
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else { return first ? Change(reset: true, dropped: 0, from: 0, tail: [], older: false) : nil }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let same = file.map { $0.device == device && $0.inode == inode } ?? false
        if !same || size < offset || first {
            file = (device, inode)
            return loadWindow(size: size)
        }
        guard size > offset, let data = bytes(from: offset, to: size) else { return nil }
        let lines = Self.lines(data, base: offset, skipPartialFirst: false, format: format)
        guard let end = lines.end, end > offset else { return nil }
        offset = end
        return append(lines.parsed)
    }

    /// The window read anew: the file's last `windowBytes`, from an item's first line.
    private func loadWindow(size: Int) -> Change {
        log = ChatLog()
        entryIndex = [:]
        entryOffset = [:]
        entryBytes = [:]
        resultOffset = [:]
        heldBytes = 0
        items = []
        itemStart = []
        values = []
        long = []
        offset = 0
        earliest = 0
        var start = max(0, size - windowBytes - 1)
        var parsed: [Parsed] = []
        var end = start
        // A single line longer than the window (a screenshot): widen until a whole line fits.
        while true {
            guard let data = bytes(from: start, to: size) else { break }
            let lines = Self.lines(data, base: start, skipPartialFirst: start > 0, format: format)
            parsed = lines.parsed
            end = lines.end ?? start
            if !parsed.isEmpty || start == 0 || size - start >= Self.olderMost { break }
            start = max(0, start - windowBytes)
        }
        offset = max(end, offset)
        ingest(parsed)
        rebuildItems()
        // A read that began mid-file: its first item may be a run of tools begun before it.
        if start > 0, !items.isEmpty { dropFront(1, bookmark: false) }
        earliest = log.entries.first.flatMap { entryOffset[$0.id] } ?? offset
        _ = trim()
        return Change(reset: true, dropped: 0, from: 0, tail: values, older: earliest > 0)
    }

    /// Lines appended: their entries into the log, the items made again from the first one they touched, the window kept.
    private func append(_ parsed: [Parsed]) -> Change? {
        let before = log.entries.count
        var touched = before
        for line in parsed {
            for event in line.events { if case .result(let id, _) = event, let index = entryIndex[id] { touched = min(touched, index) } }
        }
        ingest(parsed)
        guard log.entries.count > before || touched < before else { return nil }
        // The item holding the first entry touched, and every item after it, made again.
        var position = itemStart.count
        if let found = itemStart.lastIndex(where: { $0 <= touched }) { position = found }
        let oldTail = Set(values[position...].map(\.id))
        let startEntry = position < itemStart.count ? itemStart[position] : (itemStart.last.map { _ in touched } ?? 0)
        let (newItems, newStarts, newValues) = makeItems(from: min(startEntry, touched))
        items = Array(items[..<position]) + newItems
        itemStart = Array(itemStart[..<position]) + newStarts
        values = Array(values[..<position]) + newValues
        long = long.filter { !oldTail.contains($0.id) } + Self.long(newItems)
        let dropped = trim()
        let from = max(0, position - dropped)
        let tail = dropped > position ? Array(newValues.dropFirst(dropped - position)) : newValues
        return Change(reset: false, dropped: dropped, from: from, tail: tail, older: earliest > 0)
    }

    /// The parsed lines' events into the log, with where each entry's line starts and the bytes it holds.
    private func ingest(_ parsed: [Parsed]) {
        let before = log.entries.count
        log.append(parsed.flatMap(\.events))
        for index in before..<log.entries.count { entryIndex[log.entries[index].id] = index }
        for line in parsed {
            var owner: String?
            for event in line.events {
                switch event {
                case .entry(let entry):
                    if entryOffset[entry.id] == nil, entryIndex[entry.id] != nil { entryOffset[entry.id] = line.offset }
                    if owner == nil { owner = entry.id }
                case .result(let id, _):
                    resultOffset[id] = line.offset
                    if owner == nil, entryIndex[id] != nil { owner = id }
                case .usage:
                    continue
                }
            }
            if let owner, entryIndex[owner] != nil {
                entryBytes[owner, default: 0] += line.size
                heldBytes += line.size
            }
        }
    }

    /// The items from entry `start` on, each with its first entry's index and its wire value (those with none left out).
    private func makeItems(from start: Int) -> ([ChatItem], [Int], [(id: String, value: NodeWire.Value)]) {
        guard start < log.entries.count else { return ([], [], []) }
        var made: ([ChatItem], [Int], [(id: String, value: NodeWire.Value)]) = ([], [], [])
        for item in ChatTimeline.items(Array(log.entries[start...]), newAfter: nil) {
            guard let value = ChatValue.value(item), let first = Self.firstEntry(item).flatMap({ entryIndex[$0] }) else { continue }
            made.0.append(item)
            made.1.append(first)
            made.2.append((item.id, value))
        }
        return made
    }

    private func rebuildItems() {
        (items, itemStart, values) = makeItems(from: 0)
        long = Self.long(items)
    }

    /// The id of the entry an item begins with.
    static func firstEntry(_ item: ChatItem) -> String? {
        switch item {
        case .prompt(let entry), .reply(let entry), .team(let entry, _): return entry.id
        case .tools(_, let tools): return tools.first?.id
        default: return nil
        }
    }

    static func long(_ items: [ChatItem]) -> [(id: String, message: TeamMessage)] {
        items.compactMap { item in
            if case .team(_, let message) = item, message.needsSummary { return (item.id, message) }
            return nil
        }
    }

    // MARK: The window kept

    /// Items gone from the front when the window is a quarter over a bound, down to the bounds: how many.
    private func trim() -> Int {
        guard items.count > windowItems + windowItems / 4 || (heldBytes > windowBytes + windowBytes / 4 && items.count > Self.minItems) else { return 0 }
        // Each item's bytes: its entries', from its first entry to the next item's.
        var sizes: [Int] = []
        for (position, start) in itemStart.enumerated() {
            let end = position + 1 < itemStart.count ? itemStart[position + 1] : log.entries.count
            sizes.append(log.entries[start..<end].reduce(0) { $0 + (entryBytes[$1.id] ?? 0) })
        }
        var keep = items.count, kept = 0
        while keep > 0 {
            let next = kept + sizes[keep - 1]
            let count = items.count - keep + 1
            if count > Self.minItems, count > windowItems || next > windowBytes { break }
            kept = next
            keep -= 1
        }
        let dropped = keep
        guard dropped > 0 else { return 0 }
        dropFront(dropped, bookmark: true)
        earliest = log.entries.first.flatMap { entryOffset[$0.id] } ?? offset
        return dropped
    }

    /// The first `count` items out of the window, their entries out of the log (made again from the rest); each one,
    /// and each image in it, bookmarked when `bookmark`.
    private func dropFront(_ count: Int, bookmark: Bool) {
        let count = min(count, items.count)
        guard count > 0 else { return }
        let cut = count < itemStart.count ? itemStart[count] : log.entries.count
        if bookmark {
            for item in items[..<count] {
                if let first = Self.firstEntry(item), let at = entryOffset[first] { remember(item.id, at: at) }
                for (image, at) in imagePlaces(item) { rememberImage(image, at: at) }
            }
        }
        let gone = log.entries[..<cut]
        for entry in gone {
            heldBytes -= entryBytes[entry.id] ?? 0
            entryBytes[entry.id] = nil
            entryOffset[entry.id] = nil
            resultOffset[entry.id] = nil
        }
        let goneIDs = Set(items[..<count].map(\.id))
        var fresh = ChatLog()
        fresh.append(log.entries[cut...].map { ChatEvent.entry($0) })
        log = fresh
        entryIndex = [:]
        for (index, entry) in log.entries.enumerated() { entryIndex[entry.id] = index }
        items.removeFirst(count)
        values.removeFirst(count)
        itemStart = itemStart.dropFirst(count).map { $0 - cut }
        long = long.filter { !goneIDs.contains($0.id) }
    }

    /// Each image an item shows, with where its line starts (a prompt's: its own line; a tool's: its result's).
    private func imagePlaces(_ item: ChatItem) -> [(String, Int)] {
        switch item {
        case .prompt(let entry):
            guard case .prompt(_, let images) = entry.kind, let at = entryOffset[entry.id] else { return [] }
            return images.map { ($0.id, at) }
        case .tools(_, let tools):
            return tools.flatMap { tool in (tool.result?.images ?? []).compactMap { image in resultOffset[tool.id].map { (image.id, $0) } } }
        default:
            return []
        }
    }

    private func remember(_ id: String, at offset: Int) {
        if bookmarks.updateValue(offset, forKey: id) == nil { bookmarkOrder.append(id) }
        if bookmarkOrder.count > Self.bookmarksKept {
            for old in bookmarkOrder.prefix(bookmarkOrder.count - Self.bookmarksKept) { bookmarks[old] = nil }
            bookmarkOrder.removeFirst(bookmarkOrder.count - Self.bookmarksKept)
        }
    }

    private func rememberImage(_ id: String, at offset: Int) {
        if imageLines.updateValue(offset, forKey: id) == nil { imageOrder.append(id) }
        if imageOrder.count > Self.bookmarksKept {
            for old in imageOrder.prefix(imageOrder.count - Self.bookmarksKept) { imageLines[old] = nil }
            imageOrder.removeFirst(imageOrder.count - Self.bookmarksKept)
        }
    }

    // MARK: Older items, from the file

    /// Where item `id`'s first line starts, for one no longer in the window (or a page's first item); nil when unknown.
    func bookmark(_ id: String) -> Int? { bookmarks[id] }

    /// The newest `need` items whose lines end before byte `end`, read from the file (the window's `earliest` for those
    /// just before it), oldest first, and whether more exist before them. The first is bookmarked, so a page before it
    /// finds it, and so is each image they show. Nil when the file can't be read.
    func older(before end: Int, need: Int) -> (items: [(id: String, value: NodeWire.Value)], more: Bool)? {
        guard end > 0 else { return ([], false) }
        var chunk = Self.olderChunk
        while true {
            let start = max(0, end - chunk)
            guard let data = bytes(from: start, to: end) else { return nil }
            let lines = Self.lines(data, base: start, skipPartialFirst: start > 0, format: format)
            var page = ChatLog()
            page.append(lines.parsed.flatMap(\.events))
            var offsets: [String: Int] = [:], results: [String: Int] = [:]
            for line in lines.parsed {
                for event in line.events {
                    switch event {
                    case .entry(let entry): if offsets[entry.id] == nil { offsets[entry.id] = line.offset }
                    case .result(let id, _): results[id] = line.offset
                    case .usage: continue
                    }
                }
            }
            var made = ChatTimeline.items(page.entries, newAfter: nil).compactMap { item -> (ChatItem, NodeWire.Value)? in
                ChatValue.value(item).map { (item, $0) }
            }
            // A read that began mid-file: its first item may be a run of tools begun before it.
            if start > 0, !made.isEmpty { made.removeFirst() }
            if made.count >= need || start == 0 || chunk >= Self.olderMost {
                let taken = Array(made.suffix(need))
                if let first = taken.first, let id = Self.firstEntry(first.0), let at = offsets[id] { remember(first.0.id, at: at) }
                for (item, _) in taken {
                    switch item {
                    case .prompt(let entry):
                        if case .prompt(_, let images) = entry.kind, let at = offsets[entry.id] { images.forEach { rememberImage($0.id, at: at) } }
                    case .tools(_, let tools):
                        for tool in tools { for image in tool.result?.images ?? [] { if let at = results[tool.id] { rememberImage(image.id, at: at) } } }
                    default:
                        continue
                    }
                }
                return (taken.map { ($0.0.id, $0.1) }, made.count > need || start > 0)
            }
            chunk *= 2
        }
    }

    /// Image `id`: one the window shows, else one a page or the window showed before, read from its line. Nil for any
    /// other id.
    func image(_ id: String) -> ChatImage? {
        if let found = Self.image(id, in: items) { return found }
        guard let at = imageLines[id], let line = lineAt(at) else { return nil }
        for event in Self.lines(line, base: at, skipPartialFirst: false, format: format).parsed.flatMap(\.events) {
            switch event {
            case .entry(let entry):
                if case .prompt(_, let images) = entry.kind, let found = images.first(where: { $0.id == id }) { return found }
            case .result(_, let result):
                if let found = result.images.first(where: { $0.id == id }) { return found }
            case .usage:
                continue
            }
        }
        return nil
    }

    static func image(_ id: String, in items: [ChatItem]) -> ChatImage? {
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

    // MARK: The file

    /// One line of the file, parsed: where it starts, its bytes (its newline included), and its events.
    struct Parsed {
        var offset: Int
        var size: Int
        var events: [ChatEvent]
    }

    /// The complete lines of `data` (the file's bytes from `base`), each parsed on its own, and where the last one ends
    /// in the file (nil: no complete line). `skipPartialFirst`: `data` begins mid-line.
    static func lines(_ data: Data, base: Int, skipPartialFirst: Bool, format: TranscriptReader.Format) -> (parsed: [Parsed], end: Int?) {
        var from = data.startIndex
        if skipPartialFirst {
            guard let newline = data.firstIndex(of: 0x0A) else { return ([], nil) }
            from = newline + 1
        }
        var parsed: [Parsed] = []
        var end: Int?
        while from < data.endIndex, let newline = data[from...].firstIndex(of: 0x0A) {
            let line = data[from...newline]
            let events = ChatReader.read(Data(line), format: format).events
            let at = base + (from - data.startIndex)
            if !events.isEmpty { parsed.append(Parsed(offset: at, size: line.count, events: events)) }
            end = base + (newline + 1 - data.startIndex)
            from = newline + 1
        }
        return (parsed, end)
    }

    private func bytes(from start: Int, to end: Int) -> Data? {
        guard end > start, let handle = try? FileHandle(forReadingFrom: url) else { return end == start ? Data() : nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(start))) != nil else { return nil }
        return try? handle.read(upToCount: end - start)
    }

    /// The line that starts at `at`, its newline included (at most `olderMost` bytes).
    private func lineAt(_ at: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(at))) != nil else { return nil }
        var line = Data()
        while line.count < Self.olderMost, let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[chunk.startIndex...newline])
                return line
            }
            line.append(chunk)
        }
        return nil
    }
}
