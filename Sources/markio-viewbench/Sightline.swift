import AppKit

/// Keeps the subject's window in sight for as long as it is being measured, and
/// says so when it never got there.
///
/// A covered window is not drawn — AppKit stops sending it display cycles — so
/// a document in one is never laid out and the app reads as unable to open it.
/// The old answer was to activate each subject, which is correct for the
/// measurement and unbearable for whoever is at the machine. This is the other
/// answer: raise the window through accessibility, which does not make the
/// application active, and refuse the run if that did not work.
///
/// The window is raised only until it is seen. After that it is watched but
/// left alone: a benchmark that keeps shoving its windows forward for four
/// minutes is no better than one that steals the keyboard.
final class Sightline {
    private let subject: Subject
    private let pid: pid_t
    private let threshold: Double
    /// How long a window may stay covered after being raised before the run is
    /// refused — enough for the raise to take effect, not enough to spend an
    /// hour rediscovering the same arrangement of windows.
    private let grace: TimeInterval = 3.0
    private var inSight = false
    private var coveredSince: Date?
    private var lastCheck = Date.distantPast

    init(subject: Subject, pid: pid_t, threshold: Double) {
        self.subject = subject
        self.pid = pid
        self.threshold = threshold
    }

    /// Nil while the window is where it should be; a rejection once it is not.
    func check(elapsed: TimeInterval) -> String? {
        let interval = inSight ? 1.0 : 0.5
        guard Date().timeIntervalSince(lastCheck) >= interval else { return nil }
        lastCheck = Date()

        // Asked first, because a locked screen makes every other reading here
        // say the same wrong thing: nothing is drawn, so every window looks
        // hidden and every application looks broken.
        if Environment.screenIsLocked() {
            return "the screen was locked, so nothing was drawn"
        }

        if !inSight { WindowControl.normalize(pid: pid) }

        guard let reading = subject.visibleFraction() else {
            // No window on screen at all. Before the first sighting that is not
            // a hidden window, it is an application still starting, and some
            // take twenty seconds over a large document — refusing here would
            // throw away the slowest and most interesting readings. Absence is
            // judged at the end of the run instead, and a desk with no room to
            // show anything is caught before the benchmark starts.
            return inSight ? "the subject's window left the screen mid-run" : nil
        }

        if reading >= threshold {
            inSight = true
            coveredSince = nil
            return nil
        }
        if inSight {
            return String(
                format: "the subject's window was covered mid-run (%.0f%% of it hidden)",
                (1 - reading) * 100)
        }
        let since = coveredSince ?? Date()
        coveredSince = since
        guard Date().timeIntervalSince(since) >= grace else { return nil }
        return String(
            format: "the subject's window was %.0f%% covered — leave it in sight",
            (1 - reading) * 100)
    }
}
