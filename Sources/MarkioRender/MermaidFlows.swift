import Foundation

/// A Sankey diagram: flows between nodes, drawn in proportion to what they
/// carry.
struct SankeyDiagram {
    struct Flow {
        var from: Int
        var to: Int
        var value: Double
    }

    var nodes: [String]
    var flows: [Flow]

    static func parse(_ lines: [Substring]) -> SankeyDiagram? {
        var diagram = SankeyDiagram(nodes: [], flows: [])
        for line in lines {
            guard let fields = csv(line), fields.count == 3 else { return nil }
            // A flow carrying nothing — written as a zero or as a word that is
            // no number — is a flow of no width, and Mermaid draws the two ends
            // it names all the same.
            let value = max(Double(fields[2]) ?? 0, 0)
            guard !fields[0].isEmpty, !fields[1].isEmpty, fields[0] != fields[1] else {
                return nil
            }
            diagram.flows.append(
                Flow(
                    from: diagram.index(of: fields[0]), to: diagram.index(of: fields[1]),
                    value: value))
        }
        guard !diagram.flows.isEmpty else { return nil }
        // A cycle would make the ranks meaningless and the ribbons cross back
        // over themselves, so a flow that returns to where it came from is not
        // drawn at all.
        guard !diagram.hasCycle else { return nil }
        return diagram
    }

    private mutating func index(of name: String) -> Int {
        if let existing = nodes.firstIndex(of: name) { return existing }
        nodes.append(name)
        return nodes.count - 1
    }

    private var hasCycle: Bool {
        var outgoing = [[Int]](repeating: [], count: nodes.count)
        for flow in flows { outgoing[flow.from].append(flow.to) }
        // 0 unseen, 1 on the current path, 2 finished.
        var mark = [Int](repeating: 0, count: nodes.count)
        func walk(_ node: Int) -> Bool {
            if mark[node] == 1 { return true }
            if mark[node] == 2 { return false }
            mark[node] = 1
            for next in outgoing[node] where walk(next) { return true }
            mark[node] = 2
            return false
        }
        return nodes.indices.contains { walk($0) }
    }

    /// One CSV row: bare fields, or quoted ones where `""` is a quote.
    private static func csv(_ line: Substring) -> [String]? {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if quoted {
                if character == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                fields.append(field.trimmingCharacters(in: .whitespaces))
                field = ""
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }
        guard !quoted else { return nil }
        fields.append(field.trimmingCharacters(in: .whitespaces))
        return fields
    }
}

/// A treemap: nested rectangles, each as big a share of its parent as its value
/// is of the parent's total.
struct Treemap {
    struct Node {
        var label: String
        /// A leaf's own number; a branch's is the sum of what it holds.
        var value: Double
        var children: [Int]
        var depth: Int
    }

    var nodes: [Node]

    static func parse(_ lines: [(indent: Int, text: Substring)]) -> Treemap? {
        var map = Treemap(nodes: [])
        var stack: [(indent: Int, index: Int)] = []
        var roots: [Int] = []
        for line in lines {
            var text = line.text
            var value: Double?
            if let colon = text.lastIndex(of: ":") {
                let number = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard let read = Double(number), read >= 0 else { return nil }
                value = read
                text = text[text.startIndex..<colon]
            }
            let label = text.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard !label.isEmpty else { return nil }
            while let last = stack.last, last.indent >= line.indent { stack.removeLast() }
            map.nodes.append(
                Node(label: label, value: value ?? 0, children: [], depth: stack.count))
            let index = map.nodes.count - 1
            if let parent = stack.last {
                // A branch may carry a number of its own, and what it holds is
                // the truer figure, so the sum below overwrites it.
                map.nodes[parent.index].children.append(index)
            } else {
                roots.append(index)
            }
            stack.append((line.indent, index))
        }
        guard !map.nodes.isEmpty else { return nil }
        // Sum upwards, deepest first, which the flat array already orders for
        // us: a child always sits after its parent.
        for index in map.nodes.indices.reversed() where !map.nodes[index].children.isEmpty {
            map.nodes[index].value = map.nodes[index].children.reduce(0) {
                $0 + map.nodes[$1].value
            }
        }
        // A map of nothing but zeroes has no area to divide; the labels are
        // still what the author wrote, which is what Mermaid draws for it.
        // Several roots are drawn as one map, so they are given a parent that
        // is never itself drawn.
        if roots.count > 1 {
            let total = roots.reduce(0.0) { $0 + map.nodes[$1].value }
            for index in map.nodes.indices { map.nodes[index].depth += 1 }
            map.nodes.insert(
                Node(label: "", value: total, children: [], depth: 0), at: 0)
            for index in map.nodes.indices.dropFirst() {
                map.nodes[index].children = map.nodes[index].children.map { $0 + 1 }
            }
            map.nodes[0].children = roots.map { $0 + 1 }
        }
        return map
    }
}
