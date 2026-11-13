import Foundation
import VibeCore

/// Each message's sender (the stage 2 plan's Task 7, S2-D4; the security architecture document's S5). Every read of
/// a client's connection comes with the process that sent its bytes (`Platform.Sockets.receive`: on Linux
/// `SCM_CREDENTIALS`, one read never holding two senders' bytes; on the Mac `LOCAL_PEERTOKEN` as it is after the read,
/// whoever last used the peer's socket), and the host checks it against the process it accepted the connection from
/// (or, for a connection it made through an app connector, the process it made it for): any other sender, or none,
/// makes the connection `.unknown` for good. A frame made of two senders' bytes is handled as an unknown caller's
/// request (refused beyond `.unknown`'s rights), not dropped, as the Mac does today: the check runs after the read and
/// before any frame of it is handled.
///
/// The Mac's outcome is unchanged: what `checkPeer` did at each read (re-read `LOCAL_PEERTOKEN` and compare), this
/// does with the token `receive` read just after the read. `checkPeer` keeps its other four calls (`handle`, `reply`,
/// `deliver`, `broadcast`).
///
/// *Doesn't promise:* who reads from a connection; that the sender didn't exec another program since (on Linux the
/// token keeps its pid and start); pid reuse (a sender that wrote and ended, its pid given to a new process before the
/// host's read, is taken as the new process, see `Platform.Sockets.receive`).
enum SenderCheck {
    /// Whether bytes from `sender` keep the identity of a connection accepted from `accepted`: only when both are
    /// known and are the same process (`PeerToken.sameImage`). A missing sender (bytes sent with no credentials, or
    /// their sender gone) is never the process accepted, and with none accepted no sender is.
    static func keepsIdentity(accepted: Platform.PeerToken?, sender: Platform.PeerToken?) -> Bool {
        guard let accepted, let sender else { return false }
        return sender.sameImage(as: accepted)
    }
}

/// The senders of the bytes a connection's frame decoder holds and hasn't handed out as frames yet, run by run, so
/// that a frame made of two senders' bytes is known as one.
///
/// At most `cap` runs are noted: the bytes after them are noted only as of more than one sender (`unnoted`), until
/// they are all taken out. So a peer that has two processes take turns writing a byte each costs the host a fixed
/// amount of memory, and time linear in the bytes, however many runs a frame holds. That reports a frame of one
/// sender's bytes among them as two senders', which changes no outcome: more than one run means two reads whose
/// senders weren't the same process, at least one of them not the process accepted (or none), and `onRead` was told
/// each read's sender before its bytes were noted here, so the connection is no one's already, for good.
struct FrameSenders {
    /// The runs noted at most, before the rest are `unnoted`.
    static let cap = 64

    private var runs: [(count: Int, sender: Platform.PeerToken?)] = []
    /// Bytes after `runs` whose senders aren't noted, more than one.
    private var unnoted = 0

    /// The runs noted (at most `cap`), for tests.
    var notedRuns: Int { runs.count }

    /// `count` bytes appended to the decoder, from `sender`.
    mutating func append(_ count: Int, from sender: Platform.PeerToken?) {
        guard count > 0 else { return }
        if unnoted > 0 {
            unnoted += count
        } else if let last = runs.last, Self.same(last.sender, sender) {
            runs[runs.count - 1].count += count
        } else if runs.count < Self.cap {
            runs.append((count, sender))
        } else {
            unnoted = count
        }
    }

    /// The first `count` bytes taken out (a frame the decoder handed out): whether they came from more than one
    /// sender (two runs of no known sender count as two, and any unnoted byte as another sender's).
    mutating func take(_ count: Int) -> Bool {
        var left = count, first: Platform.PeerToken??, mixed = false, used = 0
        while left > 0, used < runs.count {
            let run = runs[used]
            if let seen = first {
                if !Self.same(seen, run.sender) { mixed = true }
            } else {
                first = .some(run.sender)
            }
            let taken = min(left, run.count)
            left -= taken
            if taken == run.count { used += 1 } else { runs[used].count -= taken }
        }
        runs.removeFirst(used)
        if left > 0, unnoted > 0 {
            unnoted -= min(left, unnoted)
            mixed = true
        }
        return mixed
    }

    /// Two runs from one sender: both known and the same process. Bytes of no known sender are no one's in particular.
    private static func same(_ one: Platform.PeerToken?, _ other: Platform.PeerToken?) -> Bool {
        guard let one, let other else { return false }
        return one.sameImage(as: other)
    }
}

extension HostServer {
    /// The rule for bytes read on `client` from `sender` (nil: none known), before any frame of them is handled: a
    /// connection that is someone (or the Mac's app's code, not yet proven) stays so only while its bytes come from the
    /// process accepted (`client.peer`: for a connector's connection, the process it was made for). Otherwise it is
    /// no one's for good: its attachments dropped with their queued output. Accepted and connector clients alike.
    func checkSender(_ client: ClientConnection, sender: Platform.PeerToken?) {
        guard client.caller != .unknown || client.runsAppCode else { return }
        guard !SenderCheck.keepsIdentity(accepted: client.peer, sender: sender) else { return }
        log("pid \(client.peer?.pid ?? 0) is no longer the one sending on its connection: it's no one to the vault now")
        client.caller = .unknown
        client.runsAppCode = false
        let attached = client.attached
        client.attached.removeAll()
        for id in attached {
            client.dropQueuedOutput(of: id)
            updateAttachment(id)
        }
    }
}
