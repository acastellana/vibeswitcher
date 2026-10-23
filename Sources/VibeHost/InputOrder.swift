import Foundation
import VibeCore

/// One session's input from every client, in order (see `HostRequest.inputUnit`): a unit (a message's text and its
/// Enter) goes in whole, and what else comes for the session meanwhile (another client's unit, keys) waits until it's
/// in, then goes in the order it came. The app's composer and the lead's tool server each send their units on
/// connections of their own: each scheduled its own, two messages went in as text, text, Enter, Enter. Runs on the
/// host's queue.
final class InputOrder {
    typealias Client = ObjectIdentifier

    /// How long a held unit (`more`) waits for its sender's next part before it's over and the rest go in.
    static let holdLimit: TimeInterval = 10
    /// How long a write waits for the program to read what was written before it: then the unit is over, refused.
    static let stallLimit: TimeInterval = 30
    /// From one unit's end to the next one's first write (or to what waited behind it): a program that reads both at
    /// once takes them for one paste, with the Enter inside it.
    static let unitGap: TimeInterval = 0.1

    private struct Part {
        let from: Client
        let writes: [HostInput.Write]
        let more: Bool
        let reply: (HostEvent) -> Void
    }

    private enum Waiting {
        /// `write(taken)`: true once it was taken here (see `HostedSession.writeTaken`).
        case input(from: Client, bytes: Int, write: (Bool) -> Void)
        case part(Part)
    }

    private let session: HostedSession
    private let queue: DispatchQueue
    private let note: (String) -> Void
    let holdLimit: TimeInterval, stallLimit: TimeInterval
    /// The client whose unit is going in.
    private var holder: Client?
    /// A part's writes are under way.
    private var writing = false
    /// The unit's first write is still to go.
    private var starting = false
    /// The holder went away while its part was going in: the unit ends with that part.
    private var holderGone = false
    /// The part going in.
    private var current: Part?
    /// The holder's parts sent before the one under way was answered.
    private var nextParts: [Part] = []
    private var waiting: [Waiting] = []
    /// The bytes of plain input in `waiting`: counted with the session's own (`HostedSession.inputWaiting`) against its
    /// room, so what's taken here is never refused once it's written.
    private var waitingBytes = 0
    /// Plain input was refused while some was taken and waited: more is, until what was taken before it went in, so
    /// none lands out of order. Never set with nothing taken (the session's own refusal says what it refuses then).
    private var refusing = false
    /// Counts the steps taken: a timer or a callback from a step already over does nothing.
    private var step = 0
    private var lastUnit = Date.distantPast
    /// Waiting out the gap after a unit before what waited behind it goes in.
    private var resting = false

    init(session: HostedSession, queue: DispatchQueue, holdLimit: TimeInterval = InputOrder.holdLimit,
         stallLimit: TimeInterval = InputOrder.stallLimit, note: @escaping (String) -> Void) {
        self.session = session
        self.queue = queue
        self.holdLimit = holdLimit
        self.stallLimit = stallLimit
        self.note = note
    }

    private var free: Bool { holder == nil && waiting.isEmpty && !resting }

    /// Plain input (`HostRequest.input`): written now (`write(false)`), unless a unit is going in or input waits for
    /// one. Then it waits, taken, if there's room for it beside what else waits for the session; false: there's none,
    /// and it's refused now. The client takes the host's next answer on its connection (a screen read) for the
    /// receipt of what it sent before: what's taken goes in (`write(true)`), so a refusal can only come before that.
    func input(from client: Client, bytes: Int, _ write: @escaping (Bool) -> Void) -> Bool {
        guard !free else {
            write(false)
            return true
        }
        let session = self.session.inputWaiting
        guard !refusing, !session.refusing, session.bytes + waitingBytes + bytes <= HostedSession.maxPendingInput else {
            refusing = waitingBytes > 0
            return false
        }
        waitingBytes += bytes
        waiting.append(.input(from: client, bytes: bytes, write: write))
        return true
    }

    /// A unit's part (`HostRequest.inputUnit`). A client sends its next part once this one is answered; what it sends
    /// after a part without `more` is a unit of its own.
    func part(from client: Client, writes: [HostInput.Write], more: Bool, reply: @escaping (HostEvent) -> Void) {
        let part = Part(from: client, writes: writes, more: more, reply: reply)
        if holder == client, current?.more == true {
            guard !writing else { return nextParts.append(part) }
            return run(part)
        }
        guard free else { return waiting.append(.part(part)) }
        begin(part)
    }

    /// The client's connection closed: its unit is over, and its units still waiting aren't written (it was told
    /// nothing of them, and may have given up). Its plain input still goes in, as it would have without a unit.
    func dropped(_ client: Client) {
        waiting.removeAll { if case .part(let part) = $0 { return part.from == client } else { return false } }
        guard holder == client else { return }
        nextParts = []
        if writing { holderGone = true } else { end() }
    }

    /// The session is gone: what waits isn't written.
    func close() {
        step += 1
        let error = HostEvent.error("No such session.")
        if writing { current?.reply(error) }
        nextParts.forEach { $0.reply(error) }
        for case .part(let part) in waiting { part.reply(error) }
        nextParts = []
        waiting = []
        waitingBytes = 0
        refusing = false
        holder = nil
        current = nil
        writing = false
    }

    private func begin(_ part: Part) {
        holder = part.from
        starting = true
        holderGone = false
        run(part)
    }

    private func run(_ part: Part) {
        step += 1
        writing = true
        current = part
        write(part, at: 0)
    }

    /// Writes `part.writes[index]` once what was written before it reached the program, and its delay (a unit's
    /// first write: the gap after the last unit) is over.
    private func write(_ part: Part, at index: Int) {
        guard index < part.writes.count else { return finished(part) }
        step += 1
        let current = step
        queue.asyncAfter(deadline: .now() + stallLimit) { [weak self] in
            guard let self, self.step == current else { return }
            self.fail(part, "The program stopped reading its input: none of the rest went in.")
        }
        session.whenInputWent { [weak self] in
            guard let self, self.step == current else { return }
            self.step += 1
            let after = self.step
            let wait = self.starting ? self.lastUnit.addingTimeInterval(Self.unitGap).timeIntervalSinceNow : part.writes[index].delay
            self.queue.asyncAfter(deadline: .now() + max(0, wait)) { [weak self] in
                guard let self, self.step == after else { return }
                self.starting = false
                guard self.session.info.isLive else { return self.fail(part, "The session ended.") }
                guard self.session.write(Data(part.writes[index].bytes)) else {
                    return self.fail(part, "Input refused: the program isn't reading it and the host's buffer is full. None of the rest went in.")
                }
                self.write(part, at: index + 1)
            }
        }
    }

    private func finished(_ part: Part) {
        writing = false
        part.reply(.ok)
        guard part.more, !holderGone else { return end() }
        if !nextParts.isEmpty { return run(nextParts.removeFirst()) }
        step += 1
        let current = step
        queue.asyncAfter(deadline: .now() + holdLimit) { [weak self] in
            guard let self, self.step == current else { return }
            self.note("input unit to \(HostServer.short(self.session.id)) held \(Int(self.holdLimit)) s with no next part: ended")
            self.end()
        }
    }

    private func fail(_ part: Part, _ message: String) {
        writing = false
        note("input unit to \(HostServer.short(session.id)) stopped: \(message)")
        part.reply(.error(message))
        nextParts.forEach { $0.reply(.error("The unit was over before this part: \(message)")) }
        end()
    }

    /// The unit is over: what waited behind it goes in, a gap later.
    private func end() {
        step += 1
        holder = nil
        writing = false
        holderGone = false
        nextParts = []
        current = nil
        lastUnit = Date()
        guard !waiting.isEmpty else {
            refusing = false
            return
        }
        resting = true
        queue.asyncAfter(deadline: .now() + Self.unitGap) { [weak self] in
            guard let self else { return }
            self.resting = false
            self.release()
        }
    }

    /// Writes what waited, in order, up to the next unit, which then goes in.
    private func release() {
        while holder == nil, !resting, !waiting.isEmpty {
            switch waiting.removeFirst() {
            case .input(_, let bytes, let write):
                waitingBytes -= bytes
                write(true)
            case .part(let part): begin(part)
            }
        }
        if waitingBytes == 0 { refusing = false }
    }
}
