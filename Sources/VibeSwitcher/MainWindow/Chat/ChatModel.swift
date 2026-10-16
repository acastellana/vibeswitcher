import Combine
import Foundation
import VibeCore

/// The conversation of the session the chat shows: read from its transcript off the main thread, the newest
/// part first, then followed as the file grows.
final class ChatModel: ObservableObject {
    enum State: Equatable {
        case none
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var log = ChatLog()
    @Published private(set) var state = State.none
    /// Part of the file before what's loaded.
    @Published private(set) var hasEarlier = false
    @Published private(set) var loadingEarlier = false
    /// The last entry you had seen when this chat opened (the "new since you looked" marker goes after it).
    @Published private(set) var markerAfter: String?
    /// Tool groups and tools you opened (by item / tool id), kept while scrolling.
    @Published var expanded: Set<String> = []
    @Published var searchActive = false
    @Published var searchQuery = ""
    @Published var searchIndex = 0
    /// Bumped to scroll to the bottom (e.g. after you send something).
    @Published private(set) var scrollToBottomRequests = 0

    static let pageBytes = 4 * 1024 * 1024
    private static let seenKey = "chatSeen"

    private(set) var path: String?
    private var url: URL?
    private var format = TranscriptReader.Format.claude
    /// Where the next read continues (just after the last complete line read).
    private var cursor = 0
    /// Where the loaded part of the file starts.
    private var earliest = 0
    /// Bumped on every switch, so reads finishing for an earlier session are dropped.
    private var generation = 0
    private var reading = false
    private let queue = DispatchQueue(label: "vibeswitcher.chat-reads", qos: .userInitiated)

    var items: [ChatItem] { ChatTimeline.items(log.entries, newAfter: markerAfter) }

    /// Shows the conversation in `path` (nil: none). Same path: nothing changes.
    func show(path: String?) {
        guard path != self.path else { return }
        generation += 1
        self.path = path
        log = ChatLog()
        expanded = []
        searchActive = false
        searchQuery = ""
        hasEarlier = false
        cursor = 0
        earliest = 0
        reading = false
        guard let path, let (url, format) = TranscriptReader.checkedURL(path, home: NSHomeDirectory()) else {
            url = nil
            markerAfter = nil
            state = path == nil ? .none : .failed("No conversation for this session yet.")
            return
        }
        self.url = url
        self.format = format
        markerAfter = Self.seen[path]
        state = .loading
        let generation = self.generation
        reading = true
        queue.async {
            let read = Self.readTail(url: url, format: format)
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.reading = false
                guard let read else { return self.state = .failed("Couldn't read the conversation.") }
                var log = ChatLog()
                log.append(read.events)
                self.log = log
                self.cursor = read.cursor
                self.earliest = read.start
                self.hasEarlier = read.start > 0
                // Nothing new since you looked: no marker.
                if self.markerAfter == log.entries.last?.id { self.markerAfter = nil }
                self.state = .ready
            }
        }
    }

    /// Reads what was added to the file since the last read (call about once a second while shown).
    func poll() {
        // Not there yet (a new session writes its transcript with the first message): try again.
        if case .failed = state, let path, !reading {
            self.path = nil
            return show(path: path)
        }
        guard let url, state == .ready, !reading else { return }
        let generation = self.generation, cursor = self.cursor, format = self.format
        reading = true
        queue.async {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size < cursor {
                // Rewritten from the start: read it again.
                DispatchQueue.main.async {
                    guard generation == self.generation else { return }
                    self.reading = false
                    let path = self.path
                    self.path = nil
                    self.show(path: path)
                }
                return
            }
            let read = size > cursor ? Self.read(url: url, from: cursor, to: size, skipPartialFirstLine: false, format: format) : nil
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.reading = false
                guard let read, !read.events.isEmpty || read.consumed > 0 else { return }
                self.log.append(read.events)
                self.cursor = cursor + read.skipped + read.consumed
            }
        }
    }

    func loadEarlier() {
        guard let url, hasEarlier, !loadingEarlier else { return }
        let generation = self.generation, end = earliest, format = self.format
        loadingEarlier = true
        queue.async {
            let start = max(0, end - Self.pageBytes)
            let read = Self.read(url: url, from: start, to: end, skipPartialFirstLine: start > 0, format: format)
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.loadingEarlier = false
                guard let read else { return }
                self.log.prepend(read.events)
                self.earliest = start + read.skipped
                self.hasEarlier = self.earliest > 0
            }
        }
    }

    /// Remembers the newest entry as seen (while the chat is on screen).
    func markSeen() {
        guard let path, let last = log.entries.last?.id, Self.seen[path] != last else { return }
        var seen = Self.seen
        seen[path] = last
        // Keep the store small: the most recent few hundred conversations are plenty.
        if seen.count > 400 { seen = Dictionary(uniqueKeysWithValues: seen.suffix(300).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(seen, forKey: Self.seenKey)
    }

    func scrollToBottom() { scrollToBottomRequests += 1 }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private static var seen: [String: String] {
        UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String] ?? [:]
    }

    // MARK: Reading (off the main thread)

    private struct Read {
        var events: [ChatEvent]
        /// Bytes of a partial first line skipped.
        var skipped: Int
        var consumed: Int
    }

    private static func readTail(url: URL, format: TranscriptReader.Format) -> (events: [ChatEvent], start: Int, cursor: Int)? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { return nil }
        let start = max(0, size - pageBytes)
        guard let read = read(url: url, from: start, to: size, skipPartialFirstLine: start > 0, format: format) else { return nil }
        return (read.events, start + read.skipped, start + read.skipped + read.consumed)
    }

    private static func read(url: URL, from start: Int, to end: Int, skipPartialFirstLine: Bool,
                             format: TranscriptReader.Format) -> Read? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              var data = try? handle.read(upToCount: end - start) else { return nil }
        var skipped = 0
        if skipPartialFirstLine {
            skipped = data.firstIndex(of: 0x0A).map { $0 - data.startIndex + 1 } ?? data.count
            data = data.subdata(in: (data.startIndex + skipped)..<data.endIndex)
        }
        let result = ChatReader.read(data, format: format)
        return Read(events: result.events, skipped: skipped, consumed: result.consumed)
    }
}
