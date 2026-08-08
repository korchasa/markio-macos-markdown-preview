import Foundation

/// A mindmap: a tree written by indentation.
///
/// The shape of a node is the brackets around its words, exactly as a flowchart
/// spells them, so the two readers agree on what `((…))` means.
struct Mindmap {
    struct Node {
        var label: String
        var shape: Flowchart.Shape
        var children: [Int]
        var depth: Int
    }

    /// Flat, with children by index — the same trick the block tree uses, and
    /// for the same reason: a tree of values would copy on every append.
    var nodes: [Node]

    static func parse(_ lines: [(indent: Int, text: Substring)]) -> Mindmap? {
        var map = Mindmap(nodes: [])
        // Each open ancestor, with the indent it was written at.
        var stack: [(indent: Int, index: Int)] = []
        for line in lines {
            // An icon or a class is decoration this does not draw.
            guard !line.text.hasPrefix("::"), !line.text.hasPrefix("class") else { return nil }
            guard let read = node(line.text) else { return nil }
            while let last = stack.last, last.indent >= line.indent { stack.removeLast() }
            // Two roots would be two mindmaps.
            guard !stack.isEmpty || map.nodes.isEmpty else { return nil }
            map.nodes.append(
                Node(label: read.label, shape: read.shape, children: [], depth: stack.count))
            let index = map.nodes.count - 1
            if let parent = stack.last { map.nodes[parent.index].children.append(index) }
            stack.append((line.indent, index))
        }
        guard !map.nodes.isEmpty else { return nil }
        return map
    }

    /// `Root`, `root((Root))`, `id[Square]`, `id{{Hexagon}}`.
    private static func node(_ text: Substring) -> (label: String, shape: Flowchart.Shape)? {
        let brackets: [(open: String, close: String, shape: Flowchart.Shape)] = [
            ("((", "))", .circle), ("{{", "}}", .hexagon), ("(", ")", .rounded),
            ("[", "]", .rectangle),
        ]
        for bracket in brackets {
            guard let open = text.range(of: bracket.open), text.hasSuffix(bracket.close),
                open.upperBound <= text.index(text.endIndex, offsetBy: -bracket.close.count)
            else { continue }
            let inner = text[
                open.upperBound..<text.index(text.endIndex, offsetBy: -bracket.close.count)]
            let label = inner.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard !label.isEmpty else { return nil }
            return (label, bracket.shape)
        }
        // A cloud or a bang needs a path this does not draw.
        guard !text.contains(")"), !text.contains("("), !text.contains("]") else { return nil }
        let label = text.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (label, .rounded)
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
