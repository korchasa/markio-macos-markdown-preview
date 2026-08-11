import Darwin
import Foundation

/// Wall-clock timing and resident-memory sampling for the benchmark harness.
///
/// Peak footprint is read from the kernel rather than inferred from allocation
/// counts: the claim Markio makes is about the memory a user's machine
/// actually gives up, and only `task_info` knows that number.
enum Measure {
    /// Seconds spent in `body`, taken from the monotonic clock so a clock
    /// adjustment mid-run cannot produce a negative duration.
    static func time<T>(_ body: () throws -> T) rethrows -> (value: T, seconds: Double) {
        var start = timespec()
        var end = timespec()
        clock_gettime(CLOCK_MONOTONIC, &start)
        let value = try body()
        clock_gettime(CLOCK_MONOTONIC, &end)
        let seconds =
            Double(end.tv_sec - start.tv_sec) + Double(end.tv_nsec - start.tv_nsec) / 1e9
        return (value, seconds)
    }

    /// Current resident size in bytes.
    static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    /// Highest resident size the process has reached.
    static func peakResidentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size_max) : 0
    }

    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1_000)
    }

    static func throughput(bytes: Int, seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        return String(format: "%.0f MB/s", Double(bytes) / 1_048_576 / seconds)
    }
}
