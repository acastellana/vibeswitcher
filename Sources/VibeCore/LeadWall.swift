import Darwin
import Foundation

/// A team task's wall (docs/process/reviews/team-on-one-task-design.md, sections 3 and 4; T1): the members' posts,
/// kept append-only, one JSON `Post` a line, in the lead's private folder
/// (`~/.vibeswitcher/lead/<project key>/walls/<slug>.jsonl`, never in the repository: a verifier is denied that folder),
/// with a read cursor per member beside it (`<slug>.seen.json`). This is the store only: the `post` and `wall` tools
/// and delivery to the named members come later (T6) and go through here.
///
/// A post is checked before anything is stored, and refused saying why, with nothing written:
/// - its size, the members' rate and the wall's count (`maxCharacters`, `perHour`, `maxPosts`);
/// - the lead's record lints (`RecordLint`: the user's other projects' names, credential shapes) and lead mail's
///   masking (`LeadMail.masked`: what it would hide, a password given a value, a bearer token, a URL with credentials);
/// - VibeSwitcher's own frame (`LeadDelivery.prefix`), so a post can't forge the mark a delivery puts on it.
public struct LeadWall: Sendable {
    // MARK: Caps

    /// The longest text a post takes: "point to a file on your branch" for more.
    public static let maxCharacters = 1_500
    /// How many posts one member may write in an hour (`ratePeriod`).
    public static let perHour = 20
    static let ratePeriod: TimeInterval = 3_600
    /// How many posts a wall holds.
    public static let maxPosts = 200

    /// What `to` names for every member.
    public static let everyone = "@all"

    // MARK: Post

    /// Who a post is for: named members, or all of them.
    public enum Recipients: Equatable, Sendable, Codable {
        case all
        case members([String])

        /// From the `to` a caller gives ("@all", or member names with or without their "@"); nil when it names
        /// nobody, or "@all" beside names.
        public init?(_ to: [String]) {
            let names = to.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if names.contains(where: { $0.caseInsensitiveCompare(LeadWall.everyone) == .orderedSame }) {
                guard names.count == 1 else { return nil }
                self = .all
                return
            }
            var members: [String] = []
            for name in names.map({ $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }) where !members.contains(name) { members.append(name) }
            guard !members.isEmpty else { return nil }
            self = .members(members)
        }

        /// Whether a post to these reaches `member`.
        public func includes(_ member: String) -> Bool {
            switch self {
            case .all: return true
            case .members(let names): return names.contains(member)
            }
        }

        /// Kept as "@all" or a list of names.
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let word = try? container.decode(String.self), word == LeadWall.everyone {
                self = .all
            } else {
                self = .members(try container.decode([String].self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .all: try container.encode(LeadWall.everyone)
            case .members(let names): try container.encode(names)
            }
        }
    }

    /// One post as the wall keeps it.
    public struct Post: Codable, Equatable, Sendable {
        /// Its place on the wall: 1 for the first. A cursor is the id of the last post read.
        public var id: Int
        /// When it was posted (seconds since 1970).
        public var at: Double
        /// The member who wrote it (filled in by VibeSwitcher, never from the post's words).
        public var author: String
        public var to: Recipients
        /// The author waits on an answer (it may wake an idle member; it carries a deadline, T9).
        public var needsAnswer: Bool
        /// The post this one answers.
        public var replyTo: Int?
        public var text: String

        public init(id: Int, at: Double, author: String, to: Recipients, needsAnswer: Bool, replyTo: Int?, text: String) {
            self.id = id
            self.at = at
            self.author = author
            self.to = to
            self.needsAnswer = needsAnswer
            self.replyTo = replyTo
            self.text = text
        }

        enum CodingKeys: String, CodingKey {
            case id, at, author, to, text
            case needsAnswer = "needs_answer"
            case replyTo = "reply_to"
        }
    }

    /// Why a post wasn't stored. Its `description` says which cap or lint, and what matched.
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        case tooLong(characters: Int)
        case rate(posts: Int, nextInMinutes: Int)
        case full
        case lint([String])
        case masked
        case frame
        case recipients
        case name(String)
        case replyTo(Int)

        public var description: String {
            let head = "Refused, not posted: "
            switch self {
            case .empty:
                return head + "the post is empty."
            case .tooLong(let characters):
                return head + "the post is \(characters) characters, over the size cap of \(LeadWall.maxCharacters) a post takes: say it shorter, or point to a file on your branch."
            case .rate(let posts, let minutes):
                return head + "you wrote \(posts) posts in the last hour, the rate cap of \(LeadWall.perHour) an hour a member may: the next can go in \(minutes) min. Put what's left in one post then."
            case .full:
                return head + "the wall holds \(LeadWall.maxPosts) posts, its count cap: ask_lead instead."
            case .lint(let problems):
                return head + "the post fails the lead's record lints, and nothing was stored. " + problems.joined(separator: "; ") + "."
            case .masked:
                // Not quoted: what matched is the secret.
                return head + "the post holds something shaped like a credential (a password or token given a value, a bearer token, a URL with credentials), and nothing was stored: never post one; leave it out."
            case .frame:
                return head + "the post holds VibeSwitcher's own mark (\"\(LeadDelivery.prefix)\"), which only VibeSwitcher writes: say it without it."
            case .recipients:
                return head + "say who it's for: \(LeadWall.everyone), or one or more members (@name)."
            case .name(let name):
                return head + "\"\(LeadMail.masked(name))\" isn't a member's name (letters, digits, '.', '_' or '-', at most \(LeadWall.maxName))."
            case .replyTo(let id):
                return head + "reply_to \(id) isn't a post on this wall."
            }
        }
    }

    // MARK: Store

    /// The wall's file and its members' cursors.
    public let file: URL
    public let cursors: URL
    /// The lead's private folder (`LeadVault.folder`): every folder made for a wall is made private (0700) up to it.
    let top: URL
    let clock: @Sendable () -> Double

    /// The wall of task `slug` in project `root`, under `folder` (the lead's private folder; tests give a scratch one).
    /// `clock`: now, in seconds since 1970. Throws `Refusal.name` for a slug that isn't one (a path, a dot file).
    public init(root: String, slug: String, folder: URL = LeadVault.standard.folder,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) throws {
        guard Self.isName(slug, longest: 200) else { throw Refusal.name(slug) }
        let walls = folder.appendingPathComponent(LeadVault.key(root), isDirectory: true).appendingPathComponent("walls", isDirectory: true)
        file = walls.appendingPathComponent("\(slug).jsonl")
        cursors = walls.appendingPathComponent("\(slug).seen.json")
        top = folder
        self.clock = clock
    }

    static let maxName = 40

    /// A member's or task's name: letters, digits, ".", "_" and "-", not starting with "." or "-".
    static func isName(_ name: String, longest: Int = maxName) -> Bool {
        guard !name.isEmpty, name.count <= longest, let first = name.unicodeScalars.first, first != ".", first != "-" else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// Why `text` can't be posted by its words alone (nil: it may): empty, over the size cap, the record lints, the
    /// masking, the frame.
    public static func textRefusal(_ text: String) -> Refusal? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if text.count > maxCharacters { return .tooLong(characters: text.count) }
        let problems = RecordLint.problems(in: text)
        if !problems.isEmpty { return .lint(problems) }
        if LeadMail.masked(text) != text { return .masked }
        if text.range(of: LeadDelivery.prefix, options: .caseInsensitive) != nil { return .frame }
        return nil
    }

    /// Appends a post by `author` and returns it as stored, or throws a `Refusal` (nothing stored) or a file error.
    /// The caps are checked against the wall as it is under the file's lock, so two members posting at once can't
    /// both take the last place.
    @discardableResult
    public func post(_ text: String, by author: String, to: [String], needsAnswer: Bool = false, replyTo: Int? = nil) throws -> Post {
        guard Self.isName(author) else { throw Refusal.name(author) }
        guard let recipients = Recipients(to) else { throw Refusal.recipients }
        if case .members(let names) = recipients, let bad = names.first(where: { !Self.isName($0) }) { throw Refusal.name(bad) }
        if let refusal = Self.textRefusal(text) { throw refusal }

        try VibePaths.ensurePrivate(file.deletingLastPathComponent(), within: top)
        let fd = open(file.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        fchmod(fd, 0o600)
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }

        let posts = Self.decode(Self.read(fd))
        let now = clock()
        if posts.count >= Self.maxPosts { throw Refusal.full }
        let recent = posts.filter { $0.author == author && now - $0.at < Self.ratePeriod }
        if recent.count >= Self.perHour {
            let next = (recent.map(\.at).min() ?? now) + Self.ratePeriod
            throw Refusal.rate(posts: recent.count, nextInMinutes: max(1, Int(((next - now) / 60).rounded(.up))))
        }
        if let replyTo, !posts.contains(where: { $0.id == replyTo }) { throw Refusal.replyTo(replyTo) }

        let post = Post(id: (posts.last?.id ?? 0) + 1, at: now, author: author, to: recipients, needsAnswer: needsAnswer, replyTo: replyTo, text: text)
        var line = try JSONEncoder().encode(post)
        line.append(0x0A)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw CocoaError(.fileWriteUnknown) }
        return post
    }

    /// The wall's posts after `cursor` (a post's id; 0: from the first), oldest first. Empty when there's no wall
    /// yet; a line that isn't a post is skipped.
    public func posts(since cursor: Int = 0) -> [Post] {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        flock(fd, LOCK_SH)
        defer { flock(fd, LOCK_UN) }
        return Self.decode(Self.read(fd)).filter { $0.id > cursor }
    }

    // MARK: Cursors

    /// The id of the last post `member` has been given (0: none yet).
    public func cursor(for member: String) -> Int {
        loadCursors()[member] ?? 0
    }

    /// Records that `member` has been given the posts up to `id`. It can go back too: a delivery that didn't go is
    /// rolled back to the cursor before it (the main-red notice's pattern, `untell`).
    public func setCursor(_ id: Int, for member: String) throws {
        guard Self.isName(member) else { throw Refusal.name(member) }
        try VibePaths.ensurePrivate(cursors.deletingLastPathComponent(), within: top)
        // Under the wall's lock, so two members' cursors set at once don't lose one.
        let fd = open(file.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        fchmod(fd, 0o600)
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        var all = loadCursors()
        all[member] = max(0, id)
        try VibePaths.writePrivate(try JSONEncoder().encode(all), to: cursors)
    }

    /// The posts for `member` after its cursor: those that name it or everyone, not its own.
    public func unread(for member: String) -> [Post] {
        posts(since: cursor(for: member)).filter { $0.author != member && $0.to.includes(member) }
    }

    func loadCursors() -> [String: Int] {
        guard let data = FileManager.default.contents(atPath: cursors.path) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    // MARK: Reading

    static func read(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var offset: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            offset += off_t(count)
        }
        return data
    }

    static func decode(_ data: Data) -> [Post] {
        data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(Post.self, from: Data($0)) }
    }
}
