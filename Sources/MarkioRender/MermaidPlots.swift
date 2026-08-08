import Foundation

/// A quadrant chart: a square cut in four, with points scattered over it.
struct QuadrantChart {
    struct Point {
        var label: String
        /// Both in 0…1, the square's own coordinates.
        var x: Double
        var y: Double
    }

    var title: String
    /// The words at each end of the axis: left and right, then bottom and top.
    var xAxis: (low: String, high: String)
    var yAxis: (low: String, high: String)
    /// Named clockwise from the top right, the way Mermaid numbers them.
    var quadrants: [String]
    var points: [Point]

    static func parse(_ lines: [Substring]) -> QuadrantChart? {
        var chart = QuadrantChart(
            title: "", xAxis: ("", ""), yAxis: ("", ""),
            quadrants: ["", "", "", ""], points: [])
        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            switch word {
            case "title":
                guard !rest.isEmpty else { return nil }
                chart.title = rest
                continue
            case "x-axis", "y-axis":
                guard let ends = ends(rest) else { return nil }
                if word == "x-axis" { chart.xAxis = ends } else { chart.yAxis = ends }
                continue
            case "quadrant-1", "quadrant-2", "quadrant-3", "quadrant-4":
                guard let number = Int(word.dropFirst(9)), !rest.isEmpty else { return nil }
                chart.quadrants[number - 1] = rest
                continue
            default:
                break
            }
            // `Campaign A: [0.3, 0.6]`
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let label = line[line.startIndex..<colon]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let body = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, body.hasPrefix("["), body.hasSuffix("]") else { return nil }
            let numbers = body.dropFirst().dropLast().split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 2, (0...1).contains(numbers[0]), (0...1).contains(numbers[1])
            else { return nil }
            chart.points.append(Point(label: label, x: numbers[0], y: numbers[1]))
        }
        guard !chart.points.isEmpty else { return nil }
        return chart
    }

    /// `Low Reach --> High Reach`, or just the one end.
    private static func ends(_ text: String) -> (low: String, high: String)? {
        let clean = { (part: Substring) in
            part.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        guard let arrow = text.range(of: "-->") else {
            let only = clean(Substring(text))
            return only.isEmpty ? nil : (only, "")
        }
        let low = clean(text[text.startIndex..<arrow.lowerBound])
        let high = clean(text[arrow.upperBound...])
        guard !low.isEmpty, !high.isEmpty else { return nil }
        return (low, high)
    }
}

/// An x–y chart: bars and lines over named categories.
struct XYChart {
    struct Series {
        var isBar: Bool
        var values: [Double]
    }

    var title: String
    var categories: [String]
    var yTitle: String
    /// The range the y axis covers, taken from the data when it is not written.
    var yRange: (low: Double, high: Double)?
    var series: [Series]

    static func parse(_ lines: [Substring]) -> XYChart? {
        var chart = XYChart(
            title: "", categories: [], yTitle: "", yRange: nil, series: [])
        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            switch word {
            case "title":
                guard let title = unquoted(rest) else { return nil }
                chart.title = title
                continue
            case "x-axis":
                guard let names = list(rest), !names.isEmpty else { return nil }
                chart.categories = names
                continue
            case "y-axis":
                guard let read = yAxis(rest) else { return nil }
                chart.yTitle = read.title
                chart.yRange = read.range
                continue
            case "bar", "line":
                guard let names = list(rest) else { return nil }
                let values = names.compactMap(Double.init)
                guard values.count == names.count, !values.isEmpty else { return nil }
                chart.series.append(Series(isBar: word == "bar", values: values))
                continue
            default:
                // A horizontal chart needs axes drawn the other way round.
                return nil
            }
        }
        guard !chart.series.isEmpty else { return nil }
        let longest = chart.series.map(\.values.count).max() ?? 0
        // Every series has to line up with the categories, or a bar would stand
        // over a name that is not its own.
        guard chart.series.allSatisfy({ $0.values.count == longest }) else { return nil }
        if chart.categories.isEmpty {
            chart.categories = (1...longest).map(String.init)
        }
        guard chart.categories.count == longest else { return nil }
        return chart
    }

    /// `[jan, feb, mar]` or `[5000, 6000]`.
    private static func list(_ text: String) -> [String]? {
        guard text.hasPrefix("["), text.hasSuffix("]") else { return nil }
        return text.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            .filter { !$0.isEmpty }
    }

    /// `"Revenue" 4000 --> 11000`, or a title alone, or a range alone.
    private static func yAxis(_ text: String) -> (title: String, range: (Double, Double)?)? {
        var body = text
        var title = ""
        if body.hasPrefix("\"") {
            guard let close = body.dropFirst().firstIndex(of: "\"") else { return nil }
            title = String(body[body.index(after: body.startIndex)..<close])
            body = String(body[body.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if body.isEmpty { return (title, nil) }
        guard let arrow = body.range(of: "-->"),
            let low = Double(
                body[body.startIndex..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)),
            let high = Double(body[arrow.upperBound...].trimmingCharacters(in: .whitespaces)),
            high > low
        else {
            // Words with no quotes around them are still a title.
            return title.isEmpty ? (body, nil) : nil
        }
        return (title, (low, high))
    }

    private static func unquoted(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return clean.isEmpty ? nil : clean
    }
}

/// A git graph: commits along a line, one lane per branch.
struct GitGraph {
    struct Commit {
        var label: String
        var tag: String
        var branch: Int
        /// Where it sits along the graph, counted in commits.
        var column: Int
        /// The commit this one merged in, when it is a merge.
        var merges: Int?
        var highlighted: Bool
    }

    var branches: [String]
    var commits: [Commit]

    static func parse(_ lines: [Substring]) -> GitGraph? {
        var graph = GitGraph(branches: ["main"], commits: [])
        var current = 0
        var column = 0
        /// The last commit on each branch, which is what a merge line points at.
        var tips: [Int: Int] = [:]
        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            switch word {
            case "commit":
                guard let options = options(rest) else { return nil }
                graph.commits.append(
                    Commit(
                        label: options.id, tag: options.tag, branch: current, column: column,
                        merges: nil, highlighted: options.highlighted))
                tips[current] = graph.commits.count - 1
                column += 1
            case "branch":
                let name = String(rest.prefix(while: { !$0.isWhitespace }))
                guard !name.isEmpty, !graph.branches.contains(name) else { return nil }
                graph.branches.append(name)
                current = graph.branches.count - 1
            case "checkout", "switch":
                guard let index = graph.branches.firstIndex(of: rest) else { return nil }
                current = index
            case "merge":
                let name = String(rest.prefix(while: { !$0.isWhitespace }))
                guard let source = graph.branches.firstIndex(of: name), source != current,
                    let tip = tips[source]
                else { return nil }
                let options = options(
                    rest.dropFirst(name.count).trimmingCharacters(in: .whitespaces))
                guard let options else { return nil }
                graph.commits.append(
                    Commit(
                        label: options.id, tag: options.tag, branch: current, column: column,
                        merges: tip, highlighted: false))
                tips[current] = graph.commits.count - 1
                column += 1
            default:
                // Cherry-picks and `%%{init}` configuration are not drawn.
                return nil
            }
        }
        guard !graph.commits.isEmpty else { return nil }
        return graph
    }

    /// `id: "Alpha" tag: "v1.0" type: HIGHLIGHT`
    private static func options(_ text: String)
        -> (id: String, tag: String, highlighted: Bool)?
    {
        var id = ""
        var tag = ""
        var highlighted = false
        var rest = Substring(text)
        while !rest.isEmpty {
            rest = Substring(rest.trimmingCharacters(in: .whitespaces))
            if rest.isEmpty { break }
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let key = rest[rest.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            var value = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                guard let close = value.dropFirst().firstIndex(of: "\"") else { return nil }
                let word = String(value[value.index(after: value.startIndex)..<close])
                rest = value[value.index(after: close)...]
                value = word
            } else {
                let word = String(value.prefix(while: { !$0.isWhitespace }))
                rest = Substring(value.dropFirst(word.count))
                value = word
            }
            switch key {
            case "id": id = value
            case "tag": tag = value
            case "type": highlighted = value == "HIGHLIGHT"
            default: return nil
            }
        }
        return (id, tag, highlighted)
    }
}
