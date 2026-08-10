import Foundation

/// A quadrant chart: a square cut in four, with points scattered over it.
struct QuadrantChart {
    struct Point {
        var label: String
        /// Both in 0…1, the square's own coordinates.
        var x: Double
        var y: Double
        /// What a point may be told about itself, on its own line or through a
        /// `classDef`: how big to be drawn and in what colours.
        var radius: Double?
        var fill: Flowchart.Colour?
        var stroke: Flowchart.Colour?
        var strokeWidth: Double?

        mutating func merge(_ other: Point) {
            if let radius = other.radius { self.radius = radius }
            if let fill = other.fill { self.fill = fill }
            if let stroke = other.stroke { self.stroke = stroke }
            if let width = other.strokeWidth { strokeWidth = width }
        }
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
        /// The looks `classDef` named, and which point asked for each of them.
        var styles: [String: Point] = [:]
        var wearing: [(index: Int, name: String)] = []
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
            case "classDef":
                // `classDef class1 color: #109060, radius: 10`
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2, let style = look(String(parts[1])) else { return nil }
                styles[String(parts[0])] = style
                continue
            default:
                break
            }
            // `Campaign A: [0.3, 0.6]`, with `:::name` and a look of its own
            // both allowed: `Campaign B:::class1: [0.8, 0.1] color: #ff3300`.
            var head = Substring(line)
            var asked: String?
            if let mark = head.range(of: ":::") {
                guard let colon = head[mark.upperBound...].firstIndex(of: ":") else { return nil }
                asked = head[mark.upperBound..<colon].trimmingCharacters(in: .whitespaces)
                head = head[head.startIndex..<mark.lowerBound]
                guard let name = asked, !name.isEmpty, !name.contains(" ") else { return nil }
            }
            guard
                let colon = line.range(of: asked == nil ? ":" : ": ", range: labelEnd(line, asked))
            else { return nil }
            let label = head.prefix(while: { $0 != ":" })
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            var body = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, body.hasPrefix("["), let close = body.firstIndex(of: "]")
            else { return nil }
            let numbers = body[body.index(after: body.startIndex)..<close].split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 2, (0...1).contains(numbers[0]), (0...1).contains(numbers[1])
            else { return nil }
            body = String(body[body.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            var point = Point(label: label, x: numbers[0], y: numbers[1])
            if !body.isEmpty {
                guard let look = look(body) else { return nil }
                point.merge(look)
            }
            if let asked { wearing.append((chart.points.count, asked)) }
            chart.points.append(point)
        }
        // A class is written under the points that wear it, so the looks are
        // handed out once every line has been read. A class nobody defined
        // leaves the point drawn the way every other point is drawn.
        for (index, name) in wearing {
            guard let style = styles[name] else { continue }
            var worn = style
            worn.merge(chart.points[index])
            worn.label = chart.points[index].label
            worn.x = chart.points[index].x
            worn.y = chart.points[index].y
            chart.points[index] = worn
        }
        // A chart with no points is still a chart: the axes and the four names
        // are the picture, and Mermaid draws it. An empty fence is not.
        guard
            !chart.points.isEmpty || !chart.xAxis.0.isEmpty || !chart.yAxis.0.isEmpty
                || chart.quadrants.contains(where: { !$0.isEmpty })
        else { return nil }
        return chart
    }

    /// Where the colon that introduces a point's place may stand: after the
    /// class name when one was written, and anywhere otherwise.
    private static func labelEnd(_ line: Substring, _ asked: String?) -> Range<Substring.Index> {
        guard let asked, let mark = line.range(of: ":::\(asked)") else {
            return line.startIndex..<line.endIndex
        }
        return mark.upperBound..<line.endIndex
    }

    /// `color: #ff3300, radius: 10, stroke-color: #10f0f0, stroke-width: 5px`.
    private static func look(_ text: String) -> Point? {
        var point = Point(label: "", x: 0, y: 0)
        for declaration in text.split(separator: ",") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value = String(value.dropLast()) }
            switch key {
            case "radius":
                guard let size = Double(value), size > 0 else { return nil }
                point.radius = size
            case "color":
                guard let colour = Flowchart.Colour(css: value) else { return nil }
                point.fill = colour
            case "stroke-color":
                guard let colour = Flowchart.Colour(css: value) else { return nil }
                point.stroke = colour
            case "stroke-width":
                let number = value.prefix(while: { $0.isNumber || $0 == "." })
                guard let width = Double(number), width > 0 else { return nil }
                point.strokeWidth = width
            default:
                return nil
            }
        }
        return point
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
        /// What each point is called, where its author named it: `[540 "PaLM"]`.
        /// Empty where nothing was written, and as long as `values`.
        var labels: [String] = []
    }

    var title: String
    var categories: [String]
    var xTitle: String = ""
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
                // The axis may be given a name before its categories.
                let (name, body) = titled(rest)
                chart.xTitle = name
                guard let names = list(body), !names.isEmpty else { return nil }
                chart.categories = names.map(\.text)
                continue
            case "y-axis":
                guard let read = yAxis(rest) else { return nil }
                chart.yTitle = read.title
                chart.yRange = read.range
                continue
            case "bar", "line":
                // A series may be named, though Mermaid draws no legend to
                // show the name in, so it is read and then left alone.
                let (_, body) = titled(rest)
                guard let points = list(body) else { return nil }
                let values = points.compactMap { Double($0.text) }
                guard values.count == points.count, !values.isEmpty else { return nil }
                chart.series.append(
                    Series(
                        isBar: word == "bar", values: values, labels: points.map(\.label)))
                continue
            default:
                // A horizontal chart needs axes drawn the other way round.
                return nil
            }
        }
        guard !chart.series.isEmpty else { return nil }
        let longest = chart.series.map(\.values.count).max() ?? 0
        if chart.categories.isEmpty {
            chart.categories = (1...longest).map(String.init)
        }
        // A series may run past the names its author wrote, and Mermaid leaves
        // those places on the axis standing without a name rather than throwing
        // the chart away. A shorter series simply stops where its numbers do.
        while chart.categories.count < longest { chart.categories.append("") }
        return chart
    }

    /// `[jan, feb, mar]`, `[5000, 6000]`, or `[540 "PaLM", 65 "LLaMA-65B"]`,
    /// where each point may be given words of its own.
    private static func list(_ text: String) -> [(text: String, label: String)]? {
        guard text.hasPrefix("["), text.hasSuffix("]") else { return nil }
        return text.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
            .map { item -> (text: String, label: String) in
                let written = item.trimmingCharacters(in: .whitespaces)
                guard !written.hasPrefix("\""), let quote = written.firstIndex(of: "\"")
                else {
                    return (written.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), "")
                }
                return (
                    written[written.startIndex..<quote].trimmingCharacters(in: .whitespaces),
                    written[quote...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                )
            }
            .filter { !$0.text.isEmpty }
    }

    /// A quoted name in front of whatever else the line carries.
    private static func titled(_ text: String) -> (name: String, rest: String) {
        guard text.hasPrefix("\""), let close = text.dropFirst().firstIndex(of: "\"") else {
            return ("", text)
        }
        return (
            String(text[text.index(after: text.startIndex)..<close]),
            String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        )
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
    /// What a commit is, which is what its dot is drawn as.
    ///
    /// A reverse is a commit that undoes another one and a highlight is one its
    /// author wants noticed; drawing either as an ordinary commit would say
    /// something the source does not.
    enum Kind {
        case normal
        case reverse
        case highlighted
    }

    struct Commit {
        var label: String
        var tag: String
        var branch: Int
        /// Where it sits along the graph, counted in commits.
        var column: Int
        /// The commit this one merged in, when it is a merge.
        var merges: Int?
        /// The commit this one copied, when it is a cherry-pick. Drawn like a
        /// merge, with a dotted line, because it is the same thing said twice.
        var picks: Int?
        var kind: Kind
    }

    var branches: [String]
    var commits: [Commit]
    /// `gitGraph TB:`: the lanes run down the page rather than across it.
    var vertical = false

    static func parse(_ lines: [Substring], vertical: Bool = false) -> GitGraph? {
        var graph = GitGraph(branches: ["main"], commits: [], vertical: vertical)
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
                        merges: nil, picks: nil, kind: options.kind))
                tips[current] = graph.commits.count - 1
                column += 1
            case "cherry-pick":
                // `cherry-pick id: "Alpha"` copies a commit onto this branch.
                guard let options = options(rest), !options.id.isEmpty,
                    let source = graph.commits.firstIndex(where: { $0.label == options.id }),
                    graph.commits[source].branch != current
                else { return nil }
                graph.commits.append(
                    Commit(
                        label: options.id, tag: options.tag, branch: current, column: column,
                        merges: nil, picks: source, kind: options.kind))
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
                        merges: tip, picks: nil, kind: options.kind))
                tips[current] = graph.commits.count - 1
                column += 1
            default:
                return nil
            }
        }
        guard !graph.commits.isEmpty else { return nil }
        return graph
    }

    /// `id: "Alpha" tag: "v1.0" type: HIGHLIGHT`
    private static func options(_ text: String)
        -> (id: String, tag: String, kind: Kind)?
    {
        var id = ""
        var tag = ""
        var kind = Kind.normal
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
            case "type":
                // A type nobody here draws is refused rather than quietly read
                // as an ordinary commit.
                switch value {
                case "NORMAL": kind = .normal
                case "REVERSE": kind = .reverse
                case "HIGHLIGHT": kind = .highlighted
                default: return nil
                }
            default: return nil
            }
        }
        return (id, tag, kind)
    }
}
