import CoreGraphics
import Foundation

/// The machine the numbers came from, and the two conditions that make a
/// reading inadmissible whatever the app did.
///
/// Thermal pressure is the one that ruins a long comparison quietly: once the
/// package is hot the kernel lowers the ceiling, and every subject measured
/// after that point is slower than the ones measured before it. Publishing a
/// benchmark without recording it means publishing the order the runs happened
/// in.
enum Environment {
    struct Passport: Encodable {
        var model: String
        var chip: String
        var cores: Int
        var memoryGB: Int
        var system: String
        var onBattery: Bool
    }

    static func passport() -> Passport {
        let info = ProcessInfo.processInfo
        return Passport(
            model: sysctl("hw.model"),
            chip: sysctl("machdep.cpu.brand_string"),
            cores: info.activeProcessorCount,
            memoryGB: Int(info.physicalMemory / 1_073_741_824),
            system: info.operatingSystemVersionString,
            onBattery: isOnBattery()
        )
    }

    /// The kernel's current ceiling, as a percentage. Below 100 the machine is
    /// throttling and no timing taken during it is comparable.
    static func cpuSpeedLimit() -> Int {
        let output = Shell.run("/usr/bin/pmset", ["-g", "therm"]).output
        for line in output.split(separator: "\n") where line.contains("CPU_Speed_Limit") {
            if let value = line.split(separator: "=").last,
                let number = Int(value.trimmingCharacters(in: .whitespaces))
            {
                return number
            }
        }
        return 100
    }

    static func thermalIsNominal() -> Bool {
        ProcessInfo.processInfo.thermalState == .nominal
    }

    /// Running on battery lets macOS trade performance for charge, which shows
    /// up as a slower subject rather than as a warning.
    static func isOnBattery() -> Bool {
        !Shell.run("/usr/bin/pmset", ["-g", "ps"]).output.contains("AC Power")
    }

    /// What fraction of this machine is busy when nothing is being asked of it.
    ///
    /// Not a constant, and not small. This desk rests at 13–17% of capacity
    /// with only a chat window and a messenger open, so a noise guard that
    /// refuses a run above a fixed 15% refuses nearly every run for the
    /// machine's ordinary background — which is how an hour of measurement
    /// produced three usable readings. What matters is the rise above resting,
    /// so resting is measured rather than assumed.
    static func restingLoadShare(seconds: Double = 3) -> Double {
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let before = SystemCpu.busySeconds()
        let start = Date()
        Thread.sleep(forTimeInterval: seconds)
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0, cores > 0 else { return 0 }
        return max(0, (SystemCpu.busySeconds() - before) / (elapsed * cores))
    }

    /// A locked screen draws nothing at all.
    ///
    /// Every window is occluded then, so no subject ever lays its document out
    /// and every probe runs to its timeout. From inside a run this is
    /// indistinguishable from an application that cannot open the file, and it
    /// is how an hour of measurements turns into an hour of zeroes — so it is
    /// asked about by name rather than inferred from the wreckage.
    static func screenIsLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        return session["CGSSessionScreenIsLocked"] as? Int == 1
    }

    /// Block until someone unlocks the machine, saying so once a minute.
    static func waitForUnlockedScreen() {
        guard screenIsLocked() else { return }
        FileHandle.standardError.write(
            Data("the screen is locked — nothing is drawn while it is, waiting…\n".utf8))
        var announced = Date()
        while screenIsLocked() {
            Thread.sleep(forTimeInterval: 5)
            if Date().timeIntervalSince(announced) >= 60 {
                announced = Date()
                FileHandle.standardError.write(Data("still waiting for the screen…\n".utf8))
            }
        }
        // The desk takes a moment to come back; measuring into that is measuring
        // the wallpaper being redrawn.
        Thread.sleep(forTimeInterval: 5)
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
