import Darwin
import Foundation
import ObjectiveC

/// Debug aid for the benches: this process's live malloc blocks, counted by the Objective-C or Swift class whose
/// instance each one is (its first word, masked, is a known class), and the rest by size. What `heap` tells about a
/// process, read from inside it, so no tool takes the bench's task port. It never suspends a thread or locks a zone
/// (either can deadlock or abort the process, see `take`), and the count itself allocates nothing (its tables are made
/// before). Only a small block's first word is read (`classedUpTo`): those live in malloc's own regions, which stay
/// mapped when a block is freed under it; a big one, which another thread may free and unmap meanwhile, is counted
/// by size only.
enum HeapCensus {
    struct Count: Equatable {
        var blocks = 0
        var bytes = 0
    }

    struct Result {
        /// By class name.
        var classes: [String: Count] = [:]
        /// Blocks of no known class (buffers, strings, CF storage), by size: "≤ 64 B", "≤ 128 B"… "> 1 MB".
        var unclassed: [String: Count] = [:]
        var total = Count()
    }

    /// What grew from `before` to `after`, by name (class or size bucket), the most bytes first.
    static func growth(from before: Result, to after: Result, top: Int = 12) -> [(name: String, before: Count, after: Count)] {
        var rows: [(name: String, before: Count, after: Count)] = []
        for (table, beforeTable, suffix) in [(after.classes, before.classes, ""), (after.unclassed, before.unclassed, " (unclassed)")] {
            for name in Set(table.keys).union(beforeTable.keys) {
                rows.append((name + suffix, beforeTable[name] ?? Count(), table[name] ?? Count()))
            }
        }
        return Array(rows.sorted { $0.after.bytes - $0.before.bytes > $1.after.bytes - $1.before.bytes }.prefix(top))
    }

    /// The size bucket of an unclassed block.
    static func bucket(_ size: Int) -> Int {
        var bucket = 0, limit = 64
        while size > limit, bucket < bucketNames.count - 1 { bucket += 1; limit *= 2 }
        return bucket
    }

    static let bucketNames: [String] = {
        var names: [String] = [], limit = 64
        while limit <= 1 << 20 {
            names.append(limit < 1024 ? "≤ \(limit) B" : limit < 1 << 20 ? "≤ \(limit / 1024) KB" : "≤ \(limit >> 20) MB")
            limit *= 2
        }
        return names + ["> 1 MB"]
    }()

    /// The tables the zone enumerator's callback fills: made before the zones are locked, so it allocates nothing.
    fileprivate struct Tables {
        var capacity: Int
        var keys: UnsafeMutablePointer<UInt>
        var counts: UnsafeMutablePointer<Int>
        var bytes: UnsafeMutablePointer<Int>
        var unclassedCounts: UnsafeMutablePointer<Int>
        var unclassedBytes: UnsafeMutablePointer<Int>
        var mask: UInt
        var totalBlocks = 0
        var totalBytes = 0

        /// The slot of a class pointer, or nil when it's no class.
        func slot(_ key: UInt) -> Int? {
            var index = Int(truncatingIfNeeded: (key >> 3) &* 0x9E37_79B9_7F4A_7C15) & (capacity - 1)
            while keys[index] != 0 {
                if keys[index] == key { return index }
                index = (index + 1) & (capacity - 1)
            }
            return nil
        }

        mutating func insert(_ key: UInt) {
            var index = Int(truncatingIfNeeded: (key >> 3) &* 0x9E37_79B9_7F4A_7C15) & (capacity - 1)
            while keys[index] != 0, keys[index] != key { index = (index + 1) & (capacity - 1) }
            keys[index] = key
        }
    }

    nonisolated(unsafe) fileprivate static var tables: Tables?

    /// The biggest block whose first word is read for its class: an object bigger than this is rare, and is counted
    /// in its size's bucket instead.
    static let classedUpTo = 16 * 1024

    /// One census at a time: each fills the one `tables` the enumerator's callback writes (a soak's hourly census
    /// and the one at its end could overlap, each counting into the other's buffers and freeing them).
    private static let running = NSLock()

    /// Counts the live blocks now. Slow (a second or so with a big heap); call it off the main thread or between phases.
    /// A second caller waits for the first's census to end.
    static func take() -> Result {
        running.lock()
        defer { running.unlock() }
        var classCount: UInt32 = 0
        guard let classList = objc_copyClassList(&classCount) else { return Result() }
        defer { free(UnsafeMutableRawPointer(classList)) }
        var capacity = 1024
        while capacity < Int(classCount) * 2 { capacity *= 2 }
        // The class bits of an isa: libobjc says which (non-pointer isas carry flags and a reference count above them).
        let mask = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_debug_isa_class_mask")
            .map { $0.assumingMemoryBound(to: UInt.self).pointee } ?? 0x0000_000f_ffff_fff8
        var built = Tables(capacity: capacity, keys: .allocate(capacity: capacity), counts: .allocate(capacity: capacity),
                           bytes: .allocate(capacity: capacity), unclassedCounts: .allocate(capacity: bucketNames.count),
                           unclassedBytes: .allocate(capacity: bucketNames.count), mask: mask)
        built.keys.initialize(repeating: 0, count: capacity)
        built.counts.initialize(repeating: 0, count: capacity)
        built.bytes.initialize(repeating: 0, count: capacity)
        built.unclassedCounts.initialize(repeating: 0, count: bucketNames.count)
        built.unclassedBytes.initialize(repeating: 0, count: bucketNames.count)
        defer {
            built.keys.deallocate(); built.counts.deallocate(); built.bytes.deallocate()
            built.unclassedCounts.deallocate(); built.unclassedBytes.deallocate()
        }
        // Raw pointers, never `AnyClass` values: Swift retains those, and some root classes (__NSGenericDeallocHandler)
        // abort on any message.
        let keys = UnsafeRawPointer(classList).assumingMemoryBound(to: UInt.self)
        for index in 0..<Int(classCount) { built.insert(keys[index]) }

        var zoneAddresses: UnsafeMutablePointer<vm_address_t>?
        var zoneCount: UInt32 = 0
        guard malloc_get_all_zones(mach_task_self_, censusRead, &zoneAddresses, &zoneCount) == KERN_SUCCESS, let zoneAddresses else {
            return Result()
        }
        let zones = (0..<Int(zoneCount)).compactMap { UnsafeMutablePointer<malloc_zone_t>(bitPattern: zoneAddresses[$0]) }
        tables = built
        // No thread is suspended and no zone locked: a thread suspended while it held a malloc lock, or this one
        // allocating while it held the zones' (fork) lock, aborted the process (_os_unfair_lock_recursive_abort under
        // _xzm_fork_lock_wait, the sandbox's soak, 11-01). The others keep running, so a block may come or go while it's
        // counted: a census is a close count, not an exact one.
        for zone in zones {
            _ = zone.pointee.introspect?.pointee.enumerator?(mach_task_self_, nil, UInt32(MALLOC_PTR_IN_USE_RANGE_TYPE),
                                                            vm_address_t(UInt(bitPattern: zone)), censusRead, censusRecord)
        }
        guard let counted = tables else { return Result() }
        tables = nil

        var result = Result()
        result.total = Count(blocks: counted.totalBlocks, bytes: counted.totalBytes)
        for index in 0..<capacity where counted.counts[index] > 0 {
            let name = UnsafeRawPointer(bitPattern: counted.keys[index]).map { String(cString: rawClassName($0)) } ?? "?"
            result.classes[name, default: Count()].blocks += counted.counts[index]
            result.classes[name, default: Count()].bytes += counted.bytes[index]
        }
        for index in 0..<bucketNames.count where counted.unclassedCounts[index] > 0 {
            result.unclassed[bucketNames[index]] = Count(blocks: counted.unclassedCounts[index], bytes: counted.unclassedBytes[index])
        }
        return result
    }
}

/// `class_getName` on a class pointer, without Swift retaining the class (see `take`).
private let rawClassName = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "class_getName"),
                                         to: (@convention(c) (UnsafeRawPointer) -> UnsafePointer<CChar>).self)

/// The zones' memory is this process's own: an address is its pointer.
private func censusRead(_ task: task_t, _ address: vm_address_t, _ size: vm_size_t, _ pointer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> kern_return_t {
    pointer?.pointee = UnsafeMutableRawPointer(bitPattern: address)
    return KERN_SUCCESS
}

/// Counts a zone's live blocks into `HeapCensus.tables`, allocating nothing (the zones are locked).
private func censusRecord(_ task: task_t, _ context: UnsafeMutableRawPointer?, _ type: UInt32, _ ranges: UnsafeMutablePointer<vm_range_t>?, _ count: UInt32) {
    guard let ranges, var tables = HeapCensus.tables else { return }
    for index in 0..<Int(count) {
        let range = ranges[index]
        let size = Int(range.size)
        tables.totalBlocks += 1
        tables.totalBytes += size
        if size >= MemoryLayout<UInt>.size, size <= HeapCensus.classedUpTo, let first = UnsafePointer<UInt>(bitPattern: UInt(range.address)),
           let slot = tables.slot(first.pointee & tables.mask) {
            tables.counts[slot] += 1
            tables.bytes[slot] += size
        } else {
            let bucket = HeapCensus.bucket(size)
            tables.unclassedCounts[bucket] += 1
            tables.unclassedBytes[bucket] += size
        }
    }
    HeapCensus.tables = tables
}
