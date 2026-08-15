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

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
