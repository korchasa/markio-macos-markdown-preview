import Foundation

enum Probe: String, Codable {
    /// Wait until the subject's own processes stop consuming CPU. Measures the
    /// whole cost the document forced on the app, and needs no permission.
    case cpuIdle = "cpu-idle"
    /// Wait until a line from the top of the document appears in the
    /// accessibility tree. Measures what the reader waits for.
    case axReady = "ax-ready"
}

struct RunResult: Encodable {
    var subject: String
    var document: String
    var probe: Probe
    var seconds: Double
    var cpuSeconds: Double
    var peakFootprintBytes: Int
    var settledFootprintBytes: Int
    var baselineFootprintBytes: Int
    var foreignCpuShare: Double
    var cpuSpeedLimit: Int
    var belowFloor: Bool
    /// The document never became readable inside the timeout.
    var didNotFinish: Bool
    var admissible: Bool
    var rejection: String?
}

struct Limits {
    /// Fraction of one core below which the subject counts as done working.
    var idleThreshold = 0.05
    var idleFor = 1.0
    var timeout = 240.0
    var sampleInterval = 0.05
    /// The accessibility walk is far more expensive than a footprint reading —
    /// every node is a round trip to the app — so it runs on its own, slower
    /// clock. This is the granularity of an `ax-ready` result.
    var axPollInterval = 0.1
    var warmupSettle = 30.0
    /// A run is thrown away when this much of the machine went to other work.
    var foreignCpuShare = 0.15
    /// And when less than this much of its window was in sight, since a covered
    /// window is not sent display cycles at all.
    var visibleFraction = 0.2
}

/// The helper processes a web-view app brings up. They are children of launchd
/// rather than of the app, so they can only be found by name.
let helperNames = [
    "com.apple.WebKit.WebContent",
    "com.apple.WebKit.GPU",
    "com.apple.WebKit.Networking",
]

enum Run {
    static func measure(
        subject: Subject,
        document: String,
        warmup: String,
        readyText: String,
        probe: Probe,
        limits: Limits
    ) throws -> RunResult {
        subject.reset()

        // Whatever web-view helpers are already up belong to something else and
        // must not be counted as the subject's.
        let foreign = ProcessTree.helperPids(in: ProcessTree.snapshot(), names: helperNames)

        // A tiny document first, so the cost of launching the app is spent
        // before the clock starts and only the document under test is timed.
        subject.open(document: warmup)
        Thread.sleep(forTimeInterval: 2.0)
        guard let pid = subject.runningPid else {
            throw Failure("\(subject.name) did not launch")
        }
        try subject.verifyLaunchedBundle()

        let tracker = Tracker(
            root: pid, appPath: subject.runPath, helperNames: helperNames, foreign: foreign)
        _ = waitForIdle(
            tracker: tracker, limits: limits, deadline: limits.warmupSettle,
            requireWork: false)

        let baseline = tracker.sample()
        let speedLimitBefore = Environment.cpuSpeedLimit()

        // The window is kept in sight by the probe itself rather than checked
        // before it starts, so the clock runs from the moment the document was
        // opened. Checking first cost the reading its first half-second, which
        // for a fast viewer is most of what there was to measure.
        let sightline = Sightline(subject: subject, pid: pid, threshold: limits.visibleFraction)

        subject.open(document: document)

        let outcome: Outcome
        switch probe {
        case .cpuIdle:
            outcome = waitForIdle(
                tracker: tracker, limits: limits, deadline: limits.timeout, requireWork: true,
                sightline: sightline)
        case .axReady:
            outcome = waitForText(
                readyText, pid: pid, tracker: tracker, limits: limits, sightline: sightline)
        }

        let final = tracker.sample()
        let speedLimitAfter = Environment.cpuSpeedLimit()
        subject.quit()

        let cpuSeconds = final.subject.cpuSeconds - baseline.subject.cpuSeconds
        let machineBusy = final.machineBusySeconds - baseline.machineBusySeconds
        // The harness's own cost is part of the method, not noise from
        // elsewhere, and it is paid identically for every subject. Counting it
        // as foreign load made the `ax-ready` probe — which is the expensive
        // one — reject the very runs it had just taken.
        let harness = final.harnessCpuSeconds - baseline.harnessCpuSeconds
        // A run that finished below the floor still occupied the give-up
        // window, and that window is what the noise guard has to divide by.
        let observed = outcome.belowFloor ? 5.0 : outcome.seconds
        let capacity = observed * Double(ProcessInfo.processInfo.activeProcessorCount)
        let foreignShare = capacity > 0 ? max(0, machineBusy - cpuSeconds - harness) / capacity : 0
        let speedLimit = min(speedLimitBefore, speedLimitAfter)

        // A probe that never fires is a fact about the app, not a spoiled run:
        // the document did not become readable in the time allowed. Counting it
        // as a rejection would drop the worst result an app can produce and
        // report the rest as if that had never happened.
        var rejection: String?
        if let buried = outcome.buried {
            // Read before the timeout is interpreted: a window nothing can see
            // is not asked to draw, so calling that document unreadable would
            // blame the app for the arrangement of windows on the desk.
            rejection = buried
        } else if outcome.timedOut {
            rejection = nil
        } else if observed < 1.0 {
            // Below a second there is nothing to judge: the kernel keeps its
            // CPU totals in hundredths, so a tenth-of-a-second window turns any
            // passing system activity into most of the machine. A run this
            // short was not slowed by anything.
            rejection = nil
        } else if foreignShare > limits.foreignCpuShare {
            rejection = String(
                format: "the machine was busy with other work (%.0f%% of capacity)",
                foreignShare * 100)
        } else if speedLimit < 100 {
            rejection = "the machine was throttling (CPU_Speed_Limit \(speedLimit))"
        }

        return RunResult(
            subject: subject.name,
            document: (document as NSString).lastPathComponent,
            probe: probe,
            seconds: outcome.seconds,
            cpuSeconds: cpuSeconds,
            peakFootprintBytes: outcome.peakFootprint,
            settledFootprintBytes: final.subject.footprintBytes,
            baselineFootprintBytes: baseline.subject.footprintBytes,
            foreignCpuShare: foreignShare,
            cpuSpeedLimit: speedLimit,
            belowFloor: outcome.belowFloor,
            didNotFinish: outcome.timedOut,
            admissible: rejection == nil,
            rejection: rejection
        )
    }

    private struct Outcome {
        var seconds: Double
        var peakFootprint: Int
        var timedOut: Bool
        /// The subject never rose above the idle threshold at all. The document
        /// cost it less than this probe can see — which is an answer, but not a
        /// duration, and reporting the give-up window as one would say the app
        /// took five seconds when it took none.
        var belowFloor = false
        /// The window was never in sight, so nothing was ever drawn in it.
        var buried: String?
    }

    /// Sample the subject until it stops working.
    ///
    /// `requireWork` matters: `open` returns before the app has picked the file
    /// up, so without waiting for activity to rise first, an app that takes a
    /// moment to start reads as instant.
    private static func waitForIdle(
        tracker: Tracker, limits: Limits, deadline: Double, requireWork: Bool,
        sightline: Sightline? = nil
    ) -> Outcome {
        let start = Date()
        var peak = 0
        var quietSince: Date?
        var previous: (cpu: Double, at: Date)?
        var working = !requireWork

        while Date().timeIntervalSince(start) < deadline {
            if let rejection = sightline?.check(elapsed: Date().timeIntervalSince(start)) {
                return Outcome(
                    seconds: 0, peakFootprint: peak, timedOut: false, buried: rejection)
            }
            let sample = tracker.sample()
            peak = max(peak, sample.subject.footprintBytes)
            let now = Date()

            if let last = previous {
                let elapsed = now.timeIntervalSince(last.at)
                let utilisation = elapsed > 0 ? (sample.subject.cpuSeconds - last.cpu) / elapsed : 0
                Trace.sample(
                    at: now.timeIntervalSince(start), utilisation: utilisation,
                    footprint: sample.subject.footprintBytes, pids: tracker.pids)
                if !working {
                    if utilisation >= limits.idleThreshold {
                        working = true
                    } else if now.timeIntervalSince(start) > 5 {
                        return Outcome(
                            seconds: 0, peakFootprint: peak, timedOut: false, belowFloor: true)
                    }
                } else if utilisation < limits.idleThreshold {
                    if let quiet = quietSince {
                        if now.timeIntervalSince(quiet) >= limits.idleFor {
                            return Outcome(
                                seconds: quiet.timeIntervalSince(start), peakFootprint: peak,
                                timedOut: false)
                        }
                    } else {
                        quietSince = now
                    }
                } else {
                    quietSince = nil
                }
            }
            previous = (sample.subject.cpuSeconds, now)
            Thread.sleep(forTimeInterval: limits.sampleInterval)
        }
        return Outcome(seconds: deadline, peakFootprint: peak, timedOut: true)
    }

    private static func waitForText(
        _ needle: String, pid: pid_t, tracker: Tracker, limits: Limits,
        sightline: Sightline? = nil
    ) -> Outcome {
        let start = Date()
        var peak = 0
        var lastPoll = Date.distantPast
        while Date().timeIntervalSince(start) < limits.timeout {
            if let rejection = sightline?.check(elapsed: Date().timeIntervalSince(start)) {
                return Outcome(
                    seconds: 0, peakFootprint: peak, timedOut: false, buried: rejection)
            }
            peak = max(peak, tracker.sample().subject.footprintBytes)
            let now = Date()
            if now.timeIntervalSince(lastPoll) >= limits.axPollInterval {
                lastPoll = now
                if Readiness.showsText(needle, pid: pid) {
                    return Outcome(
                        seconds: Date().timeIntervalSince(start), peakFootprint: peak,
                        timedOut: false)
                }
            }
            Thread.sleep(forTimeInterval: limits.sampleInterval)
        }
        return Outcome(seconds: limits.timeout, peakFootprint: peak, timedOut: true)
    }
}
