import Foundation
import VibeCore

/// What the witness works out of a lead's board and what it saw of the team (`LeadEngine.witness`), on the engine's
/// reads queue: the sessions without tools, the verifiers auto_advance audits again, the messages to tell, the working
/// time and the stalls. On the app's main thread at each refresh they held it for 7.1 s on a busy Mac
/// (hang-20261028-195651); the engine's queue only applies what's worked out here.
///
/// The app's `WitnessWork` (`Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift` 274-338), copied (the port
/// map's "Copied from the app"), `recoveryRoot` kept.
struct WitnessWork {
    /// The live workers and verifiers that never got their tools (`LeadWitness.withoutTools`).
    var withoutTools: [String] = []
    /// The verifiers that ended without a verdict for auto_advance (`LeadWitness.endedForAdvance`), when it runs.
    var endedForAdvance: [String] = []
    /// The workers auto_advance releases while their audits run, between turns now (`LeadWitness.releasableForAdvance`).
    var releasableForAdvance: [String] = []
    /// The workers whose turn ended without a report for the first time, which auto_advance nudges
    /// (`LeadWitness.stopsForAdvance`), when it runs.
    var stopsForAdvance: [LeadWitness.StopForAdvance] = []
    /// The messages not told yet as of the look (`LeadWitness.unbuiltMessages`), their texts built where they're posted.
    var messages: [(keys: [String], text: @Sendable () -> String)] = []
    var sleepInterruptions: [LeadSleepRecovery.Interruption] = []
    /// The verifiers waiting on a prompt past its wait, not told yet (`LeadWitness.stuckPrompts`): declined, then told.
    var stuckPrompts: [LeadWitness.StuckPrompt] = []
    /// The running tasks' workers at work (`LeadBudget.working`), and whether the board's counts change for it.
    var working: Set<String> = []
    var notesWork = false
    /// Every session the look saw at work (`LeadBudget.works`): the vault counts its workers' tasks' time from these.
    var busySessions: Set<String> = []
    /// The machine's sleep as of the look: the count takes only time awake (`LeadBudget.awake`).
    var sleep = MacSleepLog()
    /// The stall to keep on each task (`LeadWitness.stalls`), and whether the board's change for it.
    var stalls: [String: LeadStall] = [:]
    var notesStalls = false

    /// `firstSeen`: when the engine first saw a verifier end for auto_advance (nil: not before now). `told`: whether an
    /// event key was told already. `step` names each computation as it starts (tests watch or slow them).
    init(board: LeadBoard, seen: [String: LeadWitness.Seen], now: Date, advancing: Bool, budgetMinutes: Int,
         firstSeen: (String) -> Date?, told: (String) -> Bool, step: ((String) -> Void)? = nil, recoveryRoot: String? = nil,
         sleep: MacSleepLog = MacSleepLog()) {
        self.sleep = sleep
        step?("withoutTools")
        withoutTools = LeadWitness.withoutTools(board: board, seen: seen, now: now)
        // Sleep recovery also owns running workers and works with auto_advance off.
        sleepInterruptions = LeadSleepRecovery.interruptions(board: board, seen: seen, now: now)
        var advanced: Set<String> = []
        if advancing {
            step?("endedForAdvance")
            endedForAdvance = LeadWitness.endedForAdvance(board: board, seen: seen, now: now)
            let first = Dictionary(endedForAdvance.map { ($0, firstSeen($0) ?? now) }, uniquingKeysWith: { first, _ in first })
            step?("leftToAdvance")
            advanced = LeadWitness.leftToAdvance(board: board, seen: seen, now: now, firstSeen: first)
            step?("releasableForAdvance")
            releasableForAdvance = LeadWitness.releasableForAdvance(board: board, seen: seen)
            step?("stopsForAdvance")
            stopsForAdvance = LeadWitness.stopsForAdvance(board: board, seen: seen, now: now)
        }
        step?("unbuiltMessages")
        messages = LeadWitness.unbuiltMessages(board: board, seen: seen, now: now, advanced: advanced, advancing: advancing, told: told)
        if let recoveryRoot {
            // This initializer runs on the boards' queue. Never lock/read the ledger or write a nudge on the engine's.
            let recovering = LeadSleepRecovery.enqueue(sleepInterruptions, root: recoveryRoot)
            // Workers Fable's refusal halted: the lead's loop starts each again on Opus; told by it, not here.
            let moving = LeadUsageFallback.enqueue(LeadUsageFallback.halts(board: board, seen: seen), root: recoveryRoot)
            messages = messages.filter { !$0.keys.contains(where: recovering.contains) && !$0.keys.contains(where: moving.contains) }
        }
        step?("stuckPrompts")
        stuckPrompts = LeadWitness.stuckPrompts(board: board, seen: seen, now: now, advanced: advanced).filter { !told($0.key) }
        step?("working")
        working = LeadBudget.working(board: board, seen: seen)
        busySessions = Set(seen.filter { LeadBudget.works($0.value) }.keys)
        // The count not on board.json yet (`LeadBudgetClock`): a few bytes, read here off the engine's queue.
        let clock = recoveryRoot.map { BoardStore(root: $0).budgetClock() } ?? LeadBudgetClock()
        notesWork = board.notesWork(working, defaultMinutes: budgetMinutes, now: now.timeIntervalSince1970, clock: clock, sleep: sleep)
        step?("stalls")
        stalls = LeadWitness.stalls(board: board, seen: seen, now: now)
        var noted = board
        notesStalls = noted.noteStalls(stalls)
    }
}
