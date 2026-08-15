import AppKit
import Foundation

/// One app under measurement, and the state it has to be put in first.
///
/// Every control here exists because leaving it out biases a comparison:
///
/// - A viewer that restores the previous session opens the documents of the
///   run before as well, and the reading is then of twenty documents, not one.
///   Markio does this deliberately. Nothing on disk shows the restored set, so
///   the only reliable defence is a copy of the bundle under a fresh bundle
///   identifier, which the system has never seen and has nothing to restore.
///   That rewrite invalidates a code signature, so it is applied only to
///   unsigned bundles and the report says which subjects got it.
/// - A window that is not frontmost is throttled by App Nap, so a subject
///   measured in the background loses for a reason that has nothing to do with
///   how it renders. The subject is not activated to avoid that — an hour of
///   runs seizing the keyboard makes the machine unusable — so App Nap is
///   switched off per subject instead, and what activation cannot be replaced
///   by is caught afterwards by measuring how much of the window was in sight.
struct Subject {
    let name: String
    let originalPath: String
    var runPath: String
    let bundleId: String
    let isolatedByBundleId: Bool
    let version: String

    static func prepare(name: String, appPath: String, stagingDirectory: String) throws -> Subject {
        let plist = try readInfoPlist(appPath: appPath)
        let originalBundleId = plist["CFBundleIdentifier"] as? String ?? ""
        let version = [
            plist["CFBundleShortVersionString"] as? String,
            plist["CFBundleVersion"].map { "(\($0))" },
        ].compactMap { $0 }.joined(separator: " ")

        guard !originalBundleId.isEmpty else {
            throw Failure("\(name): the bundle at \(appPath) has no CFBundleIdentifier")
        }

        guard isRewritable(appPath: appPath) else {
            return Subject(
                name: name,
                originalPath: appPath,
                runPath: appPath,
                bundleId: originalBundleId,
                isolatedByBundleId: false,
                version: version
            )
        }

        let staged = (stagingDirectory as NSString).appendingPathComponent("\(name).app")
        try? FileManager.default.removeItem(atPath: staged)
        try FileManager.default.createDirectory(
            atPath: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: appPath, toPath: staged)

        let freshId = "\(originalBundleId).viewbench\(Int(Date().timeIntervalSince1970))"
        try rewriteBundleId(appPath: staged, to: freshId)
        // Rewriting Info.plist invalidates even an ad-hoc signature, and macOS
        // refuses to launch a bundle whose seal is broken.
        _ = Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", staged], timeout: 60)

        return Subject(
            name: name,
            originalPath: appPath,
            runPath: staged,
            bundleId: freshId,
            isolatedByBundleId: true,
            version: version
        )
    }

    /// Put the app in the state a run expects: nothing of it running, no saved
    /// window state, and App Nap off.
    func reset() {
        quit()
        let savedState = ("~/Library/Saved Application State/\(bundleId).savedState" as NSString)
            .expandingTildeInPath
        try? FileManager.default.removeItem(atPath: savedState)

        // Written through CFPreferences rather than by shelling out to
        // `defaults`: that command talks to cfprefsd and was seen to sit there
        // indefinitely for a bundle identifier the system had never registered,
        // which is exactly the identifier a staged copy has.
        CFPreferencesSetAppValue(
            "NSAppSleepDisabled" as CFString, kCFBooleanTrue, bundleId as CFString)
        CFPreferencesAppSynchronize(bundleId as CFString)
    }

    func quit() {
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        {
            application.forceTerminate()
        }
        _ = Shell.run("/usr/bin/pkill", ["-f", "\(runPath)/Contents/MacOS/"])
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Open a document without taking the front.
    ///
    /// `-g` is the whole point: an hour of runs that each seize the keyboard
    /// makes the machine unusable while the benchmark is going. What activation
    /// used to buy — a window that keeps drawing — is bought instead by leaving
    /// App Nap off and by refusing any run whose window turned out to be
    /// buried, which `WindowVisibility` decides.
    @discardableResult
    func open(document: String) -> Int32 {
        Shell.run("/usr/bin/open", ["-g", "-a", runPath, document]).status
    }

    var runningPid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?
            .processIdentifier
    }

    /// The bundle the system actually launched.
    ///
    /// `open -a <path>` is a request, not a guarantee: when several copies of
    /// the same identifier are registered, the system may bring a different one
    /// forward. A benchmark that does not check this can measure a completely
    /// different build of the app and report the number as if it were this one.
    func verifyLaunchedBundle() throws {
        guard
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .first
        else {
            throw Failure("\(name) is not running")
        }
        let launched = running.bundleURL?.path ?? "unknown"
        let expected = URL(fileURLWithPath: runPath).standardizedFileURL.path
        guard URL(fileURLWithPath: launched).standardizedFileURL.path == expected else {
            throw Failure(
                "\(name): asked for \(expected) but the system launched \(launched) — "
                    + "another copy of \(bundleId) is registered")
        }
    }

    /// How much of the subject's window is in sight, for the run's validity.
    func visibleFraction() -> Double? {
        guard let pid = runningPid else { return nil }
        return WindowVisibility.visibleFraction(pid: pid)
    }

    private static func readInfoPlist(appPath: String) throws -> [String: Any] {
        let path = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: path),
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else {
            throw Failure("cannot read \(path)")
        }
        return plist
    }

    private static func rewriteBundleId(appPath: String, to identifier: String) throws {
        let path = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        let result = Shell.run(
            "/usr/bin/plutil",
            ["-replace", "CFBundleIdentifier", "-string", identifier, path])
        guard result.status == 0 else {
            throw Failure("cannot set the bundle identifier of \(path)")
        }
    }

    /// Whether the bundle identifier may be rewritten.
    ///
    /// Only a real signature stands in the way: an ad-hoc seal — which is what
    /// a locally built bundle carries — can simply be reapplied afterwards.
    /// Getting this wrong is not a small matter. A bundle left under its own
    /// identifier is opened by whichever copy the system has registered for it,
    /// and this machine has three: the build here, one under the release
    /// tooling and one in /Applications. The first run of this harness measured
    /// the one in /Applications and reported a document that was never opened.
    private static func isRewritable(appPath: String) -> Bool {
        let description = Shell.run("/usr/bin/codesign", ["-dvv", appPath]).output
        return description.contains("Signature=adhoc") || !description.contains("Authority=")
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum Shell {
    /// Run a command and return what it printed.
    ///
    /// Both streams are drained while the child runs and the wait is bounded. A
    /// child that fills a pipe nobody is reading blocks forever, and one that
    /// simply never exits would hang the whole benchmark on a step that is not
    /// even being measured — both have happened here.
    @discardableResult
    static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 20
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        // Both streams are kept: `codesign -dvv` describes a bundle on stderr,
        // and a caller reading only stdout sees nothing and concludes the
        // bundle is unsigned.
        let collected = Collector()
        for pipe in [output, errors] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    collected.append(data)
                }
            }
        }

        do {
            try process.run()
        } catch {
            return (-1, "")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return (-1, collected.text)
        }
        return (process.terminationStatus, collected.text)
    }

    /// Somewhere for the pipe handlers to put what they read.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
