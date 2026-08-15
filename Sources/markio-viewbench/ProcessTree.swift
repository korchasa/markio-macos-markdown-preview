import Darwin
import Foundation

/// What one process costs, read from the kernel.
///
/// `ps` is not used anywhere here. Its `%cpu` is an average over the whole
/// lifetime of the process rather than an instantaneous rate, and its `rss`
/// counts shared pages once per process, so a viewer with three helpers looks
/// far heavier than Activity Monitor says it is. `proc_pid_rusage` answers
/// both questions directly, for any process of the same user, and carries the
/// lifetime peak so a footprint spike between two samples cannot be missed.
struct Usage {
    var cpuSeconds: Double
    var footprintBytes: Int
    var peakFootprintBytes: Int

    static let zero = Usage(cpuSeconds: 0, footprintBytes: 0, peakFootprintBytes: 0)

    static func + (lhs: Usage, rhs: Usage) -> Usage {
        Usage(
            cpuSeconds: lhs.cpuSeconds + rhs.cpuSeconds,
            footprintBytes: lhs.footprintBytes + rhs.footprintBytes,
            peakFootprintBytes: lhs.peakFootprintBytes + rhs.peakFootprintBytes
        )
    }
}

enum ProcessTree {
    /// Every process id in the system.
    static func allPids() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, byteCount)
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(
            decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func usage(of pid: pid_t) -> Usage? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard result == 0 else { return nil }
        return Usage(
            cpuSeconds: Double(info.ri_user_time + info.ri_system_time) / 1e9,
            footprintBytes: Int(info.ri_phys_footprint),
            peakFootprintBytes: Int(info.ri_lifetime_max_phys_footprint)
        )
    }

    /// A snapshot of the whole system: pid to parent, executable path and cost.
    struct Snapshot {
        var parents: [pid_t: pid_t] = [:]
        var paths: [pid_t: String] = [:]
        var usages: [pid_t: Usage] = [:]

        var pids: [pid_t] { Array(usages.keys) }
    }

    static func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        for pid in allPids() {
            guard let usage = usage(of: pid) else { continue }
            snapshot.usages[pid] = usage
            if let parent = parent(of: pid) { snapshot.parents[pid] = parent }
            if let path = path(of: pid) { snapshot.paths[pid] = path }
        }
        return snapshot
    }

    /// The processes doing the subject's work: the app, everything it spawned,
    /// and the helper processes it brought up.
    ///
    /// A web view's content process is started by launchd over XPC, so it is a
    /// child of launchd rather than of the app and cannot be found by walking
    /// parents. It has to be matched by executable name — and then the helpers
    /// that were already running for something else (a browser, Safari, Mail)
    /// have to be subtracted, or the tree never falls idle and every reading is
    /// noise. `foreign` is that subtraction, taken before the subject launches.
    static func subjectPids(
        in snapshot: Snapshot,
        root: pid_t,
        appPath: String,
        helperNames: [String],
        foreign: Set<pid_t>
    ) -> Set<pid_t> {
        var pids: Set<pid_t> = snapshot.usages[root] == nil ? [] : [root]

        var changed = true
        while changed {
            changed = false
            for (pid, parent) in snapshot.parents where pids.contains(parent) && !pids.contains(pid)
            {
                pids.insert(pid)
                changed = true
            }
        }

        for (pid, path) in snapshot.paths where !foreign.contains(pid) {
            if path.hasPrefix(appPath) || helperNames.contains(where: { path.contains($0) }) {
                pids.insert(pid)
            }
        }
        return pids
    }

    static func helperPids(in snapshot: Snapshot, names: [String]) -> Set<pid_t> {
        Set(snapshot.paths.filter { _, path in names.contains(where: { path.contains($0) }) }.keys)
    }

    static func total(of pids: Set<pid_t>, in snapshot: Snapshot) -> Usage {
        pids.reduce(Usage.zero) { running, pid in
            running + (snapshot.usages[pid] ?? .zero)
        }
    }

    static func total(of pids: Set<pid_t>) -> Usage {
        pids.reduce(Usage.zero) { running, pid in
            running + (usage(of: pid) ?? .zero)
        }
    }
}

/// How busy the whole machine is, in one call.
///
/// The obvious way to answer this — add up every process — costs a syscall per
/// process per sample and made the harness the busiest thing on the machine,
/// which is the one bias it cannot have. The kernel already keeps the total.
enum SystemCpu {
    /// Seconds of CPU the machine has spent on work since boot, across all
    /// cores. Only differences between two readings mean anything.
    static func busySeconds() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let ticks = Double(info.cpu_ticks.0) + Double(info.cpu_ticks.1) + Double(info.cpu_ticks.3)
        return ticks / 100
    }
}

/// Follows one subject through a run.
///
/// The set of processes doing its work changes — a web view brings its content
/// process up part way through — but working that set out means reading every
/// process in the system, which is far too expensive to do at sampling rate. So
/// the set is re-derived a few times a second and only the subject's own
/// processes are read on every sample.
final class Tracker {
    private let root: pid_t
    private let appPath: String
    private let helperNames: [String]
    private let foreign: Set<pid_t>
    private let refreshInterval: TimeInterval
    private var lastRefresh = Date.distantPast

    private(set) var pids: Set<pid_t> = []

    init(
        root: pid_t, appPath: String, helperNames: [String], foreign: Set<pid_t>,
        refreshInterval: TimeInterval = 0.5
    ) {
        self.root = root
        self.appPath = appPath
        self.helperNames = helperNames
        self.foreign = foreign
        self.refreshInterval = refreshInterval
        refresh()
    }

    func refresh() {
        pids = ProcessTree.subjectPids(
            in: ProcessTree.snapshot(), root: root, appPath: appPath, helperNames: helperNames,
            foreign: foreign)
        lastRefresh = Date()
    }

    /// The subject's cost right now, plus the machine's, for the noise guard.
    func sample() -> (subject: Usage, machineBusySeconds: Double) {
        let now = Date()
        if now.timeIntervalSince(lastRefresh) >= refreshInterval { refresh() }
        return (ProcessTree.total(of: pids), SystemCpu.busySeconds())
    }
}
