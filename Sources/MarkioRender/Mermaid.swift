import Foundation

/// A Mermaid diagram, read from a ```mermaid fence.
///
/// The subset is the diagrams that fill READMEs: a flowchart — with its shapes,
/// subgraphs, styling and all four directions — a sequence diagram with its
/// loops, alternatives, notes and activation bars, a pie chart, a state machine,
/// a class diagram, an entity–relationship diagram, a mindmap and a timeline.
/// Everything else, and every construct inside those that this does not draw,
/// makes `parse` return nil, and the fence is shown as source, which is what
/// happened before this existed. A diagram that is drawn is drawn completely or
/// not at all; there is no "most of your graph".
enum MermaidDiagram {
    case flowchart(Flowchart)
    case sequence(SequenceDiagram)
    case pie(PieChart)
    case boxes(BoxDiagram)
    case mindmap(Mindmap)
    case timeline(Timeline)
    case journey(UserJourney)
    case gantt(GanttChart)
    case quadrant(QuadrantChart)
    case xy(XYChart)
    case git(GitGraph)

    static func parse(_ source: String) -> MermaidDiagram? {
        var lines: [Substring] = []
        /// How far each line was indented. A mindmap is the one diagram whose
        /// meaning lives in the leading spaces, so they are measured here rather
        /// than thrown away with the rest of the whitespace.
        var indents: [Int] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // `%%` is a Mermaid comment, and a blank line means nothing here.
            guard !line.isEmpty, !line.hasPrefix("%%") else { continue }
            lines.append(Substring(line))
            indents.append(raw.prefix(while: { $0 == " " || $0 == "\t" }).count)
        }
        guard let header = lines.first else { return nil }
        let rest = Array(lines.dropFirst())
        if header == "mindmap" {
            let body = zip(indents.dropFirst(), rest).map { (indent: $0, text: $1) }
            return Mindmap.parse(body).map(MermaidDiagram.mindmap)
        }
        if header == "timeline" {
            return Timeline.parse(rest).map(MermaidDiagram.timeline)
        }
        if header == "journey" {
            return UserJourney.parse(rest).map(MermaidDiagram.journey)
        }
        if header == "gantt" {
            return GanttChart.parse(rest).map(MermaidDiagram.gantt)
        }
        if header == "quadrantChart" {
            return QuadrantChart.parse(rest).map(MermaidDiagram.quadrant)
        }
        if header == "xychart-beta" || header == "xychart" {
            return XYChart.parse(rest).map(MermaidDiagram.xy)
        }
        // `gitGraph TB:` turns the lanes on their side, which is a layout this
        // has not got, so only the plain form is read.
        if header == "gitGraph" || header == "gitGraph:" {
            return GitGraph.parse(rest).map(MermaidDiagram.git)
        }
        if header == "sequenceDiagram" {
            return SequenceDiagram.parse(rest).map(MermaidDiagram.sequence)
        }
        if header == "stateDiagram-v2" || header == "stateDiagram" {
            // A state machine is a flowchart whose boxes happen to be states, so
            // it is read into one rather than given a layout of its own.
            return StateDiagram.parse(rest).map(MermaidDiagram.flowchart)
        }
        if header.hasPrefix("pie") {
            return PieChart.parse(header: header, lines: rest).map(MermaidDiagram.pie)
        }
        if header == "classDiagram" || header == "classDiagram-v2" {
            return ClassDiagram.parse(rest).map(MermaidDiagram.boxes)
        }
        if header == "erDiagram" {
            return EntityDiagram.parse(rest).map(MermaidDiagram.boxes)
        }
        guard let direction = Flowchart.direction(header: header) else { return nil }
        return Flowchart.parse(rest, direction: direction).map(MermaidDiagram.flowchart)
    }
}

// MARK: - Pie chart

struct PieChart {
    struct Slice {
        var label: String
        var value: Double
    }

    var title: String
    var slices: [Slice]
    /// `pie showData` writes each slice's own number beside its name.
    var showData: Bool

    var total: Double { slices.reduce(0) { $0 + $1.value } }

    static func parse(header: Substring, lines: [Substring]) -> PieChart? {
        var words = header.split(separator: " ", omittingEmptySubsequences: true)
        guard words.first == "pie" else { return nil }
        words.removeFirst()
        var chart = PieChart(title: "", slices: [], showData: false)
        if words.first == "showData" {
            chart.showData = true
            words.removeFirst()
        }
        if words.first == "title" {
            chart.title = words.dropFirst().joined(separator: " ")
            words = []
        }
        guard words.isEmpty else { return nil }
        for line in lines {
            if line.hasPrefix("title ") {
                chart.title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.lastIndex(of: ":") else { return nil }
            let label = line[line.startIndex..<colon]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let number = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, let value = Double(number), value >= 0 else { return nil }
            chart.slices.append(Slice(label: label, value: value))
        }
        guard !chart.slices.isEmpty, chart.total > 0 else { return nil }
        return chart
    }
}

// MARK: - State diagram

/// A state machine, read into a flowchart.
///
/// The shapes carry the difference: a start is a filled dot, an end is a ring,
/// and every named state is a rounded box. Anything that needs a layout a
/// flowchart has not got — a composite state, a fork, a note — is refused.
enum StateDiagram {
    static func parse(_ lines: [Substring]) -> Flowchart? {
        var direction = Flowchart.Direction.down
        var body: [Substring] = []
        var names: [String: String] = [:]
        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if word == "direction" {
                guard let read = Flowchart.direction(header: Substring("flowchart \(rest)"))
                else { return nil }
                direction = read
                continue
            }
            if word == "state" {
                // `state "Long name" as id` is a label; `state id { … }` is a
                // machine inside a machine, and `<<fork>>` is a bar this does
                // not draw.
                guard rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"")
                else { return nil }
                let label = String(rest[rest.index(after: rest.startIndex)..<close])
                let tail = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard tail.hasPrefix("as ") else { return nil }
                names[String(tail.dropFirst(3)).trimmingCharacters(in: .whitespaces)] = label
                continue
            }
            guard !["note", "end", "class", "classDef", "click"].contains(word) else { return nil }
            // `A --> B : go` is the same edge a flowchart writes `A -->|go| B`.
            guard let arrow = line.range(of: "-->") else { return nil }
            var from = String(line[line.startIndex..<arrow.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            var tail = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            var label = ""
            if let colon = tail.firstIndex(of: ":") {
                label = String(tail[tail.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                tail = String(tail[tail.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            }
            guard !from.isEmpty, !tail.isEmpty else { return nil }
            if from == "[*]" { from = "__start" }
            if tail == "[*]" { tail = "__end" }
            let arrowText = label.isEmpty ? "-->" : "-->|\(label)|"
            body.append(Substring("\(from) \(arrowText) \(tail)"))
        }
        guard !body.isEmpty, var chart = Flowchart.parse(body, direction: direction) else {
            return nil
        }
        for index in chart.nodes.indices {
            switch chart.nodes[index].id {
            case "__start":
                chart.nodes[index] = Flowchart.Node(id: "__start", label: "", shape: .point)
            case "__end":
                chart.nodes[index] = Flowchart.Node(id: "__end", label: "", shape: .endPoint)
            default:
                chart.nodes[index].shape = .rounded
                if let label = names[chart.nodes[index].id] {
                    chart.nodes[index].label = label
                }
            }
        }
        return chart
    }
}

// MARK: - Flowchart

struct Flowchart {
    enum Direction {
        case down
        case up
        case right
        case left
    }

    enum Shape {
        case rectangle
        case rounded
        case stadium
        case diamond
        case circle
        case doubleCircle
        case hexagon
        /// `[[…]]`: a call to something described elsewhere.
        case subroutine
        /// `[/…/]` and `[\…\]`: a step that slants one way or the other.
        case parallelogram
        case parallelogramAlt
        /// `[/…\]` and `[\…/]`: a funnel, narrow at one end.
        case trapezoid
        case trapezoidAlt
        case cylinder
        /// `>…]`: a flag, notched on its left.
        case flag
        /// A state machine's `[*]`: a filled dot where it starts, a ring where
        /// it ends. No flowchart writes these; the state reader does.
        case point
        case endPoint
    }

    enum Stroke {
        case solid
        case thick
        case dotted
    }

    /// A colour written in the diagram, not taken from the theme. Kept as
    /// numbers so the parser stays free of AppKit and can run anywhere.
    struct Colour: Equatable {
        var red: Double
        var green: Double
        var blue: Double
    }

    /// What `style`, `classDef` and `:::` can say about a node. Everything else
    /// a CSS declaration could carry is refused rather than ignored.
    struct Style: Equatable {
        var fill: Colour?
        var stroke: Colour?
        var text: Colour?
        var strokeWidth: Double?

        var isEmpty: Bool {
            fill == nil && stroke == nil && text == nil && strokeWidth == nil
        }

        mutating func merge(_ other: Style) {
            if let fill = other.fill { self.fill = fill }
            if let stroke = other.stroke { self.stroke = stroke }
            if let text = other.text { self.text = text }
            if let width = other.strokeWidth { strokeWidth = width }
        }
    }

    struct Node {
        var id: String
        var label: String
        var shape: Shape
        var style = Style()
    }

    struct Edge {
        var from: Int
        var to: Int
        var label: String
        var stroke: Stroke
        /// `---` joins without an arrowhead; `-->` points.
        var arrow: Bool
    }

    /// A `subgraph`: a titled frame drawn around the nodes declared inside it.
    struct Group {
        var title: String
        var members: [Int]
    }

    var direction: Direction
    var nodes: [Node]
    var edges: [Edge]
    var groups: [Group] = []
    /// `classDef` definitions, used while parsing and of no interest afterwards.
    private var classes: [String: Style] = [:]
    private var openGroup: Int?

    static func direction(header: Substring) -> Direction? {
        let words = header.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = words.first, first == "flowchart" || first == "graph" else { return nil }
        return self.direction(word: words.count == 2 ? words[1] : "TD")
    }

    private static func direction(word: Substring) -> Direction? {
        switch word {
        case "TD", "TB": return .down
        case "BT": return .up
        case "LR": return .right
        case "RL": return .left
        default: return nil
        }
    }

    static func parse(_ lines: [Substring], direction: Direction) -> Flowchart? {
        var chart = Flowchart(direction: direction, nodes: [], edges: [])
        for line in lines {
            guard chart.parseLine(line) else { return nil }
        }
        // An unclosed `subgraph` means the author's picture has a frame this
        // one does not.
        guard chart.openGroup == nil, !chart.nodes.isEmpty else { return nil }
        chart.groups.removeAll { $0.members.isEmpty }
        return chart
    }

    /// A whole line: a subgraph boundary, a styling directive, or a statement.
    private mutating func parseLine(_ line: Substring) -> Bool {
        let word = String(line.prefix(while: { !$0.isWhitespace }))
        let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        switch word {
        case "subgraph":
            // A subgraph inside a subgraph needs frames inside frames, and a
            // frame drawn in the wrong place is worse than a fence of source.
            guard openGroup == nil else { return false }
            groups.append(Group(title: title(ofSubgraph: rest), members: []))
            openGroup = groups.count - 1
            return true
        case "end":
            guard openGroup != nil, rest.isEmpty else { return false }
            openGroup = nil
            return true
        case "direction":
            // A direction inside a subgraph turns that frame's own contents; the
            // layout has one axis per graph, so this is not drawable here.
            return false
        case "classDef":
            return defineClass(rest)
        case "class":
            return applyClass(rest)
        case "style":
            return applyStyle(rest)
        case "click", "linkStyle":
            return false
        default:
            return parseStatement(line)
        }
    }

    /// `subgraph one[First step]`, `subgraph one` or a bare title.
    private func title(ofSubgraph text: String) -> String {
        guard let open = text.firstIndex(of: "["), text.hasSuffix("]") else {
            return text.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        return inner.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    private mutating func defineClass(_ rest: String) -> Bool {
        let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let style = Flowchart.style(from: String(parts[1])) else {
            return false
        }
        for name in parts[0].split(separator: ",") {
            classes[name.trimmingCharacters(in: .whitespaces)] = style
        }
        return true
    }

    private mutating func applyClass(_ rest: String) -> Bool {
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, let style = classes[String(parts[1])] else { return false }
        for name in parts[0].split(separator: ",") {
            let id = name.trimmingCharacters(in: .whitespaces)
            guard let index = nodes.firstIndex(where: { $0.id == id }) else { return false }
            nodes[index].style.merge(style)
        }
        return true
    }

    private mutating func applyStyle(_ rest: String) -> Bool {
        let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let style = Flowchart.style(from: String(parts[1])),
            let index = nodes.firstIndex(where: { $0.id == String(parts[0]) })
        else { return false }
        nodes[index].style.merge(style)
        return true
    }

    /// `fill:#f9f,stroke:#333,stroke-width:2px,color:#fff`. A property this
    /// cannot draw fails the whole diagram, because a node drawn without the
    /// colour the author gave it is a node the author did not write.
    static func style(from text: String) -> Style? {
        var style = Style()
        for declaration in text.split(separator: ",") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value = String(value.dropLast()) }
            switch key {
            case "fill":
                guard let colour = Colour(css: value) else { return nil }
                style.fill = colour
            case "stroke":
                guard let colour = Colour(css: value) else { return nil }
                style.stroke = colour
            case "color":
                guard let colour = Colour(css: value) else { return nil }
                style.text = colour
            case "stroke-width":
                let number = value.prefix(while: { $0.isNumber || $0 == "." })
                guard let width = Double(number), width > 0 else { return nil }
                style.strokeWidth = width
            default:
                return nil
            }
        }
        return style.isEmpty ? nil : style
    }

    /// One line: a node, or a chain of nodes joined by edges.
    private mutating func parseStatement(_ line: Substring) -> Bool {
        var reader = Reader(Array(line))
        guard var left = reader.readNode(into: &self) else { return false }
        while true {
            reader.skipSpaces()
            if reader.atEnd { return true }
            // A statement may end in `;`, and nothing may follow it.
            if reader.peek() == ";" {
                reader.advance()
                reader.skipSpaces()
                return reader.atEnd
            }
            guard let link = reader.readLink() else { return false }
            guard let right = reader.readNode(into: &self) else { return false }
            edges.append(
                Edge(
                    from: left, to: right, label: link.label, stroke: link.stroke,
                    arrow: link.arrow))
            left = right
        }
    }

    private mutating func node(id: String, label: String?, shape: Shape?, class name: String?)
        -> Int?
    {
        var index: Int
        if let existing = nodes.firstIndex(where: { $0.id == id }) {
            // A later mention may be the one that gives the node its shape and
            // its words: `A --> B` then `B[Done]`.
            if let label { nodes[existing].label = label }
            if let shape { nodes[existing].shape = shape }
            index = existing
        } else {
            nodes.append(Node(id: id, label: label ?? id, shape: shape ?? .rectangle))
            index = nodes.count - 1
            // A node belongs to the frame it was first written in.
            if let group = openGroup { groups[group].members.append(index) }
        }
        if let name {
            guard let style = classes[name] else { return nil }
            nodes[index].style.merge(style)
        }
        return index
    }

    private struct Reader {
        let chars: [Character]
        var index = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { index >= chars.count }
        func peek(_ offset: Int = 0) -> Character? {
            index + offset < chars.count ? chars[index + offset] : nil
        }
        mutating func advance(_ count: Int = 1) { index += count }

        mutating func skipSpaces() {
            while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        }

        mutating func readNode(into chart: inout Flowchart) -> Int? {
            skipSpaces()
            var id = ""
            while let char = peek(), char.isLetter || char.isNumber || char == "_" || char == "-",
                !(char == "-" && (peek(1) == "-" || peek(1) == ">" || peek(1) == "."))
            {
                id.append(char)
                advance()
            }
            guard !id.isEmpty else { return nil }
            var label: String?
            var shape: Shape?
            // `[/…/]` and `[/…\]` open the same way and close differently, so a
            // candidate that does not close is put back rather than failing the
            // whole diagram.
            for opening in openings where starts(with: opening.open) {
                let mark = index
                advance(opening.open.count)
                if let text = readLabel(until: opening.close) {
                    label = text
                    shape = opening.shape
                    break
                }
                index = mark
            }
            // `A:::warning` names a class defined by `classDef`.
            var className: String?
            if starts(with: [":", ":", ":"]) {
                advance(3)
                var name = ""
                while let char = peek(), char.isLetter || char.isNumber || char == "_" {
                    name.append(char)
                    advance()
                }
                guard !name.isEmpty else { return nil }
                className = name
            }
            return chart.node(id: id, label: label, shape: shape, class: className)
        }

        /// Longest spelling first: `([` is a stadium, `(` alone is a rounded box.
        private var openings: [(open: [Character], close: [Character], shape: Shape)] {
            [
                (["(", "(", "("], [")", ")", ")"], .doubleCircle),
                (["{", "{"], ["}", "}"], .hexagon),
                (["[", "/"], ["\\", "]"], .trapezoid),
                (["[", "\\"], ["/", "]"], .trapezoidAlt),
                (["[", "/"], ["/", "]"], .parallelogram),
                (["[", "\\"], ["\\", "]"], .parallelogramAlt),
                (["[", "("], [")", "]"], .cylinder),
                (["(", "["], ["]", ")"], .stadium),
                (["[", "["], ["]", "]"], .subroutine),
                (["(", "("], [")", ")"], .circle),
                ([">"], ["]"], .flag),
                (["["], ["]"], .rectangle),
                (["("], [")"], .rounded),
                (["{"], ["}"], .diamond),
            ]
        }

        private func starts(with prefix: [Character]) -> Bool {
            guard index + prefix.count <= chars.count else { return false }
            for (offset, char) in prefix.enumerated() where chars[index + offset] != char {
                return false
            }
            return true
        }

        private mutating func readLabel(until closing: [Character]) -> String? {
            var text = ""
            while index < chars.count {
                if starts(with: closing) {
                    advance(closing.count)
                    return unquoted(text)
                }
                text.append(chars[index])
                advance()
            }
            return nil
        }

        /// `-->`, `---`, `==>`, `-.->`, either labelled after the arrow with
        /// `|text|` or inside it as `-- text -->`.
        mutating func readLink() -> (label: String, stroke: Stroke, arrow: Bool)? {
            let spellings: [(text: [Character], stroke: Stroke, arrow: Bool)] = [
                (["-", ".", "-", ">"], .dotted, true),
                (["-", ".", "-"], .dotted, false),
                (["=", "=", ">"], .thick, true),
                (["=", "=", "="], .thick, false),
                (["-", "-", ">"], .solid, true),
                (["-", "-", "-"], .solid, false),
            ]
            guard let spelling = spellings.first(where: { starts(with: $0.text) }) else {
                return readLabelledLink()
            }
            advance(spelling.text.count)
            // A trailing `-` or `=` only makes the line longer: `---->` is `-->`.
            while let char = peek(), char == "-" || char == "=" { advance() }
            var label = ""
            if peek() == "|" {
                advance()
                guard let text = readLabel(until: ["|"]) else { return nil }
                label = text
            }
            return (label, spelling.stroke, spelling.arrow)
        }

        /// `-- text -->` and its dotted and thick cousins: the words are written
        /// inside the arrow rather than after it.
        private mutating func readLabelledLink() -> (label: String, stroke: Stroke, arrow: Bool)? {
            let forms:
                [(open: [Character], closes: [(text: [Character], stroke: Stroke, arrow: Bool)])] =
                    [
                        (
                            ["-", "-"],
                            [(["-", "-", ">"], .solid, true), (["-", "-", "-"], .solid, false)]
                        ),
                        (
                            ["-", "."],
                            [([".", "-", ">"], .dotted, true), ([".", "-"], .dotted, false)]
                        ),
                        (
                            ["=", "="],
                            [(["=", "=", ">"], .thick, true), (["=", "=", "="], .thick, false)]
                        ),
                    ]
            guard let form = forms.first(where: { starts(with: $0.open) }) else { return nil }
            advance(form.open.count)
            var label = ""
            while index < chars.count {
                if let close = form.closes.first(where: { starts(with: $0.text) }) {
                    advance(close.text.count)
                    while let char = peek(), char == "-" || char == "=" { advance() }
                    return (unquoted(label), close.stroke, close.arrow)
                }
                label.append(chars[index])
                advance()
            }
            return nil
        }

        private func unquoted(_ text: String) -> String {
            var trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
                trimmed = String(trimmed.dropFirst().dropLast())
            }
            return trimmed.replacingOccurrences(of: "<br/>", with: " ")
                .replacingOccurrences(of: "<br>", with: " ")
        }
    }
}

extension Flowchart.Colour {
    /// `#f9f`, `#ff99ff` or one of the colour names people actually type. A
    /// spelling this does not know fails the diagram rather than picking one.
    init?(css text: String) {
        if text.hasPrefix("#") {
            let digits = Array(text.dropFirst())
            let channels: [Double]
            switch digits.count {
            case 3:
                channels = digits.compactMap { $0.hexDigit.map { Double($0 * 17) / 255 } }
            case 6:
                channels = stride(from: 0, to: 6, by: 2).compactMap { offset -> Double? in
                    guard let high = digits[offset].hexDigit, let low = digits[offset + 1].hexDigit
                    else { return nil }
                    return Double(high * 16 + low) / 255
                }
            default:
                return nil
            }
            guard channels.count == 3 else { return nil }
            self.init(red: channels[0], green: channels[1], blue: channels[2])
            return
        }
        guard let named = Flowchart.Colour.names[text.lowercased()] else { return nil }
        self = named
    }

    private static let names: [String: Flowchart.Colour] = [
        "black": Flowchart.Colour(red: 0, green: 0, blue: 0),
        "white": Flowchart.Colour(red: 1, green: 1, blue: 1),
        "red": Flowchart.Colour(red: 1, green: 0, blue: 0),
        "green": Flowchart.Colour(red: 0, green: 0.5, blue: 0),
        "blue": Flowchart.Colour(red: 0, green: 0, blue: 1),
        "yellow": Flowchart.Colour(red: 1, green: 1, blue: 0),
        "orange": Flowchart.Colour(red: 1, green: 0.65, blue: 0),
        "purple": Flowchart.Colour(red: 0.5, green: 0, blue: 0.5),
        "pink": Flowchart.Colour(red: 1, green: 0.75, blue: 0.8),
        "cyan": Flowchart.Colour(red: 0, green: 1, blue: 1),
        "magenta": Flowchart.Colour(red: 1, green: 0, blue: 1),
        "grey": Flowchart.Colour(red: 0.5, green: 0.5, blue: 0.5),
        "gray": Flowchart.Colour(red: 0.5, green: 0.5, blue: 0.5),
        "lightgrey": Flowchart.Colour(red: 0.83, green: 0.83, blue: 0.83),
        "lightgray": Flowchart.Colour(red: 0.83, green: 0.83, blue: 0.83),
        "transparent": Flowchart.Colour(red: -1, green: -1, blue: -1),
    ]

    /// `fill:transparent` is the one colour that is not a colour.
    var isTransparent: Bool { red < 0 }
}

extension Character {
    fileprivate var hexDigit: Int? { hexDigitValue }
}

// MARK: - Sequence diagram

struct SequenceDiagram {
    struct Participant {
        var id: String
        var label: String
    }

    /// What the point of an arrow looks like: a filled head, a cross for a
    /// message that fails, an open head for one nobody waits for.
    enum Head {
        case arrow
        case cross
        case open
    }

    struct Message {
        var from: Int
        var to: Int
        var text: String
        /// `-->>` is a reply, drawn as a dashed line.
        var dashed: Bool
        var head: Head = .arrow
        /// `->>+` turns the bar on at the far end, `->>-` turns it off here.
        var activates = false
        var deactivates = false
    }

    struct Note {
        enum Placement {
            case leftOf
            case rightOf
            case over
        }

        var placement: Placement
        var participants: [Int]
        var text: String
    }

    /// A `loop`, an `alt` with its `else` arms, an `opt`, a `par`. Each arm is a
    /// section with its own title and its own contents.
    struct Block {
        var kind: String
        var sections: [Section]
    }

    struct Section {
        var title: String
        var items: [Item]
    }

    indirect enum Item {
        case message(Message)
        case note(Note)
        case block(Block)
        case activate(Int)
        case deactivate(Int)
    }

    var participants: [Participant]
    var items: [Item]
    var autonumber = false

    /// Every message in the diagram, whatever it is nested inside. Handy for
    /// tests and for deciding whether there is a diagram at all.
    var messages: [Message] {
        SequenceDiagram.messages(in: items)
    }

    private static func messages(in items: [Item]) -> [Message] {
        items.flatMap { item -> [Message] in
            switch item {
            case .message(let message): return [message]
            case .block(let block): return block.sections.flatMap { messages(in: $0.items) }
            case .note, .activate, .deactivate: return []
            }
        }
    }

    /// The names that open a block, and whether they may be split by `else`.
    private static let openers = ["loop", "alt", "opt", "par", "critical", "break"]
    private static let dividers = ["else", "and", "option"]

    static func parse(_ lines: [Substring]) -> SequenceDiagram? {
        var diagram = SequenceDiagram(participants: [], items: [])
        // A stack of half-built blocks: the innermost is what a message joins.
        var stack: [Block] = []
        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if word == "participant" || word == "actor" {
                guard diagram.declare(line.dropFirst(word.count)) else { return nil }
                continue
            }
            if word == "autonumber" {
                diagram.autonumber = true
                continue
            }
            if openers.contains(word) {
                stack.append(Block(kind: word, sections: [Section(title: rest, items: [])]))
                continue
            }
            if dividers.contains(word) {
                guard !stack.isEmpty else { return nil }
                stack[stack.count - 1].sections.append(Section(title: rest, items: []))
                continue
            }
            if word == "end" {
                guard let block = stack.popLast(), rest.isEmpty else { return nil }
                diagram.append(.block(block), to: &stack)
                continue
            }
            if word == "activate" || word == "deactivate" {
                guard !rest.isEmpty else { return nil }
                let index = diagram.index(of: rest, label: rest)
                diagram.append(
                    word == "activate" ? .activate(index) : .deactivate(index), to: &stack)
                continue
            }
            if word.lowercased() == "note" {
                guard let note = diagram.note(rest) else { return nil }
                diagram.append(.note(note), to: &stack)
                continue
            }
            // A `rect` tints the page behind a run of messages, and a `box`
            // frames participants; neither is drawn here, so neither is read.
            guard !["rect", "box"].contains(word) else { return nil }
            guard let message = diagram.message(line) else { return nil }
            diagram.append(.message(message), to: &stack)
        }
        guard stack.isEmpty, !diagram.messages.isEmpty else { return nil }
        return diagram
    }

    /// Items land in the innermost open block, or in the diagram itself.
    private mutating func append(_ item: Item, to stack: inout [Block]) {
        if stack.isEmpty {
            items.append(item)
            return
        }
        var block = stack.removeLast()
        block.sections[block.sections.count - 1].items.append(item)
        stack.append(block)
    }

    /// `Note over A,B: text`, `Note left of A: text`.
    private mutating func note(_ rest: String) -> Note? {
        let placements: [(prefix: String, placement: Note.Placement)] = [
            ("left of ", .leftOf), ("right of ", .rightOf), ("over ", .over),
        ]
        guard let match = placements.first(where: { rest.hasPrefix($0.prefix) }) else { return nil }
        let body = rest.dropFirst(match.prefix.count)
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let names = body[body.startIndex..<colon].split(separator: ",")
        let text = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        var indices: [Int] = []
        for name in names {
            let id = name.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { return nil }
            indices.append(index(of: id, label: id))
        }
        guard !indices.isEmpty, !text.isEmpty else { return nil }
        return Note(placement: match.placement, participants: indices, text: text)
    }

    private mutating func declare(_ rest: Substring) -> Bool {
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        if let range = text.range(of: " as ") {
            let id = String(text[text.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let label = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            _ = index(of: id, label: label)
            return true
        }
        _ = index(of: text, label: text)
        return true
    }

    private mutating func message(_ line: Substring) -> Message? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = line[line.startIndex..<colon]
        let text = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // Longest arrow first, or `-->>` is read as `-->` with a stray `>`.
        let arrows: [(text: String, head: Head)] = [
            ("-->>", .arrow), ("--x", .cross), ("--)", .open), ("-->", .arrow),
            ("->>", .arrow), ("-x", .cross), ("-)", .open), ("->", .arrow),
        ]
        for arrow in arrows {
            guard let range = head.range(of: arrow.text) else { continue }
            let from = String(head[head.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            var to = String(head[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            // `->>+B` turns the bar on at B, `->>-B` turns it off.
            var activates = false
            var deactivates = false
            if to.hasPrefix("+") {
                activates = true
                to.removeFirst()
            } else if to.hasPrefix("-") {
                deactivates = true
                to.removeFirst()
            }
            to = to.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { return nil }
            return Message(
                from: index(of: from, label: from),
                to: index(of: to, label: to),
                text: text,
                dashed: arrow.text.hasPrefix("--"),
                head: arrow.head,
                activates: activates,
                deactivates: deactivates
            )
        }
        return nil
    }

    private mutating func index(of id: String, label: String) -> Int {
        if let existing = participants.firstIndex(where: { $0.id == id }) {
            return existing
        }
        participants.append(Participant(id: id, label: label))
        return participants.count - 1
    }
}
