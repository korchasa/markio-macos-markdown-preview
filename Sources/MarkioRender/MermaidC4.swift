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

    /// The diagram and the name its `title` line gave it, which is drawn above
    /// it like any other diagram's.
    static func parse(_ lines: [Substring]) -> (title: String, chart: Flowchart)? {
        var chart = Flowchart(direction: .down, nodes: [], edges: [], groups: [])
        var title = ""
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
            if line.hasPrefix("title ") {
                title = line.dropFirst("title ".count).trimmingCharacters(in: .whitespaces)
                continue
            }
            let keyword = String(line.prefix(while: { $0 != "(" && !$0.isWhitespace }))
            guard let (arguments, settings) = arguments(of: line, after: keyword),
                let painted = style(from: settings)
            else { return nil }

            // `UpdateRelStyle` and its siblings repaint what has already been
            // written, so they are applied to the diagram as it stands.
            if keyword.hasPrefix("Update") {
                guard restyle(keyword, arguments, painted, in: &chart, named: identifiers) else {
                    return nil
                }
                continue
            }
            // A deployment node is a box on its own and a frame when something
            // is written inside it, and the brace is what says which.
            if boundaries.contains(keyword) || (elements[keyword] != nil && line.hasSuffix("{")) {
                guard arguments.count >= 2, line.hasSuffix("{") else { return nil }
                var title = arguments[1]
                if elements[keyword] != nil, arguments.count > 2, !arguments[2].isEmpty {
                    title += "<br/>[\(arguments[2])]"
                }
                var group = Flowchart.Group(
                    title: title, members: [], id: arguments[0], parent: open.last)
                group.style.merge(painted)
                chart.groups.append(group)
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
                chart.nodes[node].style.merge(painted)
                if let group = open.last { chart.groups[group].members.append(node) }
                continue
            }
            if relations.contains(keyword) || keyword == "BiRel" {
                guard arguments.count >= 2 else { return nil }
                let backwards = keyword == "Rel_Back"
                let from = index(of: arguments[backwards ? 1 : 0])
                let to = index(of: arguments[backwards ? 0 : 1])
                let words = arguments.count > 2 ? arguments[2] : ""
                var edge = Flowchart.Edge(
                    from: from, to: to, label: words, stroke: .solid, arrow: true)
                edge.style.merge(painted)
                chart.edges.append(edge)
                if keyword == "BiRel" {
                    var back = Flowchart.Edge(
                        from: to, to: from, label: "", stroke: .solid, arrow: true)
                    back.style.merge(painted)
                    chart.edges.append(back)
                }
                continue
            }
            return nil
        }
        guard open.isEmpty, !chart.nodes.isEmpty else { return nil }
        return (title, chart)
    }

    /// The colours a line's `$key="value"` arguments ask for.
    ///
    /// A key that paints something is painted. The rest — where Mermaid nudges
    /// a word, how many shapes it packs into a row, the sprite it draws, the
    /// legend it writes, the tag or link it hangs off a box — is read and let
    /// go, for the same reason `Rel_U` is: this ranks and draws its own graph,
    /// so a hint about someone else's layout says nothing about this picture. A
    /// key nobody knows, or a colour that is no colour, is passed over the way
    /// Mermaid passes over it: it paints nothing, and the rest of the line is
    /// still read.
    private static func style(from settings: [String]) -> Flowchart.Style? {
        /// Which part of a thing each key paints, or nothing at all.
        enum Paint {
            case fill
            case text
            case border
            case ignored
        }
        let paints: [String: Paint] = [
            "$bgColor": .fill, "$fontColor": .text, "$borderColor": .border,
            "$textColor": .text, "$lineColor": .border,
            "$offsetX": .ignored, "$offsetY": .ignored,
            "$c4ShapeInRow": .ignored, "$c4BoundaryInRow": .ignored,
            "$shadowing": .ignored, "$sprite": .ignored, "$tags": .ignored, "$link": .ignored,
            "$legendText": .ignored, "$legendSprite": .ignored,
        ]
        var style = Flowchart.Style()
        for setting in settings {
            guard let equals = setting.firstIndex(of: "=") else { continue }
            let key = String(setting[setting.startIndex..<equals])
                .trimmingCharacters(in: .whitespaces)
            let value = String(setting[setting.index(after: equals)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard let paint = paints[key] else { continue }
            switch paint {
            case .ignored: continue
            case .fill:
                guard let colour = Flowchart.Colour(css: value) else { continue }
                style.fill = colour
            case .text:
                guard let colour = Flowchart.Colour(css: value) else { continue }
                style.text = colour
            case .border:
                guard let colour = Flowchart.Colour(css: value) else { continue }
                style.stroke = colour
            }
        }
        return style
    }

    /// The `Update…` lines a C4 author writes under the diagram to repaint it.
    ///
    /// `UpdateElementStyle`, `UpdateBoundaryStyle` and `UpdateRelStyle` name
    /// something already written and give it colours; `UpdateLayoutConfig` says
    /// how many shapes Mermaid should pack into a row, which is a hint about a
    /// layout this does not use. A line naming something nobody wrote has
    /// nothing to repaint, and Mermaid draws the diagram without it.
    private static func restyle(
        _ keyword: String, _ targets: [String], _ style: Flowchart.Style, in chart: inout Flowchart,
        named identifiers: [String: Int]
    ) -> Bool {
        switch keyword {
        case "UpdateLayoutConfig":
            return true
        case "UpdateElementStyle":
            guard let first = targets.first, let node = identifiers[first] else { return true }
            chart.nodes[node].style.merge(style)
            return true
        case "UpdateBoundaryStyle":
            guard let first = targets.first,
                let group = chart.groups.firstIndex(where: { $0.id == first })
            else { return true }
            chart.groups[group].style.merge(style)
            return true
        case "UpdateRelStyle":
            guard targets.count >= 2, let from = identifiers[targets[0]],
                let to = identifiers[targets[1]]
            else { return true }
            // The line is named by its ends, and a pair may be joined twice.
            for index in chart.edges.indices
            where chart.edges[index].from == .node(from) && chart.edges[index].to == .node(to) {
                chart.edges[index].style.merge(style)
            }
            return true
        default:
            return false
        }
    }

    /// The comma-separated arguments inside `Keyword(…)`, quotes removed: what
    /// the line says, and separately the `$key="value"` settings hung off it.
    private static func arguments(of line: Substring, after keyword: String)
        -> (plain: [String], settings: [String])?
    {
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
        return (
            arguments.filter { !$0.hasPrefix("$") }, arguments.filter { $0.hasPrefix("$") }
        )
    }
}

/// An architecture diagram: services in groups, joined at named sides.
struct ArchitectureDiagram {
    /// The five shapes Mermaid ships without an icon pack, and the question
    /// mark it draws for one out of a pack nobody registered.
    enum Icon: String {
        case cloud, database, disk, internet, server
        case unknown
        /// A `junction`: a place where lines meet and nothing is drawn.
        case junction
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
        /// The group this one was written inside, if any.
        var parent: Int?
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
    /// `align row a b c` and `align column a b c`: which services stand in one
    /// row, or in one column, whether or not a line joins them.
    var alignments: [(down: Bool, members: [Int])] = []

    static func parse(_ lines: [Substring]) -> ArchitectureDiagram? {
        var diagram = ArchitectureDiagram(groups: [], services: [], edges: [])
        for line in lines {
            let keyword = String(line.prefix(while: { !$0.isWhitespace && $0 != "(" }))
            if keyword == "group" || keyword == "service" {
                let rest = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
                guard let read = declaration(rest) else { return nil }
                var group: Int?
                if let parent = read.parent {
                    guard let found = diagram.groups.firstIndex(where: { $0.identifier == parent })
                    else { return nil }
                    group = found
                }
                if keyword == "group" {
                    diagram.groups.append(
                        Group(
                            identifier: read.identifier, label: read.label, icon: read.icon,
                            parent: group))
                } else {
                    diagram.services.append(
                        Service(
                            identifier: read.identifier, label: read.label, icon: read.icon,
                            group: group))
                }
                continue
            }
            // `junction one`: a corner where lines meet, taking a cell of its
            // own and drawing nothing in it.
            if keyword == "junction" {
                let name = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" ") else { return nil }
                diagram.services.append(
                    Service(identifier: name, label: "", icon: .junction, group: nil))
                continue
            }
            // `align row a b c` and `align column a b c` stand the services side
            // by side or one under the other, without a line between them.
            if keyword == "align" {
                let words = line.dropFirst(keyword.count)
                    .split(separator: " ", omittingEmptySubsequences: true)
                guard let axis = words.first, axis == "row" || axis == "column",
                    words.count >= 3
                else { return nil }
                // A name nobody declared is passed over rather than refused:
                // Mermaid draws the picture and simply stands nothing there.
                let members = words.dropFirst().compactMap { name in
                    diagram.services.firstIndex { $0.identifier == name }
                }
                if members.count >= 2 {
                    diagram.alignments.append((down: axis == "column", members: members))
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
        // An alignment binds its services as firmly as an edge does — the next
        // one along stands beside the one before it — but draws no line.
        for alignment in alignments {
            for (before, after) in zip(alignment.members, alignment.members.dropFirst()) {
                let step =
                    alignment.down ? Cell(column: 0, row: 1) : Cell(column: 1, row: 0)
                links[before].append((after, step))
                links[after].append((before, Cell(column: -step.column, row: -step.row)))
            }
        }

        var cells = [Int: Cell]()
        var taken = [Cell: Int]()
        var nextRow = 0
        for start in services.indices where cells[start] == nil {
            var root = Cell(column: 0, row: nextRow)
            while taken[root] != nil { root = Cell(column: root.column, row: root.row + 1) }
            cells[start] = root
            taken[root] = start
            var queue = [start]
            while let current = queue.popLast() {
                guard let here = cells[current] else { return false }
                for link in links[current] {
                    let spot = Cell(
                        column: here.column + link.step.column, row: here.row + link.step.row)
                    // A service already placed keeps where it stands: the
                    // first edge that named it is the one that settled it.
                    if cells[link.neighbour] != nil { continue }
                    // Two services sent to one cell cannot both stand there, so
                    // the second walks on in the same direction until a cell is
                    // free — which is what makes the picture drawable at all.
                    var free = spot
                    let step =
                        link.step.column == 0 && link.step.row == 0
                        ? Cell(column: 1, row: 0) : link.step
                    while taken[free] != nil {
                        free = Cell(column: free.column + step.column, row: free.row + step.row)
                    }
                    cells[link.neighbour] = free
                    taken[free] = link.neighbour
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
        // standing inside that block would look like a member. Mermaid keeps
        // such a stranger outside the frame, and so does this: it is walked to
        // the right of the block until it stands clear. Moving one can push it
        // into another group, so the sweep repeats until nothing moves. A group
        // inside a group counts as a member of the one that holds it.
        for _ in 0..<(services.count + 1) * max(groups.count, 1) {
            var occupied = Set<Cell>()
            for service in services {
                occupied.insert(Cell(column: service.column, row: service.row))
            }
            var moved = false
            for group in groups.indices {
                let members = self.members(of: group)
                guard let columns = extent(members, \.column),
                    let rows = extent(members, \.row)
                else { continue }
                for other in services.indices where !members.contains(other) {
                    guard columns.contains(services[other].column),
                        rows.contains(services[other].row)
                    else { continue }
                    occupied.remove(Cell(column: services[other].column, row: services[other].row))
                    var column = columns.upperBound + 1
                    while occupied.contains(Cell(column: column, row: services[other].row)) {
                        column += 1
                    }
                    services[other].column = column
                    occupied.insert(Cell(column: column, row: services[other].row))
                    moved = true
                }
            }
            if !moved { return true }
        }
        return false
    }

    /// Every service inside a group, including the ones inside the groups
    /// inside it.
    func members(of group: Int) -> [Int] {
        var wanted = [group]
        var inside: Set<Int> = []
        while let next = wanted.popLast() {
            inside.insert(next)
            wanted += groups.indices.filter { groups[$0].parent == next }
        }
        return services.indices.filter { service in
            services[service].group.map { inside.contains($0) } ?? false
        }
    }

    /// How many groups a group stands inside, so the outer frames can be drawn
    /// first and given room for the inner ones.
    func depth(of group: Int) -> Int {
        var steps = 0
        var walk = groups[group].parent
        while let parent = walk, steps < groups.count {
            steps += 1
            walk = groups[parent].parent
        }
        return steps
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
            // nothing. Mermaid draws a question mark for any name it cannot
            // resolve, whether the name is misspelt or comes from a pack the
            // page never registered, and so does this.
            icon = Icon(rawValue: name) ?? .unknown
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
