import AppKit
import SwiftUI
import VibeCore

/// The composer's outbox (see `Outbox`), on disk at every change: an entry is written before its message goes
/// out, so a hang, crash or relaunch mid-send leaves it here to send again or discard. Main thread only.
final class ComposerOutbox: ObservableObject {
    @Published private(set) var outbox: Outbox
    private let url: URL

    init(url: URL = OutboxStore.defaultURL) {
        self.url = url
        outbox = Outbox(restoring: OutboxStore.load(url))
        if !outbox.entries.isEmpty { Breadcrumbs.shared.note("composer: \(outbox.entries.count) unsent message(s) restored from the outbox") }
    }

    func entry(_ id: UUID) -> OutboxEntry? { outbox.entry(id) }

    /// Saves a message about to go out (before it does).
    func add(_ entry: OutboxEntry) {
        change { $0.add(entry) }
    }

    @discardableResult
    func remove(_ id: UUID) -> OutboxEntry? {
        var removed: OutboxEntry?
        change { removed = $0.remove(id) }
        return removed
    }

    @discardableResult
    func confirm(key: String, message: String, ok: Bool) -> UUID? {
        var id: UUID?
        change { id = $0.confirm(key: key, message: message, ok: ok) }
        return id
    }

    func handedOff(key: String, message: String) {
        change { $0.handedOff(key: key, message: message) }
    }

    func resend(_ id: UUID) -> OutboxEntry? {
        var entry: OutboxEntry?
        change { entry = $0.resend(id) }
        return entry
    }

    /// Drops what was sent to sessions the host no longer has (`known`: all it lists), and says so once: they're gone
    /// from the file with it.
    func forgetGone(known: Set<UUID>) {
        var dropped: [OutboxEntry] = []
        change { dropped = $0.dropGone(known: known) }
        guard !dropped.isEmpty else { return }
        let keys = Set(dropped.map(\.key)).sorted().joined(separator: ", ")
        Breadcrumbs.shared.note("composer: dropped \(dropped.count) unsent message(s) to session(s) the host no longer has (\(keys))")
    }

    func delivered(key: String, prompts: [SentMatch.Prompt]) {
        // Most polls find nothing to drop: don't rewrite the file for those.
        var copy = outbox
        guard !copy.delivered(key: key, prompts: prompts).isEmpty else { return }
        outbox = copy
        save()
    }

    private func change(_ body: (inout Outbox) -> Void) {
        var copy = outbox
        body(&copy)
        guard copy != outbox else { return }
        outbox = copy
        save()
    }

    private func save() {
        do {
            try OutboxStore.save(outbox.entries, to: url)
        } catch {
            Breadcrumbs.shared.note("composer: couldn't save the outbox: \(error.localizedDescription)")
        }
    }
}

/// Above the box: messages that may not have reached the agent (left by an earlier launch, or not taken by the
/// session host), each to send now, put back in the box, or discard. Nothing here is sent again by itself.
struct OutboxStrip: View {
    @ObservedObject var outbox: ComposerOutbox
    let rowID: String
    let agent: String
    let send: (OutboxEntry) -> Void
    let putBack: (OutboxEntry) -> Void

    var body: some View {
        let entries = outbox.outbox.needsYou(key: rowID)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange)
                            Text(entry.text.isEmpty ? "(no text)" : String(entry.text.prefix(500)))
                                .font(.system(size: 12.5)).lineLimit(3).truncationMode(.tail)
                            if !entry.attachments.isEmpty {
                                Label("\(entry.attachments.count)", systemImage: "photo").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 8) {
                            Text(status(entry)).font(.system(size: 10.5)).foregroundStyle(.orange)
                            Spacer(minLength: 0)
                            Button("Send now") { send(entry) }.controlSize(.small)
                            Button("Put back in the box") { putBack(entry) }.controlSize(.small)
                            Button("Discard") { outbox.remove(entry.id) }.controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.6),
                                                                                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
            .padding(.leading, 30)
        }
    }

    private func status(_ entry: OutboxEntry) -> String {
        let restored = outbox.outbox.restored.contains(entry.id)
        switch entry.state {
        case .sending where restored:
            return "Not sent: VibeSwitcher stopped while sending it."
        case .typed where restored:
            return "Typed in before VibeSwitcher restarted, but not in the conversation. It may still arrive."
        case .failed, .sending, .typed:
            return "The session didn't confirm it got this. It may not have reached \(agent)."
        }
    }
}
