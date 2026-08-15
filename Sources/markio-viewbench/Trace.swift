import Foundation

/// Per-sample output, off unless `MARKIO_VIEWBENCH_TRACE` is set.
///
/// A run that never ends looks identical to a slow app from the outside, and
/// the difference is always in which processes the harness decided were the
/// subject's. Printing the set alongside the utilisation is what separates
/// "this viewer is still working" from "the harness is watching the wrong
/// process".
enum Trace {
    private static let enabled =
        ProcessInfo.processInfo.environment["MARKIO_VIEWBENCH_TRACE"] != nil

    static func sample(at seconds: Double, utilisation: Double, footprint: Int, pids: Set<pid_t>) {
        guard enabled else { return }
        let names = pids.sorted().map { pid in
            "\(pid):" + ((ProcessTree.path(of: pid) as NSString?)?.lastPathComponent ?? "gone")
        }
        FileHandle.standardError.write(
            Data(
                String(
                    format: "    t=%6.2f  util=%5.2f  %5.0f MB  %@\n",
                    seconds, utilisation, Double(footprint) / 1_048_576,
                    names.joined(separator: " ")
                ).utf8))
    }
}
