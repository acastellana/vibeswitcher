import Foundation
import Testing
@testable import VibePlatform

/// The machine's own readings, each within what any machine can say, and on Linux the readers of /proc's text on
/// text of a known shape.
struct HostTests {
    @Test func volumeFreeOfTheScratchFolderIsPositive() throws {
        let folder = try TestScriptLinuxTests.scratch("host")
        defer { try? FileManager.default.removeItem(at: folder) }
        let free = try #require(Platform.Host.volumeFree(at: folder.path))
        #expect(free > 0)
        // Free to this user is never more than the volume holds.
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
        let size = try #require((attributes[.systemSize] as? NSNumber)?.int64Value)
        #expect(free <= size)
        #expect(Platform.Host.volumeFree(at: folder.appendingPathComponent("not-there").path) == nil)
    }

    @Test func descriptorLimitIsAtLeast256() {
        #expect(Platform.Host.descriptorLimit() >= 256)
    }

    /// It is the limit on open files, not on something else: the soft limit `getrlimit` gives for them (on the Mac
    /// never more, the kernel's own cap being under it at times). Read, not changed: the limit is the whole test
    /// run's.
    @Test func descriptorLimitIsTheSoftLimitOnOpenFiles() throws {
        var limit = rlimit()
        #if canImport(Glibc)
        let resource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
        #else
        let resource = RLIMIT_NOFILE
        #endif
        try #require(getrlimit(resource, &limit) == 0)
        let said = Platform.Host.descriptorLimit()
        #if os(Linux)
        #expect(UInt64(said) == UInt64(limit.rlim_cur))
        #else
        #expect(UInt64(said) <= UInt64(limit.rlim_cur))
        #endif
    }

    @Test func swapUsageIsNilOrUsedNotOverTotal() {
        if let swap = Platform.Host.swapUsage() { #expect(swap.used <= swap.total) }
    }

    @Test func memoryPressureIsNilOrOneTwoOrFour() {
        if let level = Platform.Host.memoryPressureLevel() { #expect([1, 2, 4].contains(level)) }
    }

    @Test func memoryFreeIsNilOrAPercentage() {
        if let free = Platform.Host.memoryFreePercent() { #expect((0...100).contains(free)) }
    }

    @Test func swapOutsNeverGoBack() {
        guard let first = Platform.Host.swapOuts() else { return }
        let second = Platform.Host.swapOuts()
        #expect(second != nil)
        #expect((second ?? 0) >= first)
    }

    #if os(Linux)
    // MARK: /proc's text

    /// A /proc/meminfo, cut to the lines read and some that begin or end like them.
    static let meminfo = """
        MemTotal:       98500052 kB
        MemFree:        95560324 kB
        MemAvailable:   74300000 kB
        Buffers:           61816 kB
        Cached:           716400 kB
        SwapCached:         9000 kB
        Active:           513484 kB
        SwapTotal:      25165824 kB
        SwapFree:       20971520 kB
        Dirty:               176 kB
        HugePages_Total:       3
        Hugepagesize:       2048 kB

        """

    @Test func meminfoGivesTheFreeShareAndTheSwap() throws {
        #expect(Platform.Host.freePercent(meminfo: Self.meminfo) == 75)
        let swap = try #require(Platform.Host.swap(meminfo: Self.meminfo))
        #expect(swap.total == 25_165_824 * 1024)
        #expect(swap.used == (25_165_824 - 20_971_520) * 1024)
        // The field asked for, not one that begins or ends like it; a count has no unit.
        #expect(Platform.Host.bytes("MemFree", meminfo: Self.meminfo) == 95_560_324 * 1024)
        #expect(Platform.Host.bytes("Cached", meminfo: Self.meminfo) == 716_400 * 1024)
        #expect(Platform.Host.bytes("HugePages_Total", meminfo: Self.meminfo) == 3)
        #expect(Platform.Host.bytes("Mem", meminfo: Self.meminfo) == nil)
    }

    @Test func aMachineWithNoSwapSaysZeroOfZero() throws {
        let none = Self.meminfo.replacingOccurrences(of: "SwapTotal:      25165824 kB", with: "SwapTotal:             0 kB")
            .replacingOccurrences(of: "SwapFree:       20971520 kB", with: "SwapFree:              0 kB")
        let swap = try #require(Platform.Host.swap(meminfo: none))
        #expect(swap.used == 0 && swap.total == 0)
        #expect(Platform.Host.freePercent(meminfo: none) == 75)
    }

    @Test func aMeminfoWithoutTheLinesSaysNil() {
        let lines = Self.meminfo.split(separator: "\n")
        func without(_ field: String) -> String { lines.filter { !$0.hasPrefix(field + ":") }.joined(separator: "\n") }
        #expect(Platform.Host.swap(meminfo: without("SwapTotal")) == nil)
        #expect(Platform.Host.swap(meminfo: without("SwapFree")) == nil)
        // Before Linux 3.14 there is no MemAvailable.
        #expect(Platform.Host.freePercent(meminfo: without("MemAvailable")) == nil)
        #expect(Platform.Host.freePercent(meminfo: without("MemTotal")) == nil)
        #expect(Platform.Host.freePercent(meminfo: "MemTotal: 0 kB\nMemAvailable: 0 kB\n") == nil)
        #expect(Platform.Host.freePercent(meminfo: "") == nil)
        #expect(Platform.Host.swap(meminfo: "SwapTotal: many kB\nSwapFree: 0 kB\n") == nil)
        // More free than there is (never seen) is all of it free, not a number below zero.
        #expect(Platform.Host.swap(meminfo: "SwapTotal: 10 kB\nSwapFree: 12 kB\n")?.used == 0)
        #expect(Platform.Host.freePercent(meminfo: "MemTotal: 10 kB\nMemAvailable: 12 kB\n") == 100)
    }

    @Test func vmstatGivesThePagesSwappedOut() {
        let vmstat = """
            nr_free_pages 23890081
            pgpgout 1204536
            pswpin 17
            pswpout 4821
            pswpout_extra 9
            pgalloc_dma 0

            """
        #expect(Platform.Host.swapOuts(vmstat: vmstat) == 4821)
        #expect(Platform.Host.swapOuts(vmstat: "pswpin 17\npgpgout 1204536\n") == nil)
        #expect(Platform.Host.swapOuts(vmstat: "") == nil)
    }

    static func pressure(some: String, full: String) -> String {
        "some avg10=\(some) avg60=3.20 avg300=1.10 total=123456\nfull avg10=\(full) avg60=0.90 avg300=0.30 total=23456\n"
    }

    /// Normal, warning and critical, each side of its threshold: a tenth of the last ten seconds.
    @Test func pressureIsOneTwoOrFourByTheLastTenSeconds() {
        #expect(Platform.Host.pressureLevel(pressure: Self.pressure(some: "0.00", full: "0.00")) == 1)
        #expect(Platform.Host.pressureLevel(pressure: Self.pressure(some: "9.99", full: "0.00")) == 1)
        #expect(Platform.Host.pressureLevel(pressure: Self.pressure(some: "10.00", full: "0.00")) == 2)
        #expect(Platform.Host.pressureLevel(pressure: Self.pressure(some: "64.31", full: "9.99")) == 2)
        #expect(Platform.Host.pressureLevel(pressure: Self.pressure(some: "64.31", full: "10.00")) == 4)
        #expect(Platform.Host.pressureLevel(pressure: Self.pressure(some: "100.00", full: "97.20")) == 4)
        // The ten-second share decides, not the longer ones beside it.
        #expect(Platform.Host.pressureLevel(pressure: "some avg10=0.00 avg60=80.00 avg300=90.00 total=9\nfull avg10=0.00 avg60=70.00 avg300=80.00 total=8\n") == 1)
    }

    @Test func aPressureFileOfAnotherShapeSaysNil() {
        // Only "some", as the kernel's file for the CPU was before Linux 5.13: that line decides.
        #expect(Platform.Host.pressureLevel(pressure: "some avg10=12.00 avg60=0.00 avg300=0.00 total=5\n") == 2)
        #expect(Platform.Host.pressureLevel(pressure: "") == nil)
        #expect(Platform.Host.pressureLevel(pressure: "full avg10=50.00 avg60=0.00 avg300=0.00 total=5\n") == nil)
        #expect(Platform.Host.pressureLevel(pressure: "some avg60=1.00 total=5\n") == nil)
        #expect(Platform.Host.pressureLevel(pressure: "some avg10=much avg60=1.00 total=5\n") == nil)
    }

    /// The readings come from this machine's /proc: what the file says now is what the function says, give or take
    /// what moved between the two reads.
    @Test func theReadingsAreThisMachinesProc() throws {
        let meminfo = try #require(Platform.Host.text(of: "/proc/meminfo"))
        #expect(meminfo.contains("MemTotal:"))
        let free = try #require(Platform.Host.memoryFreePercent())
        let fromText = try #require(Platform.Host.freePercent(meminfo: meminfo))
        #expect(abs(free - fromText) <= 20)
        #expect(Platform.Host.swapUsage()?.total == Platform.Host.swap(meminfo: meminfo)?.total)
        #expect(Platform.Host.swapOuts() != nil)
        #expect(Platform.Host.text(of: "/proc/no-such-file") == nil)
        // A machine without pressure stall information (this one, under WSL2) says nil; one with it, a level.
        #expect((Platform.Host.memoryPressureLevel() == nil) == (Platform.Host.text(of: "/proc/pressure/memory") == nil))
    }
    #endif
}
