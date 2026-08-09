import Foundation

/// A radar chart: one spoke per axis, one closed shape per curve.
struct RadarChart {
    struct Curve {
        var label: String
        /// One value per axis, in the order the axes were written.
        var values: [Double]
    }

    var title: String
    var axes: [String]
    var curves: [Curve]
    var low: Double
    /// Where the outer ring sits. Nil until the source says, and then the
    /// largest value written, so a chart with no `max` still fills its circle.
    var high: Double?
    var ticks: Int
    /// `graticule polygon` joins the spokes with straight lines; `circle` rings
    /// them.
    var polygon: Bool
    var showLegend: Bool

    static func parse(_ lines: [Substring]) -> RadarChart? {
        var chart = RadarChart(
            title: "", axes: [], curves: [], low: 0, high: nil, ticks: 5, polygon: false,
            showLegend: true)
        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            switch word {
            case "title":
                chart.title = rest
            case "axis":
                for field in fields(of: rest) {
                    guard let read = named(field) else { return nil }
                    chart.axes.append(read.label)
                }
            case "curve":
                guard let open = rest.firstIndex(of: "{"), rest.hasSuffix("}") else { return nil }
                let head = String(rest[rest.startIndex..<open]).trimmingCharacters(in: .whitespaces)
                guard let read = named(head) else { return nil }
                let body = rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]
                var values: [Double] = []
                for field in fields(of: String(body)) {
                    // `a: 10` names the axis a value belongs to, which this does
                    // not read: the values are taken in the order they are given.
                    guard !field.contains(":"), let value = Double(field) else { return nil }
                    values.append(value)
                }
                chart.curves.append(Curve(label: read.label, values: values))
            case "max", "min":
                guard let value = Double(rest) else { return nil }
                if word == "max" { chart.high = value } else { chart.low = value }
            case "ticks":
                // Zero rings is a bare web, which is what Mermaid draws for it.
                guard let value = Int(rest), value >= 0, value <= 20 else { return nil }
                chart.ticks = value
            case "graticule":
                guard rest == "polygon" || rest == "circle" else { return nil }
                chart.polygon = rest == "polygon"
            case "showLegend":
                guard rest == "true" || rest == "false" else { return nil }
                chart.showLegend = rest == "true"
            default:
                return nil
            }
        }
        // Two axes make a line rather than a shape, which is what Mermaid
        // draws for one, so the drawing takes whatever it is given.
        // A curve short of a value has no shape to close, so it is dropped and
        // the rest of the chart is drawn — which is what Mermaid itself does.
        // A chart that named no curve at all is a chart with nothing on it.
        guard !chart.curves.isEmpty else { return nil }
        chart.curves.removeAll { $0.values.count != chart.axes.count }
        guard chart.axes.count >= 2 else { return nil }
        let largest = chart.curves.flatMap(\.values).max() ?? 0
        let outer = chart.high ?? max(largest, chart.low + 1)
        guard outer > chart.low else { return nil }
        chart.high = outer
        return chart
    }

    /// `a["Speed"]`, `a[Speed]` or a bare `a`.
    private static func named(_ text: String) -> (id: String, label: String)? {
        guard let read = Flowchart.cell(Substring(text)) else { return nil }
        return (read.id, read.label ?? read.id)
    }

    /// Comma-separated fields, with commas inside quotes and brackets left be.
    private static func fields(of text: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var depth = 0
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if !quoted {
                if character == "[" || character == "(" || character == "{" { depth += 1 }
                if character == "]" || character == ")" || character == "}" { depth -= 1 }
                if character == "," && depth == 0 {
                    fields.append(field.trimmingCharacters(in: .whitespaces))
                    field = ""
                    continue
                }
            }
            field.append(character)
        }
        let last = field.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { fields.append(last) }
        return fields
    }
}

/// A block diagram: cells filling a grid of a stated width, with arrows between
/// them.
struct BlockDiagram {
    struct Cell {
        var node: Int?
        var span: Int
        /// `block:ID … end`: a grid of its own, framed, standing in this cell.
        var block: Int?
    }

    /// A `block:ID … end` and what is written inside it.
    struct Block {
        var id: String
        var columns: Int?
        var cells: [Cell]
    }

    var columns: Int
    /// The blocks and the arrows, held as a flowchart so the shapes, the styling
    /// and the arrow drawing are the ones a flowchart already has.
    var chart: Flowchart
    /// Every cell in reading order, blank ones included.
    var cells: [Cell]
    /// Every framed block, held flat and named by index, so a block inside a
    /// block is one more entry rather than a type that holds itself.
    var blocks: [Block] = []

    static func parse(_ lines: [Substring]) -> BlockDiagram? {
        var columns: Int?
        var chart = Flowchart(direction: .down, nodes: [], edges: [])
        var identifiers: [String: Int] = [:]
        var classes: [String: Flowchart.Style] = [:]
        var cells: [Cell] = []
        var blocks: [Block] = []
        /// The blocks currently open, innermost last.
        var open: [Int] = []
        var edgeLines: [Substring] = []

        /// Where a cell written now belongs: the innermost open block, or the
        /// diagram itself.
        func add(_ cell: Cell) {
            if let block = open.last {
                blocks[block].cells.append(cell)
            } else {
                cells.append(cell)
            }
        }

        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if word == "columns" {
                guard let value = Int(rest), value > 0, value <= 32 else { return nil }
                if let block = open.last {
                    guard blocks[block].columns == nil else { return nil }
                    blocks[block].columns = value
                } else {
                    guard columns == nil else { return nil }
                    columns = value
                }
                continue
            }
            if word.hasPrefix("block:") {
                var id = String(word.dropFirst("block:".count))
                // `block:group:2` takes two of the row's columns, the same way
                // `a["Wide"]:2` does.
                var span = 1
                if let colon = id.lastIndex(of: ":") {
                    guard let read = Int(id[id.index(after: colon)...]), read > 0 else {
                        return nil
                    }
                    span = read
                    id = String(id[id.startIndex..<colon])
                }
                guard !id.isEmpty, rest.isEmpty, identifiers[id] == nil,
                    !blocks.contains(where: { $0.id == id })
                else { return nil }
                blocks.append(Block(id: id, columns: nil, cells: []))
                add(Cell(node: nil, span: span, block: blocks.count - 1))
                open.append(blocks.count - 1)
                continue
            }
            if word == "end" {
                guard rest.isEmpty, !open.isEmpty else { return nil }
                open.removeLast()
                continue
            }
            if word == "classDef" {
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2, let style = Flowchart.style(from: String(parts[1])) else {
                    return nil
                }
                for name in parts[0].split(separator: ",") {
                    classes[name.trimmingCharacters(in: .whitespaces)] = style
                }
                continue
            }
            if word == "class" || word == "style" {
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { return nil }
                let style =
                    word == "class"
                    ? classes[String(parts[1])] : Flowchart.style(from: String(parts[1]))
                guard let style else { return nil }
                for name in parts[0].split(separator: ",") {
                    let id = name.trimmingCharacters(in: .whitespaces)
                    guard let index = identifiers[id] else { return nil }
                    chart.nodes[index].style.merge(style)
                }
                continue
            }
            // A line with a link on it joins blocks already written, so it is
            // kept back until every block has an index.
            if line.contains("-->") || line.contains("---") || line.contains("-.->") {
                edgeLines.append(line)
                continue
            }
            for token in tokens(of: line) {
                var text = token
                var span = 1
                // `a["Wide"]:2` takes two of the row's columns.
                if let colon = text.lastIndex(of: ":"), text.last?.isNumber == true {
                    guard let read = Int(text[text.index(after: colon)...]), read > 0 else {
                        return nil
                    }
                    span = read
                    text = String(text[text.startIndex..<colon])
                }
                if text == "space" {
                    add(Cell(node: nil, span: span, block: nil))
                    continue
                }
                var read: (id: String, label: String?, shape: Flowchart.Shape?)?
                if let arrow = blockArrow(text) {
                    read = arrow
                } else {
                    read = Flowchart.cell(Substring(text))
                }
                guard let read else { return nil }
                let index: Int
                if let existing = identifiers[read.id] {
                    index = existing
                    if let label = read.label { chart.nodes[index].label = label }
                    if let shape = read.shape { chart.nodes[index].shape = shape }
                } else {
                    chart.nodes.append(
                        Flowchart.Node(
                            id: read.id, label: read.label ?? read.id,
                            shape: read.shape ?? .rectangle))
                    index = chart.nodes.count - 1
                    identifiers[read.id] = index
                }
                add(Cell(node: index, span: span, block: nil))
            }
        }
        guard open.isEmpty else { return nil }

        /// An edge may name a block as well as a box, and a block is drawn as a
        /// frame, which the flowchart already knows how to end a line on.
        func end(_ name: String) -> Flowchart.End? {
            if let node = identifiers[name] { return .node(node) }
            if let block = blocks.firstIndex(where: { $0.id == name }) { return .frame(block) }
            return nil
        }
        for line in edgeLines {
            guard let read = link(line), let from = end(read.from), let to = end(read.to)
            else { return nil }
            chart.edges.append(
                Flowchart.Edge(
                    from: from, to: to, label: read.label, stroke: read.stroke, arrow: read.arrow))
        }
        guard !chart.nodes.isEmpty else { return nil }
        // With no width written, the widest row is the width, which is what
        // Mermaid's `auto` comes to for the rows people actually write.
        let width = columns ?? cells.reduce(0) { $0 + $1.span }
        guard width > 0 else { return nil }
        return BlockDiagram(columns: width, chart: chart, cells: cells, blocks: blocks)
    }

    /// `blockArrowId6<["words"]>(down)`: a fat arrow with words in it.
    ///
    /// `&nbsp;` is how a Mermaid author writes an arrow with nothing to say, so
    /// it becomes the space it stands for rather than being shown as itself.
    private static func blockArrow(_ text: String)
        -> (id: String, label: String?, shape: Flowchart.Shape?)?
    {
        let directions: [String: Flowchart.Shape] = [
            "up": .arrowUp, "down": .arrowDown, "left": .arrowLeft, "right": .arrowRight,
            "x": .arrowRight, "y": .arrowUp,
        ]
        guard let open = text.range(of: "<["), let close = text.range(of: "]>"),
            open.upperBound <= close.lowerBound, text.hasSuffix(")")
        else { return nil }
        let id = String(text[text.startIndex..<open.lowerBound])
        guard !id.isEmpty else { return nil }
        let inner = String(text[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let tail = text[close.upperBound...]
        guard tail.hasPrefix("("),
            let shape = directions[
                String(tail.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    .lowercased()]
        else { return nil }
        return (id, inner.trimmingCharacters(in: .whitespaces), shape)
    }

    /// `a --> b`, `a -->|words| b`, `a --- b`, `a -.-> b`.
    private static func link(_ line: Substring)
        -> (from: String, to: String, label: String, stroke: Flowchart.Stroke, arrow: Bool)?
    {
        let spellings: [(text: String, stroke: Flowchart.Stroke, arrow: Bool)] = [
            ("-.->", .dotted, true), ("-->", .solid, true), ("---", .solid, false),
        ]
        guard let spelling = spellings.first(where: { line.contains($0.text) }),
            let range = line.range(of: spelling.text)
        else { return nil }
        let from = line[line.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        var tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        var label = ""
        if tail.hasPrefix("|"), let close = tail.dropFirst().firstIndex(of: "|") {
            label = String(tail[tail.index(after: tail.startIndex)..<close])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            tail = String(tail[tail.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        guard !from.isEmpty, !tail.isEmpty else { return nil }
        return (from, tail, label, spelling.stroke, spelling.arrow)
    }

    /// A row's cells. A label may hold spaces, so a token ends at a space only
    /// outside every bracket and quote it opened.
    private static func tokens(of line: Substring) -> [String] {
        var tokens: [String] = []
        var token = ""
        var depth = 0
        var quoted = false
        for character in line {
            if character == "\"" { quoted.toggle() }
            if !quoted {
                if character == "[" || character == "(" || character == "{" { depth += 1 }
                if character == "]" || character == ")" || character == "}" { depth -= 1 }
                if character.isWhitespace, depth == 0 {
                    if !token.isEmpty { tokens.append(token) }
                    token = ""
                    continue
                }
            }
            token.append(character)
        }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }
}
