import Foundation
import VibeCore

/// A message a web page's composer left for a session (2026-11-20, the parity table's gap 1): the user's words, kept
/// in the server's memory and told to nobody, as a card's answer draft is (`CardStore.Draft`, LW-D6). `vibeswitcher
/// send SESSION` with no text types it, in the user's voice. A session's live value carries it as `draft`; it goes
/// with its session, and with the server.
public struct SessionDraft: Equatable, Sendable {
    public var text: String
    /// Images the page attached (`session.attach`): their paths in the node's attachments folder.
    public var images: [String]
    public var at: Date
    /// The page's action id it was left with.
    public var action: String

    public init(text: String, images: [String] = [], at: Date, action: String) {
        self.text = text
        self.images = images
        self.at = at
        self.action = action
    }

    public var value: NodeWire.Value {
        .object(["text": .string(text), "images": .array(images.map(NodeWire.Value.string)), "at": .date(at), "action": .string(action)])
    }
}
