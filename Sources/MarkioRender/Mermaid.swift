import Foundation

/// A Mermaid diagram, read from a ```mermaid fence.
///
/// The subset is the two diagrams that fill READMEs: a flowchart and a sequence
/// diagram. Everything else — and every construct inside those two that this
/// does not draw — makes `parse` return nil, and the fence is shown as source,
/// which is what happened before this existed. A diagram that is drawn is drawn
/// completely or not at all; there is no "most of your graph".
enum MermaidDiagram {
    case flowchart(Flowchart)
    case sequence(SequenceDiagram)

    static func parse(_ source: String) -> MermaidDiagram? {
        var lines: [Substring] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // `%%` is a Mermaid comment, and a blank line means nothing here.
            guard !line.isEmpty, !line.hasPrefix("%%") else { continue }
            lines.append(Substring(line))
        }
        guard let header = lines.first else { return nil }
        if header == "sequenceDiagram" {
            return SequenceDiagram.parse(Array(lines.dropFirst())).map(MermaidDiagram.sequence)
        }
        guard let direction = Flowchart.direction(header: header) else { return nil }
        return Flowchart.parse(Array(lines.dropFirst()), direction: direction)
            .map(MermaidDiagram.flowchart)
    }
}

// MARK: - Flowchart

struct Flowchart {
    /// Only the two directions people actually draw. `BT` and `RL` would need
    /// the edges routed the other way round, and a graph drawn in the wrong
    /// direction is worse than one shown as source.
    enum Direction {
        case down
        case right
    }

    enum Shape {
        case rectangle
        case rounded
        case stadium
        case diamond
        case circle
    }

    enum Stroke {
        case solid
        case thick
        case dotted
    }

    struct Node {
        var id: String
        var label: String
        var shape: Shape
    }

    struct Edge {
        var from: Int
        var to: Int
        var label: String
        var stroke: Stroke
        /// `---` joins without an arrowhead; `-->` points.
        var arrow: Bool
    }

    var direction: Direction
    var nodes: [Node]
    var edges: [Edge]

    static func direction(header: Substring) -> Direction? {
        let words = header.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = words.first, first == "flowchart" || first == "graph" else { return nil }
        switch words.count == 2 ? words[1] : "TD" {
        case "TD", "TB": return .down
        case "LR": return .right
        default: return nil
        }
    }

    static func parse(_ lines: [Substring], direction: Direction) -> Flowchart? {
        var chart = Flowchart(direction: direction, nodes: [], edges: [])
        for line in lines {
            // Subgraphs, styling and click handlers each change what the picture
            // means; drawing the graph without them would be a different graph.
            let word = line.prefix(while: { !$0.isWhitespace })
            guard
                !["subgraph", "end", "style", "classDef", "class", "click", "linkStyle"]
                    .contains(String(word))
            else { return nil }
            guard chart.parseStatement(line) else { return nil }
        }
        guard !chart.nodes.isEmpty else { return nil }
        return chart
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

    private mutating func node(id: String, label: String?, shape: Shape?) -> Int {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            // A later mention may be the one that gives the node its shape and
            // its words: `A --> B` then `B[Done]`.
            if let label { nodes[index].label = label }
            if let shape { nodes[index].shape = shape }
            return index
        }
        nodes.append(Node(id: id, label: label ?? id, shape: shape ?? .rectangle))
        return nodes.count - 1
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
            guard let opening = openings.first(where: { starts(with: $0.open) }) else {
                return chart.node(id: id, label: nil, shape: nil)
            }
            advance(opening.open.count)
            guard let label = readLabel(until: opening.close) else { return nil }
            return chart.node(id: id, label: label, shape: opening.shape)
        }

        /// Longest spelling first: `([` is a stadium, `(` alone is a rounded box.
        private var openings: [(open: [Character], close: [Character], shape: Shape)] {
            [
                (["(", "["], ["]", ")"], .stadium),
                (["[", "["], ["]", "]"], .rectangle),
                (["[", "("], [")", "]"], .rounded),
                (["(", "("], [")", ")"], .circle),
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

        /// `-->`, `---`, `==>`, `-.->` and their labelled forms.
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
                return nil
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

// MARK: - Sequence diagram

struct SequenceDiagram {
    struct Participant {
        var id: String
        var label: String
    }

    struct Message {
        var from: Int
        var to: Int
        var text: String
        /// `-->>` is a reply, drawn as a dashed line.
        var dashed: Bool
    }

    var participants: [Participant]
    var messages: [Message]

    static func parse(_ lines: [Substring]) -> SequenceDiagram? {
        var diagram = SequenceDiagram(participants: [], messages: [])
        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            if word == "participant" || word == "actor" {
                guard diagram.declare(line.dropFirst(word.count)) else { return nil }
                continue
            }
            // Loops, alternatives, notes and activation bars all draw boxes
            // around messages; without them the picture says something else.
            guard
                ![
                    "loop", "alt", "else", "opt", "par", "and", "end", "Note", "note", "rect",
                    "activate", "deactivate", "autonumber", "box", "critical", "break",
                ]
                .contains(word)
            else { return nil }
            guard diagram.message(line) else { return nil }
        }
        guard !diagram.messages.isEmpty else { return nil }
        return diagram
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

    private mutating func message(_ line: Substring) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let head = line[line.startIndex..<colon]
        let text = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // Longest arrow first, or `-->>` is read as `-->` with a stray `>`.
        for arrow in ["-->>", "->>", "-->", "->", "--x", "-x"] {
            guard let range = head.range(of: arrow) else { continue }
            let from = String(head[head.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let to = String(head[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { return false }
            messages.append(
                Message(
                    from: index(of: from, label: from),
                    to: index(of: to, label: to),
                    text: text,
                    dashed: arrow.hasPrefix("--")
                )
            )
            return true
        }
        return false
    }

    private mutating func index(of id: String, label: String) -> Int {
        if let existing = participants.firstIndex(where: { $0.id == id }) {
            return existing
        }
        participants.append(Participant(id: id, label: label))
        return participants.count - 1
    }
}
