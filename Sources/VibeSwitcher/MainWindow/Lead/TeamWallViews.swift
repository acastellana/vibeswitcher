import SwiftUI
import VibeCore

/// What a teammate's words carry wherever the app shows them (the Team view's Wall, the chat's card): its own symbol
/// and colour, never the lead's or the user's (docs/process/reviews/team-on-one-task-design.md, section 3).
enum TeammateMark {
    static let symbol = "person.2.wave.2"
    static let color = Color.teal
}

/// One member of a team task as its lane shows it: its name, its part, its last progress and, while it waits on a
/// teammate's answer, who it waits on.
struct TeamMemberLine: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let part: String
    let integrator: Bool
    /// Its last `progress`, without the "name: " the board keeps it under; nil: none yet.
    let progress: String?
    /// The teammates it waits on ("ui", or "all"): its open waits on an answer whose deadline still runs
    /// (`LeadTeamMember.waits`, as status reads them), so the line clears once a deadline passes; empty: none.
    let waitingOn: [String]

    /// A team task's members, the integrator first; none for a plain task.
    static func lines(_ task: LeadTask, now: Double = Date().timeIntervalSince1970) -> [TeamMemberLine] {
        guard let team = task.team, task.isTeam else { return [] }
        return team.enumerated().map { index, member in
            TeamMemberLine(name: member.name, part: member.part, integrator: index == 0,
                           progress: progress(of: member.name, integrator: index == 0, team: team, checkpoints: task.checkpoints ?? []),
                           waitingOn: task.waitingOn(member: member.name, now: now))
        }
    }

    /// A member's last progress: a member's checkpoints carry its name ("api: …", `LeadToolset.progress`); the
    /// integrator's carry none, so its last is the last no other member's name opens.
    static func progress(of name: String, integrator: Bool, team: [LeadTeamMember], checkpoints: [LeadCheckpoint]) -> String? {
        let others = team.map(\.name).filter { $0 != name }.map { "\($0): " }
        for checkpoint in checkpoints.reversed() {
            if checkpoint.text.hasPrefix("\(name): ") { return String(checkpoint.text.dropFirst(name.count + 2)) }
            if integrator, !others.contains(where: checkpoint.text.hasPrefix) { return checkpoint.text }
        }
        return nil
    }

    /// "waiting on @ui", "waiting on @ui and @api".
    var waitingText: String? {
        guard !waitingOn.isEmpty else { return nil }
        let names = waitingOn.map { "@" + $0 }
        return "waiting on " + (names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!)
    }

    /// What VoiceOver reads: "api, integrator, part: …, last progress: …, waiting on @ui".
    var spoken: String {
        var parts = [name + (integrator ? ", integrator" : ""), "part: \(part)"]
        parts.append(progress.map { "last progress: \($0)" } ?? "no progress yet")
        if let waitingText { parts.append(waitingText) }
        return parts.joined(separator: ", ")
    }
}

/// A team task's members, one line each, under its lane's title.
struct TeamMemberLines: View {
    let lines: [TeamMemberLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
                // The progress on a line of its own: the Team tab is narrow, and sharing a run with the part let a
                // long part push the progress out of view.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        (Text(verbatim: line.name).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(line.integrator ? AnyShapeStyle(.primary) : AnyShapeStyle(TeammateMark.color))
                            + Text(verbatim: "  " + line.part).font(.system(size: 11)).foregroundStyle(.secondary))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if let waiting = line.waitingText {
                            Text(waiting).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.orange).lineLimit(1).fixedSize()
                        }
                    }
                    Text(verbatim: line.progress ?? "no progress yet").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                }
                .help(line.spoken)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.spoken)
            }
        }
    }
}

/// A team task's wall in its details: its posts, oldest first, the latest `shown` of them in view and the earlier
/// ones folded. Each is marked as its author's: a teammate's (`TeammateMark`), or the lead's when its seal holds.
/// A post's words are shown as they are: plain text, no markup drawn, no link to follow.
struct TeamWallSection: View {
    let posts: [LeadWall.Post]
    @State private var showEarlier = false

    /// How many of the latest posts show before the earlier ones fold.
    static let shown = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if posts.isEmpty {
                Text("No posts yet.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            let earlier = posts.dropLast(Self.shown)
            if !earlier.isEmpty {
                Fold(title: "Earlier posts (\(earlier.count))", isOpen: $showEarlier, hint: "the wall's earlier posts").padding(.horizontal, -8)
                if showEarlier { ForEach(Array(earlier), id: \.id) { TeamWallPost(post: $0) } }
            }
            ForEach(Array(posts.suffix(Self.shown)), id: \.id) { TeamWallPost(post: $0) }
        }
    }
}

/// One post on the wall: its author's mark and name, who it's for, what it is (a question, a reply), when; under it,
/// its words.
struct TeamWallPost: View {
    let post: LeadWall.Post

    var isLead: Bool { post.author == LeadWall.leadAuthor }

    /// "to @ui · needs an answer", "to @all · reply to #2".
    var heading: String {
        var parts = ["#\(post.id)", "to " + LeadToolset.recipientsText(post.to)]
        if let reply = post.replyTo { parts.append("reply to #\(reply)") }
        if post.needsAnswer { parts.append("needs an answer") }
        return parts.joined(separator: " · ")
    }

    /// "Post 3 from teammate api to @ui, needs an answer: …".
    var spoken: String {
        let from = isLead ? "the lead" : "teammate \(post.author)"
        return "Post \(post.id) from \(from) to \(LeadToolset.recipientsText(post.to))"
            + (post.replyTo.map { ", reply to post \($0)" } ?? "") + (post.needsAnswer ? ", needs an answer" : "")
            + ", \(LeadBoard.clock(post.at)): \(post.text)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: isLead ? "person.2" : TeammateMark.symbol).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isLead ? Color.accentColor : TeammateMark.color).frame(width: 14).accessibilityHidden(true)
                Text(verbatim: isLead ? "Lead" : "@" + post.author).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isLead ? Color.accentColor : TeammateMark.color).fixedSize()
                Text(verbatim: heading).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(LeadBoard.clock(post.at)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
            }
            Text(verbatim: post.text).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 19)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// The board's team tasks' walls as the Team view shows them, read off the main thread: each wall's file read again
/// only when it changed, its posts kept only when the wall's checks pass (`LeadToolset.deliverable`: a member's of
/// that team, the lead's whose seal the session host vouches for). A line written into the file by hand is never shown.
final class TeamWallReads {
    typealias Walls = [String: [LeadWall.Post]]

    private let run: (@escaping () -> Void) -> Void
    private let folder: URL
    private let verify: ([SteerMessage]) throws -> [Bool]
    /// Each wall as last read, by its file: its size and change time, and the posts shown of it, kept while the file
    /// is the same once the lead's seals in it were checked (only on `run`'s queue).
    private var kept: [String: (stamp: [Double], shown: [LeadWall.Post])] = [:]
    /// Each request's number: walls read for an older one are dropped.
    private var asked = 0
    /// How many walls were read from their files (for tests).
    private(set) var reads = 0

    /// `folder`: the lead's private folder the walls are in; `verify`: the session host's check of the lead's seals.
    init(folder: URL = LeadVault.standard.folder, verify: @escaping ([SteerMessage]) throws -> [Bool] = { try LeadVault.standard.verify($0) },
         run: ((@escaping () -> Void) -> Void)? = nil) {
        let queue = DispatchQueue(label: "VibeSwitcher.team-walls", qos: .utility)
        self.run = run ?? { queue.async(execute: $0) }
        self.folder = folder
        self.verify = verify
    }

    /// Reads the walls of `board`'s team tasks and hands them, by task slug, to `then` on the main thread.
    func make(root: String, board: LeadBoard, then: @escaping (Walls) -> Void) {
        let tasks = board.tasks.filter(\.isTeam)
        asked += 1
        let number = asked
        run { [self] in
            var walls: Walls = [:]
            for task in tasks {
                guard let wall = try? LeadWall(root: root, slug: task.slug, folder: folder) else { continue }
                walls[task.slug] = posts(wall, task, lead: "lead of \(LeadMail.project(of: root))")
            }
            DispatchQueue.main.async { if number == self.asked { then(walls) } }
        }
    }

    /// The posts shown of `task`'s wall, its file read again only when it changed (or its lead's seals couldn't be
    /// checked last time).
    private func posts(_ wall: LeadWall, _ task: LeadTask, lead: String) -> [LeadWall.Post] {
        var info = stat()
        guard lstat(wall.file.path, &info) == 0 else { kept[wall.file.path] = nil; return [] }
        let stamp = [Double(info.st_size), Double(info.st_mtimespec.tv_sec), Double(info.st_mtimespec.tv_nsec), Double(info.st_ino)]
        if let kept = kept[wall.file.path], kept.stamp == stamp { return kept.shown }
        reads += 1
        let (shown, checked) = Self.shown(task, wall.posts(), lead: lead, verify: verify)
        kept[wall.file.path] = checked ? (stamp, shown) : nil
        return shown
    }

    /// The posts the Team view shows: a member's that pass the wall's checks, the lead's whose seal holds (none when
    /// the session host can't say: then `checked` is false).
    static func shown(_ task: LeadTask, _ posts: [LeadWall.Post], lead: String,
                      verify: ([SteerMessage]) throws -> [Bool]) -> (posts: [LeadWall.Post], checked: Bool) {
        let marked = posts.filter { $0.author == LeadWall.leadAuthor && $0.seal != nil }
        var vouched: [LeadWall.Post] = []
        var checked = true
        if !marked.isEmpty {
            if let valid = try? verify(marked.map { LeadWall.sealed($0, task: task.slug, lead: lead) }), valid.count == marked.count {
                vouched = zip(marked, valid).filter(\.1).map(\.0)
            } else {
                checked = false
            }
        }
        return (posts.filter { LeadToolset.deliverable($0, team: task.team ?? [], vouched: vouched) }, checked)
    }
}
