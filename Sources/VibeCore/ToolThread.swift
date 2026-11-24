import Foundation

/// The threads the lead's tool server (vibeswitcher-mcp) and auto_advance start: each with a stack of `stackSize`, not
/// a detached thread's default 512 KB. They decode, restore and merge the board's tasks, a debug build's frames holding
/// dozens of copies of a task each (`LeadToolset.mergeBatch`'s was 118 KB), and a stack that overflows takes the whole
/// process down (SIGBUS): on 2026-11-18 a receipt field 14 bytes larger did, in `BoardStore.restore` during
/// LeadAdvanceTests, and ended a merge's test run.
public enum ToolThread {
    /// The stack each gets: at least 4× the most any measured path needs in a debug build. ToolThreadStackTests and
    /// every `LeadAdvanceTests.Advancing` pass measure it, and fail when one needs more than a quarter. Measured
    /// 2026-11-18 (the lowest stack page touched): an auto_advance pass, at its deepest a batch merge, 300 KB in debug
    /// (380 KB before `LeadTask`'s largest fields were `Boxed`) and 156 KB in release; a tool call 220 KB and 92 KB;
    /// reading, archiving and restoring the board 108 KB and 76 KB. The memory is reserved, not used: a thread
    /// touches only the pages it reaches.
    public static let stackSize = 4 << 20

    /// `body` on a thread of its own with a stack of `stackSize`.
    public static func detach(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.stackSize = stackSize
        thread.start()
    }
}
