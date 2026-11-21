import Foundation
import VibeCore

/// The rest of the Mac's Team tab (the parity table's board row, 2026-11-21): the lead's Results (`post_update`'s
/// cards: a title, a Markdown body and its kept screenshots), carried in the board's value beside its records; and a
/// task's details as its row opens (`TeamRowDetails`: why it last failed, its checkpoints, the worker's report, the
/// audit and its findings, its merge and its score line), asked when a row opens (`board.task`, a read) so the board's
/// stream stays small. A result's image is served by `board.image` (a read): only a file the board's own result names,
/// in its kept-images folder `.vibeswitcher/updates/<id>/` under the lead's root, read with no link followed, as a PNG,
/// JPEG, GIF or WebP its bytes agree with (`ChatImageBytes`), in parts. Every string is the sessions' writing: inert
/// and capped (`BoardValue.text`).
enum BoardDetails {
    /// The newest results a board carries.
    static let resultsKept = 20
    /// The most bytes of a result's body, and its lines.
    static let bodyBytes = 8_000
    static let bodyLines = 200
    /// The most images of a result sent, and checkpoints and findings of a task.
    static let imagesKept = 6
    static let checkpointsKept = 8
    static let findingsKept = 60

    static func text(_ value: String, _ limit: Int, _ lines: Int = 1) -> String { BoardValue.text(value, limit: limit, lines: lines) }

    /// The results, newest first: each its id, title, body (Markdown, the page renders it as text nodes), when, and how
    /// many images it names (`board.image` serves them by index).
    static func results(_ board: LeadBoard?) -> NodeWire.Value {
        .array((board?.updates ?? []).suffix(resultsKept).reversed().map { update in
            .object(["id": .string(text(update.id, 80)), "title": .string(text(update.title, 300)),
                     "body": .string(text(update.body, bodyBytes, bodyLines)), "at": BoardValue.date(update.at),
                     "images": .int(min(update.images.count, imagesKept))])
        })
    }

    /// A task's details, as its row opens (`TeamRowDetails`).
    static func task(_ task: LeadTask) -> NodeWire.Value {
        var fields: [String: NodeWire.Value] = ["slug": .string(text(task.slug, 120)), "title": .string(text(task.title, 400))]
        let failure: String? = task.setback?.reason ?? (task.status == .failed ? task.evidence?.summary : task.status == .blocked ? task.blocker : nil)
        fields["failure"] = failure.map { .string(text($0, 4_000, 40)) } ?? .null
        fields["checkpoints"] = .array((task.checkpoints ?? []).suffix(checkpointsKept).map { checkpoint in
            .object(["text": .string(text(checkpoint.text, 600, 4)), "at": BoardValue.date(checkpoint.at)])
        })
        fields["report"] = task.report.flatMap { $0.isEmpty ? nil : .string(text($0, 8_000, 200)) } ?? .null
        if let evidence = task.evidence ?? task.setback?.evidence {
            fields["audit"] = .object([
                "last": .bool(task.evidence == nil), "passes": .bool(evidence.passes),
                "completion": .string(evidence.completion.rawValue), "integrity": .string(evidence.integrity.rawValue),
                "summary": .string(text(evidence.summary, 4_000, 40)),
                "vote": task.evidence != nil ? task.audits?.vote.map { .string(text($0.text, 300)) } ?? .null : .null,
                "panel": .null,
            ])
        } else if let panel = task.panel {
            fields["audit"] = .object([
                "last": .bool(false), "passes": .null, "completion": .null, "integrity": .null, "summary": .null, "vote": .null,
                "panel": .string(text("\(panel.progress) (\(panel.focuses.joined(separator: "; "))); the shared build and test run: \(panel.run)", 600, 4)),
            ])
        } else {
            fields["audit"] = .null
        }
        fields["round"] = task.audits.map { .int($0.rounds) } ?? .null
        fields["findings"] = .array((task.audits?.findings ?? []).prefix(findingsKept).map { finding in
            .object(["id": .string(text(finding.id, 40)), "severity": .string(finding.severity.rawValue), "status": .string(finding.status.rawValue),
                     "blocks": .bool(finding.blocks), "text": .string(text(findingText(finding), 1_200, 6))])
        })
        fields["merged"] = task.merged.map { merged in
            .string("Merged \(text(String(merged.commit.prefix(8)), 8)) at \(LeadBoard.clock(merged.at))" + (merged.tested ? ", tests passed" : ", no tests ran")
                    + (merged.unaudited ? ", no audit" : ""))
        } ?? .null
        if let score = task.score, score.review != nil || score.rounds > 0 || score.questions > 0 || task.merged != nil {
            fields["score"] = .string(text(score.line, 600, 2))
            fields["reverted"] = .bool(score.revertedBy != nil)
        } else {
            fields["score"] = .null
            fields["reverted"] = .bool(false)
        }
        fields["worker"] = BoardValue.session(task.worker)
        fields["verifier"] = BoardValue.session(task.verifier)
        return .object(fields)
    }

    /// "F1 b.txt:1 — evidence (fixed in round 2)" (the Mac's `TeamRowDetails.findingText`, copied).
    static func findingText(_ finding: LeadFinding) -> String {
        var text = "\(finding.id) \(finding.place) — \(finding.evidence)"
        switch finding.status {
        case .open: break
        case .unconfirmed: text += " (unconfirmed\(finding.reason.map { ": \($0)" } ?? ""))"
        case .fixed: text += " (fixed\(finding.closed.map { " in round \($0)" } ?? ""))"
        case .dismissed:
            text += " (dismissed\(finding.closedBy == "lead" ? " by the lead" : "")\(finding.reason.map { ": \($0)" } ?? "")"
                + "\(finding.followUp.map { " → task \($0)" } ?? ""))"
        }
        return text
    }

    /// The bytes of a result's image: only one the board's own result `update` names at `index`, whose file is in that
    /// result's kept folder, read below `root` with no link followed; nil for anything else.
    static func image(root: String, board: LeadBoard, update id: String, index: Int) -> (data: Data, mediaType: String)? {
        guard let update = board.updates.first(where: { $0.id == id }), index >= 0, index < min(update.images.count, imagesKept) else { return nil }
        let path = (update.images[index] as NSString).standardizingPath
        let folder = (([root, ".vibeswitcher", "updates", update.id] as [String]).joined(separator: "/") as NSString).standardizingPath
        let name = (path as NSString).lastPathComponent
        guard (path as NSString).deletingLastPathComponent == folder, !name.isEmpty, name != "..", name != "." else { return nil }
        guard case .data(let data) = Platform.Files.readRegular(in: root, path: [".vibeswitcher", "updates", update.id, name],
                                                                limit: ChatImageBytes.most) else { return nil }
        guard let type = ChatImageBytes.sniff(data) else { return nil }
        return (data, type)
    }
}

/// `board.task` and `board.image` (reads, anyone of the uid, a page that reads): a project's board read again from its
/// root (`BoardFile.read`: no link followed), the task by its slug, the image by its result and index.
extension Requests {
    /// The root of the lead whose project is `project` (a project id, or a folder a lead runs in). On `queue`.
    func leadRoot(_ project: String?) -> String? {
        guard let project, !project.isEmpty, let leads = engine?.leads.leads.values else { return nil }
        return leads.first { NodeIds.project(root: $0.root) == project || $0.root == (project as NSString).standardizingPath }?.root
    }

    func boardTask(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let slug = request.args?["task"]?.string, !slug.isEmpty, slug.utf8.count <= 200 else {
            return reply(.init(re: request.id, error: .init(.badArgs, "board.task needs a project and a task's slug")))
        }
        guard let root = leadRoot(request.args?["project"]?.string) else {
            return reply(.init(re: request.id, error: .init(.gone, "no lead runs for that project on this node")))
        }
        let queue = self.queue
        DispatchQueue.global(qos: .userInitiated).async {
            let read = BoardFile.read(root: root)
            let value = read.board?.tasks.first { $0.slug == slug }.map(BoardDetails.task)
            queue.async {
                guard let value else {
                    return reply(.init(re: request.id, error: .init(.gone, read.refusal ?? "no task \(ConfigSeal.inert(slug, limit: 80)) on that board")))
                }
                reply(.init(re: request.id, result: value))
            }
        }
    }

    func boardImage(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let update = request.args?["update"]?.string, !update.isEmpty, update.utf8.count <= 200,
              let index = request.args?["index"]?.int else {
            return reply(.init(re: request.id, error: .init(.badArgs, "board.image needs a project, a result's id and an image's index")))
        }
        let offset = request.args?["offset"]?.int ?? 0
        guard offset >= 0 else { return reply(.init(re: request.id, error: .init(.badArgs, "board.image's offset is a byte of the image"))) }
        guard let root = leadRoot(request.args?["project"]?.string) else {
            return reply(.init(re: request.id, error: .init(.gone, "no lead runs for that project on this node")))
        }
        let queue = self.queue
        DispatchQueue.global(qos: .userInitiated).async {
            let image = BoardFile.read(root: root).board.flatMap { BoardDetails.image(root: root, board: $0, update: update, index: index) }
            let part = ChatImageBytes.part(bytes: image, offset: offset)
            queue.async {
                switch part {
                case .value(let value): reply(.init(re: request.id, result: value))
                case .refused(let failure): reply(.init(re: request.id, error: failure))
                }
            }
        }
    }
}
