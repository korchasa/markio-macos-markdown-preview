import Foundation

/// A mindmap: a tree written by indentation.
///
/// The shape of a node is the brackets around its words, exactly as a flowchart
/// spells them, so the two readers agree on what `((…))` means.
struct Mindmap {
    struct Node {
        /// What the node is called in the source, which is how a `class` line
        /// names it. A node written as bare words is named by those words.
        var id: String
        var label: String
        var shape: Flowchart.Shape
        var children: [Int]
        var depth: Int
        var style = Flowchart.Style()
    }

    /// Flat, with children by index — the same trick the block tree uses, and
    /// for the same reason: a tree of values would copy on every append.
    var nodes: [Node]

    static func parse(_ lines: [(indent: Int, text: Substring)]) -> Mindmap? {
        var map = Mindmap(nodes: [])
        // Each open ancestor, with the indent it was written at.
        var stack: [(indent: Int, index: Int)] = []
        /// The styles `classDef` named, waiting for a `class` to use them.
        var styles: [String: Flowchart.Style] = [:]
        for line in lines {
            let word = line.text.prefix(while: { !$0.isWhitespace })
            let rest = line.text.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if word == "classDef" {
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2, let style = Flowchart.style(from: String(parts[1]))
                else { return nil }
                for name in parts[0].split(separator: ",") {
                    styles[name.trimmingCharacters(in: .whitespaces)] = style
                }
                continue
            }
            if word == "class" {
                let parts = rest.split(separator: " ", omittingEmptySubsequences: true)
                // A style nobody defined and a node nobody wrote both leave the
                // line with nothing to paint, which is what Mermaid makes of it.
                guard parts.count == 2 else { return nil }
                guard let style = styles[String(parts[1])] else { continue }
                for name in parts[0].split(separator: ",") {
                    let id = name.trimmingCharacters(in: .whitespaces)
                    guard let index = map.nodes.firstIndex(where: { $0.id == id }) else {
                        continue
                    }
                    map.nodes[index].style.merge(style)
                }
                continue
            }
            // `::icon(fa fa-book)` asks for a glyph out of a font that has to be
            // fetched, and Mermaid draws nothing for it on a page that has not
            // already loaded that font — which is every page here. So the line
            // belongs to the node above it and adds nothing to the picture.
            if line.text.hasPrefix("::icon("), line.text.hasSuffix(")") {
                // It has to stand under a node, like anything else indented.
                guard !stack.isEmpty else { return nil }
                continue
            }
            guard !line.text.hasPrefix("::") else { return nil }
            guard let read = node(line.text) else { return nil }
            while let last = stack.last, last.indent >= line.indent { stack.removeLast() }
            // Two roots would be two mindmaps.
            guard !stack.isEmpty || map.nodes.isEmpty else { return nil }
            map.nodes.append(
                Node(
                    id: read.id, label: read.label, shape: read.shape, children: [],
                    depth: stack.count))
            let index = map.nodes.count - 1
            if let parent = stack.last { map.nodes[parent.index].children.append(index) }
            stack.append((line.indent, index))
        }
        guard !map.nodes.isEmpty else { return nil }
        return map
    }

    /// `Root`, `root((Root))`, `id[Square]`, `id{{Hexagon}}`, `id))Bang((` and
    /// `id)Cloud(`. The longer brackets are tried first so `))` is never read as
    /// two of `)`.
    private static func node(_ text: Substring)
        -> (id: String, label: String, shape: Flowchart.Shape)?
    {
        let brackets: [(open: String, close: String, shape: Flowchart.Shape)] = [
            ("((", "))", .circle), ("{{", "}}", .hexagon), ("))", "((", .bang),
            (")", "(", .cloud), ("(", ")", .rounded), ("[", "]", .rectangle),
        ]
        for bracket in brackets {
            guard let open = text.range(of: bracket.open), text.hasSuffix(bracket.close),
                open.upperBound <= text.index(text.endIndex, offsetBy: -bracket.close.count)
            else { continue }
            let inner = text[
                open.upperBound..<text.index(text.endIndex, offsetBy: -bracket.close.count)]
            let label = inner.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let id = text[text.startIndex..<open.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { return nil }
            return (id.isEmpty ? label : id, label, bracket.shape)
        }
        guard !text.contains(")"), !text.contains("("), !text.contains("]") else { return nil }
        let label = text.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (label, label, .rounded)
    }
}

/// A timeline: periods along a line, each with the things that happened in it.
struct Timeline {
    struct Period {
        var title: String
        var events: [String]
        /// Which section it belongs to, or nil when the timeline has none.
        var section: Int?
    }

    var title: String
    var sections: [String]
    var periods: [Period]

    static func parse(_ lines: [Substring]) -> Timeline? {
        var timeline = Timeline(title: "", sections: [], periods: [])
        var section: Int?
        for line in lines {
            // A keyword on its own is a half-written line, not a period whose
            // name happens to be `section`.
            guard line != "section", line != "title" else { return nil }
            if line.hasPrefix("title ") {
                timeline.title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("section ") {
                let name = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                timeline.sections.append(name)
                section = timeline.sections.count - 1
                continue
            }
            // `: another event` continues the period written above it.
            if line.hasPrefix(":") {
                guard !timeline.periods.isEmpty else { return nil }
                let event = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard !event.isEmpty else { return nil }
                timeline.periods[timeline.periods.count - 1].events.append(event)
                continue
            }
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let head = parts.first, !head.isEmpty else { return nil }
            let events = parts.dropFirst().filter { !$0.isEmpty }
            timeline.periods.append(
                Period(title: head, events: Array(events), section: section))
        }
        guard !timeline.periods.isEmpty else { return nil }
        return timeline
    }
}
