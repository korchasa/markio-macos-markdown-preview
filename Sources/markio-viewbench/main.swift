import Foundation

/// `markio-viewbench` — what a document costs the Mac apps that open it.
///
/// This is not `markio-bench`. That one measures Markio's own parser in
/// process, with no window and no other app involved. This one drives finished
/// applications, Markio among them, from the outside, so a claim about Markio
/// next to another viewer rests on the same procedure for both.
///
///     markio-viewbench plan.json [out.json]
///
/// The plan names the apps, the documents and how many rounds to run. Every
/// control the procedure depends on is in the code rather than in the operator:
/// subjects are interleaved and shuffled so a machine that drifts drifts across
/// all of them equally, each subject is reset and brought to the front before
/// it is timed, and a run taken while the machine was busy or throttling is
/// rejected instead of averaged in.

struct Plan: Decodable {
    struct SubjectSpec: Decodable {
        var name: String
        var app: String
    }
    struct DocumentSpec: Decodable {
        var name: String
        var path: String
        /// A line from the first screenful, used by the `ax-ready` probe to
        /// tell "the window exists" from "the document is drawn".
        var readyText: String
    }
    var subjects: [SubjectSpec]
    var documents: [DocumentSpec]
    /// A short document opened before each timed one, so that launching the app
    /// is paid for outside the measurement.
    var warmup: String
    var rounds: Int
    var probes: [Probe]
    var cooldownSeconds: Double?
}

struct Statistic: Encodable {
    var subject: String
    var document: String
    var probe: Probe
    var runs: Int
    var rejected: Int
    /// Runs where the document cost the app less work than the probe can see.
    /// They carry no duration, so they are counted rather than averaged in.
    var belowFloor: Int
    var medianSeconds: Double?
    var fastestSeconds: Double?
    var medianCpuMilliseconds: Double?
    var medianPeakFootprintMB: Double?
    var spreadSeconds: Double?
}

struct Report: Encodable {
    var machine: Environment.Passport
    var startedAt: String
    var subjects: [String: String]
    var isolatedByBundleId: [String]
    var statistics: [Statistic]
    var runs: [RunResult]
    var notes: [String]
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

/// Median absolute deviation: how much the runs disagreed. A benchmark that
/// prints one number and not this one is asking to be believed rather than
/// checked.
func spread(_ values: [Double]) -> Double? {
    guard let centre = median(values) else { return nil }
    return median(values.map { abs($0 - centre) })
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let planPath = arguments.first else {
    FileHandle.standardError.write(
        Data("usage: markio-viewbench <plan.json> [out.json]\n".utf8))
    exit(2)
}
// `dump <pid>` prints a running app's accessibility tree, which is the only way
// to tell a probe that cannot see from an app that does not speak.
if planPath == "dump" {
    guard arguments.count > 1, let pid = pid_t(arguments[1]) else {
        FileHandle.standardError.write(Data("usage: markio-viewbench dump <pid>\n".utf8))
        exit(2)
    }
    guard Readiness.isTrusted(prompting: true) else {
        FileHandle.standardError.write(Data("error: needs Accessibility permission\n".utf8))
        exit(1)
    }
    print(Readiness.dump(pid: pid))
    exit(0)
}

let outputPath = arguments.count > 1 ? arguments[1] : "viewbench.json"

let planData: Data
do {
    planData = try Data(contentsOf: URL(fileURLWithPath: planPath))
} catch {
    FileHandle.standardError.write(Data("error: cannot read \(planPath)\n".utf8))
    exit(1)
}
let plan: Plan
do {
    plan = try JSONDecoder().decode(Plan.self, from: planData)
} catch {
    FileHandle.standardError.write(Data("error: \(planPath) is not a valid plan: \(error)\n".utf8))
    exit(1)
}

if plan.probes.contains(.axReady) && !Readiness.isTrusted(prompting: true) {
    FileHandle.standardError.write(
        Data(
            """
            error: the ax-ready probe needs Accessibility permission.
                   Grant it to the terminal running this command in
                   System Settings > Privacy & Security > Accessibility,
                   then run it again.

            """.utf8))
    exit(1)
}

let staging = NSTemporaryDirectory() + "markio-viewbench"
var subjects: [Subject] = []
for spec in plan.subjects {
    do {
        subjects.append(
            try Subject.prepare(name: spec.name, appPath: spec.app, stagingDirectory: staging))
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

var notes: [String] = []
if Environment.isOnBattery() {
    notes.append(
        "The machine was on battery, where macOS may trade speed for charge. Run it on mains.")
}
let signedSubjects = subjects.filter { !$0.isolatedByBundleId }.map(\.name)
if !signedSubjects.isEmpty {
    notes.append(
        "Signed bundles cannot be given a fresh identifier without breaking the signature, so "
            + signedSubjects.joined(separator: ", ")
            + " were isolated by clearing saved application state only. A subject that restores "
            + "its previous session by some other means would carry it into the reading.")
}

let limits = Limits()
let cooldown = plan.cooldownSeconds ?? 3.0
var results: [RunResult] = []

// Interleaved and shuffled: all rounds of one subject in a row would confound
// the subject with whatever the machine was doing at that hour.
for round in 1...max(1, plan.rounds) {
    for document in plan.documents {
        for probe in plan.probes {
            for subject in subjects.shuffled() {
                FileHandle.standardError.write(
                    Data(
                        "round \(round) · \(subject.name) · \(document.name) · \(probe.rawValue)\n"
                            .utf8))
                do {
                    let result = try Run.measure(
                        subject: subject,
                        document: document.path,
                        warmup: plan.warmup,
                        readyText: document.readyText,
                        probe: probe,
                        limits: limits)
                    results.append(result)
                    let verdict = result.admissible ? "ok" : "rejected: \(result.rejection ?? "")"
                    FileHandle.standardError.write(
                        Data(
                            String(
                                format: "    %.2f s wall · %.2f s cpu · %.0f MB peak · %@\n",
                                result.seconds, result.cpuSeconds,
                                Double(result.peakFootprintBytes) / 1_048_576, verdict
                            ).utf8))
                } catch {
                    FileHandle.standardError.write(Data("    failed: \(error)\n".utf8))
                }
                Thread.sleep(forTimeInterval: cooldown)
            }
        }
    }
}

var statistics: [Statistic] = []
for subject in subjects {
    for document in plan.documents {
        for probe in plan.probes {
            let all = results.filter {
                $0.subject == subject.name
                    && $0.document == (document.path as NSString).lastPathComponent
                    && $0.probe == probe
            }
            let good = all.filter(\.admissible)
            let timed = good.filter { !$0.belowFloor }
            let seconds = timed.map(\.seconds)
            statistics.append(
                Statistic(
                    subject: subject.name,
                    document: document.name,
                    probe: probe,
                    runs: good.count,
                    rejected: all.count - good.count,
                    belowFloor: good.count - timed.count,
                    medianSeconds: median(seconds),
                    fastestSeconds: seconds.min(),
                    medianCpuMilliseconds: median(good.map { $0.cpuSeconds * 1000 }),
                    medianPeakFootprintMB: median(
                        good.map { Double($0.peakFootprintBytes) / 1_048_576 }),
                    spreadSeconds: spread(seconds)))
        }
    }
}

let formatter = ISO8601DateFormatter()
let report = Report(
    machine: Environment.passport(),
    startedAt: formatter.string(from: Date()),
    subjects: Dictionary(uniqueKeysWithValues: subjects.map { ($0.name, $0.version) }),
    isolatedByBundleId: subjects.filter(\.isolatedByBundleId).map(\.name),
    statistics: statistics,
    runs: results,
    notes: notes)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
do {
    try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath))
} catch {
    FileHandle.standardError.write(Data("error: cannot write \(outputPath): \(error)\n".utf8))
    exit(1)
}

print("")
for statistic in statistics.sorted(by: { ($0.document, $0.subject) < ($1.document, $1.subject) }) {
    let seconds =
        statistic.medianSeconds.map { String(format: "%7.2f s", $0) }
        ?? (statistic.belowFloor > 0 ? "below floor" : "          —")
    let cpu = statistic.medianCpuMilliseconds.map { String(format: "%8.1f ms", $0) } ?? "       —"
    let peak = statistic.medianPeakFootprintMB.map { String(format: "%5.0f MB", $0) } ?? "      —"
    print(
        "\(statistic.document.padding(toLength: 10, withPad: " ", startingAt: 0)) "
            + "\(statistic.subject.padding(toLength: 12, withPad: " ", startingAt: 0)) "
            + "\(statistic.probe.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) "
            + "median \(seconds)  cpu \(cpu)  peak \(peak)  "
            + "n=\(statistic.runs) rejected=\(statistic.rejected)")
}
for note in notes { print("\nnote: \(note)") }
print("\nwritten to \(outputPath)")
