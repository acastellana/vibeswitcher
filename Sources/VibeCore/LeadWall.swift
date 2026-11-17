import Darwin
import Foundation

/// A team task's wall (docs/process/reviews/team-on-one-task-design.md, sections 3 and 4; T1): the members' posts,
/// kept append-only, one JSON `Post` a line, in the lead's private folder
/// (`~/.vibeswitcher/lead/<project key>/walls/<slug>.jsonl`, never in the repository: a verifier is denied that folder),
/// This is the store; the `post` and `wall` tools and delivery to the named members (`LeadTeam.swift`, T6) go through
/// it. What each member has been delivered is the board's (`LeadTeamMember.wallSeen`), claimed under the board's lock.
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

    /// The author the lead's own posts carry: no member can be named it (`LeadTeam.nameProblem` wants a letter first).
    public static let leadAuthor = "_lead"

    /// How long a member's `needs_answer` post waits on an answer by default (T9: no member waits on a teammate without
    /// a limit), and the longest it may: past its deadline with no reply, VibeSwitcher tells the asker to go on with a
    /// stated assumption or ask_lead, and tells the lead (`LeadToolset.peerDeadlines`).
    public static let answerWait: TimeInterval = 10 * 60
    public static let longestWait: TimeInterval = 20 * 60

    /// The wait a post asks for in `minutes`, capped at `longestWait` (and at least a minute); `answerWait` when none
    /// is given, or one that isn't a number of minutes.
    public static func wait(minutes: Double?) -> TimeInterval {
        guard let minutes, minutes.isFinite, minutes > 0 else { return answerWait }
        return min(max(minutes * 60, 60), longestWait)
    }

    /// The line breaks `SteerReply.quote` doesn't split on, each made a plain "\n" before a post is checked or stored,
    /// so every line a reader sees of a delivered post is quoted: LINE and PARAGRAPH SEPARATOR, NEXT LINE, the vertical
    /// tab and the form feed.
    static let otherLineBreaks: [Character] = ["\u{2028}", "\u{2029}", "\u{0085}", "\u{000B}", "\u{000C}"]

    /// `text` with `otherLineBreaks` made "\n".
    public static func plainLines(_ text: String) -> String {
        String(text.map { otherLineBreaks.contains($0) ? "\n" : $0 })
    }

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
        /// A lead's post only: the session host's seal of it as the lead's (`sealed`). The wall's file is the lead's
        /// private folder's, but a worker's shell can write it: a post marked as the lead's without a seal that holds
        /// is never sent or shown as the lead's.
        public var seal: String?
        /// A `needsAnswer` post: when its wait on an answer ends (seconds since 1970). See `answerBy`.
        public var deadline: Double?

        /// When a question's wait on an answer ends: its `deadline`, never past `longestWait` after it was posted (a
        /// line written into the file by hand can't ask for longer); `answerWait` after it for one stored without one.
        /// Nil for a post that doesn't ask for an answer.
        public var answerBy: Double? {
            guard needsAnswer else { return nil }
            return min(deadline ?? at + LeadWall.answerWait, at + LeadWall.longestWait)
        }

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
            case id, at, author, to, text, seal, deadline
            case needsAnswer = "needs_answer"
            case replyTo = "reply_to"
        }
    }

    /// What the session host seals a lead's post as (`Post.seal`): its delivery (its place, who it's for, its words),
    /// as lead `lead`'s on task `task`, so a sealed post can't be moved to another wall or place, or sent to others.
    public static func sealed(_ post: Post, task: String, lead: String) -> SteerMessage {
        var message = SteerMessage(id: "wall \(task) \(post.id)", text: delivery(post), from: .lead(lead), agentPid: 0, at: post.at)
        message.seal = post.seal
        return message
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

    /// The wall's file.
    public let file: URL
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
    /// both take the last place. `seal`: the lead's post's seal (`Post.seal`), made for it as it's stored; what it
    /// throws stores nothing. `waitMinutes`: with `needsAnswer`, how long it waits on an answer (`wait(minutes:)`).
    @discardableResult
    public func post(_ text: String, by author: String, to: [String], needsAnswer: Bool = false, replyTo: Int? = nil,
                     waitMinutes: Double? = nil, seal: ((Post) throws -> String)? = nil) throws -> Post {
        let text = Self.plainLines(text)
        guard Self.isName(author) else { throw Refusal.name(author) }
        guard let recipients = Recipients(to) else { throw Refusal.recipients }
        if case .members(let names) = recipients, let bad = names.first(where: { !Self.isName($0) }) { throw Refusal.name(bad) }
        if let refusal = Self.textRefusal(text) { throw refusal }

        try VibePaths.ensurePrivate(file.deletingLastPathComponent(), within: top)
        let fd = open(file.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        fchmod(fd, 0o600)
        guard Self.lock(fd) else { throw CocoaError(.fileWriteUnknown) }
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

        var post = Post(id: (posts.last?.id ?? 0) + 1, at: now, author: author, to: recipients, needsAnswer: needsAnswer, replyTo: replyTo, text: text)
        if needsAnswer { post.deadline = now + Self.wait(minutes: waitMinutes) }
        if let seal { post.seal = try seal(post) }
        var line = try JSONEncoder().encode(post)
        line.append(0x0A)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw CocoaError(.fileWriteUnknown) }
        return post
    }

    /// The wall's posts after `cursor` (a post's id; 0: from the first), oldest first. Empty when there's no wall
    /// yet; a line that isn't a post is skipped. It never waits on the file's lock: a worker's shell can take that lock
    /// and keep it, and the session host reads the wall while it holds its own (the vault's `mayDeliverPost`). A post
    /// goes in with one write, its line whole; a line still being written isn't a post yet, and is skipped. Opened not
    /// to block (a pipe put in the file's place doesn't hang it).
    public func posts(since cursor: Int = 0) -> [Post] {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        return Self.decode(Self.read(fd)).filter { $0.id > cursor }
    }

    /// How long `post` waits for the file's lock, held by another post being stored (or by a worker's shell, which
    /// then has the post refused rather than hung).
    static let lockWait: TimeInterval = 3

    /// Takes the file's exclusive lock, waiting at most `lockWait`.
    static func lock(_ fd: Int32) -> Bool {
        let until = Date().addingTimeInterval(lockWait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < until else { return false }
            usleep(10_000)
        }
        return true
    }

    // MARK: Delivery

    /// The posts after `cursor` (a post's id) that are for `member`: those that name it or everyone, not its own.
    public static func posts(_ posts: [Post], for member: String, after cursor: Int) -> [Post] {
        posts.filter { $0.id > cursor && $0.author != member && $0.to.includes(member) }
    }

    /// Whether `post` may wake `member` while it's idle: it asks for an answer, or it's the first reply to `member`'s
    /// own post that asked for one (`posts`: the wall up to it).
    public static func wakes(_ post: Post, for member: String, in posts: [Post]) -> Bool {
        if post.needsAnswer { return true }
        guard let asked = post.replyTo, let question = posts.first(where: { $0.id == asked }),
              question.author == member, question.needsAnswer else { return false }
        return !posts.contains { $0.id < post.id && $0.replyTo == asked }
    }

    /// Whether `question` has its answer on the wall (`posts`): a reply to it (`replyTo`) by anyone but its author.
    public static func answered(_ question: Post, in posts: [Post]) -> Bool {
        posts.contains { $0.replyTo == question.id && $0.author != question.author }
    }

    /// The text a post is delivered as (the sender's frame, the teammate's or the lead's, goes around it): its place
    /// on the wall, who it's for, and how to answer it, then its words. The vault seals a teammate's delivery only when
    /// its text is this for a post stored on that wall by that member (`LeadVault`'s `maySeal`).
    public static func delivery(_ post: Post) -> String {
        let to: String
        switch post.to {
        case .all: to = everyone
        case .members(let names): to = names.map { "@" + $0 }.joined(separator: " ")
        }
        let answer = post.needsAnswer ? ", needs an answer: reply with post(reply_to: \(post.id))" : ""
        let reply = post.replyTo.map { ", replying to post #\($0)" } ?? ""
        return "Wall post #\(post.id) to \(to)\(reply)\(answer):\n\(post.text)"
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

    /// The posts of the file's lines; a last line without its "\n" is one still being written, not a post yet.
    static func decode(_ data: Data) -> [Post] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        lines.removeLast()
        return lines.filter { !$0.isEmpty }.compactMap { try? JSONDecoder().decode(Post.self, from: Data($0)) }
    }
}
