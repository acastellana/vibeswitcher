import Foundation
import VibeCore

/// A plugin's card on the wire (`card.plugin`, `WireSchema`): the same shape for every plugin, each field as
/// `PluginCard` names it. What the agent wrote (the body, the context) is only ever text: every client shows it inert.
extension PluginCard {
    public var value: NodeWire.Value {
        func text(_ value: String?) -> NodeWire.Value { value.map(NodeWire.Value.string) ?? .null }
        return .object([
            "plugin": .string(plugin), "request": .string(request), "session": .string(session), "asker": .string(asker),
            "title": .string(title), "noun": .string(noun), "ask": .string(ask),
            "facts": .array(facts.map { .object(["name": .string($0.name), "label": .string($0.label), "value": .string($0.value),
                                                 "folder": .bool($0.folder), "decisive": .bool($0.decisive)]) }),
            "body": .object(["name": .string(body.name), "label": .string(body.label), "note": text(body.note),
                             "lines": .array(body.lines.map(NodeWire.Value.string)), "bytes": .int(body.bytes), "size": .string(body.size)]),
            "context": context.map { .object(["name": .string($0.name), "label": .string($0.label), "text": .string($0.text)]) } ?? .null,
            "severity": .string(severity.rawValue), "expiresAt": expiresAt.map(NodeWire.Value.date) ?? .null,
            "actions": .array(actions.map { .object(["word": .string($0.word), "label": .string($0.label), "acts": .bool($0.acts),
                                                     "short": .string($0.short), "does": .string($0.does), "verb": .string($0.verb),
                                                     "marks": .string($0.marks)]) }),
            "waiting": text(waiting), "state": .string(state), "outcome": text(outcome),
        ])
    }
}
