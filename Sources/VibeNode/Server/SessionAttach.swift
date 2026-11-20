import Foundation
import VibeCore

/// An image a web page pasted or dropped into a session's composer (the composer's lane, 2026-11-20), saved where the
/// session's agent can read it, as the app saves a pasted image (`Attachments`: `<root>/attachments`, the folder 0700,
/// each file 0600, `pasted-<date>-<4>.<ext>`, those older than 30 days pruned). A page's message is at most 64 KiB
/// (`NodeWebListener.limits`), so an image comes in parts (`session.attach`), kept in the server's memory until the
/// last arrives, then checked to be the image its type says (by its first bytes) and written. Nothing is typed: the
/// page's draft names the file (`session.draft`'s `images`), and `vibeswitcher send SESSION` sends it, in the user's
/// voice. On the engine's queue.
final class SessionAttachments {
    /// The most an image may be, whole.
    static let maxBytes = 5 << 20
    /// The most parts an image comes in.
    static let maxParts = 200
    /// The most images coming in at once, from every page.
    static let maxUploads = 4
    /// How long an image's parts are kept waiting for the rest.
    static let uploadLife: TimeInterval = 120
    /// How much the folder may hold before a page's image is refused.
    static let folderLimit = 200 << 20
    /// Pasted images older than this go (the agents have long read them; the app's `Attachments.prune`).
    static let kept: TimeInterval = 30 * 86_400

    /// The types an image may be, with their files' extensions.
    static let types = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"]

    struct Upload {
        var session: String
        var type: String
        var parts: Int
        var received: [Int: Data] = [:]
        var bytes = 0
        var started: Date
    }

    private var uploads: [String: Upload] = [:]

    /// The folder the images go in, under the node's `root`.
    static func folder(root: URL) -> URL { root.appendingPathComponent("attachments", isDirectory: true) }

    /// Whether `path` is an image a page attached: a file in `root`'s attachments folder, by its name.
    static func isAttached(_ path: String, root: URL) -> Bool {
        let folder = folder(root: root).standardizedFileURL.path
        let standard = URL(fileURLWithPath: path).standardizedFileURL
        return standard.deletingLastPathComponent().path == folder && types.values.contains(standard.pathExtension)
            && FileManager.default.fileExists(atPath: standard.path)
    }

    enum Taken {
        /// More parts to come: how many came.
        case partial(Int)
        /// The whole image, to be written.
        case whole(Data, type: String)
        case refused(NodeWire.Code, String)
    }

    /// Part `part` of `parts` of upload `id` for `session`, `type`, `data`. A part that came before is taken again
    /// (a page's retry). Uploads older than `uploadLife` are dropped first.
    func take(id: String, session: String, type: String, part: Int, parts: Int, data: Data, now: Date = Date()) -> Taken {
        uploads = uploads.filter { now.timeIntervalSince($0.value.started) < Self.uploadLife }
        guard Self.types[type] != nil else { return .refused(.badArgs, "an attached image is png, jpeg, gif or webp, not \(ConfigSeal.inert(type, limit: 40))") }
        guard (1...Self.maxParts).contains(parts), (0..<parts).contains(part) else {
            return .refused(.badArgs, "an image comes in 1 to \(Self.maxParts) parts, each numbered from 0")
        }
        var upload = uploads[id] ?? Upload(session: session, type: type, parts: parts, started: now)
        guard upload.session == session, upload.type == type, upload.parts == parts else {
            return .refused(.badArgs, "upload \(ConfigSeal.inert(id, limit: 40)) is another image's")
        }
        if uploads[id] == nil, uploads.count >= Self.maxUploads {
            return .refused(.refused, "\(Self.maxUploads) images are coming in already: try again once they're in")
        }
        upload.bytes += data.count - (upload.received[part]?.count ?? 0)
        upload.received[part] = data
        guard upload.bytes <= Self.maxBytes else {
            uploads[id] = nil
            return .refused(.badArgs, "an attached image is at most \(Self.maxBytes >> 20) MB")
        }
        guard upload.received.count == parts else {
            uploads[id] = upload
            return .partial(upload.received.count)
        }
        uploads[id] = nil
        let whole = (0..<parts).reduce(into: Data()) { $0.append(upload.received[$1] ?? Data()) }
        guard Self.looks(whole, like: type) else { return .refused(.badArgs, "that isn't a \(type) image (its first bytes say otherwise)") }
        return .whole(whole, type: type)
    }

    /// Whether `data` starts as a `type` image does.
    static func looks(_ data: Data, like type: String) -> Bool {
        let head = [UInt8](data.prefix(12))
        switch type {
        case "image/png": return head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/jpeg": return head.starts(with: [0xFF, 0xD8, 0xFF])
        case "image/gif": return head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8))
        case "image/webp": return head.count == 12 && head.starts(with: Array("RIFF".utf8)) && Array(head[8..<12]) == Array("WEBP".utf8)
        default: return false
        }
    }

    /// `data` written as a new file in `root`'s attachments folder, as the app names a pasted image; the folder's old
    /// images pruned first. Its path, or why not. Reads and writes the disk: off the engine's queue.
    static func write(_ data: Data, type: String, root: URL, now: Date = Date()) -> Result<String, Refusal> {
        let folder = folder(root: root)
        let files = FileManager.default
        do {
            try VibePaths.ensurePrivate(folder, within: root)
        } catch {
            return .failure(Refusal("the attachments folder couldn't be made: \(error.localizedDescription)"))
        }
        var held = 0
        for url in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [] {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if now.timeIntervalSince(values?.contentModificationDate ?? now) > kept { try? files.removeItem(at: url) } else { held += values?.fileSize ?? 0 }
        }
        guard held + data.count <= folderLimit else {
            return .failure(Refusal("the node's attachments folder holds \(held >> 20) MB of images already: older ones go after 30 days"))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "pasted-\(formatter.string(from: now))-\(UUID().uuidString.prefix(4).lowercased()).\(types[type] ?? "png")"
        let url = folder.appendingPathComponent(name)
        do {
            try VibePaths.writePrivate(data, to: url)
        } catch {
            return .failure(Refusal("the image couldn't be written in the attachments folder: \(error.localizedDescription)"))
        }
        return .success(url.path)
    }

    struct Refusal: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

extension Requests {
    /// `session.attach` with `session` (the node's whole id for it), `upload` (the page's id for the image, a UUID),
    /// `type`, `part`, `parts` and `data` (that part, base64), from a web page whose token drafts (the composer's lane,
    /// 2026-11-20): a pasted or dropped image, in parts (`SessionAttachments`). The reply to the last part carries the
    /// `path` it was written to, for the page's draft; the others say how many parts came (`received`). Only for a
    /// session the host started with an agent in it. `draft`'s preamble (the action id, a repeat answered as before, a
    /// stopping node) came first.
    func attach(_ request: NodeWire.Request, done: @escaping (NodeWire.Reply) -> Void) {
        guard let id = request.args?["session"]?.string, !id.isEmpty else {
            return done(.init(re: request.id, error: .init(.badArgs, "session.attach needs session")))
        }
        guard let upload = request.args?["upload"]?.string, UUID(uuidString: upload) != nil else {
            return done(.init(re: request.id, error: .init(.badArgs, "session.attach needs upload, a UUID")))
        }
        guard let part = request.args?["part"]?.int, let parts = request.args?["parts"]?.int, let type = request.args?["type"]?.string,
              let encoded = request.args?["data"]?.string, let data = Data(base64Encoded: encoded), !data.isEmpty else {
            return done(.init(re: request.id, error: .init(.badArgs, "session.attach needs type, part, parts and data (base64)")))
        }
        guard let hostID = UUID(uuidString: String(id.dropFirst(NodeIds.node.count + 1))), id.hasPrefix(NodeIds.node + ":"),
              let session = link.sessions.first(where: { $0.id == hostID && $0.isLive }) else {
            return done(.init(re: request.id, error: .init(.gone, "no session \(ConfigSeal.inert(id, limit: 80)) the node's host runs")))
        }
        guard HostedAgents.agent(of: session) != nil else {
            return done(.init(re: request.id, error: .init(.refused, "that session is a shell: it takes no images")))
        }
        switch attachments.take(id: upload.lowercased(), session: id, type: type, part: part, parts: parts, data: data) {
        case .refused(let code, let why):
            done(.init(re: request.id, error: .init(code, why)))
        case .partial(let received):
            done(.init(re: request.id, result: .object(["session": .string(id), "received": .int(received)])))
        case .whole(let image, let type):
            let (queue, root, note) = (self.queue, self.root, self.note)
            DispatchQueue.global(qos: .userInitiated).async {
                let written = SessionAttachments.write(image, type: type, root: root)
                queue.async {
                    switch written {
                    case .failure(let refusal):
                        done(.init(re: request.id, error: .init(.refused, refusal.message)))
                    case .success(let path):
                        note("session.attach on \(id) from a web page: an image of \(image.count) bytes kept in the attachments folder")
                        done(.init(re: request.id, result: .object(["session": .string(id), "received": .int(parts), "path": .string(path)])))
                    }
                }
            }
        }
    }
}
