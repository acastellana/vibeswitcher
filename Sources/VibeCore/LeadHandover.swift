import Foundation

/// The lead's role going to a new session (VibeSwitcher started another lead for the project). The vault moves the
/// role at once (issuing the new grant withdraws the old one), and everything addressed to the lead must move with
/// it: the board, which names the lead reports and wake-ups go to, stops naming the old one as soon as the role
/// goes, and what still waits in the old lead's inbox is taken out, to be delivered to the new lead once it runs.
/// The new lead's tool server names it on the board as it starts (`LeadToolset.introduceLead`). Until then no lead
/// is named: reports stay on the board (status lists them), and the app holds its messages.
public enum LeadHandover {
    /// The lead the board names, if it names one.
    public static func named(_ board: LeadBoard) -> LeadAgent? {
        guard let pid = board.leadPid, let tty = board.leadTTY else { return nil }
        return LeadAgent(pid: pid, tty: tty, session: board.leadSession)
    }

    /// The lead to tell: the one the board names, while its session holds the lead's role (`holder`: the session the
    /// vault has the role bound to) and its agent still runs on its terminal. A replaced lead's session is still
    /// there, its agent too, but the role isn't: it gets nothing.
    public static func current(_ board: LeadBoard, holder: String?, isRunning: (LeadAgent) -> Bool) -> LeadAgent? {
        guard let lead = named(board), let session = lead.session, session == holder, isRunning(lead) else { return nil }
        return lead
    }

    /// The board names no lead from now on; returns the one it named.
    @discardableResult
    public static func release(_ board: inout LeadBoard) -> LeadAgent? {
        let replaced = named(board)
        board.leadPid = nil
        board.leadTTY = nil
        board.leadSession = nil
        return replaced
    }

    /// Hands the role over on the board: the lead it named is named no more (see `release`), and what waited in its
    /// inbox is taken out (see `takeWaiting`), returned for the new lead.
    public static func begin(_ store: BoardStore, inbox: URL = VibePaths.root) throws -> (replaced: LeadAgent?, waiting: [SteerMessage]) {
        let replaced = try store.update { board in release(&board) }
        return (replaced, replaced.map { takeWaiting(for: $0, root: inbox) } ?? [])
    }

    /// The new lead's session, once started: the board names it until its tool server says where its agent runs.
    /// A tool server that introduced it first already did.
    public static func started(_ session: String, on board: inout LeadBoard) {
        if board.leadSession == nil { board.leadSession = session }
    }

    /// Takes everything waiting for `lead` out of its inbox, in order, none marked delivered (the replaced lead never
    /// got them). A message marked as the user's keeps that only with a valid seal (it's sealed again when posted to
    /// the new lead); when the seals can't be checked now, none does.
    public static func takeWaiting(for lead: LeadAgent, root: URL = VibePaths.root) -> [SteerMessage] {
        let taken = SteerInbox.pending(tty: lead.tty, root: root).filter { $0.agentPid == lead.pid }
            .compactMap { SteerInbox.withdraw(id: $0.id, tty: lead.tty, root: root) }
        let users = taken.filter { $0.from == .user }
        guard !users.isEmpty else { return taken }
        var verdicts = (SteerSeal.for(root).verify(users) ?? users.map { _ in false }).makeIterator()
        return taken.map { message in
            guard message.from == .user, verdicts.next() != true else { return message }
            var demoted = message
            demoted.from = .system("a message for the lead this one replaced, marked as the user's but not vouched for")
            demoted.seal = nil
            return demoted
        }
    }
}
