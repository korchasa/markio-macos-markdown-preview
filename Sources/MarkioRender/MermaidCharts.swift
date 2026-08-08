import Foundation

/// A user journey: sections of tasks, each scored from one to five and done by
/// somebody.
struct UserJourney {
    struct Task {
        var name: String
        var score: Int
        var actors: [String]
        var section: Int?
    }

    var title: String
    var sections: [String]
    var tasks: [Task]

    static func parse(_ lines: [Substring]) -> UserJourney? {
        var journey = UserJourney(title: "", sections: [], tasks: [])
        var section: Int?
        for line in lines {
            guard line != "section", line != "title" else { return nil }
            if line.hasPrefix("title ") {
                journey.title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("section ") {
                let name = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                journey.sections.append(name)
                section = journey.sections.count - 1
                continue
            }
            // `Make tea: 5: Me, Cat`
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, !parts[0].isEmpty, let score = Int(parts[1]),
                (1...5).contains(score)
            else { return nil }
            let actors = parts[2].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            journey.tasks.append(
                Task(name: parts[0], score: score, actors: actors, section: section))
        }
        guard !journey.tasks.isEmpty else { return nil }
        return journey
    }
}

/// A Gantt chart: sections of tasks, each occupying a stretch of days.
///
/// Time is counted in days from the earliest start, so nothing here has to know
/// about calendars beyond turning `YYYY-MM-DD` into a day number and back.
struct GanttChart {
    struct Task {
        var name: String
        var section: Int?
        /// Days from the chart's own zero.
        var start: Double
        var length: Double
        var done: Bool
        var active: Bool
        var critical: Bool
        var milestone: Bool
    }

    var title: String
    var sections: [String]
    var tasks: [Task]
    /// The day number the chart starts on, so the axis can print real dates.
    /// Nil when the chart named no date at all and the axis can only count days.
    var origin: Int?

    static func parse(_ lines: [Substring]) -> GanttChart? {
        var chart = GanttChart(title: "", sections: [], tasks: [], origin: nil)
        var section: Int?
        // Where each named task ends, so `after id` can be resolved as it is read.
        var ends: [String: Double] = [:]
        var starts: [String: Double] = [:]
        var previousEnd: Double = 0
        /// Whether any real date was written down. Without one the numbers are
        /// days from the first task and the axis must say so.
        var dated = false
        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            switch word {
            case "title":
                guard !rest.isEmpty else { return nil }
                chart.title = rest
                continue
            case "dateFormat":
                // Only the default is understood, and a chart written in another
                // format would be drawn on the wrong days.
                guard rest == "YYYY-MM-DD" else { return nil }
                continue
            case "section":
                guard !rest.isEmpty else { return nil }
                chart.sections.append(rest)
                section = chart.sections.count - 1
                continue
            case "excludes", "includes", "weekday", "todayMarker", "axisFormat", "tickInterval",
                "displayMode", "inclusiveEndDates", "click":
                // `excludes weekends` moves every bar after it, so ignoring it
                // would draw days the author did not ask for.
                return nil
            default:
                break
            }
            guard let colon = line.lastIndex(of: ":") else { return nil }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            var fields = line[line.index(after: colon)...]
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard !name.isEmpty, !fields.isEmpty else { return nil }

            var task = Task(
                name: name, section: section, start: 0, length: 1, done: false, active: false,
                critical: false, milestone: false)
            while let first = fields.first {
                switch first {
                case "done": task.done = true
                case "active": task.active = true
                case "crit": task.critical = true
                case "milestone": task.milestone = true
                default: break
                }
                guard ["done", "active", "crit", "milestone"].contains(first) else { break }
                fields.removeFirst()
            }
            // What is left is `[id,] [start,] end`, longest first.
            guard (1...3).contains(fields.count) else { return nil }
            var identifier: String?
            if fields.count == 3 { identifier = fields.removeFirst() }
            // With two fields left the first is a start when it reads as one and
            // the task's own name when it does not — `:a1, 3d` names a task the
            // lines below it can point at, `:2026-01-01, 3d` dates it.
            if fields.count == 2 {
                if let start = moment(fields[0], ends: ends, starts: starts) {
                    dated = dated || day(fields[0]) != nil
                    task.start = start
                } else {
                    identifier = fields.removeFirst()
                    task.start = previousEnd
                }
            } else {
                task.start = previousEnd
            }
            guard let last = fields.last else { return nil }
            if let span = span(last) {
                task.length = span
            } else if let end = moment(last, ends: ends, starts: starts) {
                dated = dated || day(last) != nil
                task.length = end - task.start
            } else {
                return nil
            }
            guard task.length >= 0 else { return nil }
            if task.milestone { task.length = 0 }
            previousEnd = task.start + task.length
            if let identifier {
                guard !identifier.isEmpty, !identifier.contains(" ") else { return nil }
                starts[identifier] = task.start
                ends[identifier] = previousEnd
            }
            chart.tasks.append(task)
        }
        guard !chart.tasks.isEmpty else { return nil }
        // Everything was counted from the first real date; shift it all so the
        // chart starts at zero and the axis knows which day that was.
        let earliest = chart.tasks.map(\.start).min() ?? 0
        if dated {
            chart.origin = Int(earliest.rounded(.down))
            for index in chart.tasks.indices { chart.tasks[index].start -= earliest.rounded(.down) }
        }
        return chart
    }

    /// `2014-01-01`, `after a1`, `until a1`.
    private static func moment(
        _ text: String, ends: [String: Double], starts: [String: Double]
    ) -> Double? {
        if text.hasPrefix("after ") {
            let names = text.dropFirst(6).split(separator: " ").map(String.init)
            let known = names.compactMap { ends[$0] }
            guard known.count == names.count, let latest = known.max() else { return nil }
            return latest
        }
        if text.hasPrefix("until ") {
            let names = text.dropFirst(6).split(separator: " ").map(String.init)
            let known = names.compactMap { starts[$0] }
            guard known.count == names.count, let earliest = known.min() else { return nil }
            return earliest
        }
        return day(text).map(Double.init)
    }

    /// `30d`, `2w`, `12h`.
    private static func span(_ text: String) -> Double? {
        guard let unit = text.last, let number = Double(text.dropLast()) else { return nil }
        switch unit {
        case "d": return number
        case "w": return number * 7
        case "h": return number / 24
        default: return nil
        }
    }

    /// A day number for `YYYY-MM-DD`, counted from the same zero for every date,
    /// which is all a bar needs — the calendar itself never appears.
    static func day(_ text: String) -> Int? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
            let dayOfMonth = Int(parts[2]), (1...12).contains(month), (1...31).contains(dayOfMonth)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: "UTC") else { return nil }
        calendar.timeZone = zone
        guard let date = calendar.date(from: components) else { return nil }
        return Int((date.timeIntervalSince1970 / 86400).rounded())
    }

    /// The other way round, for the axis.
    static func date(_ day: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let date = Date(timeIntervalSince1970: Double(day) * 86400)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d-%02d", parts.month ?? 1, parts.day ?? 1)
    }
}
