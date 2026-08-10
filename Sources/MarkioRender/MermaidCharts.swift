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
            // `Make tea: 5` is a step nobody was named for, which Mermaid puts
            // on the line with no faces beside it. A score outside the scale is
            // kept as written and drawn on the nearest line.
            guard (2...3).contains(parts.count), !parts[0].isEmpty, let score = Int(parts[1])
            else { return nil }
            let actors = (parts.count == 3 ? parts[2] : "").split(separator: ",")
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
        /// `vert`: not a row of its own but a heavy rule across the whole
        /// chart, named under the axis. It marks a moment everything else is
        /// read against.
        var vertical = false
    }

    var title: String
    var sections: [String]
    var tasks: [Task]
    /// The day the chart starts on, so the axis can print real dates. A chart
    /// told in hours starts part way through a day, so this is a fraction as
    /// well. Nil when the chart named no date at all and the axis can only
    /// count days.
    var origin: Double?
    /// The days a task's length skips, counted from the chart's own zero. They
    /// are shaded, because a bar that spans them is longer than its `3d` says.
    var excluded: Set<Int> = []
    /// How the axis writes a date, in the same `%Y-%m-%d` a chart writes.
    var axisFormat = ""
    /// How far apart the ticks stand, as a count and a unit — `1week`.
    var tickInterval: (count: Int, unit: String)?
    /// Whether to mark today, and nil when the chart said `todayMarker off`.
    var marksToday = true
    /// `displayMode compact` packs tasks that do not overlap onto one row.
    var compact = false

    /// A task may point at one written below it — `until isadded` — so the
    /// lines are read twice: once to find out where every named task stands,
    /// and once for real, with those places already known.
    static func parse(_ lines: [Substring], compact: Bool = false) -> GanttChart? {
        var found: [String: Double] = [:]
        var opened: [String: Double] = [:]
        // The first reading must not stop at a task that points at one it has
        // not reached yet, or it would never reach it.
        _ = read(lines, compact: compact, searching: true, ends: &found, starts: &opened)
        return read(lines, compact: compact, searching: false, ends: &found, starts: &opened)
    }

    private static func read(
        _ lines: [Substring], compact: Bool, searching: Bool, ends: inout [String: Double],
        starts: inout [String: Double]
    ) -> GanttChart? {
        var chart = GanttChart(title: "", sections: [], tasks: [], origin: nil)
        chart.compact = compact
        var section: Int?
        /// How a date is written in this chart, and how a day is read from it.
        var format = "YYYY-MM-DD"
        /// The days off: weekends, named weekdays, and named dates.
        var offWeekdays: Set<Int> = []
        var offDates: Set<Int> = []
        var onDates: Set<Int> = []
        /// The last working day of the week, as `weekday friday` sets it. The
        /// two days after it are the weekend.
        var lastWorkday = 6
        /// `inclusiveEndDates` makes `2026-01-05` mean the end of that day.
        var inclusive = false
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
                guard !rest.isEmpty else { return nil }
                format = rest
                continue
            case "axisFormat":
                guard !rest.isEmpty else { return nil }
                chart.axisFormat = rest
                continue
            case "tickInterval":
                // `1week`, `2day`, `1month`.
                // A unit Mermaid does not know — `1decade`, `1year` — is passed
                // over without a word, and the ticks fall where they would have
                // fallen anyway.
                let count = rest.prefix(while: { $0.isNumber })
                let unit = String(rest.dropFirst(count.count))
                guard let number = Int(count), number > 0,
                    ["millisecond", "second", "minute", "hour", "day", "week", "month"]
                        .contains(unit)
                else { continue }
                chart.tickInterval = (count: number, unit: unit)
                continue
            case "todayMarker":
                guard !rest.isEmpty else { return nil }
                // Anything but `off` is CSS for a line this draws its own way.
                chart.marksToday = rest != "off"
                continue
            case "displayMode":
                guard rest == "compact" else { return nil }
                chart.compact = true
                continue
            case "inclusiveEndDates":
                guard rest.isEmpty else { return nil }
                inclusive = true
                continue
            case "weekday":
                guard let index = weekdays[rest.lowercased()] else { return nil }
                lastWorkday = index
                continue
            case "weekend":
                // Which day the weekend starts on: `weekend friday` makes
                // Friday and Saturday the days off rather than Saturday and
                // Sunday. It is read the same way `weekday` is.
                guard let index = weekdays[rest.lowercased()] else { return nil }
                lastWorkday = index == 1 ? 7 : index - 1
                continue
            case "excludes", "includes":
                guard !rest.isEmpty else { return nil }
                for written in rest.split(separator: ",").map({
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }) {
                    if written == "weekends" {
                        guard word == "excludes" else { return nil }
                        offWeekdays.formUnion([lastWorkday % 7 + 1, (lastWorkday + 1) % 7 + 1])
                        continue
                    }
                    if let index = weekdays[written] {
                        guard word == "excludes" else { return nil }
                        offWeekdays.insert(index)
                        continue
                    }
                    guard let date = day(written, format: format) else { return nil }
                    let number = Int(date.rounded(.down))
                    if word == "excludes" {
                        offDates.insert(number)
                    } else {
                        onDates.insert(number)
                    }
                }
                continue
            case "click":
                // A picture cannot be followed, so the line names a task and
                // then changes nothing about how the chart is drawn.
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { return nil }
                continue
            case "section":
                guard !rest.isEmpty else { return nil }
                chart.sections.append(rest)
                section = chart.sections.count - 1
                continue
            default:
                break
            }
            // The name is what stands before the first colon, not the last: a
            // task told in hours carries colons of its own — `17:49`.
            guard let colon = line.firstIndex(of: ":") else { return nil }
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
                case "vert": task.vertical = true
                default: break
                }
                guard ["done", "active", "crit", "milestone", "vert"].contains(first) else { break }
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
                if let start = moment(fields[0], ends: ends, starts: starts, format: format) {
                    dated = dated || day(fields[0], format: format) != nil
                    task.start = start
                } else {
                    identifier = fields.removeFirst()
                    task.start = previousEnd
                }
            } else {
                task.start = previousEnd
            }
            // A task cannot begin on a day nobody works.
            let off = { (day: Double) in
                offDay(
                    day, weekdays: offWeekdays, dates: offDates, kept: onDates)
            }
            while off(task.start) { task.start += 1 }
            guard let last = fields.last else { return nil }
            if let span = span(last) {
                // A length is counted in working days, so a bar that runs over
                // a weekend reaches further along the calendar than it says.
                task.length = span
                if !offWeekdays.isEmpty || !offDates.isEmpty {
                    var left = span
                    var walked = task.start
                    while left > 0 {
                        let step = min(1, left)
                        walked += step
                        left -= step
                        while off(walked) { walked += 1 }
                    }
                    task.length = walked - task.start
                }
            } else if let end = moment(last, ends: ends, starts: starts, format: format) {
                dated = dated || day(last, format: format) != nil
                task.length = end - task.start + (inclusive ? 1 : 0)
            } else {
                return nil
            }
            if searching {
                task.length = max(task.length, 0)
            } else {
                guard task.length >= 0 else { return nil }
            }
            if task.milestone || task.vertical { task.length = 0 }
            previousEnd = task.start + task.length
            if let identifier {
                guard !identifier.isEmpty, !identifier.contains(" ") else { return nil }
                starts[identifier] = task.start
                ends[identifier] = previousEnd
            }
            chart.tasks.append(task)
        }
        // A chart that says how it should be drawn and then draws nothing is a
        // chart with nothing in it, which is what Mermaid shows.
        guard !chart.tasks.isEmpty else { return chart }
        // Everything was counted from the first real date; shift it all so the
        // chart starts at zero and the axis knows which day that was.
        let earliest = chart.tasks.map(\.start).min() ?? 0
        // A chart told in days starts on a whole day; one told in hours starts
        // at the first task's own time, so that the axis does not open hours
        // before anything happens.
        let zero = dated ? earliest : 0
        if dated {
            chart.origin = zero
            for index in chart.tasks.indices { chart.tasks[index].start -= zero }
        }
        // The days off are shaded across the whole chart, so they are gathered
        // once its span is known and written down where the plot counts from.
        if !offWeekdays.isEmpty || !offDates.isEmpty {
            let last = chart.tasks.map { $0.start + $0.length }.max() ?? 0
            for step in 0...Int(last.rounded(.up)) {
                let absolute = Double(step) + zero
                guard offDay(absolute, weekdays: offWeekdays, dates: offDates, kept: onDates)
                else { continue }
                chart.excluded.insert(step)
            }
        }
        return chart
    }

    /// Which weekday each name stands for, counting Sunday as one, the way
    /// `Calendar` does.
    private static let weekdays = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6,
        "saturday": 7,
    ]

    /// Whether nobody works on that day: a weekend, a named weekday or a named
    /// date, unless an `includes` line named it back.
    private static func offDay(
        _ number: Double, weekdays offWeekdays: Set<Int>, dates: Set<Int>, kept: Set<Int>
    ) -> Bool {
        let whole = Int(number.rounded(.down))
        guard !kept.contains(whole) else { return false }
        if dates.contains(whole) { return true }
        // 1970-01-01 was a Thursday, which is weekday five.
        let weekday = ((whole % 7) + 7) % 7 + 5
        return offWeekdays.contains(weekday > 7 ? weekday - 7 : weekday)
    }

    /// `2014-01-01`, `after a1`, `until a1`.
    private static func moment(
        _ text: String, ends: [String: Double], starts: [String: Double], format: String
    ) -> Double? {
        // A name nobody wrote leaves nothing to follow, and Mermaid puts such a
        // task at the beginning of the chart rather than dropping it.
        if text.hasPrefix("after ") {
            let names = text.dropFirst(6).split(separator: " ").map(String.init)
            return names.compactMap { ends[$0] }.max() ?? starts.values.min() ?? 0
        }
        if text.hasPrefix("until ") {
            let names = text.dropFirst(6).split(separator: " ").map(String.init)
            return names.compactMap { starts[$0] }.min() ?? starts.values.min() ?? 0
        }
        return day(text, format: format)
    }

    /// `30d`, `2w`, `12h`, `10m`, `45s`. Everything is counted in days, so a
    /// chart told in minutes works in fractions of one.
    private static func span(_ text: String) -> Double? {
        guard let unit = text.last, let number = Double(text.dropLast()) else { return nil }
        switch unit {
        case "d": return number
        case "w": return number * 7
        case "h": return number / 24
        case "m": return number / 1440
        case "s": return number / 86400
        default: return nil
        }
    }

    /// A day number for a date written the way `dateFormat` says, counted from
    /// the same zero for every date, which is all a bar needs.
    ///
    /// The format is read as Mermaid writes it: `YYYY`, `YY`, `MM`, `DD`, `HH`,
    /// `mm`, `ss` and whatever punctuation stands between them, plus `X` for a
    /// count of seconds and `x` for a count of milliseconds.
    static func day(_ text: String, format: String = "YYYY-MM-DD") -> Double? {
        if format == "X" { return Double(text).map { $0 / 86400 } }
        if format == "x" { return Double(text).map { $0 / 86_400_000 } }
        var read = Substring(text)
        var pattern = Substring(format)
        var year: Int?
        var month = 1
        var dayOfMonth = 1
        var seconds = 0
        let tokens: [(text: String, digits: Int)] = [
            ("YYYY", 4), ("YY", 2), ("MM", 2), ("DD", 2), ("HH", 2), ("mm", 2), ("ss", 2),
            ("SSS", 3),
        ]
        while !pattern.isEmpty {
            guard let token = tokens.first(where: { pattern.hasPrefix($0.text) }) else {
                // Anything else in the format has to stand there in the date.
                guard let expected = pattern.first, read.first == expected else { return nil }
                pattern = pattern.dropFirst()
                read = read.dropFirst()
                continue
            }
            guard read.count >= token.digits,
                let number = Int(read.prefix(token.digits)),
                read.prefix(token.digits).allSatisfy(\.isNumber)
            else { return nil }
            switch token.text {
            case "YYYY": year = number
            case "YY": year = 2000 + number
            case "MM": month = number
            case "DD": dayOfMonth = number
            case "HH": seconds += number * 3600
            case "mm": seconds += number * 60
            case "ss": seconds += number
            default: break
            }
            pattern = pattern.dropFirst(token.text.count)
            read = read.dropFirst(token.digits)
        }
        // A chart told in hours names no year at all — `dateFormat HH:mm` — so
        // the day is the first of the epoch and the time of day is the whole of
        // what was written.
        guard read.isEmpty, (1...12).contains(month), (1...31).contains(dayOfMonth)
        else { return nil }
        guard year != nil || seconds > 0 || format.contains("HH") else { return nil }
        var components = DateComponents()
        components.year = year ?? 1970
        components.month = month
        components.day = dayOfMonth
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: "UTC") else { return nil }
        calendar.timeZone = zone
        guard let date = calendar.date(from: components) else { return nil }
        return (date.timeIntervalSince1970 + Double(seconds)) / 86400
    }

    /// The other way round, for the axis.
    ///
    /// The year is written out. A chart that runs over a new year would
    /// otherwise label two different days the same way, and a reader has no way
    /// of telling which is which from a picture that omits it.
    static func date(_ day: Double, format: String = "") -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let date = Date(timeIntervalSince1970: day * 86400)
        let parts = calendar.dateComponents(
            [.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let dayOfMonth = parts.day ?? 1
        guard !format.isEmpty else {
            return String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
        }
        // `axisFormat` is written the way `strftime` writes one.
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var written = ""
        var pattern = Substring(format)
        while let char = pattern.first {
            guard char == "%", pattern.count >= 2 else {
                written.append(char)
                pattern = pattern.dropFirst()
                continue
            }
            let letter = pattern[pattern.index(after: pattern.startIndex)]
            switch letter {
            case "Y": written += String(format: "%04d", year)
            case "y": written += String(format: "%02d", year % 100)
            case "m": written += String(format: "%02d", month)
            case "d": written += String(format: "%02d", dayOfMonth)
            case "e": written += String(dayOfMonth)
            case "b": written += months[max(0, min(11, month - 1))]
            case "a": written += days[max(0, min(6, (parts.weekday ?? 1) - 1))]
            case "H": written += String(format: "%02d", parts.hour ?? 0)
            case "M": written += String(format: "%02d", parts.minute ?? 0)
            case "S": written += String(format: "%02d", parts.second ?? 0)
            case "%": written += "%"
            default: written += "%\(letter)"
            }
            pattern = pattern.dropFirst(2)
        }
        return written
    }

    /// Today, as a day number, so a chart can mark where the reader stands.
    static func today() -> Int {
        Int((Date().timeIntervalSince1970 / 86400).rounded(.down))
    }
}
