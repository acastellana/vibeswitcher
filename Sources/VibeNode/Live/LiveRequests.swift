import Foundation

/// A `subscribe` request's arguments, read (the live wire contract's §3): `sub`, `collection`, and for a resume `since`;
/// `key`, `after` and `limit` are the chat's (slice 2).
struct LiveSubscribe: Equatable {
    /// What a client already holds: a `seq` of the stream, in the server's `epoch`.
    struct Since: Equatable {
        var epoch: String
        var seq: Int
    }

    enum Parsed {
        case success(LiveSubscribe)
        case failure(NodeWire.Failure)
    }

    var sub: String
    var collection: String
    var key: String?
    var since: Since?
    var after: String?
    var limit: Int?

    /// The longest `sub` a client may name a subscription.
    static let subLength = 32

    /// Whether `sub` is a subscription's name: 1 to 32 of `[A-Za-z0-9._-]`.
    static func isSub(_ sub: String) -> Bool {
        (1...subLength).contains(sub.utf8.count) && sub.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }

    /// `args` read, or `bad-args` saying which is out of form. A `since` that isn't `{epoch: string, seq: int ≥ 0}` is
    /// no resume (the client gets a snapshot), not an error: whatever it held, a snapshot reconciles it.
    static func parse(_ args: [String: NodeWire.Value]?) -> Parsed {
        let args = args ?? [:]
        guard let sub = args["sub"]?.string, isSub(sub) else {
            return .failure(.init(.badArgs, "subscribe needs a sub: 1 to \(subLength) letters, digits, '.', '_' or '-'"))
        }
        guard let collection = args["collection"]?.string else {
            return .failure(.init(.badArgs, "subscribe needs a collection"))
        }
        let key = args["key"]?.string
        if collection == "chat", key == nil { return .failure(.init(.badArgs, "a chat subscription needs the session's id as its key")) }
        var since: Since?
        if let epoch = args["since"]?["epoch"]?.string, let seq = args["since"]?["seq"]?.int, seq >= 0 {
            since = Since(epoch: epoch, seq: seq)
        }
        return .success(LiveSubscribe(sub: sub, collection: collection, key: key, since: since, after: args["after"]?.string,
                                      limit: args["limit"]?.int))
    }
}
