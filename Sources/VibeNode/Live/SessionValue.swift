import Foundation
import VibeCore

extension Session {
    /// A session as the live protocol's `sessions` collection carries it (the live wire contract's §5): the eight fields
    /// `status` writes (`Requests.value(_:)`), by the same names and unchanged, and twelve more, every one present (null
    /// when it holds nothing). Fields marked † in the contract (`project`, `task`, `detail`, `activity`, `startFolder`,
    /// `cwd`) are an agent's or a path's words: a client shows them as text only.
    public var liveValue: NodeWire.Value {
        guard case .object(var fields) = Requests.value(self) else { return Requests.value(self) }
        fields["shownStatus"] = .string(Requests.statusWord(shownStatus))
        fields["project"] = .string(project)
        fields["task"] = task.map(NodeWire.Value.string) ?? .null
        fields["detail"] = detail.map(NodeWire.Value.string) ?? .null
        fields["activity"] = activity.map(NodeWire.Value.string) ?? .null
        fields["activitySince"] = activitySince.map(NodeWire.Value.date) ?? .null
        fields["startedAt"] = .date(startedAt)
        fields["hasHooks"] = .bool(hasHooks)
        fields["leadAsks"] = .bool(leadAsks)
        fields["startFolder"] = startFolder.map(NodeWire.Value.string) ?? .null
        fields["backgroundJobs"] = .int(backgroundJobs.count)
        fields["hasTranscript"] = .bool(transcriptPath != nil)
        return .object(fields)
    }
}
