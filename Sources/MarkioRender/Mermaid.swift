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
    case packet(PacketDiagram)
    case kanban(KanbanBoard)
    case sankey(SankeyDiagram)
    case treemap(Treemap)
    case architecture(ArchitectureDiagram)
    case radar(RadarChart)
    case blocks(BlockDiagram)
    /// A diagram with the name its YAML preamble gave it, set above it.
    indirect case titled(String, MermaidDiagram)

    /// What a diagram's preamble said, beyond its name.
    struct Settings {
        /// `config.kanban.ticketBaseUrl`: what a card's ticket id points at.
        var ticketBaseUrl = ""
    }

    static func parse(_ source: String) -> MermaidDiagram? {
        guard let front = frontMatter(source) else { return nil }
        guard let diagram = parse(body: front.body, settings: front.settings) else { return nil }
        guard !front.title.isEmpty else { return diagram }
        // A title in the preamble and a `title` line in the diagram are two
        // names for one picture, and which of them Mermaid shows is not
        // something to guess at.
        guard !declaresTitle(front.body) else { return nil }
        return .titled(front.title, diagram)
    }

    /// Mermaid's YAML preamble: `---`, some keys, `---`, and then the diagram.
    ///
    /// Two keys are read. `title` names the picture, and the drawing shows it.
    /// `config` changes how Mermaid draws rather than what it draws — the theme,
    /// a gantt's display mode — and a picture drawn to settings other than the
    /// ones its author wrote is not the picture they asked for, so a `config`
    /// holding anything but the settings named in `Settings` refuses the fence.
    ///
    /// A source with no preamble is returned untouched; nil means there was one
    /// and it said something this does not understand.
    private static func frontMatter(_ source: String)
        -> (title: String, settings: Settings, body: String)?
    {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        guard index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "---" else {
            return ("", Settings(), source)
        }
        var title = ""
        var settings = Settings()
        /// The keys open above this line, outermost first, with the indent each
        /// was written at — which is all the YAML nesting a preamble ever has.
        var path: [(indent: Int, key: String)] = []
        index += 1
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            index += 1
            if line == "---" {
                return (title, settings, lines[index...].joined(separator: "\n"))
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = String(line[line.startIndex..<colon])
            let value = scalar(line[line.index(after: colon)...])
            while let last = path.last, last.indent >= indent { path.removeLast() }
            let here = path.map(\.key) + [key]
            if value.isEmpty {
                // A key with nothing after it opens what is written under it.
                path.append((indent, key))
                guard here == ["config"] || here == ["config", "kanban"] else { return nil }
                continue
            }
            switch here {
            case ["title"]:
                guard title.isEmpty else { return nil }
                title = value
            case ["config", "kanban", "ticketBaseUrl"]:
                settings.ticketBaseUrl = value
            default:
                return nil
            }
        }
        // Opened and never closed, which is neither a preamble nor a diagram.
        return nil
    }

    /// A YAML scalar as written on one line: the value, and its quotes taken off
    /// if it has any.
    private static func scalar(_ text: Substring) -> String {
        let value = text.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"]
        where value.count >= 2 && value.hasPrefix(quote)
            && value.hasSuffix(quote)
        {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Whether the diagram itself names a title, in the `title …` line that a
    /// pie chart, a gantt or a radar accepts.
    private static func declaresTitle(_ body: String) -> Bool {
        body.split(separator: "\n").contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text == "title" || text.hasPrefix("title ") || text.hasPrefix("title:")
        }
    }

    private static func parse(body source: String, settings: Settings) -> MermaidDiagram? {
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
        // A kanban setting over a diagram that is not a board says the author
        // meant something this has not understood.
        guard settings.ticketBaseUrl.isEmpty || header == "kanban" else { return nil }
        let rest = Array(lines.dropFirst())
        if header == "mindmap" || header == "kanban" || header == "treemap-beta"
            || header == "treemap"
        {
            let body = zip(indents.dropFirst(), rest).map { (indent: $0, text: $1) }
            switch header {
            case "mindmap": return Mindmap.parse(body).map(MermaidDiagram.mindmap)
            case "kanban":
                return KanbanBoard.parse(body, ticketBaseUrl: settings.ticketBaseUrl)
                    .map(MermaidDiagram.kanban)
            default: return Treemap.parse(body).map(MermaidDiagram.treemap)
            }
        }
        if header == "sankey-beta" || header == "sankey" {
            return SankeyDiagram.parse(rest).map(MermaidDiagram.sankey)
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
        if header == "packet-beta" || header == "packet" {
            return PacketDiagram.parse(rest).map(MermaidDiagram.packet)
        }
        if header == "zenuml" {
            // ZenUML says what a sequence diagram says, so it is read into one.
            return ZenUML.parse(rest).map(MermaidDiagram.sequence)
        }
        if header == "radar-beta" || header == "radar" {
            return RadarChart.parse(rest).map(MermaidDiagram.radar)
        }
        if header == "block-beta" || header == "block" {
            return BlockDiagram.parse(rest).map(MermaidDiagram.blocks)
        }
        if header == "architecture-beta" || header == "architecture" {
            return ArchitectureDiagram.parse(rest).map(MermaidDiagram.architecture)
        }
        if C4Diagram.headers.contains(String(header)) {
            // A C4 diagram is elements, boundaries and relations, which is a
            // flowchart with its shapes chosen by what each element is.
            return C4Diagram.parse(rest).map { read in
                read.title.isEmpty
                    ? .flowchart(read.chart) : .titled(read.title, .flowchart(read.chart))
            }
        }
        if header == "requirementDiagram" {
            return RequirementDiagram.parse(rest).map(MermaidDiagram.boxes)
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
/// a fork is a bar, a choice is a diamond, and every named state is a rounded
/// box. A note is a slip of paper joined to its state by a dotted line, which
/// is a node and an edge like any other.
enum StateDiagram {
    static func parse(_ lines: [Substring]) -> Flowchart? {
        var direction = Flowchart.Direction.down
        var body: [Substring] = []
        var names: [String: String] = [:]
        /// The states written as a bar or a diamond rather than a rounded box.
        var shapes: [String: Flowchart.Shape] = [:]
        /// A note being written across several lines, and the state it is tied
        /// to. Its words are gathered until `end note` closes it.
        var openNote: (state: String, words: [String])?
        var notes = 0
        /// The composite states currently open, innermost last. `[*]` inside one
        /// is that machine's own beginning and end, not the whole diagram's, so
        /// the points are named after the state that holds them.
        var open: [String] = []
        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if word == "direction" {
                guard let read = Flowchart.direction(header: Substring("flowchart \(rest)"))
                else { return nil }
                direction = read
                continue
            }
            if line == "}" {
                guard !open.isEmpty else { return nil }
                open.removeLast()
                body.append("end")
                continue
            }
            if var note = openNote {
                if line == "end note" {
                    let words = note.words.joined(separator: "<br/>")
                    guard !words.isEmpty else { return nil }
                    body.append(Substring("__note\(notes)[\(words)]"))
                    body.append(Substring("\(note.state) -.- __note\(notes)"))
                    shapes["__note\(notes)"] = .note
                    notes += 1
                    openNote = nil
                    continue
                }
                note.words.append(String(line))
                openNote = note
                continue
            }
            if word == "note" {
                guard let note = self.note(rest) else { return nil }
                guard let words = note.words else {
                    openNote = (state: note.state, words: [])
                    continue
                }
                body.append(Substring("__note\(notes)[\(words)]"))
                body.append(Substring("\(note.state) -.- __note\(notes)"))
                shapes["__note\(notes)"] = .note
                notes += 1
                continue
            }
            if word == "state" {
                // `state "Long name" as id` names a state; `state id { … }` is a
                // machine inside a machine; `state id <<fork>>` is a bar.
                if let open = rest.range(of: "<<"), let close = rest.range(of: ">>") {
                    let name = String(rest[rest.startIndex..<open.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    let kind = String(rest[open.upperBound..<close.lowerBound])
                    guard !name.isEmpty, !name.contains(" ") else { return nil }
                    switch kind {
                    case "fork", "join": shapes[name] = .bar
                    case "choice": shapes[name] = .diamond
                    default: return nil
                    }
                    continue
                }
                if rest.hasPrefix("\"") {
                    guard let close = rest.dropFirst().firstIndex(of: "\"") else { return nil }
                    let label = String(rest[rest.index(after: rest.startIndex)..<close])
                    let tail = rest[rest.index(after: close)...]
                        .trimmingCharacters(in: .whitespaces)
                    guard tail.hasPrefix("as ") else { return nil }
                    names[String(tail.dropFirst(3)).trimmingCharacters(in: .whitespaces)] = label
                    continue
                }
                guard rest.hasSuffix("{") else { return nil }
                let name = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" ") else { return nil }
                open.append(name)
                body.append(Substring("subgraph \(name)"))
                continue
            }
            // The words a flowchart already knows are handed to it as written.
            if ["class", "classDef", "style", "click", "linkStyle"].contains(word) {
                body.append(line)
                continue
            }
            guard word != "end" else { return nil }
            // `A --> B : go` is the same edge a flowchart writes `A -->|go| B`.
            guard let arrow = line.range(of: "-->") else {
                // `id: Words` is what the state is called on the page.
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = String(line[line.startIndex..<colon]).trimmingCharacters(
                    in: .whitespaces)
                let label = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" "), !label.isEmpty else { return nil }
                names[name] = label
                continue
            }
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
            let scope = open.last ?? ""
            if from == "[*]" { from = "__start\(scope)" }
            if tail == "[*]" { tail = "__end\(scope)" }
            let arrowText = label.isEmpty ? "-->" : "-->|\(label)|"
            body.append(Substring("\(from) \(arrowText) \(tail)"))
        }
        guard open.isEmpty, openNote == nil, !body.isEmpty,
            var chart = Flowchart.parse(body, direction: direction)
        else { return nil }
        for index in chart.nodes.indices {
            let id = chart.nodes[index].id
            if id.hasPrefix("__start") {
                chart.nodes[index] = Flowchart.Node(id: id, label: "", shape: .point)
            } else if id.hasPrefix("__end") {
                chart.nodes[index] = Flowchart.Node(id: id, label: "", shape: .endPoint)
            } else if let shape = shapes[id] {
                // A fork and a choice are read as the mark they are, so the
                // name the author gave them is not written on the page.
                chart.nodes[index].shape = shape
                if shape != .note { chart.nodes[index].label = "" }
            } else {
                chart.nodes[index].shape = .rounded
                if let label = names[id] { chart.nodes[index].label = label }
            }
        }
        // A composite state wears the name it was given, the same way a plain
        // state does.
        for index in chart.groups.indices {
            if let label = names[chart.groups[index].id] { chart.groups[index].title = label }
        }
        return chart
    }

    /// `note right of Still : waiting`, or the same without the words when the
    /// note runs on until `end note`. Which side it is written on is Mermaid's
    /// hint to its own layout, and this one places notes for itself.
    private static func note(_ rest: String) -> (state: String, words: String?)? {
        var text = rest
        for side in ["left of ", "right of "] where text.hasPrefix(side) {
            text = String(text.dropFirst(side.count))
        }
        guard text != rest else { return nil }
        var words: String?
        if let colon = text.firstIndex(of: ":") {
            let said = String(text[text.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !said.isEmpty else { return nil }
            words = said
            text = String(text[text.startIndex..<colon])
        }
        let state = text.trimmingCharacters(in: .whitespaces)
        guard !state.isEmpty, !state.contains(" ") else { return nil }
        return (state: state, words: words)
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
        /// A mindmap's `)…(` and `))…((`: a puffy cloud and a starburst.
        case cloud
        case bang
        /// A state machine's `<<fork>>` and `<<join>>`: a heavy bar that splits
        /// one thread into several or gathers them back.
        case bar
        /// A state machine's note: a slip of paper with a folded corner.
        case note
        /// A block diagram's `blockArrowId<[…]>(down)`: a fat arrow with words
        /// in it, pointing one of four ways.
        case arrowUp
        case arrowDown
        case arrowLeft
        case arrowRight
    }

    enum Stroke {
        case solid
        case thick
        case dotted
        /// `A ~~~ B`: a link that only holds one box below another. It ranks
        /// the two like any other link and then draws nothing at all.
        case invisible
    }

    /// A colour written in the diagram, not taken from the theme. Kept as
    /// numbers so the parser stays free of AppKit and can run anywhere.
    struct Colour: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        /// How much of what is behind shows through, from `rgba(…)` or `#rrggbbaa`.
        var alpha: Double = 1
    }

    /// What `style`, `classDef` and `:::` can say about a node. Everything else
    /// a CSS declaration could carry is refused rather than ignored.
    struct Style: Equatable {
        var fill: Colour?
        var stroke: Colour?
        var text: Colour?
        var strokeWidth: Double?
        /// `opacity:0.5`: how much of the page shows through everything the
        /// style paints, colours the theme supplied included.
        var opacity: Double?

        var isEmpty: Bool {
            fill == nil && stroke == nil && text == nil && strokeWidth == nil && opacity == nil
        }

        mutating func merge(_ other: Style) {
            if let fill = other.fill { self.fill = fill }
            if let stroke = other.stroke { self.stroke = stroke }
            if let text = other.text { self.text = text }
            if let width = other.strokeWidth { strokeWidth = width }
            if let opacity = other.opacity { self.opacity = opacity }
        }
    }

    struct Node {
        var id: String
        var label: String
        var shape: Shape
        var style = Style()
    }

    /// What an edge joins. `outside --> subgraph1` ends on the frame's border,
    /// not on any one box inside it, so a frame is an endpoint in its own right.
    enum End: Hashable {
        case node(Int)
        case frame(Int)

        /// The box this end names, when it names a box rather than a frame.
        var node: Int? {
            if case .node(let index) = self { return index }
            return nil
        }
    }

    struct Edge {
        var from: End
        var to: End
        var label: String
        var stroke: Stroke
        /// `---` joins without an arrowhead; `-->` points.
        var arrow: Bool
        /// A colour for the line and one for its words, when something has said
        /// what they should be. `fill` means nothing on a line.
        var style = Style()

        init(from: End, to: End, label: String, stroke: Stroke, arrow: Bool) {
            self.from = from
            self.to = to
            self.label = label
            self.stroke = stroke
            self.arrow = arrow
        }

        /// The common case, where both ends are boxes.
        init(from: Int, to: Int, label: String, stroke: Stroke, arrow: Bool) {
            self.init(from: .node(from), to: .node(to), label: label, stroke: stroke, arrow: arrow)
        }
    }

    /// A `subgraph`: a titled frame drawn around the nodes declared inside it.
    struct Group {
        var title: String
        var members: [Int]
        /// What the frame is called in the source. An edge may name it, and an
        /// edge that names a frame reaches every box the frame holds.
        var id: String = ""
        /// The frame this one was written inside, if any.
        var parent: Int?
        /// `direction TB` inside the frame turns the frame's own contents. A
        /// frame that does not say keeps the direction of whatever holds it.
        var direction: Direction?
        /// What the frame is painted with, when something has said.
        var style = Style()
    }

    var direction: Direction
    var nodes: [Node]
    var edges: [Edge]
    var groups: [Group] = []
    /// `classDef` definitions, used while parsing and of no interest afterwards.
    private var classes: [String: Style] = [:]
    /// The frames currently open, innermost last. A frame inside a frame is an
    /// ordinary thing to write, so what is open is a stack and not one slot.
    private var openGroups: [Int] = []
    private var openGroup: Int? { openGroups.last }

    /// A graph put together by some other reader — a C4 diagram, a state
    /// machine — where the nodes, the edges and the frames are already known.
    init(direction: Direction, nodes: [Node], edges: [Edge], groups: [Group] = []) {
        self.direction = direction
        self.nodes = nodes
        self.edges = edges
        self.groups = groups
    }

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
        guard chart.openGroups.isEmpty, !chart.nodes.isEmpty else { return nil }
        chart.dropEmptyGroups()
        chart.joinFramesNamedByEdges()
        guard !chart.nodes.isEmpty else { return nil }
        return chart
    }

    /// A frame with nothing in it and nothing inside it is not drawn.
    ///
    /// Removing one renumbers the rest, so the parents are renumbered with them
    /// — a frame pointing at the wrong parent would be drawn inside a stranger.
    private mutating func dropEmptyGroups() {
        while true {
            let holds = Set(groups.compactMap(\.parent))
            guard
                let empty = groups.indices.first(where: {
                    groups[$0].members.isEmpty && !holds.contains($0)
                })
            else { return }
            groups.remove(at: empty)
            for index in groups.indices {
                guard let parent = groups[index].parent else { continue }
                groups[index].parent =
                    parent == empty ? nil : (parent > empty ? parent - 1 : parent)
            }
        }
    }

    /// `outside --> subgraph1` names a frame, and reading it as a box invents a
    /// node the author never wrote.
    ///
    /// A frame is only ever named by an edge, never declared, so the box that
    /// carries the name has no label of its own and no other statement about
    /// it: taking it out and pointing the edge at the frame loses nothing.
    private mutating func joinFramesNamedByEdges() {
        let named = Dictionary(
            groups.enumerated().filter { !$0.element.id.isEmpty }.map {
                ($0.element.id, $0.offset)
            },
            uniquingKeysWith: { first, _ in first })
        let standIns = nodes.indices.filter { named[nodes[$0].id] != nil }
        guard !standIns.isEmpty else { return }
        let dropped = Set(standIns)
        // Taking nodes out renumbers the rest, so everything that holds a node
        // number is renumbered with them.
        var moved = [Int: Int]()
        var next = 0
        for index in nodes.indices where !dropped.contains(index) {
            moved[index] = next
            next += 1
        }
        func end(_ end: End) -> End {
            guard case .node(let index) = end else { return end }
            if let frame = named[nodes[index].id], dropped.contains(index) { return .frame(frame) }
            return .node(moved[index] ?? index)
        }
        edges = edges.map {
            Edge(
                from: end($0.from), to: end($0.to), label: $0.label, stroke: $0.stroke,
                arrow: $0.arrow)
        }
        // An edge to a frame that is also an edge from it says nothing.
        edges.removeAll { $0.from == $0.to }
        for index in groups.indices {
            groups[index].members = groups[index].members.compactMap { moved[$0] }
        }
        nodes = nodes.indices.filter { !dropped.contains($0) }.map { nodes[$0] }
    }

    /// A whole line: a subgraph boundary, a styling directive, or a statement.
    private mutating func parseLine(_ line: Substring) -> Bool {
        let word = String(line.prefix(while: { !$0.isWhitespace }))
        let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        switch word {
        case "subgraph":
            groups.append(
                Group(
                    title: title(ofSubgraph: rest), members: [], id: id(ofSubgraph: rest),
                    parent: openGroups.last))
            openGroups.append(groups.count - 1)
            return true
        case "end":
            guard !openGroups.isEmpty, rest.isEmpty else { return false }
            openGroups.removeLast()
            return true
        case "direction":
            // Inside a frame this turns that frame's own contents; at the top
            // level it is the same word the header carries.
            guard let turn = Flowchart.direction(word: Substring(rest)) else { return false }
            if let group = openGroups.last {
                groups[group].direction = turn
            } else {
                direction = turn
            }
            return true
        case "classDef":
            return defineClass(rest)
        case "class":
            return applyClass(rest)
        case "style":
            return applyStyle(rest)
        case "click":
            return noteClick(rest)
        case "linkStyle":
            return applyLinkStyle(rest)
        default:
            return parseStatement(line)
        }
    }

    /// What the frame is called: `one` in both `subgraph one[First step]` and a
    /// bare `subgraph one`. A quoted title alone names nothing.
    private func id(ofSubgraph text: String) -> String {
        let name = String(text.prefix(while: { $0 != "[" })).trimmingCharacters(in: .whitespaces)
        guard !name.hasPrefix("\""), !name.contains(" ") else { return "" }
        return name
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

    /// `click A "https://example.com"`, `click A href "…" "Tooltip"` or a call
    /// to a script. A picture on a page cannot be followed or hovered, and
    /// Mermaid draws a clickable box exactly like any other, so the line is
    /// read for the box it names and then changes nothing.
    private func noteClick(_ rest: String) -> Bool {
        let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return false }
        return nodes.contains { $0.id == String(parts[0]) }
    }

    /// `linkStyle 0,1 stroke:#f00,stroke-width:2px` or `linkStyle default …`.
    /// The numbers count the links in the order they were written.
    private mutating func applyLinkStyle(_ rest: String) -> Bool {
        let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let style = Flowchart.style(from: String(parts[1])) else {
            return false
        }
        if parts[0] == "default" {
            for index in edges.indices { edges[index].style.merge(style) }
            return true
        }
        for number in parts[0].split(separator: ",") {
            guard let index = Int(number.trimmingCharacters(in: .whitespaces)),
                edges.indices.contains(index)
            else { return false }
            edges[index].style.merge(style)
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

    /// One declaration per comma — except the commas inside `rgb(…)`, which
    /// separate a colour's own numbers and hold the declaration together.
    private static func declarations(in text: String) -> [Substring] {
        var parts: [Substring] = []
        var start = text.startIndex
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "(": depth += 1
            case ")": depth -= 1
            case "," where depth == 0:
                parts.append(text[start..<index])
                start = text.index(after: index)
            default: break
            }
        }
        parts.append(text[start...])
        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// `fill:#f9f,stroke:#333,stroke-width:2px,color:#fff`. A property this
    /// cannot draw fails the whole diagram, because a node drawn without the
    /// colour the author gave it is a node the author did not write.
    static func style(from text: String) -> Style? {
        var style = Style()
        for declaration in declarations(in: text) {
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
            case "opacity":
                guard let share = Double(value), (0...1).contains(share) else { return nil }
                style.opacity = share
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
        }
        // A node belongs to the frame it is written inside, whether or not that
        // is where it was first named: `c1-->a2` above the frames still leaves
        // `a2` a member of the frame that goes on to use it. The first frame to
        // use a node keeps it — one node cannot sit in two frames.
        if let group = openGroup, !groups.contains(where: { $0.members.contains(index) }) {
            groups[group].members.append(index)
        }
        if let name {
            guard let style = classes[name] else { return nil }
            nodes[index].style.merge(style)
        }
        return index
    }

    /// One written cell — `a`, `a["Words"]`, `a(("Round"))` — read the way a
    /// flowchart reads its nodes.
    static func cell(_ text: Substring) -> (id: String, label: String?, shape: Shape?)? {
        var reader = Reader(Array(text))
        guard let read = reader.readBare(), reader.atEnd else { return nil }
        return read
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

        /// The identifier and, where the text gives one, the shape and the words
        /// that go in it. Knows nothing about a chart, so a block diagram can
        /// read its cells with the same spellings a flowchart uses.
        mutating func readBare() -> (id: String, label: String?, shape: Shape?)? {
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
            return (id, label, shape)
        }

        mutating func readNode(into chart: inout Flowchart) -> Int? {
            guard let (id, label, shape) = readBare() else { return nil }
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
                (["~", "~", "~"], .invisible, false),
            ]
            guard let spelling = spellings.first(where: { starts(with: $0.text) }) else {
                return readLabelledLink()
            }
            advance(spelling.text.count)
            // A trailing `-` or `=` only makes the line longer: `---->` is `-->`.
            while let char = peek(), char == "-" || char == "=" || char == "~" { advance() }
            // `--->` opens as the plain `---` and only then shows its head, so
            // the head is read after the line's length rather than with it.
            var arrow = spelling.arrow
            if peek() == ">" {
                advance()
                arrow = true
            }
            var label = ""
            if peek() == "|" {
                advance()
                guard let text = readLabel(until: ["|"]) else { return nil }
                label = text
            }
            return (label, spelling.stroke, arrow)
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
            // `<br/>` stays in the label: the layout is what breaks the line,
            // and turning it into a space here would lose the author's break.
            return trimmed
        }
    }
}

extension Flowchart.Colour {
    /// `#f9f`, `#ff99ff`, `rgb(0, 0, 0)` or any colour name CSS knows. A
    /// spelling this does not know fails the diagram rather than picking one.
    init?(css text: String) {
        let written = text.trimmingCharacters(in: .whitespaces).lowercased()
        if written == "transparent" {
            self.init(red: -1, green: -1, blue: -1)
            return
        }
        if written.hasPrefix("rgb") {
            guard let open = written.firstIndex(of: "("), written.hasSuffix(")") else { return nil }
            let inside = written[
                written.index(after: open)..<written.index(before: written.endIndex)]
            let parts = inside.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            let channels = parts.prefix(3).compactMap { part -> Double? in
                if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
                return Double(part).map { $0 / 255 }
            }
            guard channels.count == 3 else { return nil }
            var alpha = 1.0
            if parts.count == 4 {
                guard let written = Double(parts[3]), (0...1).contains(written) else { return nil }
                alpha = written
            }
            self.init(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
            return
        }
        let hex =
            written.hasPrefix("#") ? String(written.dropFirst()) : Flowchart.Colour.names[written]
        guard let hex else { return nil }
        let digits = Array(hex)
        let channels: [Double]
        switch digits.count {
        case 3:
            channels = digits.compactMap { $0.hexDigit.map { Double($0 * 17) / 255 } }
        case 6, 8:
            channels = stride(from: 0, to: digits.count, by: 2).compactMap { offset -> Double? in
                guard let high = digits[offset].hexDigit, let low = digits[offset + 1].hexDigit
                else { return nil }
                return Double(high * 16 + low) / 255
            }
        default:
            return nil
        }
        guard channels.count == (digits.count == 3 ? 3 : digits.count / 2) else { return nil }
        self.init(
            red: channels[0], green: channels[1], blue: channels[2],
            alpha: channels.count == 4 ? channels[3] : 1)
    }

    /// Every colour name CSS knows, as the hex it stands for. A diagram may
    /// name any of them, so knowing only the dozen people usually type turned a
    /// valid `fill:chartreuse` into a fence of source.
    private static let names: [String: String] = [
        "aliceblue": "f0f8ff", "antiquewhite": "faebd7", "aqua": "00ffff",
        "aquamarine": "7fffd4", "azure": "f0ffff", "beige": "f5f5dc", "bisque": "ffe4c4",
        "black": "000000", "blanchedalmond": "ffebcd", "blue": "0000ff",
        "blueviolet": "8a2be2", "brown": "a52a2a", "burlywood": "deb887",
        "cadetblue": "5f9ea0", "chartreuse": "7fff00", "chocolate": "d2691e",
        "coral": "ff7f50", "cornflowerblue": "6495ed", "cornsilk": "fff8dc",
        "crimson": "dc143c", "cyan": "00ffff", "darkblue": "00008b", "darkcyan": "008b8b",
        "darkgoldenrod": "b8860b", "darkgray": "a9a9a9", "darkgreen": "006400",
        "darkgrey": "a9a9a9", "darkkhaki": "bdb76b", "darkmagenta": "8b008b",
        "darkolivegreen": "556b2f", "darkorange": "ff8c00", "darkorchid": "9932cc",
        "darkred": "8b0000", "darksalmon": "e9967a", "darkseagreen": "8fbc8f",
        "darkslateblue": "483d8b", "darkslategray": "2f4f4f", "darkslategrey": "2f4f4f",
        "darkturquoise": "00ced1", "darkviolet": "9400d3", "deeppink": "ff1493",
        "deepskyblue": "00bfff", "dimgray": "696969", "dimgrey": "696969",
        "dodgerblue": "1e90ff", "firebrick": "b22222", "floralwhite": "fffaf0",
        "forestgreen": "228b22", "fuchsia": "ff00ff", "gainsboro": "dcdcdc",
        "ghostwhite": "f8f8ff", "gold": "ffd700", "goldenrod": "daa520", "gray": "808080",
        "green": "008000", "greenyellow": "adff2f", "grey": "808080", "honeydew": "f0fff0",
        "hotpink": "ff69b4", "indianred": "cd5c5c", "indigo": "4b0082", "ivory": "fffff0",
        "khaki": "f0e68c", "lavender": "e6e6fa", "lavenderblush": "fff0f5",
        "lawngreen": "7cfc00", "lemonchiffon": "fffacd", "lightblue": "add8e6",
        "lightcoral": "f08080", "lightcyan": "e0ffff", "lightgoldenrodyellow": "fafad2",
        "lightgray": "d3d3d3", "lightgreen": "90ee90", "lightgrey": "d3d3d3",
        "lightpink": "ffb6c1", "lightsalmon": "ffa07a", "lightseagreen": "20b2aa",
        "lightskyblue": "87cefa", "lightslategray": "778899", "lightslategrey": "778899",
        "lightsteelblue": "b0c4de", "lightyellow": "ffffe0", "lime": "00ff00",
        "limegreen": "32cd32", "linen": "faf0e6", "magenta": "ff00ff", "maroon": "800000",
        "mediumaquamarine": "66cdaa", "mediumblue": "0000cd", "mediumorchid": "ba55d3",
        "mediumpurple": "9370db", "mediumseagreen": "3cb371", "mediumslateblue": "7b68ee",
        "mediumspringgreen": "00fa9a", "mediumturquoise": "48d1cc",
        "mediumvioletred": "c71585", "midnightblue": "191970", "mintcream": "f5fffa",
        "mistyrose": "ffe4e1", "moccasin": "ffe4b5", "navajowhite": "ffdead", "navy": "000080",
        "oldlace": "fdf5e6", "olive": "808000", "olivedrab": "6b8e23", "orange": "ffa500",
        "orangered": "ff4500", "orchid": "da70d6", "palegoldenrod": "eee8aa",
        "palegreen": "98fb98", "paleturquoise": "afeeee", "palevioletred": "db7093",
        "papayawhip": "ffefd5", "peachpuff": "ffdab9", "peru": "cd853f", "pink": "ffc0cb",
        "plum": "dda0dd", "powderblue": "b0e0e6", "purple": "800080",
        "rebeccapurple": "663399", "red": "ff0000", "rosybrown": "bc8f8f",
        "royalblue": "4169e1", "saddlebrown": "8b4513", "salmon": "fa8072",
        "sandybrown": "f4a460", "seagreen": "2e8b57", "seashell": "fff5ee", "sienna": "a0522d",
        "silver": "c0c0c0", "skyblue": "87ceeb", "slateblue": "6a5acd", "slategray": "708090",
        "slategrey": "708090", "snow": "fffafa", "springgreen": "00ff7f",
        "steelblue": "4682b4", "tan": "d2b48c", "teal": "008080", "thistle": "d8bfd8",
        "tomato": "ff6347", "turquoise": "40e0d0", "violet": "ee82ee", "wheat": "f5deb3",
        "white": "ffffff", "whitesmoke": "f5f5f5", "yellow": "ffff00", "yellowgreen": "9acd32",
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
        /// `actor A`, and ZenUML's nameless caller: drawn as a stick figure
        /// rather than a box, the way Mermaid draws one.
        var isActor = false
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
        /// What a `rect` tints the page behind its messages with.
        var fill: Flowchart.Colour?
    }

    /// A `box`: a titled band above a run of neighbouring participants.
    struct Group {
        var label: String
        var fill: Flowchart.Colour?
        var members: [Int] = []
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
    var groups: [Group] = []
    var autonumber = false
    /// Written above the participants. Mermaid's own `sequenceDiagram` has no
    /// title; a ZenUML one does, and it is read into this.
    var title = ""

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
        /// The `box` open above the participants, if any.
        var openGroup: Int?
        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if word == "participant" || word == "actor" {
                guard let index = diagram.declare(line.dropFirst(word.count)) else { return nil }
                if word == "actor" { diagram.participants[index].isActor = true }
                if let group = openGroup { diagram.groups[group].members.append(index) }
                continue
            }
            if word == "box" {
                // `box Aqua Team`, `box rgb(0,0,255) Team`, or just `box Team`.
                guard openGroup == nil, stack.isEmpty else { return nil }
                let (fill, label) = tint(rest)
                guard !label.isEmpty else { return nil }
                diagram.groups.append(Group(label: label, fill: fill))
                openGroup = diagram.groups.count - 1
                continue
            }
            if word == "rect" {
                // A `rect` needs its colour: an untinted band tints nothing.
                let (fill, label) = tint(rest)
                guard let fill, label.isEmpty else { return nil }
                stack.append(
                    Block(kind: "rect", sections: [Section(title: "", items: [])], fill: fill))
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
                guard rest.isEmpty else { return nil }
                if stack.isEmpty, let group = openGroup {
                    // A box with nobody in it frames nothing.
                    guard !diagram.groups[group].members.isEmpty else { return nil }
                    openGroup = nil
                    continue
                }
                guard let block = stack.popLast() else { return nil }
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
            guard let message = diagram.message(line) else { return nil }
            diagram.append(.message(message), to: &stack)
        }
        guard stack.isEmpty, openGroup == nil, !diagram.messages.isEmpty else { return nil }
        // A box frames neighbours: one drawn around participants with a
        // stranger standing between them would say they were in it too.
        for group in diagram.groups {
            let members = group.members.sorted()
            guard members.last! - members.first! == members.count - 1 else { return nil }
        }
        return diagram
    }

    /// A colour written before some words, as `rect` and `box` write one:
    /// `rgb(0,0,255)`, `rgba(0,0,255,0.1)` or a name CSS knows.
    private static func tint(_ text: String) -> (fill: Flowchart.Colour?, label: String) {
        var rest = Substring(text)
        var written = ""
        while let char = rest.first, !char.isWhitespace {
            written.append(char)
            rest = rest.dropFirst()
            // `rgb(0, 0, 255)` has spaces inside it, so the colour is not over
            // until its bracket closes.
            if written.contains("("), !written.hasSuffix(")") {
                guard let close = rest.firstIndex(of: ")") else { return (nil, text) }
                written += rest[rest.startIndex...close]
                rest = rest[rest.index(after: close)...]
                break
            }
        }
        guard let colour = Flowchart.Colour(css: written) else { return (nil, text) }
        return (colour, rest.trimmingCharacters(in: .whitespaces))
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

    private mutating func declare(_ rest: Substring) -> Int? {
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: " as ") {
            let id = String(text[text.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let label = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return index(of: id, label: label)
        }
        return index(of: text, label: text)
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
