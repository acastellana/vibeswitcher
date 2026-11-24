import Foundation
import VibeCore

/// The open cards across a server restart or a `switch` (2026-11-24: the user's first switch on the real node lost the
/// four open cards, and the lead asked them all again). Kept in `<root>/v2/cards.json` (format 1): every open card whole
/// (its id and code, the question with its version, the facts, the held config's hashes, the base move, the page's
/// draft) and the plugin cards not drawn again yet (`CardStore.kept`).
///
/// The file is no seal (a worker of the user's uid can write it), so it is taken back only while its bytes' SHA-256 is
/// the digest the vault keeps (`LeadVaultV2.Request.keepCards`, which only the server may set, as every v2 request):
/// each write goes to `cards.json.partial`, its digest to the vault, then the rename over `cards.json`, so at the start
/// the one file whose digest is the vault's is taken (the partial one when a crash came between the vault and the
/// rename). Anything else is dropped, said in the log, and each lead is told of the open questions the user no longer
/// sees, as before (`tellUnshownQuestions`). A host restart starts the vault over: nothing is taken back then.
///
/// What comes back is what this node drew: a question as the lead's sealed post last made it, an approval's facts (built
/// again from git and the vault at once, `buildApproval`), held config bound to the hashes it showed (a look finding the
/// same hashes keeps the card), a base move. A plugin card isn't shown again from the file: its plugin is asked about
/// the request anew, and the card it draws takes the kept id (`CardStore.adopt`). Closed cards aren't kept.
final class CardKeep: @unchecked Sendable {
    /// The file as written.
    struct File: Codable, Equatable {
        var format = 1
        var cards: [CardStore.Card]
    }

    /// Whether changes are written: from the first welcome's restore on, so an empty store at the start never writes
    /// over what is to be taken back. On the engine's queue, as all but `writes`.
    var saving = false
    /// A write is queued for this turn of the queue.
    var pending = false
    /// The digest last handed to `writes`.
    var written: String?
    /// The file's writes and the vault's calls, one after another.
    let writes = DispatchQueue(label: "vibenode.lead-engine.cards", qos: .utility)

    /// The most the file is read or written.
    static let bytesAtMost = 16 * 1024 * 1024

    /// `<root>/v2/cards.json`, and its partial write beside it.
    static func url(root: URL) -> URL { root.appendingPathComponent("v2", isDirectory: true).appendingPathComponent("cards.json") }
    static func partialURL(root: URL) -> URL { url(root: root).appendingPathExtension("partial") }

    /// Whether a kept file is there (at the engine's start: plugins wait for the restore then).
    static func exists(root: URL) -> Bool {
        [url(root: root), partialURL(root: root)].contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func encoded(_ file: File) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(file)) ?? Data()
    }

    /// What `vouched` (the vault's digest) takes back of the two files' bytes: the cards of the one whose SHA-256 it is,
    /// or why none.
    static func taken(file: Data?, partial: Data?, vouched: String?) -> Result<[CardStore.Card], Refusal> {
        guard file != nil || partial != nil else { return .success([]) }
        guard let vouched else { return .failure(Refusal("the vault keeps no digest of it (a host restart starts the vault over)")) }
        guard let bytes = [file, partial].compactMap({ $0 }).first(where: { BuildInfo.sha256(of: $0) == vouched }) else {
            return .failure(Refusal("its bytes aren't the ones the vault keeps the digest of"))
        }
        guard let read = try? JSONDecoder().decode(File.self, from: bytes), read.format == 1 else {
            return .failure(Refusal("it doesn't read as format 1"))
        }
        return .success(read.cards)
    }

    struct Refusal: Error, Equatable, CustomStringConvertible {
        var description: String
        init(_ text: String) { description = text }
    }
}

extension LeadEngine {
    /// The cards `cards.json` keeps, taken back at the server's first welcome (`restartLook`) while the vault vouches for
    /// its bytes (`CardKeep`), then every change written. `then` on `queue` once done (taken back or not). On `queue`.
    func restoreCards(then: @escaping () -> Void) {
        let (root, client, note) = (self.root, link.vaultV2, self.note)
        cardKeep.writes.async { [weak self] in
            let file = PluginDesk.bounded(CardKeep.url(root: root), limit: CardKeep.bytesAtMost)
            let partial = PluginDesk.bounded(CardKeep.partialURL(root: root), limit: CardKeep.bytesAtMost)
            var taken: Result<[CardStore.Card], CardKeep.Refusal> = .success([])
            if file != nil || partial != nil {
                do {
                    taken = CardKeep.taken(file: file, partial: partial, vouched: try client.keptCards())
                } catch {
                    taken = .failure(CardKeep.Refusal("the vault couldn't be asked for its digest (\(error))"))
                }
            }
            guard let self else { return }
            self.queue.async {
                switch taken {
                case .failure(let why): note("cards: \(CardKeep.url(root: root).path) not taken back: \(why); its cards are dropped")
                case .success(let kept): self.takeBack(kept)
                }
                self.cards.restoring = false
                self.cardKeep.saving = true
                self.cardKeepWatch = self.cards.changes.subscribe(on: self.queue) { [weak self] _ in self?.keepCards() }
                self.keepCards()
                then()
            }
        }
    }

    /// `kept`, the cards a server before this one kept, taken back: each open one this server hasn't drawn meanwhile
    /// (a post or a look that came first keeps its own), the plugin cards set aside for their plugin's next drawing. On
    /// `queue`.
    func takeBack(_ kept: [CardStore.Card]) {
        let now = Date()
        var (shown, plugins, skipped) = (0, 0, 0)
        for card in kept where card.isOpen {
            if card.kind == .plugin {
                guard let request = card.plugin, (request.expiresAt).map({ $0 > now }) == true else { skipped += 1; continue }
                cards.kept[CardStore.keptKey(plugin: request.plugin, request: request.request)] = card
                plugins += 1
                continue
            }
            let drawn = cards.cards[card.id] != nil
                || card.question.map { cards.card(question: $0.id, root: card.root) != nil } == true
                || ((card.kind == .configHeld || card.kind == .baseMove) && cards.list(project: card.project).contains { $0.kind == card.kind })
            guard !drawn else { skipped += 1; continue }
            cards.put(card)
            shown += 1
            if card.kind == .approval, let commit = card.approval?.commit { buildApproval(card: card.id, commit: commit, root: card.root) }
        }
        if shown + plugins + skipped > 0 {
            note("cards: \(shown) open card(s) taken back across the restart" + (plugins > 0 ? ", \(plugins) plugin request(s) to draw again under their ids" : "")
                 + (skipped > 0 ? ", \(skipped) left (drawn again meanwhile, or expired)" : ""))
            cardsChanged()
        }
    }

    /// Every open card written to `cards.json` once this turn of the queue is done (`CardKeep`). On `queue`.
    func keepCards() {
        guard cardKeep.saving, !cardKeep.pending else { return }
        cardKeep.pending = true
        queue.async { [weak self] in self?.writeCards() }
    }

    private func writeCards() {
        cardKeep.pending = false
        guard cardKeep.saving else { return }
        let now = Date()
        cards.kept = cards.kept.filter { ($0.value.plugin?.expiresAt).map { $0 > now } == true }
        let open = cards.list() + cards.kept.values.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        let data = CardKeep.encoded(CardKeep.File(cards: open))
        let digest = BuildInfo.sha256(of: data)
        guard digest != cardKeep.written else { return }
        guard data.count <= CardKeep.bytesAtMost else {
            return note("cards: \(open.count) open cards are past \(CardKeep.bytesAtMost / 1024 / 1024) MiB: not kept across a restart")
        }
        cardKeep.written = digest
        let (root, client, note, queue) = (self.root, link.vaultV2, self.note, self.queue)
        cardKeep.writes.async { [weak self] in
            let (url, partial) = (CardKeep.url(root: root), CardKeep.partialURL(root: root))
            do {
                try VibePaths.ensurePrivate(url.deletingLastPathComponent(), within: root)
                try VibePaths.writePrivate(data, to: partial)
                try client.keepCards(digest: digest)
                guard rename(partial.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
            } catch {
                note("cards: \(url.path) not written (\(error)): the open cards aren't kept across a server restart")
                queue.async { if self?.cardKeep.written == digest { self?.cardKeep.written = nil } }
            }
        }
    }
}
