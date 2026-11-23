import Foundation

/// The engine's leaf watches (the architecture review's row 8): each a type that owns its state, given what it needs of
/// the engine (its queue, notes, its files, the clock) and never the engine itself; where it must call back (telling a
/// lead), it holds a narrow protocol weakly, read on the engine's queue, so nothing reaches an engine that has gone.
enum EngineWatch {
    /// That the caller runs on `queue`, where the watch's state lives: checked in debug builds.
    static func assertOn(_ queue: DispatchQueue) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }
}
