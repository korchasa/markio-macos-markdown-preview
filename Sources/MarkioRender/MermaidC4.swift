import Foundation

/// A C4 diagram, read into a flowchart.
///
/// It needs no layout of its own: a C4 element is a labelled box, a boundary is
/// a frame around the boxes inside it, and a relation is an arrow with words on
/// it — all three are things a flowchart already draws. What C4 adds is which
/// box gets which shape, and that the kind and the description are written
/// under the name rather than beside it.
enum C4Diagram {
    static let headers: Set<String> = [
        "C4Context", "C4Container", "C4Component", "C4Dynamic", "C4Deployment",
    ]

    /// Every element keyword, with the shape its box takes.
    private static let elements: [String: Flowchart.Shape] = [
        "Person": .stadium, "Person_Ext": .stadium,
        "System": .rectangle, "System_Ext": .rectangle,
        "SystemDb": .cylinder, "SystemDb_Ext": .cylinder,
        "SystemQueue": .subroutine, "SystemQueue_Ext": .subroutine,
        "Container": .rectangle, "Container_Ext": .rectangle,
        "ContainerDb": .cylinder, "ContainerDb_Ext": .cylinder,
        "ContainerQueue": .subroutine, "ContainerQueue_Ext": .subroutine,
        "Component": .rounded, "Component_Ext": .rounded,
        "Node": .rectangle, "Node_L": .rectangle, "Node_R": .rectangle,
        "Deployment_Node": .rectangle,
    ]
    private static let boundaries: Set<String> = [
        "Enterprise_Boundary", "System_Boundary", "Container_Boundary", "Boundary",
        "Node_Boundary",
    ]
    /// The direction suffixes are a hint about where Mermaid should put the
    /// arrow, and this ranks its own graph, so they read as plain relations.
    private static let relations: Set<String> = [
        "Rel", "Rel_U", "Rel_D", "Rel_L", "Rel_R", "Rel_Up", "Rel_Down", "Rel_Left",
        "Rel_Right", "Rel_Back",
    ]

    /// Something outside the system under discussion, drawn paler than the rest.
    private static let outside = Flowchart.Colour(red: 0.90, green: 0.90, blue: 0.92)

    static func parse(_ lines: [Substring]) -> Flowchart? {
        var chart = Flowchart(direction: .down, nodes: [], edges: [], groups: [])
        var identifiers: [String: Int] = [:]
        // The boundary each open brace belongs to, so `}` closes the right one.
        var open: [Int] = []

        func index(of identifier: String) -> Int {
            if let existing = identifiers[identifier] { return existing }
            chart.nodes.append(
                Flowchart.Node(
                    id: identifier, label: identifier, shape: .rectangle, style: Flowchart.Style()))
            identifiers[identifier] = chart.nodes.count - 1
            return chart.nodes.count - 1
        }

        for line in lines {
            if line == "}" {
                guard !open.isEmpty else { return nil }
                open.removeLast()
                continue
            }
            if line.hasPrefix("title ") { continue }
            // `UpdateElementStyle` and friends restyle a diagram that is already
            // drawn, which is not something this reads.
            guard !line.hasPrefix("Update") else { return nil }

            let keyword = String(line.prefix(while: { $0 != "(" && !$0.isWhitespace }))
            guard let arguments = arguments(of: line, after: keyword) else { return nil }

            if boundaries.contains(keyword) {
                guard arguments.count >= 2, line.hasSuffix("{") else { return nil }
                chart.groups.append(Flowchart.Group(title: arguments[1], members: []))
                open.append(chart.groups.count - 1)
                continue
            }
            if let shape = elements[keyword] {
                guard arguments.count >= 2 else { return nil }
                let node = index(of: arguments[0])
                // The kind, the name and what it does, one under the other.
                var label = "«\(keyword.replacingOccurrences(of: "_Ext", with: ""))»<br/>"
                label += arguments[1]
                if arguments.count > 2, !arguments[2].isEmpty {
                    label += "<br/>\(arguments[2])"
                }
                chart.nodes[node].label = label
                chart.nodes[node].shape = shape
                if keyword.hasSuffix("_Ext") { chart.nodes[node].style.fill = outside }
                if let group = open.last { chart.groups[group].members.append(node) }
                continue
            }
            if relations.contains(keyword) || keyword == "BiRel" {
                guard arguments.count >= 2 else { return nil }
                let backwards = keyword == "Rel_Back"
                let from = index(of: arguments[backwards ? 1 : 0])
                let to = index(of: arguments[backwards ? 0 : 1])
                let words = arguments.count > 2 ? arguments[2] : ""
                chart.edges.append(
                    Flowchart.Edge(
                        from: from, to: to, label: words, stroke: .solid, arrow: true))
                if keyword == "BiRel" {
                    chart.edges.append(
                        Flowchart.Edge(
                            from: to, to: from, label: "", stroke: .solid, arrow: true))
                }
                continue
            }
            return nil
        }
        guard open.isEmpty, !chart.nodes.isEmpty else { return nil }
        return chart
    }

    /// The comma-separated arguments inside `Keyword(…)`, quotes removed.
    private static func arguments(of line: Substring, after keyword: String) -> [String]? {
        var rest = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("(") else { return nil }
        guard let close = rest.lastIndex(of: ")") else { return nil }
        rest = String(rest[rest.index(after: rest.startIndex)..<close])
        var arguments: [String] = []
        var field = ""
        var quoted = false
        for character in rest {
            if character == "\"" {
                quoted.toggle()
            } else if character == "," && !quoted {
                arguments.append(field.trimmingCharacters(in: .whitespaces))
                field = ""
            } else {
                field.append(character)
            }
        }
        guard !quoted else { return nil }
        arguments.append(field.trimmingCharacters(in: .whitespaces))
        // `$tags="v1.0"` and the other named arguments describe styling this
        // does not draw, so they are dropped rather than shown as text.
        return arguments.filter { !$0.hasPrefix("$") }
    }
}

/// An architecture diagram: services in groups, joined at named sides.
struct ArchitectureDiagram {
    /// The five shapes Mermaid ships without an icon pack.
    enum Icon: String {
        case cloud, database, disk, internet, server
    }

    struct Service {
        var identifier: String
        var label: String
        var icon: Icon
        var group: Int?
        /// Where it sits on the grid, worked out from the edges.
        var column = 0
        var row = 0
    }

    struct Group {
        var identifier: String
        var label: String
        var icon: Icon
    }

    enum Side: String {
        case left = "L"
        case right = "R"
        case top = "T"
        case bottom = "B"
    }

    struct Edge {
        var from: Int
        var fromSide: Side
        var to: Int
        var toSide: Side
        var fromArrow: Bool
        var toArrow: Bool
    }

    var groups: [Group]
    var services: [Service]
    var edges: [Edge]

    static func parse(_ lines: [Substring]) -> ArchitectureDiagram? {
        var diagram = ArchitectureDiagram(groups: [], services: [], edges: [])
        for line in lines {
            let keyword = String(line.prefix(while: { !$0.isWhitespace && $0 != "(" }))
            if keyword == "group" || keyword == "service" {
                let rest = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
                guard let read = declaration(rest) else { return nil }
                if keyword == "group" {
                    // A group inside a group needs a frame inside a frame,
                    // which this layout has not got.
                    guard read.parent == nil else { return nil }
                    diagram.groups.append(
                        Group(identifier: read.identifier, label: read.label, icon: read.icon))
                } else {
                    var group: Int?
                    if let parent = read.parent {
                        guard
                            let found = diagram.groups.firstIndex(where: {
                                $0.identifier == parent
                            })
                        else { return nil }
                        group = found
                    }
                    diagram.services.append(
                        Service(
                            identifier: read.identifier, label: read.label, icon: read.icon,
                            group: group))
                }
                continue
            }
            // `db:L -- R:server`, `db:L --> R:server`, `db:T <-- B:server`
            guard let edge = edge(line, in: diagram) else { return nil }
            diagram.edges.append(edge)
        }
        guard !diagram.services.isEmpty, diagram.place() else { return nil }
        return diagram
    }

    private static func offset(_ side: Side) -> (column: Int, row: Int) {
        switch side {
        case .left: return (-1, 0)
        case .right: return (1, 0)
        // The renderer's rows grow downwards, so the top of a tile is the
        // smaller row number.
        case .top: return (0, -1)
        case .bottom: return (0, 1)
        }
    }

    private static func opposite(_ side: Side) -> Side {
        switch side {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    /// Works out where every service sits.
    ///
    /// In this language the sides are not decoration: `db:L -- R:server` says
    /// the server is to the left of the database. So the grid is read off the
    /// edges, and a source whose edges disagree with each other — two services
    /// sent to the same cell, or one sent to two — describes a picture that
    /// cannot be drawn, and is refused rather than drawn wrongly.
    private mutating func place() -> Bool {
        struct Cell: Hashable {
            var column: Int
            var row: Int
        }
        var links = [[(neighbour: Int, step: Cell)]](repeating: [], count: services.count)
        for edge in edges {
            let out = ArchitectureDiagram.offset(edge.fromSide)
            let back = ArchitectureDiagram.offset(edge.toSide)
            // Opposite sides mean the two sit side by side. Any other pair means
            // the second is over one and along one, which is why such an edge is
            // drawn with a bend in it.
            let step =
                edge.toSide == ArchitectureDiagram.opposite(edge.fromSide)
                ? Cell(column: out.column, row: out.row)
                : Cell(column: out.column - back.column, row: out.row - back.row)
            links[edge.from].append((edge.to, step))
            links[edge.to].append((edge.from, Cell(column: -step.column, row: -step.row)))
        }

        var cells = [Int: Cell]()
        var taken = [Cell: Int]()
        var nextRow = 0
        for start in services.indices where cells[start] == nil {
            let root = Cell(column: 0, row: nextRow)
            guard taken[root] == nil else { return false }
            cells[start] = root
            taken[root] = start
            var queue = [start]
            while let current = queue.popLast() {
                guard let here = cells[current] else { return false }
                for link in links[current] {
                    let spot = Cell(
                        column: here.column + link.step.column, row: here.row + link.step.row)
                    if let already = cells[link.neighbour] {
                        guard already == spot else { return false }
                        continue
                    }
                    guard taken[spot] == nil else { return false }
                    cells[link.neighbour] = spot
                    taken[spot] = link.neighbour
                    queue.append(link.neighbour)
                }
            }
            // A blank row between one connected picture and the next.
            nextRow = (cells.values.map(\.row).max() ?? nextRow) + 2
        }

        let leftmost = cells.values.map(\.column).min() ?? 0
        let topmost = cells.values.map(\.row).min() ?? 0
        for index in services.indices {
            guard let cell = cells[index] else { return false }
            services[index].column = cell.column - leftmost
            services[index].row = cell.row - topmost
        }
        // A frame is drawn around the block its members occupy, so a stranger
        // standing inside that block would look like a member.
        for group in groups.indices {
            let members = services.indices.filter { services[$0].group == group }
            guard let columns = extent(members, \.column), let rows = extent(members, \.row) else {
                continue
            }
            for other in services.indices where services[other].group != group {
                if columns.contains(services[other].column), rows.contains(services[other].row) {
                    return false
                }
            }
        }
        return true
    }

    private func extent(_ members: [Int], _ axis: KeyPath<Service, Int>) -> ClosedRange<Int>? {
        let values = members.map { services[$0][keyPath: axis] }
        guard let low = values.min(), let high = values.max() else { return nil }
        return low...high
    }

    /// `db(database)[Database] in api`
    private static func declaration(_ text: String)
        -> (identifier: String, label: String, icon: Icon, parent: String?)?
    {
        var body = text
        var parent: String?
        if let inside = body.range(of: " in ") {
            parent = String(body[inside.upperBound...]).trimmingCharacters(in: .whitespaces)
            body = String(body[body.startIndex..<inside.lowerBound])
        }
        let identifier = String(body.prefix(while: { $0 != "(" && $0 != "[" }))
            .trimmingCharacters(in: .whitespaces)
        guard !identifier.isEmpty else { return nil }
        var icon = Icon.server
        if let open = body.firstIndex(of: "("), let close = body.firstIndex(of: ")"), open < close {
            let name = String(body[body.index(after: open)..<close])
            // An icon from a pack has to be fetched, and this app fetches
            // nothing; only the five Mermaid ships are drawn.
            guard let known = Icon(rawValue: name) else { return nil }
            icon = known
        }
        var label = identifier
        if let open = body.firstIndex(of: "["), body.hasSuffix("]") {
            label = String(body[body.index(after: open)..<body.index(before: body.endIndex)])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard !label.isEmpty else { return nil }
        }
        return (identifier, label, icon, parent)
    }

    private static func edge(_ line: Substring, in diagram: ArchitectureDiagram) -> Edge? {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count == 3 else { return nil }
        let joint = String(words[1])
        guard joint.contains("--") else { return nil }
        let fromArrow = joint.hasPrefix("<")
        let toArrow = joint.hasSuffix(">")
        guard joint.trimmingCharacters(in: CharacterSet(charactersIn: "<>-")).isEmpty else {
            return nil
        }
        func anchor(_ text: Substring, sideFirst: Bool) -> (index: Int, side: Side)? {
            let parts = text.split(separator: ":")
            guard parts.count == 2 else { return nil }
            let name = String(sideFirst ? parts[1] : parts[0])
            let side = String(sideFirst ? parts[0] : parts[1])
            guard let index = diagram.services.firstIndex(where: { $0.identifier == name }),
                let read = Side(rawValue: side)
            else { return nil }
            return (index, read)
        }
        guard let start = anchor(words[0], sideFirst: false),
            let end = anchor(words[2], sideFirst: true)
        else { return nil }
        return Edge(
            from: start.index, fromSide: start.side, to: end.index, toSide: end.side,
            fromArrow: fromArrow, toArrow: toArrow)
    }
}
