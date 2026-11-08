import Foundation

/// The witness hands sleep interruptions to the lead's tool server. Kept across app/tool-server relaunches;
/// consumption is recorded before delivery, so an uncertain delivery is left to the lead rather than repeated.
public enum LeadSleepRecovery {
    public static let error = "API Error: Your computer went to sleep mid-response"
    public static func isSleepError(_ text: String?) -> Bool { text?.hasPrefix(error) == true }
    public static let message = "Your turn ended when the Mac slept. Check git status and your last commit, then go on from where you were."
    static let retryWait = "resume_after_sleep"

    public struct Interruption: Codable, Equatable, Sendable {
        public var slug: String
        public var session: String
        public var verifier: Bool
        public var at: Double
        public var key: String { "\(session)|api-error-\(Int(at))" }
    }

    public static func interruptions(board: LeadBoard, seen: [String: LeadWitness.Seen], now: Date = Date()) -> [Interruption] {
        board.tasks.flatMap { task -> [Interruption] in
            let workers = [.running, .failed].contains(task.status) ? [task.worker].compactMap { $0 }.filter { $0 != task.stopped } : []
            let verifiers = task.status == .review && task.evidence == nil ? task.awaitedVerifiers : []
            return (workers + verifiers).compactMap { session in
                guard let info = seen[session], info.live, !info.agentQuit, info.usageLimit == nil,
                      info.submittedAt == nil, !info.neverGotTools(now: now),
                      isSleepError(info.apiError), let at = info.apiErrorAt else { return nil }
                return Interruption(slug: task.slug, session: session, verifier: verifiers.contains(session), at: at)
            }
        }
    }

    struct Record: Codable {
        var event: Interruption
        var handled: Double?
        var attempted: Bool?
        var released: Bool?
    }

    struct Store {
        let root: String
        var folder: String { (root as NSString).appendingPathComponent(".vibeswitcher") }
        var file: URL { URL(fileURLWithPath: folder).appendingPathComponent("sleep-recovery.json") }

        func edit<T>(_ body: (inout [Record]) throws -> T) throws -> T {
            guard let lock = FileLock.attempt((folder as NSString).appendingPathComponent("run/sleep-recovery.lock")) else {
                throw BoardError(text: "Sleep recovery is busy")
            }
            defer { lock.release() }
            let original = try FileManager.default.fileExists(atPath: file.path) ? Data(contentsOf: file) : nil
            var records = try original.map { try JSONDecoder().decode([Record].self, from: $0) } ?? []
            let result = try body(&records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(records)
            if data != original { try VibePaths.writePrivate(data, to: file) }
            return result
        }

        func pending() throws -> [Interruption] { try edit { $0.filter { $0.handled == nil }.map(\.event) } }

        /// A refusal or an observation we cannot act on belongs to the lead again.
        func release(_ event: Interruption) throws {
            try edit { records in
                guard let index = records.firstIndex(where: { $0.event == event }) else { return }
                records[index].released = true
            }
        }

        /// Claims once, counting both roles together against the task's two resumes in the preceding hour.
        func claim(_ event: Interruption, now: Double, attempting: Bool = true) throws -> Bool? {
            try edit { records in
                guard let index = records.firstIndex(where: { $0.event == event && $0.handled == nil }) else { return nil }
                let count = records.filter { $0.event.slug == event.slug && $0.attempted == true && ($0.handled ?? -.infinity) > now - 3600 }.count
                records[index].handled = now
                records[index].attempted = attempting && count < 2
                return count < 2
            }
        }
    }

    /// Returns only keys safely handed off. Repeated observations merely nudge the pending work; consumed events
    /// remain deduplicated. A failed write leaves the ordinary witness notice visible.
    public static func enqueue(_ events: [Interruption], root: String) -> Set<String> {
        guard !events.isEmpty else { return [] }
        do {
            let (keys, added) = try Store(root: root).edit { records in
                var added = false
                for event in events where !records.contains(where: { $0.event == event }) {
                    records.append(Record(event: event))
                    added = true
                }
                let suppressed = records.filter { $0.released != true && events.contains($0.event) }
                return (Set(suppressed.map { $0.event.key }), added)
            }
            if added { LeadAdvance.nudge(root: root) }
            return keys
        } catch { return [] }
    }
}
