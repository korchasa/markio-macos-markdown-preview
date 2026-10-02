import AppKit
import CoreText

/// Draws a parsed Mermaid diagram with the same primitives everything else in a
/// block uses: filled and stroked paths, and glyph runs placed by hand.
///
/// There is no diagram engine and no web view — a flowchart is a few boxes on
/// ranks with lines between them, and a sequence diagram is columns with arrows
/// across them. Both fit in a page of geometry, which is the whole reason this
/// is worth having natively.
@MainActor
enum MermaidLayout {
    struct Drawing {
        var decorations: [BlockBox.Decoration]
        var size: CGSize
        /// How wide the picture itself came out, which is how the caller knows
        /// it has to be drawn again smaller.
        var contentWidth: CGFloat
        /// The page the picture was drawn on, so whoever puts a card behind it
        /// paints the same colour. A diagram that names a Mermaid theme brings
        /// its own, and the card has to follow it rather than the document's.
        var background: CGColor = CGColor(gray: 1, alpha: 1)
        /// Where the picture actually ended up inside `size`, and the margin it
        /// was given. A caller that wants the picture and not the field of card
        /// around it — a bitmap, a file — crops to this instead of asking for
        /// the drawing again at a narrower width, which would be a second
        /// layout and so a second picture.
        var contentRect: CGRect = .zero
        var padding: CGFloat = 16
        /// Where the boxes, lines and words of a graph came to rest, for the
        /// layout bench to count crossings on. Kinds without boxes joined by
        /// lines leave it empty.
        var geometry: Geometry?
    }

    /// The parts of a graph drawing a layout is judged by, in the drawing's own
    /// points. Nothing draws from this; it is read only to measure the layout.
    struct Geometry: Encodable {
        struct Line: Encodable {
            /// The line as drawn, from the border it leaves to the border it
            /// reaches, before the room for its end marks is taken off.
            var points: [CGPoint]
            /// The plate under the line's words, if it has any.
            var label: CGRect?
            /// The boxes the line belongs to — its ends, or everything inside a
            /// frame it ends on — which it may touch without that being a fault.
            var ends: [Int]
            var loop: Bool
        }

        var nodes: [CGRect] = []
        var frames: [CGRect] = []
        var lines: [Line] = []
    }

    /// Every distance in a diagram, scaled together.
    ///
    /// A wide graph is redrawn at a smaller scale rather than clipped, and one
    /// factor over the type size, the padding and the gaps is what keeps the
    /// smaller drawing looking like the same picture instead of a cramped one.
    private struct Metrics {
        var scale: CGFloat = 1
        var nodePaddingX: CGFloat { 14 * scale }
        var nodePaddingY: CGFloat { 9 * scale }
        var minimumNodeWidth: CGFloat { 54 * scale }
        var rankGap: CGFloat { 44 * scale }
        var siblingGap: CGFloat { 32 * scale }
        var arrowLength: CGFloat { 9 * scale }
        var arrowWidth: CGFloat { 7 * scale }
        var messageGap: CGFloat { 34 * scale }
        var columnGap: CGFloat { 40 * scale }
        /// The margin around the picture is the block's, not the diagram's, so
        /// it does not shrink with the drawing.
        let padding: CGFloat = 16
    }

    /// The smallest a diagram is drawn before it is left to run wide.
    ///
    /// A picture shrunk past this is a grey smudge, but a picture cut off at
    /// the column edge is a lie about what the document says — so it shrinks
    /// this far and no further, and whatever is still too wide is shown whole
    /// and small rather than cropped.
    static let minimumScale: CGFloat = 0.08

    /// The smallest lettering a diagram sets, as a fraction of the theme's
    /// control label.
    ///
    /// A few drawings shrink that label a little for the text they crowd most;
    /// nothing goes below this. The enlarged window reads it to decide how far
    /// it may shrink a picture and still leave it readable.
    static let smallestLabelFactor: CGFloat = 0.85

    static func draw(_ diagram: MermaidDiagram, theme: Theme, width: CGFloat) -> Drawing {
        let theme = theme.forDiagrams
        let page = background(of: diagram, theme: theme)
        // A diagram grows with the page it sits on: the reader zoomed the
        // document, not the prose in it.
        let asked = Metrics(scale: theme.metrics.zoom)
        var drawing = settled(
            draw(diagram, theme: theme, width: width, metrics: asked), width: width)
        drawing.background = page
        let room = width - Metrics().padding * 2
        guard room > 0 else { return drawing }
        defer { drawing.background = page }
        // Laying the diagram out again at a smaller scale does not shrink it by
        // exactly that scale — a label that stops wrapping takes a whole line
        // with it — so the fit is approached in a few passes rather than
        // guessed once and cropped when the guess falls short.
        var scale = asked.scale
        var pass = 0
        while drawing.contentWidth > room, drawing.contentWidth > 0, scale > minimumScale,
            pass < 6
        {
            scale = max(minimumScale, scale * room / drawing.contentWidth)
            drawing = settled(
                draw(diagram, theme: theme, width: width, metrics: Metrics(scale: scale)),
                width: width)
            pass += 1
        }
        return drawing
    }

    /// The drawing with the empty card either side of the picture taken off.
    ///
    /// A diagram is centred in the width it was offered, so one drawn at its own
    /// size sits in a field of card. Cutting that away is not the same as asking
    /// for the drawing again at a narrower width: width decides where a label
    /// wraps, so a second layout is a second picture — which is how the page and
    /// the enlarged copy came to disagree.
    static func cropped(_ drawing: Drawing) -> Drawing {
        var copy = drawing
        let dx = drawing.padding - drawing.contentRect.minX
        guard abs(dx) > 0.5 else {
            copy.size.width = drawing.contentRect.width + drawing.padding * 2
            return copy
        }
        copy.decorations = drawing.decorations.map { moved($0, right: dx, down: 0) }
        copy.contentRect = drawing.contentRect.offsetBy(dx: dx, dy: 0)
        copy.size.width = drawing.contentRect.width + drawing.padding * 2
        return copy
    }

    /// The same picture centred in a width that holds it, for a caller who
    /// wants the drawing to fill a column rather than end where it ends.
    static func centred(_ drawing: Drawing, in width: CGFloat) -> Drawing {
        var copy = cropped(drawing)
        let dx = max(0, (width - copy.size.width) / 2)
        guard dx > 0.5 else { return copy }
        copy.decorations = copy.decorations.map { moved($0, right: dx, down: 0) }
        copy.contentRect = copy.contentRect.offsetBy(dx: dx, dy: 0)
        copy.size.width = width
        return copy
    }

    /// The page a diagram is drawn on: the reader's white one, unless the
    /// diagram named a Mermaid theme, which brings its own.
    private static func background(of diagram: MermaidDiagram, theme: Theme) -> CGColor {
        switch diagram {
        case .themed(let name, let inner):
            return background(of: inner, theme: theme.mermaidThemed(name) ?? theme)
        case .titled(_, let inner):
            return background(of: inner, theme: theme)
        default:
            return theme.palette.codeBackground
        }
    }

    private static func draw(
        _ diagram: MermaidDiagram, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        switch diagram {
        case .flowchart(let chart):
            return flowchart(chart, theme: theme, width: width, metrics: metrics)
        case .sequence(let sequence):
            return self.sequence(sequence, theme: theme, width: width, metrics: metrics)
        case .pie(let chart):
            return pie(chart, theme: theme, width: width, metrics: metrics)
        case .boxes(let diagram):
            return boxes(diagram, theme: theme, width: width, metrics: metrics)
        case .mindmap(let map):
            return mindmap(map, theme: theme, width: width, metrics: metrics)
        case .timeline(let line):
            return timeline(line, theme: theme, width: width, metrics: metrics)
        case .journey(let journey):
            return self.journey(journey, theme: theme, width: width, metrics: metrics)
        case .gantt(let chart):
            return gantt(chart, theme: theme, width: width, metrics: metrics)
        case .quadrant(let chart):
            return quadrant(chart, theme: theme, width: width, metrics: metrics)
        case .xy(let chart):
            return xy(chart, theme: theme, width: width, metrics: metrics)
        case .git(let graph):
            return gitGraph(graph, theme: theme, width: width, metrics: metrics)
        case .packet(let diagram):
            return packet(diagram, theme: theme, width: width, metrics: metrics)
        case .kanban(let board):
            return kanban(board, theme: theme, width: width, metrics: metrics)
        case .sankey(let diagram):
            return sankey(diagram, theme: theme, width: width, metrics: metrics)
        case .treemap(let map):
            return treemap(map, theme: theme, width: width, metrics: metrics)
        case .architecture(let diagram):
            return architecture(diagram, theme: theme, width: width, metrics: metrics)
        case .radar(let chart):
            return radar(chart, theme: theme, width: width, metrics: metrics)
        case .blocks(let diagram):
            return blocks(diagram, theme: theme, width: width, metrics: metrics)
        case .empty:
            // Nothing was written, so nothing is drawn: a picture the size of
            // one line, which is what an empty diagram takes up in Mermaid.
            return Drawing(
                decorations: [],
                size: CGSize(width: metrics.padding * 2, height: metrics.padding * 2),
                contentWidth: metrics.padding * 2)
        case .titled(let title, let inner):
            return titled(title, inner, theme: theme, width: width, metrics: metrics)
        case .themed(let name, let inner):
            // The parser only lets through a name this can paint in, so the
            // fallback here is never the one that runs.
            return draw(
                inner, theme: theme.mermaidThemed(name) ?? theme, width: width, metrics: metrics)
        }
    }

    /// The name a diagram's YAML preamble gave it, set above the diagram.
    ///
    /// The picture underneath is drawn exactly as it would have been without a
    /// name, and then moved down to make room, so every kind gets a title
    /// without any kind having to know about one.
    private static func titled(
        _ title: String, _ inner: MermaidDiagram, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let line = text(
            title, font: scaled(theme.bodyBold, by: metrics.scale * 1.1),
            color: theme.palette.text)
        let size = measure(line)
        let room = size.height + 12 * metrics.scale
        var drawing = draw(inner, theme: theme, width: width, metrics: metrics)
        let origin = CGPoint(x: max(metrics.padding, (width - size.width) / 2), y: metrics.padding)
        drawing.decorations =
            [.glyphs(line, origin: origin)] + drawing.decorations.map { moved($0, down: room) }
        drawing.size.height += room
        drawing.contentWidth = max(drawing.contentWidth, size.width)
        return drawing
    }

    private static func moved(
        _ decoration: BlockBox.Decoration, right: CGFloat = 0, down: CGFloat = 0
    ) -> BlockBox.Decoration {
        switch decoration {
        case .fill(let rect, let color, let cornerRadius):
            return .fill(
                rect: rect.offsetBy(dx: right, dy: down), color: color, cornerRadius: cornerRadius)
        case .stroke(let rect, let color, let width):
            return .stroke(rect: rect.offsetBy(dx: right, dy: down), color: color, width: width)
        case .path(let path, let color, let lineWidth, let filled):
            var shift = CGAffineTransform(translationX: right, y: down)
            return .path(
                path.copy(using: &shift) ?? path, color: color, lineWidth: lineWidth,
                filled: filled)
        case .image(let image, let rect):
            return .image(image, rect: rect.offsetBy(dx: right, dy: down))
        case .glyphs(let line, let origin):
            return .glyphs(line, origin: CGPoint(x: origin.x + right, y: origin.y + down))
        }
    }

    /// The rectangle one drawn thing covers.
    ///
    /// A glyph run is placed by its baseline, so its box is read back from the
    /// line's own measurement rather than from the origin alone.
    private static func bounds(of decoration: BlockBox.Decoration) -> CGRect {
        switch decoration {
        case .fill(let rect, _, _): return rect
        case .stroke(let rect, _, let width): return rect.insetBy(dx: -width / 2, dy: -width / 2)
        case .image(_, let rect): return rect
        case .path(let path, _, let lineWidth, let filled):
            let box = path.boundingBoxOfPath
            guard !box.isNull, !box.isInfinite else { return .null }
            return filled ? box : box.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .glyphs(let line, let origin):
            let size = measure(line)
            return CGRect(
                x: origin.x, y: origin.y + descent(line) - size.height,
                width: size.width, height: size.height)
        }
    }

    private static func bounds(of decorations: [BlockBox.Decoration]) -> CGRect? {
        let boxes = decorations.map(bounds(of:)).filter { !$0.isNull && !$0.isInfinite }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The picture measured by what was drawn rather than by what was planned,
    /// and slid back into view if any of it landed outside.
    ///
    /// Each kind reports the width of the boxes it laid out, which is not the
    /// same as the width of the picture: a loop beside a box reaches past
    /// them, and so does a word that outgrew the card it was written in. Both
    /// used to be cut off by the edge of the bitmap — a picture the reader could
    /// see was incomplete. Measuring the decorations catches every such case at
    /// once, including the kinds nobody has thought about yet.
    private static func settled(_ drawing: Drawing, width: CGFloat) -> Drawing {
        var drawing = drawing
        guard let box = bounds(of: drawing.decorations) else { return drawing }
        let padding = Metrics().padding
        drawing.contentWidth = max(drawing.contentWidth, box.width)
        // The shift is signed. A kind centres its picture inside the width it
        // was given using its own measurement, so a part that reaches further
        // right than that measurement knew about — a loop, an overlong
        // word — lands past the right-hand edge with room still free on the
        // left. Sliding only rightwards left that case cropped.
        let wanted = max(padding, (width - box.width) / 2)
        let right = wanted - box.minX
        let down = box.minY < padding ? padding - box.minY : 0
        if abs(right) > 0.5 || down > 0.5 {
            drawing.decorations = drawing.decorations.map { moved($0, right: right, down: down) }
        }
        drawing.size.height = max(drawing.size.height, box.maxY + down + padding)
        // And as wide: a word laid beside a line near the right-hand edge used
        // to be cut off by the bitmap even after the picture had been measured,
        // because only the height grew to hold what was drawn.
        drawing.size.width = max(drawing.size.width, box.maxX + right + padding)
        drawing.contentRect = box.offsetBy(dx: right, dy: down)
        drawing.padding = padding
        return drawing
    }

    // MARK: - Boxes with rows

    private struct Compartment {
        var lines: [CTLine]
        var height: CGFloat
    }

    private struct Entity {
        var frame: CGRect
        var title: CTLine
        var titleSize: CGSize
        var stereotype: CTLine?
        var stereotypeSize: CGSize
        var compartments: [Compartment]
    }

    /// A class diagram and an entity diagram: titled boxes with rows, joined by
    /// lines whose ends say what the relation is.
    private static func boxes(
        _ diagram: BoxDiagram, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let titleFont = scaled(theme.bodyBold, by: metrics.scale)
        let rowFont = scaled(theme.controlLabel, by: metrics.scale)
        let padding = 8 * metrics.scale
        var entities: [Entity] = []
        for box in diagram.boxes {
            let title = text(box.name, font: titleFont, color: theme.palette.text)
            let titleSize = measure(title)
            var stereotype: CTLine?
            var stereotypeSize = CGSize.zero
            if !box.stereotype.isEmpty {
                let line = text(
                    box.stereotype.hasPrefix("<<")
                        ? box.stereotype : "«\(box.stereotype)»", font: rowFont,
                    color: theme.palette.secondaryText)
                stereotype = line
                stereotypeSize = measure(line)
            }
            var widest = max(titleSize.width, stereotypeSize.width)
            var compartments: [Compartment] = []
            for rows in box.compartments where !rows.isEmpty || diagram.keepsEmptyCompartments {
                var lines: [CTLine] = []
                var height: CGFloat = padding
                for row in rows {
                    let line = text(row, font: rowFont, color: theme.palette.text)
                    widest = max(widest, measure(line).width)
                    height += measure(line).height + 2 * metrics.scale
                    lines.append(line)
                }
                compartments.append(Compartment(lines: lines, height: height))
            }
            let header =
                padding * 2 + titleSize.height + (stereotype == nil ? 0 : stereotypeSize.height)
            let height = header + compartments.reduce(0) { $0 + $1.height }
            entities.append(
                Entity(
                    frame: CGRect(
                        x: 0, y: 0, width: widest + padding * 2 + 12 * metrics.scale,
                        height: height),
                    title: title,
                    titleSize: titleSize,
                    stereotype: stereotype,
                    stereotypeSize: stereotypeSize,
                    compartments: compartments
                )
            )
        }

        // A relation keeps room at each end for its marks and its counts, so
        // the stretch between a box and the words or the next box has to hold
        // two of them; the words are a layer of their own.
        let headRoom = 11 * metrics.scale
        let markRoom =
            diagram.links.flatMap { [$0.fromEnd, $0.toEnd] }
            .map { reach(of: $0, room: headRoom) + 3 * metrics.scale }.max() ?? 0
        let colour = theme.palette.secondaryText
        var labelSizes: [Int: CGSize] = [:]
        for (index, link) in diagram.links.enumerated()
        where !link.label.isEmpty && link.from != link.to {
            let said = edgeWords(link.label, font: rowFont, color: colour)
            labelSizes[index] = plate(said.size, centred: .zero).size
        }
        var loops: [Int: CGSize] = [:]
        for link in diagram.links where link.from == link.to {
            let said =
                link.label.isEmpty ? .zero : measure(text(link.label, font: rowFont, color: colour))
            let beside =
                loopReach(metrics) + metrics.arrowLength
                + (said.width > 0 ? said.width + 12 * metrics.scale : 0)
            let below =
                loopReach(metrics) + metrics.arrowLength
                + (said.height > 0 ? said.height + 6 * metrics.scale : 0)
            let known = loops[link.from] ?? .zero
            loops[link.from] = CGSize(
                width: max(known.width, beside), height: max(known.height, below))
        }
        let titleRoom =
            measure(text("X", font: rowFont, color: theme.palette.text)).height
            + 10 * metrics.scale
        // The same layout a flowchart gets: a namespace is a frame, a relation
        // an edge between two boxes.
        let chart = Flowchart(
            direction: diagram.direction, nodes: [],
            edges: diagram.links.map {
                Flowchart.Edge(
                    from: $0.from, to: $0.to, label: $0.label, stroke: .solid, arrow: false)
            },
            groups: diagram.namespaces.enumerated().map { index, space in
                Flowchart.Group(
                    title: space.name,
                    members: diagram.boxes.indices.filter { diagram.boxes[$0].namespace == index },
                    parent: space.parent)
            })
        let placement = placed(
            chart: chart, sizes: entities.map(\.frame.size), labels: labelSizes, loops: loops,
            metrics: metrics, titleRoom: titleRoom, inset: 12 * metrics.scale,
            layerGap: metrics.rankGap,
            // Two crow's feet side by side need their own width apart, and a
            // little more, or they read as one mark; and a line turns only
            // past its mark and the count written beside it.
            lineGap: 18 * metrics.scale, endRoom: markRoom + 12 * metrics.scale, inTextOrder: true)
        var content = placement.size
        for link in diagram.links where link.from == link.to {
            guard let frame = placement.nodes[link.from], let room = loops[link.from] else {
                continue
            }
            if placement.below.contains(link.from) {
                content.height = max(content.height, frame.maxY + room.height)
            } else {
                content.width = max(content.width, frame.maxX + room.width)
            }
        }
        let left = max(metrics.padding, (width - content.width) / 2)
        for index in entities.indices {
            entities[index].frame = (placement.nodes[index] ?? .zero).offsetBy(dx: left, dy: 0)
        }
        // A namespace's name is written inside its frame, in the strip the
        // layout kept above what the frame holds.
        let walls = diagram.namespaces.indices.compactMap {
            index -> (rect: CGRect, name: String)? in
            guard let box = placement.frames[index] else { return nil }
            return (
                rect: CGRect(
                    x: box.minX + left, y: box.minY - titleRoom, width: box.width,
                    height: box.height + titleRoom),
                name: diagram.namespaces[index].name
            )
        }
        // Where every box came to rest, taken once and not read again from the
        // array they live in. A relation asks this while it is being routed,
        // and a closure that reaches back into a variable the surrounding code
        // can still write to is a closure sharing something that may change.
        let placed = entities.map(\.frame)

        let slips = notes(
            diagram.notes, beside: placed, theme: theme, font: rowFont,
            metrics: metrics)

        let drawnRoutes = placement.routes.compactMap { index, route -> [CGPoint]? in
            let link = diagram.links[index]
            guard link.from < placed.count, link.to < placed.count else { return nil }
            return carried(
                route.map { CGPoint(x: $0.x + left, y: $0.y) }, from: placed[link.from],
                to: placed[link.to], boxes: placed)
        }
        var decorations: [BlockBox.Decoration] = []
        for wall in walls {
            decorations += namespace(
                wall.rect, named: wall.name, theme: theme, font: rowFont, metrics: metrics,
                titleRoom: titleRoom, routes: drawnRoutes)
        }
        var geometry = Geometry(nodes: placed, frames: walls.map(\.rect))
        for (index, link) in diagram.links.enumerated() {
            guard link.from < entities.count, link.to < entities.count else { continue }
            let from = placed[link.from]
            let to = placed[link.to]
            let drawn = relation(
                link, from: from, to: to,
                route: placement.routes[index].map {
                    carried(
                        $0.map { CGPoint(x: $0.x + left, y: $0.y) }, from: from, to: to,
                        boxes: placed)
                },
                wordsAt: placement.labels[index]?.offsetBy(dx: left, dy: 0),
                loopBelow: placement.below.contains(link.from), theme: theme, font: rowFont,
                metrics: metrics)
            decorations += drawn.decorations
            geometry.lines.append(
                Geometry.Line(
                    points: drawn.path, label: drawn.plate, ends: [link.from, link.to],
                    loop: link.from == link.to))
        }
        for (index, entity) in entities.enumerated() {
            decorations += self.entity(
                entity, style: diagram.boxes[index].style, theme: theme, padding: padding,
                metrics: metrics)
        }
        decorations += slips
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: content.height + metrics.padding * 2),
            contentWidth: content.width,
            geometry: geometry
        )
    }

    /// The titled frame a `namespace` draws around the classes inside it.
    /// The x of every upright stretch of line that crosses a horizontal strip
    /// inside the given span — what a frame's name has to keep clear of.
    private static func crossings(
        of routes: [[CGPoint]], strip top: CGFloat, _ bottom: CGFloat, from left: CGFloat,
        to right: CGFloat
    ) -> [CGFloat] {
        var found: [CGFloat] = []
        for route in routes {
            for (a, b) in zip(route, route.dropFirst())
            where abs(a.x - b.x) < 0.5 && a.x > left && a.x < right
                && min(a.y, b.y) < bottom - 0.5 && max(a.y, b.y) > top + 0.5
            {
                found.append(a.x)
            }
        }
        return found
    }

    /// The first place from the left, between two edges, where words of a
    /// given width stand clear of every crossing line; nil when there is none.
    private static func spot(
        _ width: CGFloat, from left: CGFloat, to right: CGFloat, clear of: [CGFloat],
        by clearance: CGFloat
    ) -> CGFloat? {
        var x = left
        while x + width <= right {
            guard
                let hit = of.filter({ $0 > x - clearance && $0 < x + width + clearance }).max()
            else { return x }
            x = hit + clearance
        }
        return nil
    }

    private static func namespace(
        _ rect: CGRect, named name: String, theme: Theme, font: CTFont, metrics: Metrics,
        titleRoom: CGFloat, routes: [[CGPoint]]
    ) -> [BlockBox.Decoration] {
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        let line = text(name, font: font, color: theme.palette.secondaryText)
        let size = measure(line)
        return [
            .path(path, color: theme.palette.codeBackground, lineWidth: 0, filled: true),
            .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false),
            // Written at the left, as a flowchart frame's name is, unless a
            // line crosses it there; then wherever along the strip none does.
            .glyphs(
                line,
                origin: CGPoint(
                    x: spot(
                        size.width, from: rect.minX + 8 * metrics.scale,
                        to: rect.maxX - 8 * metrics.scale,
                        clear: crossings(
                            of: routes, strip: rect.minY, rect.minY + titleRoom, from: rect.minX,
                            to: rect.maxX),
                        by: 4 * metrics.scale) ?? rect.minX + 8 * metrics.scale,
                    y: rect.minY + 6 * metrics.scale + size.height
                )),
        ]
    }

    /// The notes of a class diagram, drawn where they will not cover a box.
    ///
    /// A note tied to a box stands to its left, and is slid further left until
    /// it covers nothing — a note laid over the picture says less than no note
    /// at all. A note standing on its own has nowhere it belongs, so it goes in
    /// a row above everything. Both may end up outside the rectangle the boxes
    /// were laid out in; the drawing is measured by what was drawn, so the
    /// picture grows to hold them.
    private static func notes(
        _ notes: [BoxDiagram.Note], beside frames: [CGRect], theme: Theme, font: CTFont,
        metrics: Metrics
    ) -> [BlockBox.Decoration] {
        guard !notes.isEmpty else { return [] }
        let padding = 8 * metrics.scale
        let gap = 24 * metrics.scale
        var taken = frames
        var decorations: [BlockBox.Decoration] = []
        let top = frames.map(\.minY).min() ?? metrics.padding
        var free = frames.map(\.minX).min() ?? metrics.padding
        for note in notes {
            let (lines, size) = labelLines(note.text, font: font, color: theme.palette.text)
            let width = size.width + padding * 2
            let height = size.height + padding * 2
            var rect: CGRect
            if let attached = note.attached, attached < frames.count {
                let box = frames[attached]
                rect = CGRect(
                    x: box.minX - gap - width, y: box.minY, width: width, height: height)
                // Slide left of whatever it lands on, and of whatever that
                // uncovers, until the slip stands clear.
                for _ in 0..<taken.count {
                    guard let hit = taken.first(where: { $0.intersects(rect) }) else { break }
                    rect.origin.x = hit.minX - gap - width
                }
                decorations.append(
                    .path(
                        dashed(
                            from: CGPoint(x: rect.maxX, y: rect.midY),
                            to: CGPoint(x: box.minX, y: box.midY), dash: 3 * metrics.scale,
                            gap: 3 * metrics.scale),
                        color: theme.palette.secondaryText, lineWidth: 1, filled: false))
            } else {
                rect = CGRect(x: free, y: top - gap - height, width: width, height: height)
                free = rect.maxX + gap
            }
            taken.append(rect)
            let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            decorations.append(
                .path(path, color: theme.palette.codeBackground, lineWidth: 0, filled: true))
            decorations.append(
                .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
            var y = rect.minY + padding
            for line in lines {
                let size = measure(line)
                decorations.append(
                    .glyphs(
                        line,
                        origin: CGPoint(x: rect.minX + padding, y: y + size.height - descent(line)))
                )
                y += size.height
            }
        }
        return decorations
    }

    private static func entity(
        _ entity: Entity, style: Flowchart.Style, theme: Theme, padding: CGFloat, metrics: Metrics
    ) -> [BlockBox.Decoration] {
        let frame = entity.frame
        let path = CGPath(roundedRect: frame, cornerWidth: 3, cornerHeight: 3, transform: nil)
        var decorations: [BlockBox.Decoration] = [
            .path(
                path,
                color: faded(
                    authorFill(
                        style, or: theme.palette.background, ink: theme.palette.text, theme: theme),
                    by: style), lineWidth: 0, filled: true),
            .path(
                path,
                color: faded(style.stroke.map(cgColor) ?? theme.palette.tableBorder, by: style),
                lineWidth: (style.strokeWidth.map { CGFloat($0) } ?? 1) * metrics.scale,
                filled: false),
        ]
        var y = frame.minY + padding
        if let stereotype = entity.stereotype {
            decorations.append(
                .glyphs(
                    stereotype,
                    origin: CGPoint(
                        x: frame.midX - entity.stereotypeSize.width / 2,
                        y: y + entity.stereotypeSize.height - descent(stereotype)
                    )
                )
            )
            y += entity.stereotypeSize.height
        }
        decorations.append(
            .glyphs(
                entity.title,
                origin: CGPoint(
                    x: frame.midX - entity.titleSize.width / 2,
                    y: y + entity.titleSize.height - descent(entity.title)
                )
            )
        )
        y += entity.titleSize.height + padding
        for compartment in entity.compartments {
            let rule = CGMutablePath()
            rule.move(to: CGPoint(x: frame.minX, y: y))
            rule.addLine(to: CGPoint(x: frame.maxX, y: y))
            decorations.append(
                .path(rule, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
            var rowY = y + padding / 2
            for line in compartment.lines {
                let size = measure(line)
                decorations.append(
                    .glyphs(
                        line,
                        origin: CGPoint(
                            x: frame.minX + padding, y: rowY + size.height - descent(line))))
                rowY += size.height + 2 * metrics.scale
            }
            y += compartment.height
        }
        return decorations
    }

    private static func relation(
        _ link: BoxDiagram.Link, from: CGRect, to: CGRect, route: [CGPoint]?, wordsAt: CGRect?,
        loopBelow: Bool, theme: Theme, font: CTFont, metrics: Metrics
    ) -> (decorations: [BlockBox.Decoration], path: [CGPoint], plate: CGRect?) {
        let colour = theme.palette.secondaryText
        // A relation is a line between two boxes like any other, so it runs
        // the way the layout routed it, corners rounded, as a flowchart edge
        // does; only its end marks and its counts belong to the diagram that
        // wrote it. A loop is the one line the layout leaves to the caller.
        let points: [CGPoint]
        if let route, route.count >= 2 {
            points = rounded(route, radius: 12 * metrics.scale)
        } else if loopBelow && from == to {
            let reach = loopReach(metrics) * 4 / 3
            let left = from.minX + from.width / 4
            let right = from.maxX - from.width / 4
            points = samples(
                from: CGPoint(x: right, y: from.maxY),
                out: CGPoint(x: right, y: from.maxY + reach),
                in: CGPoint(x: left, y: from.maxY + reach),
                to: CGPoint(x: left, y: from.maxY))
        } else {
            points = connection(from: from, to: to, metrics: metrics)
        }
        let start = points[0]
        let end = points[points.count - 1]
        // Which way the line is going where it meets each box, which is where
        // the marks stand and which way they face.
        let direction = normalized(
            CGPoint(x: points[1].x - start.x, y: points[1].y - start.y))
        let backwards = normalized(
            CGPoint(
                x: points[points.count - 2].x - end.x, y: points[points.count - 2].y - end.y))
        let headRoom = 11 * metrics.scale
        // A crow's foot stands a little off the entity rather than on its
        // border; the marks a class diagram draws touch the box, as they should.
        let clear = 3 * metrics.scale
        var shaftPath = shortened(points, by: inset(link.toEnd, room: headRoom, clear: clear))
        shaftPath = shortened(
            shaftPath.reversed(), by: inset(link.fromEnd, room: headRoom, clear: clear)
        ).reversed()
        var decorations: [BlockBox.Decoration] = []
        if link.dashed {
            decorations.append(
                .path(
                    dashed(along: shaftPath, dash: 5, gap: 4), color: colour, lineWidth: 1.3,
                    filled: false))
        } else {
            let shaft = CGMutablePath()
            shaft.move(to: shaftPath[0])
            for point in shaftPath.dropFirst() { shaft.addLine(to: point) }
            decorations.append(.path(shaft, color: colour, lineWidth: 1.3, filled: false))
        }
        func off(_ end: BoxDiagram.End, _ point: CGPoint, _ away: CGPoint) -> CGPoint {
            switch end {
            case .one, .zeroOrOne, .oneOrMore, .zeroOrMore:
                return CGPoint(x: point.x + away.x * clear, y: point.y + away.y * clear)
            default: return point
            }
        }
        decorations += terminal(
            link.fromEnd, at: off(link.fromEnd, start, direction),
            direction: CGPoint(x: -direction.x, y: -direction.y), theme: theme, metrics: metrics)
        decorations += terminal(
            link.toEnd, at: off(link.toEnd, end, backwards),
            direction: CGPoint(x: -backwards.x, y: -backwards.y), theme: theme, metrics: metrics)

        // A count stands beside the line, a little way along it from its own
        // box, so it never lands on the box or on the relation's own words.
        for (words, point, away) in [
            (link.fromCount, start, direction), (link.toCount, end, backwards),
        ] where !words.isEmpty {
            let line = text(words, font: font, color: colour)
            let size = measure(line)
            let across = CGPoint(x: -away.y, y: away.x)
            let centre = CGPoint(
                x: point.x + away.x * 20 * metrics.scale + across.x * (size.height * 0.8),
                y: point.y + away.y * 20 * metrics.scale + across.y * (size.height * 0.8)
            )
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: centre.x - size.width / 2,
                        y: centre.y + size.height / 2 - descent(line)
                    )
                )
            )
        }
        guard !link.label.isEmpty else { return (decorations, points, nil) }
        // The layout made a block for the words; they are written in it.
        if let wordsAt {
            let said = edgeWords(link.label, font: font, color: colour)
            decorations.append(
                .fill(rect: wordsAt, color: theme.palette.background, cornerRadius: 2))
            decorations += centred(said.lines, size: said.size, in: wordsAt)
            return (decorations, points, wordsAt)
        }
        let line = text(link.label, font: font, color: colour)
        let size = measure(line)
        // Half way along the line the line actually takes, not half way between
        // the boxes: on a line that turns, the two are not the same place. A
        // loop is the exception — its words stand past its furthest point.
        let apex = point(along: points, at: length(of: points) / 2).point
        let middle =
            from != to
            ? apex
            : loopBelow
                ? CGPoint(x: apex.x, y: apex.y + size.height / 2 + 6 * metrics.scale)
                : CGPoint(x: apex.x + size.width / 2 + 6 * metrics.scale, y: apex.y)
        let plate = CGRect(
            x: middle.x - size.width / 2 - 3, y: middle.y - size.height / 2 - 1,
            width: size.width + 6, height: size.height + 2)
        decorations.append(.fill(rect: plate, color: theme.palette.background, cornerRadius: 2))
        decorations.append(
            .glyphs(
                line,
                origin: CGPoint(
                    x: middle.x - size.width / 2, y: middle.y + size.height / 2 - descent(line))))
        return (decorations, points, plate)
    }

    /// How far an end's marks reach out from the box: a crow's foot with a
    /// circle beyond it is the longest, and needs a little clear space too.
    private static func reach(of end: BoxDiagram.End, room: CGFloat) -> CGFloat {
        switch end {
        case .one, .zeroOrOne, .oneOrMore, .zeroOrMore: return room * 1.9
        default: return inset(end, room: room, clear: 0)
        }
    }

    /// How far the shaft stops short of the box, to leave the end its room.
    private static func inset(_ end: BoxDiagram.End, room: CGFloat, clear: CGFloat) -> CGFloat {
        switch end {
        case .none: return 0
        case .arrow, .triangle: return room
        case .diamond, .hollowDiamond: return room * 1.3
        // An entity's marks are drawn across the line, so the line runs on
        // under them to where they start, just clear of the entity's border.
        // Stopped short of them, it left the bars of "exactly one" hanging in
        // the air between the line and the box.
        case .one, .zeroOrOne, .oneOrMore, .zeroOrMore: return clear
        }
    }

    /// What is drawn where a line meets a box.
    private static func terminal(
        _ end: BoxDiagram.End, at tip: CGPoint, direction: CGPoint, theme: Theme, metrics: Metrics
    ) -> [BlockBox.Decoration] {
        let colour = theme.palette.secondaryText
        let side = CGPoint(x: -direction.y, y: direction.x)
        let length = 11 * metrics.scale
        let half = 5 * metrics.scale
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(
                x: tip.x - direction.x * along + side.x * across,
                y: tip.y - direction.y * along + side.y * across)
        }
        switch end {
        case .none:
            return []
        case .arrow:
            // An association is drawn as an open head — two strokes meeting at
            // the box — and never as a filled one: a filled head is what a
            // different relation means.
            let path = CGMutablePath()
            path.move(to: point(length, half))
            path.addLine(to: tip)
            path.addLine(to: point(length, -half))
            return [.path(path, color: colour, lineWidth: 1.3, filled: false)]
        case .triangle:
            let path = CGMutablePath()
            path.move(to: tip)
            path.addLine(to: point(length, half + 1))
            path.addLine(to: point(length, -half - 1))
            path.closeSubpath()
            return [
                .path(path, color: theme.palette.background, lineWidth: 0, filled: true),
                .path(path, color: colour, lineWidth: 1.3, filled: false),
            ]
        case .diamond, .hollowDiamond:
            let path = CGMutablePath()
            path.move(to: tip)
            path.addLine(to: point(length * 0.7, half))
            path.addLine(to: point(length * 1.4, 0))
            path.addLine(to: point(length * 0.7, -half))
            path.closeSubpath()
            return end == .diamond
                ? [.path(path, color: colour, lineWidth: 0, filled: true)]
                : [
                    .path(path, color: theme.palette.background, lineWidth: 0, filled: true),
                    .path(path, color: colour, lineWidth: 1.3, filled: false),
                ]
        case .one, .zeroOrOne, .oneOrMore, .zeroOrMore:
            // A crow's foot: a bar or a circle for whether none is allowed, and
            // three prongs for whether many are.
            var decorations: [BlockBox.Decoration] = []
            let many = end == .oneOrMore || end == .zeroOrMore
            if many {
                // The foot spreads where it meets the entity and gathers to a
                // point away from it, which is the way it is read: many of this
                // stand against one of that.
                let crow = CGMutablePath()
                for across in [half, 0, -half] {
                    crow.move(to: point(length, 0))
                    crow.addLine(to: point(0, across))
                }
                decorations.append(.path(crow, color: colour, lineWidth: 1.3, filled: false))
            }
            let mark = many ? length : length * 0.45
            if end == .zeroOrOne || end == .zeroOrMore {
                let radius = 3.5 * metrics.scale
                let centre = point(mark + radius, 0)
                let circle = CGPath(
                    ellipseIn: CGRect(
                        x: centre.x - radius, y: centre.y - radius, width: radius * 2,
                        height: radius * 2), transform: nil)
                decorations.append(
                    .path(circle, color: theme.palette.background, lineWidth: 0, filled: true))
                decorations.append(.path(circle, color: colour, lineWidth: 1.3, filled: false))
            } else {
                // "Exactly one" is two bars, "one or many" the crow plus one.
                let bar = CGMutablePath()
                for along in end == .one ? [mark, mark + 4 * metrics.scale] : [mark] {
                    bar.move(to: point(along, half))
                    bar.addLine(to: point(along, -half))
                }
                decorations.append(.path(bar, color: colour, lineWidth: 1.3, filled: false))
            }
            return decorations
        }
    }

    // MARK: - Pie chart

    /// Slice colours, written down rather than taken from the theme: a pie says
    /// which slice is which by colour, so the colours have to stay apart from
    /// each other and readable on either background.
    private static func pie(
        _ chart: PieChart, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale)
        let diameter = 180 * metrics.scale
        let swatch = 12 * metrics.scale
        // Every slice at nothing leaves no wedge to cut, so none is drawn; the
        // legend still says what the author wrote, which is what Mermaid draws.
        let total = chart.total

        var entries: [(line: CTLine, size: CGSize)] = []
        for slice in chart.slices {
            let share = total > 0 ? Int((slice.value / total * 100).rounded()) : 0
            let number =
                slice.value == slice.value.rounded() ? "\(Int(slice.value))" : "\(slice.value)"
            let words =
                chart.showData
                ? "\(slice.label) — \(number) (\(share)%)" : "\(slice.label) — \(share)%"
            let line = text(words, font: font, color: theme.palette.text)
            entries.append((line, measure(line)))
        }
        let legendWidth =
            (entries.map(\.size.width).max() ?? 0) + swatch + 8 * metrics.scale
        let legendHeight =
            entries.reduce(0) { $0 + $1.size.height + 6 * metrics.scale } - 6 * metrics.scale
        let gap = 24 * metrics.scale
        let content = diameter + gap + legendWidth

        var titleLine: CTLine?
        var titleSize = CGSize.zero
        if !chart.title.isEmpty {
            let line = text(chart.title, font: titleFont, color: theme.palette.text)
            titleLine = line
            titleSize = measure(line)
        }
        let titleRoom = titleLine == nil ? 0 : titleSize.height + 14 * metrics.scale
        let bodyHeight = max(diameter, legendHeight)
        let height = metrics.padding * 2 + titleRoom + bodyHeight

        let left = max(metrics.padding, (width - content) / 2)
        var decorations: [BlockBox.Decoration] = []
        if let titleLine {
            decorations.append(
                .glyphs(
                    titleLine,
                    origin: CGPoint(
                        x: max(metrics.padding, (width - titleSize.width) / 2),
                        y: metrics.padding + titleSize.height - descent(titleLine)
                    )
                )
            )
        }
        let centre = CGPoint(
            x: left + diameter / 2,
            y: metrics.padding + titleRoom + bodyHeight / 2
        )
        // Wedges start at twelve o'clock and go round clockwise, which is the
        // order a reader expects the first slice to be in.
        var angle = -CGFloat.pi / 2
        for (index, slice) in chart.slices.enumerated() where total > 0 {
            let sweep = CGFloat(slice.value / total) * .pi * 2
            let wedge = CGMutablePath()
            wedge.move(to: centre)
            wedge.addArc(
                center: centre, radius: diameter / 2, startAngle: angle, endAngle: angle + sweep,
                clockwise: false)
            wedge.closeSubpath()
            decorations.append(
                .path(
                    wedge, color: theme.diagramWheel[index % theme.diagramWheel.count],
                    lineWidth: 0, filled: true))
            decorations.append(
                .path(wedge, color: theme.palette.background, lineWidth: 1, filled: false))
            angle += sweep
        }

        var y = metrics.padding + titleRoom + (bodyHeight - legendHeight) / 2
        for (index, entry) in entries.enumerated() {
            let box = CGRect(
                x: left + diameter + gap,
                y: y + (entry.size.height - swatch) / 2,
                width: swatch,
                height: swatch
            )
            decorations.append(
                .fill(
                    rect: box, color: theme.diagramWheel[index % theme.diagramWheel.count],
                    cornerRadius: 2))
            decorations.append(
                .glyphs(
                    entry.line,
                    origin: CGPoint(
                        x: box.maxX + 8 * metrics.scale,
                        y: y + entry.size.height - descent(entry.line)
                    )
                )
            )
            y += entry.size.height + 6 * metrics.scale
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    // MARK: - Mindmap

    /// A mindmap: the root on the left, its branches opening to the right.
    ///
    /// Depth decides the column and nothing else does, so every node the same
    /// number of steps from the root lines up. A parent is then centred on the
    /// children it opens, which is what makes a branch read as one thing however
    /// deep it goes.
    private static func mindmap(
        _ map: Mindmap, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let fonts = [
            scaled(theme.bodyBold, by: metrics.scale * 1.1),
            scaled(theme.body, by: metrics.scale),
            scaled(theme.body, by: metrics.scale * 0.92),
        ]
        // Which top-level branch each node hangs off, so a branch keeps one
        // colour from its first node to its last leaf.
        var branch = [Int](repeating: 0, count: map.nodes.count)
        for (index, node) in map.nodes.enumerated() {
            for (position, child) in node.children.enumerated() {
                branch[child] = index == 0 ? position : branch[index]
            }
        }

        var boxes: [Placed] = []
        for (index, node) in map.nodes.enumerated() {
            let font = fonts[min(node.depth, fonts.count - 1)]
            let (lines, size) = labelLines(node.label, font: font, color: theme.palette.text)
            var box = CGSize(
                width: size.width + metrics.nodePaddingX * 2,
                height: size.height + metrics.nodePaddingY * 2
            )
            if node.shape == .circle { box.width = max(box.width, box.height) }
            if node.shape == .hexagon { box.width += size.width * 0.2 }
            if node.shape == .cloud || node.shape == .bang {
                box.width += size.width * 0.4 + 20 * metrics.scale
                box.height += size.height * 0.8
            }
            // The branch's colour is the outline unless the author painted one.
            var style = Flowchart.Style(
                stroke: colour(theme.diagramWheel[branch[index] % theme.diagramWheel.count]))
            style.merge(node.style)
            boxes.append(
                Placed(
                    frame: CGRect(origin: .zero, size: box),
                    lines: lines,
                    labelSize: size,
                    shape: node.shape,
                    style: style
                )
            )
        }

        // Columns first: a node's x is settled by its depth alone.
        let deepest = map.nodes.map(\.depth).max() ?? 0
        var columns = [CGFloat](repeating: 0, count: deepest + 1)
        for (index, node) in map.nodes.enumerated() {
            columns[node.depth] = max(columns[node.depth], boxes[index].frame.width)
        }
        var lefts = [CGFloat](repeating: 0, count: columns.count)
        for depth in 1..<max(1, columns.count) {
            lefts[depth] = lefts[depth - 1] + columns[depth - 1] + metrics.rankGap
        }
        for index in boxes.indices { boxes[index].frame.origin.x = lefts[map.nodes[index].depth] }

        // Then rows: leaves take the next free line, parents take the middle of
        // the children they opened.
        let rowGap = 10 * metrics.scale
        var cursor: CGFloat = 0
        func place(_ index: Int) {
            let children = map.nodes[index].children
            guard let first = children.first, let last = children.last else {
                boxes[index].frame.origin.y = cursor
                cursor += boxes[index].frame.height + rowGap
                return
            }
            for child in children { place(child) }
            let middle = (boxes[first].frame.midY + boxes[last].frame.midY) / 2
            boxes[index].frame.origin.y = middle - boxes[index].frame.height / 2
        }
        place(0)

        // A root taller than everything it opens would be placed above the top
        // of the picture, so the whole tree is dropped back into view.
        let top = boxes.map(\.frame.minY).min() ?? 0
        let bottom = boxes.map(\.frame.maxY).max() ?? 0
        let content = CGSize(
            width: (boxes.map(\.frame.maxX).max() ?? 0), height: bottom - top)
        let left = max(metrics.padding, (width - content.width) / 2)
        for index in boxes.indices {
            boxes[index].frame.origin.x += left
            boxes[index].frame.origin.y += metrics.padding - top
        }

        var decorations: [BlockBox.Decoration] = []
        for (index, node) in map.nodes.enumerated() {
            for child in node.children {
                let start = CGPoint(x: boxes[index].frame.maxX, y: boxes[index].frame.midY)
                let end = CGPoint(x: boxes[child].frame.minX, y: boxes[child].frame.midY)
                let path = CGMutablePath()
                path.move(to: start)
                let waist = (start.x + end.x) / 2
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: waist, y: start.y),
                    control2: CGPoint(x: waist, y: end.y)
                )
                decorations.append(
                    .path(
                        path,
                        color: theme.diagramWheel[branch[child] % theme.diagramWheel.count],
                        // A branch near the root is drawn thicker, the way a
                        // trunk is thicker than a twig.
                        lineWidth: max(1, 3 - CGFloat(map.nodes[child].depth)) * metrics.scale,
                        filled: false
                    )
                )
            }
        }
        for box in boxes { decorations += node(box, theme: theme, metrics: metrics) }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: content.height + metrics.padding * 2),
            contentWidth: content.width
        )
    }

    /// Turns a drawn colour back into the registry's, so a mindmap can hand a
    /// stroke to the same node drawer a flowchart uses.
    private static func colour(_ value: CGColor) -> Flowchart.Colour {
        let parts = value.components ?? [0, 0, 0, 1]
        guard parts.count >= 3 else { return Flowchart.Colour(red: 0, green: 0, blue: 0) }
        return Flowchart.Colour(
            red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }

    // MARK: - Timeline

    /// A timeline: periods across the page, what happened in each one under it.
    private static func timeline(
        _ timeline: Timeline, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        if timeline.downward {
            return timelineDown(timeline, theme: theme, width: width, metrics: metrics)
        }
        let font = scaled(theme.body, by: metrics.scale * 0.94)
        let periodFont = scaled(theme.bodyBold, by: metrics.scale)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale * 1.1)
        let pad = 8 * metrics.scale
        let gap = 12 * metrics.scale

        struct Column {
            var head: [CTLine]
            var headSize: CGSize
            var events: [(lines: [CTLine], size: CGSize)]
            var frame: CGRect
            var tint: CGColor
        }
        var columns: [Column] = []
        for (index, period) in timeline.periods.enumerated() {
            let head = labelLines(period.title, font: periodFont, color: theme.palette.text)
            var widest = head.size.width
            var events: [(lines: [CTLine], size: CGSize)] = []
            var stack: CGFloat = 0
            for event in period.events {
                let (lines, size) = labelLines(event, font: font, color: theme.palette.text)
                widest = max(widest, size.width)
                stack += size.height + pad * 2 + 6 * metrics.scale
                events.append((lines, size))
            }
            columns.append(
                Column(
                    head: head.lines,
                    headSize: head.size,
                    events: events,
                    frame: CGRect(
                        x: 0, y: 0, width: max(96 * metrics.scale, widest + pad * 2),
                        height: stack),
                    tint: theme.diagramWheel[(period.section ?? index) % theme.diagramWheel.count]
                )
            )
        }
        var x: CGFloat = 0
        for index in columns.indices {
            columns[index].frame.origin.x = x
            x += columns[index].frame.width + gap
        }
        let content = x - gap

        var titleLine: CTLine?
        var titleSize = CGSize.zero
        if !timeline.title.isEmpty {
            let line = text(timeline.title, font: titleFont, color: theme.palette.text)
            titleLine = line
            titleSize = measure(line)
        }
        let titleRoom = titleLine == nil ? 0 : titleSize.height + 14 * metrics.scale
        let headHeight = (columns.map(\.headSize.height).max() ?? 0) + pad * 2
        let sectionHeight =
            timeline.sections.isEmpty
            ? 0
            : (timeline.sections.map {
                labelLines($0, font: font, color: theme.palette.text).size.height
            }.max() ?? 0) + pad * 2 + 8 * metrics.scale
        let bodyHeight = columns.map(\.frame.height).max() ?? 0
        let height =
            metrics.padding * 2 + titleRoom + sectionHeight + headHeight + 18 * metrics.scale
            + bodyHeight

        let left = max(metrics.padding, (width - content) / 2)
        var decorations: [BlockBox.Decoration] = []
        if let titleLine {
            decorations.append(
                .glyphs(
                    titleLine,
                    origin: CGPoint(
                        x: max(metrics.padding, (width - titleSize.width) / 2),
                        y: metrics.padding + titleSize.height - descent(titleLine)
                    )
                )
            )
        }

        // A section is a band over the run of periods it owns, so its span says
        // which columns belong to it without a line joining them.
        let sectionTop = metrics.padding + titleRoom
        for (index, name) in timeline.sections.enumerated() {
            let owned = columns.indices.filter { timeline.periods[$0].section == index }
            guard let first = owned.first, let last = owned.last else { continue }
            let band = CGRect(
                x: left + columns[first].frame.minX,
                y: sectionTop,
                width: columns[last].frame.maxX - columns[first].frame.minX,
                height: sectionHeight - 8 * metrics.scale
            )
            decorations.append(
                .fill(
                    rect: band,
                    color: theme.diagramWheel[index % theme.diagramWheel.count].copy(alpha: 0.22)
                        ?? theme.diagramWheel[0],
                    cornerRadius: 4 * metrics.scale))
            let (lines, size) = labelLines(name, font: font, color: theme.palette.text)
            decorations += centred(lines, size: size, in: band)
        }

        let headTop = sectionTop + sectionHeight
        let axis = headTop + headHeight + 9 * metrics.scale
        let rule = CGMutablePath()
        rule.move(to: CGPoint(x: left, y: axis))
        rule.addLine(to: CGPoint(x: left + content, y: axis))
        decorations.append(
            .path(rule, color: theme.palette.tableBorder, lineWidth: 1, filled: false))

        for column in columns {
            let head = CGRect(
                x: left + column.frame.minX, y: headTop, width: column.frame.width,
                height: headHeight)
            decorations.append(
                .fill(
                    rect: head, color: column.tint.copy(alpha: 0.3) ?? column.tint,
                    cornerRadius: 4 * metrics.scale))
            decorations += centred(column.head, size: column.headSize, in: head)
            // The dot is what ties the column to the line under it.
            let dot = CGRect(
                x: head.midX - 3 * metrics.scale, y: axis - 3 * metrics.scale,
                width: 6 * metrics.scale, height: 6 * metrics.scale)
            decorations.append(
                .path(
                    CGPath(ellipseIn: dot, transform: nil), color: column.tint, lineWidth: 0,
                    filled: true))

            var y = axis + 9 * metrics.scale
            for event in column.events {
                let card = CGRect(
                    x: left + column.frame.minX, y: y, width: column.frame.width,
                    height: event.size.height + pad * 2)
                decorations.append(
                    .fill(
                        rect: card, color: column.tint.copy(alpha: 0.14) ?? column.tint,
                        cornerRadius: 4 * metrics.scale))
                decorations += centred(event.lines, size: event.size, in: card)
                y = card.maxY + 6 * metrics.scale
            }
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    /// `timeline TD`: the same timeline with the line of travel running down
    /// the page. Each period is a row — its name on the left of the rule, what
    /// happened in it on the right — and a section is a band across the rows it
    /// owns.
    private static func timelineDown(
        _ timeline: Timeline, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale * 0.94)
        let periodFont = scaled(theme.bodyBold, by: metrics.scale)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale * 1.1)
        let pad = 8 * metrics.scale
        let gap = 8 * metrics.scale

        struct Row {
            var head: [CTLine]
            var headSize: CGSize
            var events: [(lines: [CTLine], size: CGSize)]
            var height: CGFloat
            var tint: CGColor
        }
        var rows: [Row] = []
        var headWidth = 90 * metrics.scale
        var eventWidth = 120 * metrics.scale
        for (index, period) in timeline.periods.enumerated() {
            let (head, headSize) = labelLines(
                period.title, font: periodFont, color: theme.palette.text)
            headWidth = max(headWidth, headSize.width + pad * 2)
            var events: [(lines: [CTLine], size: CGSize)] = []
            var stack: CGFloat = 0
            for event in period.events {
                let (lines, size) = labelLines(event, font: font, color: theme.palette.text)
                eventWidth = max(eventWidth, size.width + pad * 2)
                stack += size.height + pad * 2 + gap
                events.append((lines, size))
            }
            let rowHeight = max(headSize.height + pad * 2, max(stack - gap, 0))
            rows.append(
                Row(
                    head: head, headSize: headSize, events: events, height: rowHeight,
                    tint: theme.diagramWheel[(period.section ?? index) % theme.diagramWheel.count]
                ))
        }
        // The rule stands between the two columns, so the picture is as wide as
        // both of them and the room the rule takes between.
        let rail = 24 * metrics.scale
        let content = headWidth + rail + eventWidth

        var titleLine: CTLine?
        var titleSize = CGSize.zero
        if !timeline.title.isEmpty {
            let line = text(timeline.title, font: titleFont, color: theme.palette.text)
            titleLine = line
            titleSize = measure(line)
        }
        let titleRoom = titleLine == nil ? 0 : titleSize.height + 14 * metrics.scale
        // A section's name may be written over several lines, and every band is
        // drawn the same depth, so the deepest name decides it.
        let bandHeight =
            (timeline.sections.map {
                labelLines($0, font: font, color: theme.palette.text).size.height
            }.max() ?? 0) + (timeline.sections.isEmpty ? 0 : pad * 2)

        var decorations: [BlockBox.Decoration] = []
        let left = max(metrics.padding, (width - content) / 2)
        if let titleLine {
            decorations.append(
                .glyphs(
                    titleLine,
                    origin: CGPoint(
                        x: max(metrics.padding, (width - titleSize.width) / 2),
                        y: metrics.padding + titleSize.height - descent(titleLine))))
        }

        // Where each row stands, with a band opened above the first row of every
        // section. The rule runs from the first row to the last, so it is drawn
        // once the whole run is measured.
        var y = metrics.padding + titleRoom
        var placed: [(row: Int, top: CGFloat)] = []
        var lastSection: Int?
        var railTop = y
        var railBottom = y
        for (index, row) in rows.enumerated() {
            let section = timeline.periods[index].section
            if section != lastSection {
                lastSection = section
                if let section, section < timeline.sections.count {
                    let band = CGRect(
                        x: left, y: y, width: content, height: bandHeight - 4 * metrics.scale)
                    decorations.append(
                        .fill(
                            rect: band,
                            color: theme.diagramWheel[section % theme.diagramWheel.count].copy(
                                alpha: 0.22) ?? theme.diagramWheel[0],
                            cornerRadius: 4 * metrics.scale))
                    let (lines, size) = labelLines(
                        timeline.sections[section], font: font, color: theme.palette.text)
                    decorations += centred(lines, size: size, in: band)
                    y += bandHeight
                }
            }
            if placed.isEmpty { railTop = y }
            placed.append((index, y))
            y += row.height + gap * 2
            railBottom = y - gap * 2
        }
        let height = y - gap * 2 + metrics.padding

        let rule = CGMutablePath()
        let railX = left + headWidth + rail / 2
        rule.move(to: CGPoint(x: railX, y: railTop))
        rule.addLine(to: CGPoint(x: railX, y: railBottom))
        decorations.append(
            .path(rule, color: theme.palette.tableBorder, lineWidth: 1, filled: false))

        for (index, top) in placed {
            let row = rows[index]
            let head = CGRect(
                x: left, y: top, width: headWidth, height: row.headSize.height + pad * 2)
            decorations.append(
                .fill(
                    rect: head, color: row.tint.copy(alpha: 0.3) ?? row.tint,
                    cornerRadius: 4 * metrics.scale))
            decorations += centred(row.head, size: row.headSize, in: head)
            // The dot is what ties the row to the rule beside it.
            let dot = CGRect(
                x: railX - 3 * metrics.scale, y: head.midY - 3 * metrics.scale,
                width: 6 * metrics.scale, height: 6 * metrics.scale)
            decorations.append(
                .path(
                    CGPath(ellipseIn: dot, transform: nil), color: row.tint, lineWidth: 0,
                    filled: true))
            var cardTop = top
            for event in row.events {
                let card = CGRect(
                    x: left + headWidth + rail, y: cardTop, width: eventWidth,
                    height: event.size.height + pad * 2)
                decorations.append(
                    .fill(
                        rect: card, color: row.tint.copy(alpha: 0.14) ?? row.tint,
                        cornerRadius: 4 * metrics.scale))
                decorations += centred(event.lines, size: event.size, in: card)
                decorations.append(
                    .path(
                        dashed(
                            from: CGPoint(x: railX, y: card.midY),
                            to: CGPoint(x: card.minX, y: card.midY), dash: 3, gap: 3),
                        color: theme.palette.tableBorder, lineWidth: 1, filled: false))
                cardTop = card.maxY + gap
            }
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    // MARK: - User journey

    /// A journey: the steps of a working day in order, each scored by how it
    /// felt, with a face under it saying so.
    ///
    /// The picture is the one every journey map is drawn as — a band per part of
    /// the day, a card per step, a line of travel under them, and the feeling
    /// hanging below that line — rather than a chart of the scores, which loses
    /// the one thing a journey is for.
    private static func journey(
        _ journey: UserJourney, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale * 0.94)
        let smallFont = scaled(theme.controlLabel, by: metrics.scale * 0.9)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale * 1.1)
        let pad = 8 * metrics.scale
        // One gap between every two pieces — card and card, band and band, band
        // and the cards under it. Three different gaps read as three different
        // relations where the source states one.
        let gap = 6 * metrics.scale

        struct Step {
            var name: CTLine
            var nameSize: CGSize
            var actors: CTLine?
            var actorsSize: CGSize
            var score: Int
            var column: CGFloat
            var columnWidth: CGFloat
            var tint: CGColor
        }
        var steps: [Step] = []
        for (index, task) in journey.tasks.enumerated() {
            let name = text(task.name, font: font, color: theme.palette.text)
            var actors: CTLine?
            var actorsSize = CGSize.zero
            if !task.actors.isEmpty {
                let line = text(
                    task.actors.joined(separator: ", "), font: smallFont,
                    color: theme.palette.secondaryText)
                actors = line
                actorsSize = measure(line)
            }
            let nameSize = measure(name)
            steps.append(
                Step(
                    name: name,
                    nameSize: nameSize,
                    actors: actors,
                    actorsSize: actorsSize,
                    score: task.score,
                    column: 0,
                    columnWidth: max(
                        84 * metrics.scale, max(nameSize.width, actorsSize.width) + pad * 3),
                    tint: theme.diagramWheel[(task.section ?? index) % theme.diagramWheel.count]
                )
            )
        }
        var x: CGFloat = 0
        for index in steps.indices {
            steps[index].column = x
            x += steps[index].columnWidth
        }
        let content = x

        var titleLine: CTLine?
        var titleSize = CGSize.zero
        if !journey.title.isEmpty {
            let line = text(journey.title, font: titleFont, color: theme.palette.text)
            titleLine = line
            titleSize = measure(line)
        }
        let titleRoom = titleLine == nil ? 0 : titleSize.height + 14 * metrics.scale
        let rowHeight = (steps.map(\.nameSize.height).max() ?? 12) + pad * 2
        let bandHeight = journey.sections.isEmpty ? 0 : rowHeight + gap
        let cardHeight =
            (steps.map(\.nameSize.height).max() ?? 12)
            + (steps.map(\.actorsSize.height).max() ?? 0) + pad * 2
        let faceRoom = 120 * metrics.scale
        let height =
            metrics.padding * 2 + titleRoom + bandHeight + cardHeight + 22 * metrics.scale
            + faceRoom

        let left = max(metrics.padding, (width - content) / 2)
        var decorations: [BlockBox.Decoration] = []
        if let titleLine {
            decorations.append(
                .glyphs(
                    titleLine,
                    origin: CGPoint(
                        x: max(metrics.padding, (width - titleSize.width) / 2),
                        y: metrics.padding + titleSize.height - descent(titleLine)
                    )
                )
            )
        }
        let bandTop = metrics.padding + titleRoom
        // A part of the day is a band over the steps it holds, standing clear of
        // the band beside it: two bands that touch read as one.
        for (index, name) in journey.sections.enumerated() {
            let owned = steps.indices.filter { journey.tasks[$0].section == index }
            guard let first = owned.first, let last = owned.last else { continue }
            let band = CGRect(
                x: left + steps[first].column + gap / 2,
                y: bandTop,
                width: steps[last].column + steps[last].columnWidth - steps[first].column - gap,
                height: rowHeight
            )
            let tint = theme.diagramWheel[index % theme.diagramWheel.count]
            decorations.append(
                .fill(
                    rect: band, color: tint.copy(alpha: 0.22) ?? tint,
                    cornerRadius: 4 * metrics.scale))
            decorations.append(
                .path(
                    CGPath(
                        roundedRect: band, cornerWidth: 4 * metrics.scale,
                        cornerHeight: 4 * metrics.scale, transform: nil),
                    color: tint.copy(alpha: 0.55) ?? tint, lineWidth: 1, filled: false))
            let line = text(name, font: font, color: theme.palette.text)
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: band.midX - size.width / 2,
                        y: band.midY + size.height / 2 - descent(line)
                    )
                )
            )
        }

        // A card per step, under the band its part of the day covers.
        let cardTop = bandTop + bandHeight
        for step in steps {
            let card = CGRect(
                x: left + step.column + gap / 2, y: cardTop,
                width: step.columnWidth - gap, height: cardHeight)
            decorations.append(
                .fill(
                    rect: card, color: step.tint.copy(alpha: 0.14) ?? step.tint,
                    cornerRadius: 4 * metrics.scale))
            decorations.append(
                .path(
                    CGPath(
                        roundedRect: card, cornerWidth: 4 * metrics.scale,
                        cornerHeight: 4 * metrics.scale, transform: nil),
                    color: step.tint.copy(alpha: 0.5) ?? step.tint, lineWidth: 1, filled: false))
            var y = card.midY - (step.nameSize.height + step.actorsSize.height) / 2
            for (line, size) in [(step.name, step.nameSize)]
                + (step.actors.map { [($0, step.actorsSize)] } ?? [])
            {
                decorations.append(
                    .glyphs(
                        line,
                        origin: CGPoint(
                            x: card.midX - size.width / 2, y: y + size.height - descent(line))))
                y += size.height
            }
        }

        // The line of travel, pointing the way the day runs.
        let axisY = cardTop + cardHeight + 14 * metrics.scale
        let axis = CGMutablePath()
        axis.move(to: CGPoint(x: left, y: axisY))
        axis.addLine(to: CGPoint(x: left + content, y: axisY))
        decorations.append(
            .path(axis, color: theme.palette.text, lineWidth: 1.5 * metrics.scale, filled: false))
        let barb = 6 * metrics.scale
        let head = CGMutablePath()
        head.move(to: CGPoint(x: left + content, y: axisY))
        head.addLine(to: CGPoint(x: left + content - barb * 1.6, y: axisY - barb))
        head.addLine(to: CGPoint(x: left + content - barb * 1.6, y: axisY + barb))
        head.closeSubpath()
        decorations.append(.path(head, color: theme.palette.text, lineWidth: 0, filled: true))

        // How a step felt hangs below the line, the better the higher, on a
        // thread back up to the step it belongs to.
        let radius = 11 * metrics.scale
        for step in steps {
            let centre = left + step.column + step.columnWidth / 2
            let placed = min(max(step.score, 1), 5)
            let drop =
                axisY + 26 * metrics.scale
                + (faceRoom - 52 * metrics.scale) * CGFloat(5 - placed) / 4
            decorations.append(
                .path(
                    dashed(
                        from: CGPoint(x: centre, y: axisY),
                        to: CGPoint(x: centre, y: drop - radius), dash: 2, gap: 3),
                    color: theme.palette.tableBorder, lineWidth: 1, filled: false))
            decorations += face(
                step.score, at: CGPoint(x: centre, y: drop), radius: radius, colour: step.tint,
                theme: theme, metrics: metrics)
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    /// How a step felt: a smile above three, a straight face at three, a frown
    /// below it — which is the reading Mermaid gives a score too.
    private static func face(
        _ score: Int, at centre: CGPoint, radius: CGFloat, colour: CGColor, theme: Theme,
        metrics: Metrics
    ) -> [BlockBox.Decoration] {
        let ring = CGPath(
            ellipseIn: CGRect(
                x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2),
            transform: nil)
        var decorations: [BlockBox.Decoration] = [
            .path(ring, color: colour.copy(alpha: 0.18) ?? colour, lineWidth: 0, filled: true),
            .path(ring, color: colour, lineWidth: 1.4 * metrics.scale, filled: false),
        ]
        let eyes = CGMutablePath()
        let eye = radius * 0.13
        for side in [-1, 1] as [CGFloat] {
            eyes.addEllipse(
                in: CGRect(
                    x: centre.x + side * radius * 0.36 - eye, y: centre.y - radius * 0.28 - eye,
                    width: eye * 2, height: eye * 2))
        }
        decorations.append(.path(eyes, color: colour, lineWidth: 0, filled: true))
        let mouth = CGMutablePath()
        let reach = radius * 0.45
        let lip = centre.y + radius * 0.28
        if score == 3 {
            mouth.move(to: CGPoint(x: centre.x - reach, y: lip))
            mouth.addLine(to: CGPoint(x: centre.x + reach, y: lip))
        } else {
            // A smile bows down, a frown bows up: on this page y grows downward.
            let bend = score > 3 ? radius * 0.5 : -radius * 0.5
            mouth.move(to: CGPoint(x: centre.x - reach, y: lip - (score > 3 ? radius * 0.1 : 0)))
            mouth.addQuadCurve(
                to: CGPoint(x: centre.x + reach, y: lip - (score > 3 ? radius * 0.1 : 0)),
                control: CGPoint(x: centre.x, y: lip + bend))
        }
        decorations.append(
            .path(mouth, color: colour, lineWidth: 1.4 * metrics.scale, filled: false))
        return decorations
    }

    // MARK: - Gantt chart

    /// A Gantt chart: one row per task, its bar spanning the days it takes.
    private static func gantt(
        _ chart: GanttChart, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale * 0.94)
        let smallFont = scaled(theme.controlLabel, by: metrics.scale * smallestLabelFactor)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale * 1.1)
        let sectionFont = scaled(theme.bodyBold, by: metrics.scale * 0.94)
        let pad = 6 * metrics.scale

        let names = chart.tasks.map { text($0.name, font: font, color: theme.palette.text) }
        let sectionNames = chart.sections.map {
            text($0, font: sectionFont, color: theme.palette.text)
        }
        let gutter =
            max(
                names.map { measure($0).width }.max() ?? 0,
                sectionNames.map { measure($0).width }.max() ?? 0
            ) + 16 * metrics.scale
        let rowHeight = (names.map { measure($0).height }.max() ?? 12) + pad * 2
        let span = chart.tasks.map { $0.start + $0.length }.max() ?? 1
        // The axis carries whole dates, so how wide one is decides both how wide
        // the plot has to be and how many ticks can be labelled without the
        // dates running into each other.
        func axisLabel(_ day: Double) -> String {
            guard let origin = chart.origin else { return "day \(Int(day.rounded()))" }
            return GanttChart.date(origin + day, format: chart.axisFormat)
        }
        let sample = axisLabel(span)
        let dateWidth =
            measure(text(sample, font: smallFont, color: theme.palette.text)).width
            + 14 * metrics.scale
        // A day gets at least a hair of width, and the plot never gets so wide
        // that the caller's shrinking cannot bring it back.
        let plotWidth = max(
            240 * metrics.scale, dateWidth * 3,
            min(430 * metrics.scale, span * 14 * metrics.scale))
        // How far apart the ticks stand: what the chart asked for when it asked,
        // and otherwise as many as fit without the dates running together.
        //
        // A step worked out from the span alone lands on figures nobody counts
        // in — seven minutes, nineteen hours — so the room the labels leave is
        // only the starting point, and the step itself is the next round amount
        // of time above it. A chart with no date in it is counted in whole days,
        // and its axis says so, so the rounder steps are the only ones it takes.
        let whole: [Double] = [1, 2, 7, 14, 30, 90, 180, 365]
        let second: Double = 1 / 86400
        let minute: Double = 1 / 1440
        let hour: Double = 1 / 24
        var rounds: [Double] = []
        if chart.origin != nil {
            for count in [1.0, 2, 5, 10, 15, 30] { rounds.append(count * second) }
            for count in [1.0, 2, 5, 10, 15, 30] { rounds.append(count * minute) }
            for count in [1.0, 2, 3, 6, 12] { rounds.append(count * hour) }
        }
        rounds += whole
        let room = span / Double(max(2, min(4, Int(plotWidth / dateWidth))))
        var tickStep = rounds.first { $0 >= room } ?? max(room, 365)
        if let interval = chart.tickInterval {
            let days: Double
            switch interval.unit {
            case "week": days = 7
            case "month": days = 30
            case "hour": days = 1 / 24
            case "minute": days = 1 / 1440
            case "second": days = 1 / 86400
            case "millisecond": days = 1 / 86_400_000
            default: days = 1
            }
            tickStep = max(days * Double(interval.count), span / 60)
        }
        // A chart told in hours has its ticks at round moments of the clock
        // rather than at multiples of its own start, so one opening at 17:32 is
        // still read against 17:35 and 17:40. A chart told in days already
        // starts on a whole day, and counting its ticks from any other one only
        // moves the first of them off the edge of the plot.
        let ticks: [Double] = {
            let step = max(tickStep, 0.0001)
            let began = step < 1 ? (chart.origin ?? 0) : 0
            var day = (began / step).rounded(.up) * step - began
            var found: [Double] = []
            while day <= span + 1e-9, found.count < 200 {
                found.append(day)
                day += step
            }
            return found.isEmpty ? [0] : found
        }()
        let perDay = span > 0 ? plotWidth / span : plotWidth
        let content = gutter + plotWidth

        var titleLine: CTLine?
        var titleSize = CGSize.zero
        if !chart.title.isEmpty {
            let line = text(chart.title, font: titleFont, color: theme.palette.text)
            titleLine = line
            titleSize = measure(line)
        }
        let titleRoom = titleLine == nil ? 0 : titleSize.height + 14 * metrics.scale
        let axisHeight =
            measure(text(sample, font: smallFont, color: theme.palette.text)).height
            + 10 * metrics.scale
        // Which row each task stands on. `displayMode compact` puts tasks that
        // do not overlap on one row; otherwise every task has a row to itself.
        // A section takes a row of its own before the tasks under it.
        var rowOf = [Int](repeating: 0, count: chart.tasks.count)
        var rows = 0
        var lastSection: Int?
        /// The first row of the section being filled, and where each of its
        /// rows is free from.
        var sectionStart = 0
        var free: [Double] = []
        for (index, task) in chart.tasks.enumerated() {
            // A `vert` is a rule across the chart rather than a row in it, so
            // it takes no room among the bars.
            if task.vertical {
                rowOf[index] = -1
                continue
            }
            if task.section != lastSection {
                lastSection = task.section
                rows += 1
                sectionStart = rows
                free = []
            }
            if chart.compact, let landed = free.firstIndex(where: { $0 <= task.start }) {
                rowOf[index] = sectionStart + landed
                free[landed] = task.start + max(task.length, 0.5)
                continue
            }
            rowOf[index] = rows
            rows += 1
            free.append(task.start + max(task.length, 0.5))
        }
        // A rule across the chart is named under it, so its name needs a row of
        // its own below the last bar.
        let verticals = chart.tasks.filter(\.vertical)
        let vertRoom = verticals.isEmpty ? 0 : rowHeight
        let height =
            metrics.padding * 2 + titleRoom + axisHeight + CGFloat(rows) * rowHeight + vertRoom

        let left = max(metrics.padding, (width - content) / 2)
        let plotLeft = left + gutter
        var decorations: [BlockBox.Decoration] = []
        if let titleLine {
            decorations.append(
                .glyphs(
                    titleLine,
                    origin: CGPoint(
                        x: max(metrics.padding, (width - titleSize.width) / 2),
                        y: metrics.padding + titleSize.height - descent(titleLine)
                    )
                )
            )
        }

        // Ticks across the span, each with the day it stands for. Without a date
        // in the source the axis counts days from the first task instead.
        let axisTop = metrics.padding + titleRoom
        let bodyTop = axisTop + axisHeight
        let bodyBottom = bodyTop + CGFloat(rows) * rowHeight
        // The days nobody works are shaded behind everything, so a bar that
        // spans a weekend is seen to span it.
        for off in chart.excluded.sorted() where Double(off) <= span {
            decorations.append(
                .fill(
                    rect: CGRect(
                        x: plotLeft + CGFloat(off) * perDay, y: bodyTop,
                        width: max(1, perDay), height: bodyBottom - bodyTop),
                    color: theme.palette.tableBorder.copy(alpha: 0.35)
                        ?? theme.palette.tableBorder, cornerRadius: 0))
        }
        for day in ticks {
            let x = plotLeft + CGFloat(day) * perDay
            let rule = CGMutablePath()
            rule.move(to: CGPoint(x: x, y: bodyTop))
            rule.addLine(to: CGPoint(x: x, y: bodyBottom))
            decorations.append(
                .path(rule, color: theme.palette.tableBorder, lineWidth: 0.5, filled: false))
            let line = text(axisLabel(day), font: smallFont, color: theme.palette.secondaryText)
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: min(
                            left + content - size.width,
                            max(left, x - size.width / 2)),
                        y: bodyTop - 6 * metrics.scale - descent(line)
                    )
                )
            )
        }

        // The line where the reader stands, if today falls inside the chart.
        if chart.marksToday, let origin = chart.origin {
            let today = Double(GanttChart.today()) - origin
            if today >= 0, today <= span {
                let rule = CGMutablePath()
                let x = plotLeft + CGFloat(today) * perDay
                rule.move(to: CGPoint(x: x, y: bodyTop))
                rule.addLine(to: CGPoint(x: x, y: bodyBottom))
                decorations.append(
                    .path(
                        rule, color: CGColor(red: 0.85, green: 0.33, blue: 0.33, alpha: 0.8),
                        lineWidth: 1.5 * metrics.scale, filled: false))
            }
        }

        // The rules a `vert` asks for, drawn over the bars and named under the
        // chart in the ink the rule is drawn in.
        for task in verticals {
            let x = plotLeft + CGFloat(task.start) * perDay
            let rule = CGMutablePath()
            rule.move(to: CGPoint(x: x, y: bodyTop))
            rule.addLine(to: CGPoint(x: x, y: bodyBottom))
            let colour =
                task.critical
                ? CGColor(red: 0.85, green: 0.33, blue: 0.33, alpha: 1) : theme.diagramWheel[0]
            decorations.append(
                .path(rule, color: colour, lineWidth: 2.5 * metrics.scale, filled: false))
            let line = text(task.name, font: smallFont, color: colour)
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: min(left + content - size.width, max(left, x - size.width / 2)),
                        y: bodyBottom + 6 * metrics.scale + size.height - descent(line))))
        }

        lastSection = nil
        for (index, task) in chart.tasks.enumerated() where !task.vertical {
            let y = bodyTop + CGFloat(rowOf[index]) * rowHeight
            if task.section != lastSection {
                lastSection = task.section
                if let section = task.section {
                    let line = sectionNames[section]
                    let size = measure(line)
                    let band = CGRect(
                        x: left, y: y - rowHeight, width: content,
                        height: rowHeight - 2 * metrics.scale)
                    decorations.append(
                        .fill(
                            rect: band,
                            color: theme.diagramWheel[section % theme.diagramWheel.count].copy(
                                alpha: 0.16) ?? theme.diagramWheel[0],
                            cornerRadius: 3 * metrics.scale))
                    decorations.append(
                        .glyphs(
                            line,
                            origin: CGPoint(
                                x: left + 6 * metrics.scale,
                                y: band.midY + size.height / 2 - descent(line))))
                }
            }
            let line = names[index]
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: plotLeft - 10 * metrics.scale - size.width,
                        y: y + rowHeight / 2 + size.height / 2 - descent(line))))
            let colour =
                task.critical
                ? CGColor(red: 0.85, green: 0.33, blue: 0.33, alpha: 1)
                : task.done
                    ? theme.palette.secondaryText
                    : task.active
                        ? theme.diagramWheel[0]
                        : theme.diagramWheel[(task.section ?? 0) % theme.diagramWheel.count]
            let barTop = y + pad
            let barHeight = rowHeight - pad * 2
            if task.milestone {
                // A milestone is a moment rather than a stretch, so it is drawn
                // as a diamond and not as a bar of no width nobody would see.
                // The moment is the middle of whatever length it was written
                // with, which for the usual `0d` is simply the day it falls on.
                let centre = CGPoint(
                    x: plotLeft + CGFloat(task.start + task.length / 2) * perDay,
                    y: barTop + barHeight / 2)
                let radius = barHeight / 2
                let diamond = CGMutablePath()
                diamond.move(to: CGPoint(x: centre.x, y: centre.y - radius))
                diamond.addLine(to: CGPoint(x: centre.x + radius, y: centre.y))
                diamond.addLine(to: CGPoint(x: centre.x, y: centre.y + radius))
                diamond.addLine(to: CGPoint(x: centre.x - radius, y: centre.y))
                diamond.closeSubpath()
                decorations.append(.path(diamond, color: colour, lineWidth: 0, filled: true))
            } else {
                let bar = CGRect(
                    x: plotLeft + CGFloat(task.start) * perDay,
                    y: barTop,
                    width: max(2 * metrics.scale, CGFloat(task.length) * perDay),
                    height: barHeight
                )
                decorations.append(
                    .fill(
                        rect: bar, color: task.done ? (colour.copy(alpha: 0.45) ?? colour) : colour,
                        cornerRadius: 3 * metrics.scale))
            }
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    // MARK: - Sankey diagram

    /// Flows between nodes, every band as thick as what it carries.
    private static func sankey(
        _ diagram: SankeyDiagram, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.controlLabel, by: metrics.scale * 0.9)
        let ranks = self.ranks(
            count: diagram.nodes.count, edges: diagram.flows.map { ($0.from, $0.to) })
        // A node is as tall as the larger of what reaches it and what leaves,
        // because both have to fit against its own edge.
        var incoming = [Double](repeating: 0, count: diagram.nodes.count)
        var outgoing = [Double](repeating: 0, count: diagram.nodes.count)
        for flow in diagram.flows {
            outgoing[flow.from] += flow.value
            incoming[flow.to] += flow.value
        }
        let weight = zip(incoming, outgoing).map(max)

        let barWidth = 12 * metrics.scale
        let nodeGap = 12 * metrics.scale
        let plotHeight = 260 * metrics.scale
        // One scale for the whole picture: the busiest rank fills the height,
        // and every other band is read against it.
        let busiest = ranks.map { rank in rank.reduce(0.0) { $0 + weight[$1] } }.max() ?? 1
        let tallestRank = ranks.map(\.count).max() ?? 1
        let usable = max(40 * metrics.scale, plotHeight - nodeGap * CGFloat(tallestRank - 1))
        let perUnit = busiest > 0 ? usable / CGFloat(busiest) : 1

        // A flow diagram is drawn to be read for its sizes, so each name carries
        // the number the author gave it rather than leaving it to the eye.
        let labels = diagram.nodes.indices.map { index in
            text(
                "\(diagram.nodes[index])  \(number(weight[index]))", font: font,
                color: theme.palette.text)
        }
        let widest = labels.map { measure($0).width }.max() ?? 0
        let columnGap = max(90 * metrics.scale, widest + 24 * metrics.scale)
        let content = CGFloat(ranks.count - 1) * columnGap + barWidth + widest + 8 * metrics.scale
        let height = metrics.padding * 2 + plotHeight

        let left = max(metrics.padding, (width - content) / 2)
        var frames = [CGRect](repeating: .zero, count: diagram.nodes.count)
        for (level, rank) in ranks.enumerated() {
            let total =
                CGFloat(rank.reduce(0.0) { $0 + weight[$1] }) * perUnit
                + nodeGap * CGFloat(rank.count - 1)
            var y = metrics.padding + (plotHeight - total) / 2
            for node in rank {
                let tall = max(2 * metrics.scale, CGFloat(weight[node]) * perUnit)
                frames[node] = CGRect(
                    x: left + CGFloat(level) * columnGap, y: y, width: barWidth, height: tall)
                y += tall + nodeGap
            }
        }

        var decorations: [BlockBox.Decoration] = []
        // Ribbons first, so a bar is never hidden by what leaves it. Each end
        // walks down its own node, in the order the flows were written.
        var leaving = [CGFloat](repeating: 0, count: diagram.nodes.count)
        var arriving = [CGFloat](repeating: 0, count: diagram.nodes.count)
        for flow in diagram.flows {
            let thickness = CGFloat(flow.value) * perUnit
            let from = frames[flow.from]
            let to = frames[flow.to]
            let startTop = from.minY + leaving[flow.from]
            let endTop = to.minY + arriving[flow.to]
            leaving[flow.from] += thickness
            arriving[flow.to] += thickness
            let waist = (from.maxX + to.minX) / 2
            let ribbon = CGMutablePath()
            ribbon.move(to: CGPoint(x: from.maxX, y: startTop))
            ribbon.addCurve(
                to: CGPoint(x: to.minX, y: endTop),
                control1: CGPoint(x: waist, y: startTop),
                control2: CGPoint(x: waist, y: endTop))
            ribbon.addLine(to: CGPoint(x: to.minX, y: endTop + thickness))
            ribbon.addCurve(
                to: CGPoint(x: from.maxX, y: startTop + thickness),
                control1: CGPoint(x: waist, y: endTop + thickness),
                control2: CGPoint(x: waist, y: startTop + thickness))
            ribbon.closeSubpath()
            let colour = theme.diagramWheel[flow.from % theme.diagramWheel.count]
            decorations.append(
                .path(ribbon, color: colour.copy(alpha: 0.4) ?? colour, lineWidth: 0, filled: true))
        }
        for (index, frame) in frames.enumerated() {
            decorations.append(
                .fill(
                    rect: frame, color: theme.diagramWheel[index % theme.diagramWheel.count],
                    cornerRadius: 2 * metrics.scale))
            let size = measure(labels[index])
            // The name goes to the right of its bar, except where there is
            // nothing to its right but the edge of the picture.
            let rightwards = frame.maxX + 8 * metrics.scale + size.width <= left + content
            decorations.append(
                .glyphs(
                    labels[index],
                    origin: CGPoint(
                        x: rightwards
                            ? frame.maxX + 8 * metrics.scale
                            : frame.minX - 8 * metrics.scale - size.width,
                        y: frame.midY + size.height / 2 - descent(labels[index]))))
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    // MARK: - Treemap

    /// How square a row of rectangles comes out, given the side it runs along.
    ///
    /// This is what "squarified" means: a row takes one more rectangle only
    /// while doing so leaves every rectangle in it closer to square than
    /// stopping would. Everything is in drawn area, not in the source's units.
    private static func worstRatio(_ areas: [Double], along side: Double) -> Double {
        guard let low = areas.min(), let high = areas.max(), low > 0, side > 0 else {
            return .infinity
        }
        let sum = areas.reduce(0, +)
        guard sum > 0 else { return .infinity }
        return max(side * side * high / (sum * sum), sum * sum / (side * side * low))
    }

    /// Nested rectangles, each as big a share of its parent as its value is of
    /// the parent's total.
    private static func treemap(
        _ map: Treemap, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.controlLabel, by: metrics.scale * 0.9)
        let headFont = scaled(theme.bodyBold, by: metrics.scale * 0.9)
        let side = min(420 * metrics.scale, max(280 * metrics.scale, width - metrics.padding * 2))
        let tall = side * 0.62
        let headRoom =
            measure(text("Ay", font: headFont, color: theme.palette.text)).height + 6
            * metrics.scale

        var frames = [CGRect](repeating: .zero, count: map.nodes.count)
        let left = max(metrics.padding, (width - side) / 2)
        frames[0] = CGRect(x: left, y: metrics.padding, width: side, height: tall)

        func squarify(_ children: [Int], in area: CGRect) {
            let total = children.reduce(0.0) { $0 + map.nodes[$1].value }
            guard total > 0, area.width > 1, area.height > 1 else { return }
            let perUnit = Double(area.width) * Double(area.height) / total
            var remaining = children.sorted { map.nodes[$0].value > map.nodes[$1].value }
            var rest = area
            while !remaining.isEmpty {
                let short = Double(min(rest.width, rest.height))
                guard short > 0 else { return }
                var row: [Int] = []
                var areas: [Double] = []
                while let next = remaining.first {
                    let area = map.nodes[next].value * perUnit
                    if !row.isEmpty,
                        worstRatio(areas + [area], along: short) > worstRatio(areas, along: short)
                    {
                        break
                    }
                    row.append(next)
                    areas.append(area)
                    remaining.removeFirst()
                }
                // The row runs along the shorter side, which is what keeps its
                // rectangles from turning into slivers.
                let rowTotal = areas.reduce(0, +)
                let thickness = CGFloat(rowTotal / short)
                let across = rest.width <= rest.height
                var offset: CGFloat = 0
                for (position, node) in row.enumerated() {
                    let share = CGFloat(areas[position] / rowTotal) * CGFloat(short)
                    frames[node] =
                        across
                        ? CGRect(
                            x: rest.minX + offset, y: rest.minY, width: share, height: thickness)
                        : CGRect(
                            x: rest.minX, y: rest.minY + offset, width: thickness, height: share)
                    offset += share
                }
                rest =
                    across
                    ? CGRect(
                        x: rest.minX, y: rest.minY + thickness, width: rest.width,
                        height: rest.height - thickness)
                    : CGRect(
                        x: rest.minX + thickness, y: rest.minY, width: rest.width - thickness,
                        height: rest.height)
            }
            for child in children where !map.nodes[child].children.isEmpty {
                var inner = frames[child].insetBy(dx: 3 * metrics.scale, dy: 3 * metrics.scale)
                inner.origin.y += headRoom
                inner.size.height -= headRoom
                squarify(map.nodes[child].children, in: inner)
            }
        }
        // The outermost name is a level of the map like any other, so it gets
        // its own head row and its children are drawn inside it. The one root
        // that is not drawn is the nameless parent invented for a map that was
        // written with several.
        var inside = frames[0]
        if !map.nodes[0].label.isEmpty {
            inside = inside.insetBy(dx: 3 * metrics.scale, dy: 3 * metrics.scale)
            inside.origin.y += headRoom
            inside.size.height -= headRoom
        }
        squarify(map.nodes[0].children, in: inside)

        var decorations: [BlockBox.Decoration] = []
        let tileGap = 2 * metrics.scale
        // A tile is drawn over its parent, not over the page, and a class
        // paints a section and everything in it — so the colour a leaf's name
        // is read against is its own tint over its parent's. Each tile records
        // what it leaves behind for its children.
        var parents = [Int](repeating: -1, count: map.nodes.count)
        for (index, node) in map.nodes.enumerated() {
            for child in node.children { parents[child] = index }
        }
        var behind = [CGColor](repeating: theme.palette.codeBackground, count: map.nodes.count)
        for (index, node) in map.nodes.enumerated() {
            let frame = frames[index]
            let page =
                parents[index] >= 0 ? behind[parents[index]] : theme.palette.codeBackground
            let wheel = theme.diagramWheel[index % theme.diagramWheel.count]
            let strength: CGFloat = node.children.isEmpty ? 0.55 : 0.18
            let colour =
                node.style.fill.map {
                    wash(
                        cgColor($0), on: page,
                        under: node.style.text.map(cgColor) ?? theme.palette.text, shownAt: strength
                    )
                } ?? wheel
            behind[index] =
                frame.width > 2 && frame.height > 2 ? over(colour, at: strength, on: page) : page
        }
        for (index, node) in map.nodes.enumerated() where index > 0 || !node.label.isEmpty {
            let frame = frames[index]
            guard frame.width > 2, frame.height > 2 else { continue }
            // A rectangle a class painted keeps that paint; one nobody painted
            // takes its turn off the wheel.
            let wheel = theme.diagramWheel[index % theme.diagramWheel.count]
            let branch = !node.children.isEmpty
            let strength: CGFloat = branch ? 0.18 : 0.55
            let page =
                parents[index] >= 0 ? behind[parents[index]] : theme.palette.codeBackground
            let colour =
                node.style.fill.map {
                    wash(
                        cgColor($0), on: page,
                        under: node.style.text.map(cgColor) ?? theme.palette.text, shownAt: strength
                    )
                } ?? wheel
            // Tiles stand apart by a gap of their own rather than by a line in
            // the page colour drawn over the seam: a class that gives a tile a
            // dark border turned that line dark, and the tile then sat flush
            // against its neighbours while every other tile kept a gap. A
            // border a class asks for is drawn inside the tile, so it never
            // eats into the gap.
            let tile = frame.insetBy(dx: tileGap / 2, dy: tileGap / 2)
            let corner = 3 * metrics.scale
            decorations.append(
                .fill(
                    rect: tile, color: colour.copy(alpha: strength) ?? colour, cornerRadius: corner)
            )
            if let stroke = node.style.stroke {
                let pen = CGFloat(node.style.strokeWidth ?? 1.5)
                let edge = tile.insetBy(dx: pen / 2, dy: pen / 2)
                if edge.width > 0, edge.height > 0 {
                    decorations.append(
                        .path(
                            CGPath(
                                roundedRect: edge, cornerWidth: min(corner, edge.width / 2),
                                cornerHeight: min(corner, edge.height / 2), transform: nil),
                            color: cgColor(stroke), lineWidth: pen, filled: false))
                }
            }
            // A branch is named along its own top edge, above what it holds; a
            // leaf gets its name in the middle. Both carry their number: a
            // branch's is the sum of what it holds, and that is what the map is
            // about.
            let words = "\(node.label)  \(number(node.value))"
            let line = text(
                words, font: branch ? headFont : font,
                color: node.style.text.map(cgColor) ?? theme.palette.text)
            let size = measure(line)
            guard size.width <= frame.width - 6 * metrics.scale,
                size.height <= frame.height - 4 * metrics.scale
            else { continue }
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: frame.midX - size.width / 2,
                        y: branch
                            ? frame.minY + 4 * metrics.scale + size.height - descent(line)
                            : frame.midY + size.height / 2 - descent(line))))
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: tall + metrics.padding * 2),
            contentWidth: side
        )
    }

    // MARK: - Packet diagram

    /// A run of bits cut into named fields, wrapped at a row of thirty-two.
    private static func packet(
        _ packet: PacketDiagram, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.controlLabel, by: metrics.scale * smallestLabelFactor)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale * 1.1)
        // Every field has to hold its own name, so the field that needs the most
        // room per bit decides how wide a bit is drawn. A row of one-bit flags
        // is what forces this: at a fixed width their names do not fit, and a
        // packet drawn with the names left out is not the packet that was
        // written. The stretch stops at two and a half times, past which one
        // name would decide the size of the whole picture.
        let baseBit = 15 * metrics.scale
        var bit = baseBit
        for field in packet.fields {
            let words = measure(text(field.label, font: font, color: theme.palette.text)).width
            let bits = CGFloat(field.last - field.first + 1)
            guard bits > 0 else { continue }
            bit = max(bit, min(baseBit * 2.5, (words + 6 * metrics.scale) / bits))
        }
        let rowHeight = 30 * metrics.scale
        let numberRoom =
            measure(text("00", font: font, color: theme.palette.text)).height
            + 3 * metrics.scale
        let content = bit * CGFloat(packet.bitsPerRow)

        // A field wider than the row is cut where the row ends, which is what a
        // packet does: the bits carry on over the line.
        struct Piece {
            var label: String
            var row: Int
            var first: Int
            var last: Int
            var field: Int
            /// Whether the field starts here, so only one piece is labelled.
            var opens: Bool
        }
        var pieces: [Piece] = []
        for (index, field) in packet.fields.enumerated() {
            var start = field.first
            while start <= field.last {
                let row = start / packet.bitsPerRow
                let end = min(field.last, (row + 1) * packet.bitsPerRow - 1)
                pieces.append(
                    Piece(
                        label: field.label, row: row, first: start % packet.bitsPerRow,
                        last: end % packet.bitsPerRow, field: index, opens: start == field.first))
                start = end + 1
            }
        }
        let rows = (pieces.map(\.row).max() ?? 0) + 1

        var titleLine: CTLine?
        var titleSize = CGSize.zero
        if !packet.title.isEmpty {
            let line = text(packet.title, font: titleFont, color: theme.palette.text)
            titleLine = line
            titleSize = measure(line)
        }
        let titleRoom = titleLine == nil ? 0 : titleSize.height + 14 * metrics.scale
        let height =
            metrics.padding * 2 + titleRoom + CGFloat(rows) * (rowHeight + numberRoom)

        let left = max(metrics.padding, (width - content) / 2)
        var decorations: [BlockBox.Decoration] = []
        if let titleLine {
            decorations.append(
                .glyphs(
                    titleLine,
                    origin: CGPoint(
                        x: max(metrics.padding, (width - titleSize.width) / 2),
                        y: metrics.padding + titleSize.height - descent(titleLine)
                    )
                )
            )
        }
        /// Where a bit number stands against the `x` it belongs to: just after
        /// it, just before it, or centred on it.
        enum Side { case after, before, over }
        var wantedNumbers: [(row: Int, value: Int, x: CGFloat, side: Side, top: CGFloat)] = []
        for piece in pieces {
            let top = metrics.padding + titleRoom + CGFloat(piece.row) * (rowHeight + numberRoom)
            let frame = CGRect(
                x: left + bit * CGFloat(piece.first),
                y: top + numberRoom,
                width: bit * CGFloat(piece.last - piece.first + 1),
                height: rowHeight
            )
            decorations.append(
                .fill(
                    rect: frame.insetBy(dx: 0.5, dy: 0.5),
                    color: theme.diagramWheel[piece.field % theme.diagramWheel.count].copy(
                        alpha: 0.2)
                        ?? theme.palette.tableHeaderBackground,
                    cornerRadius: 2 * metrics.scale))
            decorations.append(
                .path(
                    CGPath(rect: frame, transform: nil), color: theme.palette.tableBorder,
                    lineWidth: 1, filled: false))
            if piece.opens || piece.first == 0 {
                let line = text(piece.label, font: font, color: theme.palette.text)
                let size = measure(line)
                // A name too long for its own field is dropped rather than
                // spilled over the field beside it.
                if size.width <= frame.width - 4 * metrics.scale {
                    decorations.append(
                        .glyphs(
                            line,
                            origin: CGPoint(
                                x: frame.midX - size.width / 2,
                                y: frame.midY + size.height / 2 - descent(line))))
                }
            }
            // The bit each end of the field stands on, above its own edge. A
            // field of one bit has one number, centred over it, as Mermaid
            // writes it: the same number at both edges says it twice, and the
            // copy at the left edge runs into the number of the field before.
            let base = piece.row * packet.bitsPerRow
            if piece.first == piece.last {
                wantedNumbers.append(
                    (
                        row: piece.row, value: base + piece.first, x: frame.midX, side: .over,
                        top: top
                    ))
            } else {
                wantedNumbers.append(
                    (
                        row: piece.row, value: base + piece.first, x: frame.minX, side: .after,
                        top: top
                    ))
                wantedNumbers.append(
                    (
                        row: piece.row, value: base + piece.last, x: frame.maxX, side: .before,
                        top: top
                    ))
            }
        }
        // A row of one-bit fields wants more numbers over it than the row is
        // wide, and printed as asked they run into each other and become a
        // smear. The two ends of the row are placed first — they are what says
        // how long the row is — and after them each number is placed only where
        // it is still clear of the ones already there. Two fields that meet both
        // number the edge between them, one each side of it, as Mermaid does:
        // the end of one field and the start of the next are both worth
        // reading, and there is room for both.
        for row in 0..<rows {
            var placed: [CGRect] = []
            let candidates = wantedNumbers.filter { $0.row == row }
            let ends = row * packet.bitsPerRow
            let ordered = candidates.sorted { a, b in
                func rank(_ item: (row: Int, value: Int, x: CGFloat, side: Side, top: CGFloat))
                    -> Int
                {
                    item.value == ends || item.value == ends + packet.bitsPerRow - 1 ? 0 : 1
                }
                return (rank(a), a.x) < (rank(b), b.x)
            }
            for candidate in ordered {
                let line = text(
                    "\(candidate.value)", font: font, color: theme.palette.secondaryText)
                let size = measure(line)
                let room = 2 * metrics.scale
                let anchor: CGFloat
                switch candidate.side {
                case .after: anchor = candidate.x + room
                case .before: anchor = candidate.x - room - size.width
                case .over: anchor = candidate.x - size.width / 2
                }
                let originX = min(left + content - size.width, max(left, anchor))
                let box = CGRect(
                    x: originX - room / 2, y: 0, width: size.width + room, height: 1)
                guard !placed.contains(where: { $0.intersects(box) }) else { continue }
                placed.append(box)
                decorations.append(
                    .glyphs(
                        line,
                        origin: CGPoint(
                            x: originX,
                            y: candidate.top + numberRoom - 3 * metrics.scale - descent(line))))
            }
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    // MARK: - Kanban board

    /// Columns of cards, each column as tall as it needs to be.
    private static func kanban(
        _ board: KanbanBoard, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale * 0.94)
        let smallFont = scaled(theme.controlLabel, by: metrics.scale * smallestLabelFactor)
        let headFont = scaled(theme.bodyBold, by: metrics.scale)
        let pad = 8 * metrics.scale
        let gap = 12 * metrics.scale
        /// A card's words start past its priority stripe, so the room they need
        /// is the stripe as well as the padding on both sides.
        let inset = pad * 2 + 4 * metrics.scale
        /// The widest a card is allowed to grow before its words wrap. A board
        /// is read by glancing across its columns, and a column as wide as its
        /// longest sentence stops being something anyone glances at.
        let cardWidth = 150 * metrics.scale

        struct Card {
            var label: [CTLine]
            var labelSize: CGSize
            /// The ticket id, kept apart from the rest so it can be drawn as
            /// the link it is when the board says where tickets live.
            var ticket: CTLine?
            var ticketSize: CGSize
            var details: CTLine?
            var detailsSize: CGSize
            var priority: String
            var height: CGFloat
            /// The whole second line: the ticket, then everything else.
            var footWidth: CGFloat
            var footHeight: CGFloat
        }
        struct Column {
            var head: CTLine
            var headSize: CGSize
            var cards: [Card]
            var height: CGFloat
        }
        var columns: [Column] = []
        for column in board.columns {
            let head = text(column.title, font: headFont, color: theme.palette.text)
            var cards: [Card] = []
            var stack: CGFloat = 0
            for card in column.cards {
                let (label, labelSize) = wrapped(
                    card.label, font: font, color: theme.palette.text, within: cardWidth - inset)
                var ticket: CTLine?
                var ticketSize = CGSize.zero
                if !card.ticket.isEmpty {
                    // A board with somewhere to send its tickets shows them the
                    // way Mermaid does: in the colour a link is written in, and
                    // underlined.
                    let line = text(
                        card.ticket, font: smallFont,
                        color: board.ticketBaseUrl.isEmpty
                            ? theme.palette.secondaryText : theme.palette.link)
                    ticket = line
                    ticketSize = measure(line)
                }
                var details: CTLine?
                var detailsSize = CGSize.zero
                if !card.details.isEmpty {
                    let line = text(
                        card.details.joined(separator: " · "), font: smallFont,
                        color: theme.palette.secondaryText)
                    details = line
                    detailsSize = measure(line)
                }
                let footWidth =
                    ticketSize.width + detailsSize.width
                    + (ticket != nil && details != nil ? 10 * metrics.scale : 0)
                let footHeight = max(ticketSize.height, detailsSize.height)
                let height = pad * 2 + labelSize.height + (footHeight == 0 ? 0 : footHeight + 2)
                cards.append(
                    Card(
                        label: label, labelSize: labelSize, ticket: ticket, ticketSize: ticketSize,
                        details: details, detailsSize: detailsSize, priority: card.priority,
                        height: height, footWidth: footWidth, footHeight: footHeight))
                stack += height + 6 * metrics.scale
            }
            columns.append(
                Column(head: head, headSize: measure(head), cards: cards, height: stack))
        }
        let headHeight = (columns.map(\.headSize.height).max() ?? 0) + pad * 2
        let bodyHeight = columns.map(\.height).max() ?? 0
        // A card's words wrap at a readable measure, so one long title makes a
        // tall card rather than a board six times too wide. Every column takes
        // the same width, because a board whose columns are different widths
        // reads as a board with a column that matters more.
        let columnWidth = max(
            board.columnWidth.map { CGFloat($0) * metrics.scale } ?? 150 * metrics.scale,
            columns.map { column in
                max(
                    column.headSize.width + pad * 2,
                    column.cards.map { inset + max($0.labelSize.width, $0.footWidth) }.max()
                        ?? 0)
            }.max() ?? 0)
        let content = CGFloat(columns.count) * columnWidth + CGFloat(columns.count - 1) * gap
        let height = metrics.padding * 2 + headHeight + 8 * metrics.scale + bodyHeight

        let left = max(metrics.padding, (width - content) / 2)
        var decorations: [BlockBox.Decoration] = []
        for (index, column) in columns.enumerated() {
            let x = left + CGFloat(index) * (columnWidth + gap)
            let tint = theme.diagramWheel[index % theme.diagramWheel.count]
            let head = CGRect(
                x: x, y: metrics.padding, width: columnWidth, height: headHeight)
            decorations.append(
                .fill(
                    rect: head, color: tint.copy(alpha: 0.28) ?? tint,
                    cornerRadius: 5 * metrics.scale))
            decorations.append(
                .glyphs(
                    column.head,
                    origin: CGPoint(
                        x: head.midX - column.headSize.width / 2,
                        y: head.midY + column.headSize.height / 2 - descent(column.head))))
            var y = head.maxY + 8 * metrics.scale
            for card in column.cards {
                let frame = CGRect(x: x, y: y, width: columnWidth, height: card.height)
                decorations.append(
                    .fill(
                        rect: frame, color: theme.palette.background,
                        cornerRadius: 5 * metrics.scale))
                decorations.append(
                    .path(
                        CGPath(
                            roundedRect: frame, cornerWidth: 5 * metrics.scale,
                            cornerHeight: 5 * metrics.scale, transform: nil),
                        color: theme.palette.tableBorder, lineWidth: 1, filled: false))
                // A priority is a stripe down the card's own edge, so a glance
                // over the board finds the urgent ones without reading them.
                if let colour = priorityColour(card.priority) {
                    decorations.append(
                        .fill(
                            rect: CGRect(
                                x: frame.minX, y: frame.minY, width: 4 * metrics.scale,
                                height: frame.height),
                            color: colour, cornerRadius: 2 * metrics.scale))
                }
                var wordsY = frame.minY + pad
                for line in card.label {
                    let size = measure(line)
                    decorations.append(
                        .glyphs(
                            line,
                            origin: CGPoint(
                                x: frame.minX + pad + 4 * metrics.scale,
                                y: wordsY + size.height - descent(line))))
                    wordsY += size.height
                }
                let footLeft = frame.minX + pad + 4 * metrics.scale
                let footBase = frame.minY + pad + card.labelSize.height + 2 + card.footHeight
                if let ticket = card.ticket {
                    let origin = CGPoint(x: footLeft, y: footBase - descent(ticket))
                    decorations.append(.glyphs(ticket, origin: origin))
                    if !board.ticketBaseUrl.isEmpty {
                        let rule = CGMutablePath()
                        rule.move(to: CGPoint(x: origin.x, y: origin.y + 1.5 * metrics.scale))
                        rule.addLine(
                            to: CGPoint(
                                x: origin.x + card.ticketSize.width,
                                y: origin.y + 1.5 * metrics.scale))
                        decorations.append(
                            .path(rule, color: theme.palette.link, lineWidth: 1, filled: false))
                    }
                }
                if let details = card.details {
                    // The rest of the metadata is set against the card's far
                    // edge, which is where Mermaid puts it.
                    decorations.append(
                        .glyphs(
                            details,
                            origin: CGPoint(
                                x: max(
                                    footLeft + card.ticketSize.width
                                        + (card.ticket == nil ? 0 : 10 * metrics.scale),
                                    frame.maxX - pad - card.detailsSize.width),
                                y: footBase - descent(details))))
                }
                y = frame.maxY + 6 * metrics.scale
            }
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    /// Words broken into lines no wider than the room given, breaking between
    /// words and never inside one. A word longer than the room is left whole and
    /// overhangs, because a word cut in half reads as a different word.
    private static func wrapped(
        _ words: String, font: CTFont, color: CGColor, within room: CGFloat
    ) -> (lines: [CTLine], size: CGSize) {
        var lines: [CTLine] = []
        var current = ""
        func settle() {
            guard !current.isEmpty else { return }
            lines.append(text(current, font: font, color: color))
            current = ""
        }
        for word in words.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if !current.isEmpty, measure(text(candidate, font: font, color: color)).width > room {
                settle()
                current = String(word)
            } else {
                current = candidate
            }
        }
        settle()
        let sizes = lines.map(measure)
        return (
            lines,
            CGSize(
                width: sizes.map(\.width).max() ?? 0, height: sizes.reduce(0) { $0 + $1.height })
        )
    }

    /// Mermaid's five priorities, in Mermaid's hues: red, orange, none, blue
    /// and light blue. Folding two levels into one colour drops the very
    /// difference the author wrote down, and the middle level is the one a
    /// board has most of, so it is the one left plain.
    private static func priorityColour(_ priority: String) -> CGColor? {
        switch priority.lowercased() {
        case "very high": return CGColor(red: 0.85, green: 0.30, blue: 0.30, alpha: 1)
        case "high": return CGColor(red: 0.95, green: 0.60, blue: 0.22, alpha: 1)
        case "low": return CGColor(red: 0.29, green: 0.53, blue: 0.89, alpha: 1)
        case "very low": return CGColor(red: 0.62, green: 0.80, blue: 0.96, alpha: 1)
        default: return nil
        }
    }

    // MARK: - Quadrant chart

    /// A square cut in four, with the points scattered over it.
    private static func quadrant(
        _ chart: QuadrantChart, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale * 0.9)
        let quadrantFont = scaled(theme.bodyBold, by: metrics.scale * 0.9)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale * 1.1)
        let side = 300 * metrics.scale
        let axisRoom =
            measure(text("Ay", font: font, color: theme.palette.text)).height + 8 * metrics.scale
        // The y axis is written down the left, so it takes the width of its
        // longest word rather than the height of a line.
        let yWords = [chart.yAxis.low, chart.yAxis.high].filter { !$0.isEmpty }
        let yRoom =
            (yWords.map { measure(text($0, font: font, color: theme.palette.text)).width }.max()
                ?? 0) + 10 * metrics.scale
        let content = side + yRoom

        var titleLine: CTLine?
        var titleSize = CGSize.zero
        if !chart.title.isEmpty {
            let line = text(chart.title, font: titleFont, color: theme.palette.text)
            titleLine = line
            titleSize = measure(line)
        }
        let titleRoom = titleLine == nil ? 0 : titleSize.height + 14 * metrics.scale
        let height = metrics.padding * 2 + titleRoom + side + axisRoom

        let left = max(metrics.padding, (width - content) / 2)
        let plot = CGRect(
            x: left + yRoom, y: metrics.padding + titleRoom, width: side, height: side)
        var decorations: [BlockBox.Decoration] = []
        if let titleLine {
            decorations.append(
                .glyphs(
                    titleLine,
                    origin: CGPoint(
                        x: max(metrics.padding, (width - titleSize.width) / 2),
                        y: metrics.padding + titleSize.height - descent(titleLine)
                    )
                )
            )
        }
        // Numbered clockwise from the top right, the way Mermaid numbers them.
        let corners = [
            CGRect(x: plot.midX, y: plot.minY, width: side / 2, height: side / 2),
            CGRect(x: plot.minX, y: plot.minY, width: side / 2, height: side / 2),
            CGRect(x: plot.minX, y: plot.midY, width: side / 2, height: side / 2),
            CGRect(x: plot.midX, y: plot.midY, width: side / 2, height: side / 2),
        ]
        // Every quarter takes the same faint tint. A colour wheel would say
        // something the source never did — green for good, red for bad — and a
        // reader would believe it, because that is what those colours mean.
        let quarterTint =
            theme.palette.tableHeaderBackground.copy(alpha: 0.5)
            ?? theme.palette.tableHeaderBackground
        // What is already on the square: every quarter's name, every dot, and
        // every point's name written so far. A point's name goes where it runs
        // into none of them.
        var written: [CGRect] = []
        for (index, corner) in corners.enumerated() {
            decorations.append(
                .fill(rect: corner.insetBy(dx: 1, dy: 1), color: quarterTint, cornerRadius: 0))
            let name = chart.quadrants[index]
            guard !name.isEmpty else { continue }
            let line = text(name, font: quadrantFont, color: theme.palette.secondaryText)
            let size = measure(line)
            // Along the top of its own quarter rather than through the middle
            // of it, which is where the points are.
            let top = corner.minY + 10 * metrics.scale
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: corner.midX - size.width / 2,
                        y: top + size.height - descent(line))))
            written.append(
                CGRect(
                    x: corner.midX - size.width / 2, y: top, width: size.width,
                    height: size.height))
        }
        let frame = CGMutablePath()
        frame.addRect(plot)
        frame.move(to: CGPoint(x: plot.midX, y: plot.minY))
        frame.addLine(to: CGPoint(x: plot.midX, y: plot.maxY))
        frame.move(to: CGPoint(x: plot.minX, y: plot.midY))
        frame.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        decorations.append(
            .path(frame, color: theme.palette.tableBorder, lineWidth: 1, filled: false))

        var centres: [CGPoint] = []
        var reaches: [CGFloat] = []
        var dots: [CGRect] = []
        for point in chart.points {
            // y grows up the page here and down everywhere else, so a point
            // written at 1 belongs at the top.
            let centre = CGPoint(
                x: plot.minX + CGFloat(point.x) * side,
                y: plot.maxY - CGFloat(point.y) * side
            )
            centres.append(centre)
            // A point told how big to be, and in what colours, is drawn that
            // way: a colour on a quadrant chart is the author saying something,
            // not decoration.
            let radius = CGFloat(point.radius ?? 5) * metrics.scale
            let dot = CGRect(
                x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            // A ring drawn round the dot is half outside it, and a name over
            // the ring is as hard to read as one over the dot.
            let ring = point.stroke == nil ? 0 : CGFloat(point.strokeWidth ?? 1) * metrics.scale / 2
            written.append(dot.insetBy(dx: -ring, dy: -ring))
            dots.append(dot.insetBy(dx: -ring, dy: -ring))
            reaches.append(radius + ring)
            let disc = CGPath(ellipseIn: dot, transform: nil)
            decorations.append(
                .path(
                    disc, color: point.fill.map(cgColor) ?? theme.diagramWheel[0], lineWidth: 0,
                    filled: true))
            if let stroke = point.stroke {
                decorations.append(
                    .path(
                        disc, color: cgColor(stroke),
                        lineWidth: CGFloat(point.strokeWidth ?? 1) * metrics.scale, filled: false))
            }
        }
        for (index, point) in chart.points.enumerated() {
            let centre = centres[index]
            let line = text(point.label, font: font, color: theme.palette.text)
            let size = measure(line)
            // Under its dot and centred on it, the way Mermaid writes it. A name
            // beside the dot had to change sides near the right edge, so names
            // jumped left and right of their dots for no reason a reader could
            // see. Where the place under the dot is taken — by another dot, by
            // another name, by a quarter's name — the name tries above the dot,
            // then leaning to one side under or over it, then beside it, then a
            // line further away or off a corner, because two things on top of
            // each other say less than one. A name never leaves the square:
            // outside it, it stands among the axis words and belongs to no dot.
            let radius = reaches[index]
            let gap = 4 * metrics.scale
            let below = radius + gap + size.height / 2
            let aside = radius + gap + size.width / 2
            let step = size.height + 3 * metrics.scale
            // Under or over the dot, a name that does not fit centred may still
            // fit starting or ending at the dot.
            let lean = max(0, size.width / 2 - radius)
            let offsets: [CGVector] = [
                CGVector(dx: 0, dy: below), CGVector(dx: 0, dy: -below),
                CGVector(dx: -lean, dy: below), CGVector(dx: lean, dy: below),
                CGVector(dx: -lean, dy: -below), CGVector(dx: lean, dy: -below),
                CGVector(dx: aside, dy: 0), CGVector(dx: -aside, dy: 0),
            ]
            // Beside the dot, a name a little lower or higher still reads as
            // level with it, and often clears a neighbour the level one grazes.
            let nudges = [size.height / 4, -size.height / 4, size.height / 2, -size.height / 2]
            let further: [CGVector] =
                nudges.flatMap {
                    [CGVector(dx: aside, dy: $0), CGVector(dx: -aside, dy: $0)]
                } + [
                    CGVector(dx: 0, dy: below + step), CGVector(dx: 0, dy: -below - step),
                    CGVector(dx: aside, dy: below), CGVector(dx: -aside, dy: below),
                    CGVector(dx: aside, dy: -below), CGVector(dx: -aside, dy: -below),
                ]
            // A place that runs past the edge is pushed back inside: a name
            // over a dot in the corner stands over it, flush with the border.
            let boxes = (offsets + further).map {
                CGRect(
                    x: max(
                        plot.minX, min(centre.x + $0.dx - size.width / 2, plot.maxX - size.width)),
                    y: max(
                        plot.minY,
                        min(centre.y + $0.dy - size.height / 2, plot.maxY - size.height)),
                    width: size.width, height: size.height)
            }
            // How much of a place is already taken; the first place with none
            // wins, and when every place is taken, the one taken least. A name
            // over its own dot hides the very thing it names, so that counts
            // three times over.
            func covered(_ box: CGRect) -> CGFloat {
                func area(_ other: CGRect) -> CGFloat {
                    let overlap = other.intersection(box.insetBy(dx: -2, dy: 0))
                    return overlap.isNull ? 0 : overlap.width * overlap.height
                }
                return written.reduce(0) { $0 + area($1) } + 2 * area(dots[index])
            }
            // A name nearer another dot than its own reads as that dot's name,
            // which is worse than a name a little in the way: it costs as much
            // as a quarter of the name being covered.
            func distance(from box: CGRect, to dot: Int) -> CGFloat {
                let near = CGPoint(
                    x: max(box.minX, min(centres[dot].x, box.maxX)),
                    y: max(box.minY, min(centres[dot].y, box.maxY)))
                return hypot(near.x - centres[dot].x, near.y - centres[dot].y) - reaches[dot]
            }
            func ownsIt(_ box: CGRect) -> Bool {
                let own = distance(from: box, to: index)
                return !centres.indices.contains {
                    $0 != index && distance(from: box, to: $0) < own - 1
                }
            }
            func cost(_ box: CGRect) -> CGFloat {
                covered(box) + (ownsIt(box) ? 0 : box.width * box.height / 4)
            }
            let box = boxes.min { cost($0) < cost($1) } ?? boxes[0]
            written.append(box)
            decorations.append(
                .glyphs(line, origin: CGPoint(x: box.minX, y: box.maxY - descent(line))))
        }

        for (words, position) in [
            (chart.xAxis.low, CGPoint(x: plot.minX + side / 4, y: plot.maxY + axisRoom / 2)),
            (chart.xAxis.high, CGPoint(x: plot.maxX - side / 4, y: plot.maxY + axisRoom / 2)),
        ] where !words.isEmpty {
            let line = text(words, font: font, color: theme.palette.secondaryText)
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: position.x - size.width / 2,
                        y: position.y + size.height / 2 - descent(line))))
        }
        for (words, y) in [
            (chart.yAxis.high, plot.minY + side / 4), (chart.yAxis.low, plot.maxY - side / 4),
        ] where !words.isEmpty {
            let line = text(words, font: font, color: theme.palette.secondaryText)
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: plot.minX - 10 * metrics.scale - size.width,
                        y: y + size.height / 2 - descent(line))))
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    // MARK: - XY chart

    /// Bars and lines over named categories.
    private static func xy(
        _ chart: XYChart, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.controlLabel, by: metrics.scale * 0.9)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale * 1.1)
        let values = chart.series.flatMap(\.values)
        let low = chart.yRange?.low ?? min(0, values.min() ?? 0)
        let high = chart.yRange?.high ?? (values.max() ?? 1)
        guard high > low else { return Drawing(decorations: [], size: .zero, contentWidth: 0) }

        // Room down the left for the biggest number the axis will print.
        let ticks = (0...4).map { low + (high - low) * Double($0) / 4 }
        let tickLines = ticks.map {
            text(number($0), font: font, color: theme.palette.secondaryText)
        }
        let gutter = (tickLines.map { measure($0).width }.max() ?? 0) + 10 * metrics.scale
        let plotWidth = max(
            240 * metrics.scale,
            min(420 * metrics.scale, CGFloat(chart.categories.count) * 60 * metrics.scale))
        let plotHeight = 190 * metrics.scale
        let labelRoom = (tickLines.first.map { measure($0).height } ?? 10) + 8 * metrics.scale
        let content = gutter + plotWidth

        var titleLine: CTLine?
        var titleSize = CGSize.zero
        if !chart.title.isEmpty {
            let line = text(chart.title, font: titleFont, color: theme.palette.text)
            titleLine = line
            titleSize = measure(line)
        }
        // The axis is named above it rather than turned on its side: rotated
        // glyphs are the one thing this drawing has no way to place.
        var yTitleLine: CTLine?
        var yTitleSize = CGSize.zero
        if !chart.yTitle.isEmpty {
            let line = text(chart.yTitle, font: font, color: theme.palette.secondaryText)
            yTitleLine = line
            yTitleSize = measure(line)
        }
        let yTitleRoom = yTitleLine == nil ? 0 : yTitleSize.height + 6 * metrics.scale
        let titleRoom = titleLine == nil ? 0 : titleSize.height + 14 * metrics.scale
        let height = metrics.padding * 2 + titleRoom + yTitleRoom + plotHeight + labelRoom

        let left = max(metrics.padding, (width - content) / 2)
        let plot = CGRect(
            x: left + gutter, y: metrics.padding + titleRoom + yTitleRoom, width: plotWidth,
            height: plotHeight)
        var decorations: [BlockBox.Decoration] = []
        if let titleLine {
            decorations.append(
                .glyphs(
                    titleLine,
                    origin: CGPoint(
                        x: max(metrics.padding, (width - titleSize.width) / 2),
                        y: metrics.padding + titleSize.height - descent(titleLine)
                    )
                )
            )
        }
        if let yTitleLine {
            decorations.append(
                .glyphs(
                    yTitleLine,
                    origin: CGPoint(
                        x: left, y: plot.minY - 6 * metrics.scale - descent(yTitleLine))))
        }
        for (index, line) in tickLines.enumerated() {
            let y = plot.maxY - plotHeight * CGFloat(index) / 4
            let rule = CGMutablePath()
            rule.move(to: CGPoint(x: plot.minX, y: y))
            rule.addLine(to: CGPoint(x: plot.maxX, y: y))
            decorations.append(
                .path(
                    rule, color: theme.palette.tableBorder, lineWidth: index == 0 ? 1 : 0.5,
                    filled: false))
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: plot.minX - 8 * metrics.scale - size.width,
                        y: y + size.height / 2 - descent(line))))
        }

        let step = plotWidth / CGFloat(chart.categories.count)
        func level(_ value: Double) -> CGFloat {
            CGFloat((value - low) / (high - low)) * plotHeight
        }
        let bars = chart.series.filter(\.isBar).count
        var barIndex = 0
        for (index, series) in chart.series.enumerated() {
            let colour = theme.diagramWheel[index % theme.diagramWheel.count]
            if series.isBar {
                // Several bar series share a category, so each takes a slice of
                // it rather than standing on top of the one before.
                let room = step * 0.7 / CGFloat(max(1, bars))
                for (position, value) in series.values.enumerated() {
                    let tall = max(1, level(value))
                    let bar = CGRect(
                        x: plot.minX + step * CGFloat(position) + step * 0.15
                            + room * CGFloat(barIndex),
                        y: plot.maxY - tall,
                        width: room,
                        height: tall
                    )
                    decorations.append(
                        .fill(rect: bar, color: colour, cornerRadius: 2 * metrics.scale))
                }
                barIndex += 1
            } else {
                let path = CGMutablePath()
                for (position, value) in series.values.enumerated() {
                    let point = CGPoint(
                        x: plot.minX + step * (CGFloat(position) + 0.5),
                        y: plot.maxY - level(value)
                    )
                    if position == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                decorations.append(
                    .path(path, color: colour, lineWidth: 2 * metrics.scale, filled: false))
            }
            // A point its author named carries the words just above it.
            for (position, name) in series.labels.enumerated()
            where !name.isEmpty && position < series.values.count {
                let line = text(name, font: font, color: theme.palette.secondaryText)
                let size = measure(line)
                let top = plot.maxY - level(series.values[position])
                decorations.append(
                    .glyphs(
                        line,
                        origin: CGPoint(
                            x: min(
                                max(
                                    plot.minX,
                                    plot.minX + step * (CGFloat(position) + 0.5) - size.width / 2),
                                plot.maxX - size.width),
                            y: max(plot.minY + size.height, top - 6 * metrics.scale)
                                - descent(line))))
            }
        }
        for (index, name) in chart.categories.enumerated() {
            let line = text(name, font: font, color: theme.palette.secondaryText)
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: plot.minX + step * (CGFloat(index) + 0.5) - size.width / 2,
                        y: plot.maxY + 6 * metrics.scale + size.height - descent(line))))
        }
        // The axis's own name stands under the names of its categories.
        if !chart.xTitle.isEmpty {
            let line = text(chart.xTitle, font: font, color: theme.palette.secondaryText)
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: plot.midX - size.width / 2,
                        y: plot.maxY + 10 * metrics.scale + size.height * 2 - descent(line))))
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    /// A number as written: no decimal point where it does not need one, and no
    /// trailing zeros where it does. Two places is as far as it goes, which is
    /// as far as the numbers in a diagram ever mean anything.
    private static func number(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))" }
        var written = String(format: "%.2f", value)
        while written.hasSuffix("0") { written.removeLast() }
        if written.hasSuffix(".") { written.removeLast() }
        return written
    }

    // MARK: - Git graph

    /// Commits along a line, one lane per branch.
    private static func gitGraph(
        _ graph: GitGraph, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.controlLabel, by: metrics.scale * 0.9)
        let branchFont = scaled(theme.bodyBold, by: metrics.scale * 0.9)
        /// How far a branch name's tag reaches past the words on it.
        let namePad = 6 * metrics.scale
        let gutter =
            (graph.branches.map {
                measure(text($0, font: branchFont, color: theme.palette.text)).width
            }.max() ?? 0) + 14 * metrics.scale
        // Turned on its side the lanes run down the page: what was a column of
        // commits becomes a row of them, and the branch names sit above their
        // lanes rather than beside them.
        let down = graph.vertical
        /// What is written under a commit's dot, and nothing when nothing is.
        ///
        /// A commit's own name is its place in the graph unless its author gave
        /// it one. A merge is named only by its author: a merge is read from the
        /// two lines meeting at it, and a number under it says nothing they do
        /// not. A copy is not named at all — it goes by the tag saying what it
        /// was picked from. Both are Mermaid's rules, in the one condition it
        /// writes a commit label under.
        func named(_ order: Int, _ commit: GitGraph.Commit) -> String {
            guard graph.names, commit.picks == nil else { return "" }
            if commit.merges != nil { return commit.label }
            return commit.label.isEmpty ? "\(order)" : commit.label
        }
        // A commit is named under its dot, and a name is far wider than a dot:
        // laid across the page the commits have to stand as far apart as their
        // names, or a row of names runs into itself. Down the page the names
        // stack instead and the dots need no more room than they take.
        let tagFont = scaled(theme.bodyBold, by: metrics.scale * 0.8)
        let widest =
            graph.commits.enumerated().map { order, commit in
                measure(text(named(order, commit), font: font, color: theme.palette.text)).width
            }.max() ?? 0
        let step = down ? 56 * metrics.scale : max(56 * metrics.scale, widest + 8 * metrics.scale)
        // Down the page the names stand side by side over their lanes, so a
        // lane has to be at least as wide as the tag it is named by — two tags
        // touching read as one word twice as long.
        let widestName =
            (graph.branches.map {
                measure(text($0, font: branchFont, color: theme.palette.text)).width
            }.max() ?? 0) + namePad * 2 + 8 * metrics.scale
        let lane = down ? max(46 * metrics.scale, widestName) : 46 * metrics.scale
        let radius = 7 * metrics.scale
        let columns = (graph.commits.map(\.column).max() ?? 0) + 1
        let nameHeight =
            (graph.branches.map {
                measure(text($0, font: branchFont, color: theme.palette.text)).height
            }.max() ?? 0) + 10 * metrics.scale
        // A tag may say a great deal more than a name — what a copy was picked
        // from, and through which parent — and pushing the commits apart far
        // enough to hold it would stretch the whole graph for one word. Mermaid
        // lets a tag overlap whatever stands beside it, so the picture grows
        // only by what hangs off either end of it.
        let widestTag =
            graph.commits.map {
                measure(text($0.tag, font: tagFont, color: theme.palette.text)).width
            }.max() ?? 0
        let spill = max(0, (widestTag - step) / 2)
        let content =
            spill * 2
            + (down
                ? CGFloat(graph.branches.count) * lane : gutter + CGFloat(columns) * step)
        let height =
            down
            ? metrics.padding * 2 + nameHeight + CGFloat(columns) * step
            : metrics.padding * 2 + CGFloat(graph.branches.count) * lane

        let left = max(metrics.padding, (width - content) / 2)
        /// How far along its lane a commit stands, and how far across the lanes.
        func along(_ column: Int) -> CGFloat {
            (down ? metrics.padding + nameHeight : left + spill + gutter)
                + step * (CGFloat(column) + 0.5)
        }
        func across(_ branch: Int) -> CGFloat {
            (down ? left + spill : metrics.padding) + lane * (CGFloat(branch) + 0.5)
        }
        func centre(of commit: GitGraph.Commit) -> CGPoint {
            down
                ? CGPoint(x: across(commit.branch), y: along(commit.column))
                : CGPoint(x: along(commit.column), y: across(commit.branch))
        }

        var decorations: [BlockBox.Decoration] = []
        for (index, name) in graph.branches.enumerated() {
            let side = across(index)
            let colour = theme.diagramWheel[index % theme.diagramWheel.count]
            let own = graph.commits.filter { $0.branch == index }
            guard let first = own.first, let last = own.last else { continue }
            let rail = CGMutablePath()
            if down {
                rail.move(to: CGPoint(x: side, y: centre(of: first).y))
                rail.addLine(to: CGPoint(x: side, y: centre(of: last).y))
            } else {
                rail.move(to: CGPoint(x: centre(of: first).x, y: side))
                rail.addLine(to: CGPoint(x: centre(of: last).x, y: side))
            }
            decorations.append(
                .path(rail, color: colour, lineWidth: 2.5 * metrics.scale, filled: false))
            // The name used to be written in the branch's own colour on the
            // page, where the paler half of the wheel came out at 2.2:1 — a
            // word nobody could read, saying which line is which. The colour
            // moves behind the word instead, as a tag, and the word is written
            // in the ink everything else in the picture is written in.
            let line = text(name, font: branchFont, color: theme.palette.text)
            let size = measure(line)
            let origin =
                down
                ? CGPoint(
                    x: side - size.width / 2, y: metrics.padding + size.height - descent(line))
                : CGPoint(
                    x: left + spill + gutter - 10 * metrics.scale - namePad - size.width,
                    y: side + size.height / 2 - descent(line))
            let tag = CGRect(
                x: origin.x - namePad, y: origin.y + descent(line) - size.height - namePad / 2,
                width: size.width + namePad * 2, height: size.height + namePad)
            decorations.append(
                .fill(
                    rect: tag,
                    color: wash(
                        colour, on: theme.palette.codeBackground, under: theme.palette.text,
                        shownAt: 0.28
                    ).copy(alpha: 0.28) ?? colour, cornerRadius: 4 * metrics.scale))
            decorations.append(.glyphs(line, origin: origin))
        }
        // A branch is drawn from where it left its parent and a merge back to
        // where it rejoined, so a lane is never a line floating on its own.
        for (index, commit) in graph.commits.enumerated() {
            let here = centre(of: commit)
            let opened = !graph.commits[..<index].contains { $0.branch == commit.branch }
            let source =
                commit.merges ?? commit.picks
                ?? (opened
                    ? graph.commits[..<index].lastIndex(where: { $0.branch != commit.branch })
                    : nil)
            guard let source else { continue }
            let from = centre(of: graph.commits[source])
            // The bend leaves along the lane and arrives across it, whichever
            // way round the lanes were drawn.
            let firstControl =
                down
                ? CGPoint(x: from.x, y: (from.y + here.y) / 2)
                : CGPoint(x: (from.x + here.x) / 2, y: from.y)
            let secondControl =
                down
                ? CGPoint(x: here.x, y: (from.y + here.y) / 2)
                : CGPoint(x: (from.x + here.x) / 2, y: here.y)
            let path = CGMutablePath()
            path.move(to: from)
            path.addCurve(to: here, control1: firstControl, control2: secondControl)
            // A cherry-pick copies rather than joins, so its line is dotted:
            // the two dots are the same work, not one line running on.
            var drawn: CGPath = path
            if commit.picks != nil {
                let points = (0...24).map { step -> CGPoint in
                    let time = CGFloat(step) / 24
                    let rest = 1 - time
                    func at(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                        rest * rest * rest * a + 3 * rest * rest * time * b
                            + 3 * rest * time * time * c + time * time * time * d
                    }
                    return CGPoint(
                        x: at(from.x, firstControl.x, secondControl.x, here.x),
                        y: at(from.y, firstControl.y, secondControl.y, here.y))
                }
                drawn = dashed(along: points, dash: 3, gap: 3)
            }
            decorations.append(
                .path(
                    drawn, color: theme.diagramWheel[commit.branch % theme.diagramWheel.count],
                    lineWidth: 2 * metrics.scale, filled: false))
        }
        for (order, commit) in graph.commits.enumerated() {
            let here = centre(of: commit)
            let colour = theme.diagramWheel[commit.branch % theme.diagramWheel.count]
            let dot = CGRect(
                x: here.x - radius, y: here.y - radius, width: radius * 2, height: radius * 2)
            // A merge is drawn hollow: it is the one commit that belongs to two
            // lines at once, and a reader following a lane has to be able to see
            // where the other one arrived.
            if commit.merges != nil {
                decorations.append(
                    .path(
                        CGPath(ellipseIn: dot, transform: nil), color: theme.palette.background,
                        lineWidth: 0, filled: true))
                decorations.append(
                    .path(
                        CGPath(ellipseIn: dot, transform: nil), color: colour,
                        lineWidth: 2.5 * metrics.scale, filled: false))
            } else {
                decorations.append(
                    .path(
                        CGPath(ellipseIn: dot, transform: nil), color: colour, lineWidth: 0,
                        filled: true))
            }
            switch commit.kind {
            case .normal:
                break
            case .highlighted:
                decorations.append(
                    .path(
                        CGPath(
                            ellipseIn: dot.insetBy(dx: -3 * metrics.scale, dy: -3 * metrics.scale),
                            transform: nil),
                        color: colour, lineWidth: 1.5 * metrics.scale, filled: false))
            case .reverse:
                // A commit that undoes another one is crossed out, which is the
                // one mark a reader already knows the meaning of.
                let arm = radius * 0.62
                let cross = CGMutablePath()
                cross.move(to: CGPoint(x: here.x - arm, y: here.y - arm))
                cross.addLine(to: CGPoint(x: here.x + arm, y: here.y + arm))
                cross.move(to: CGPoint(x: here.x + arm, y: here.y - arm))
                cross.addLine(to: CGPoint(x: here.x - arm, y: here.y + arm))
                decorations.append(
                    .path(
                        cross, color: theme.palette.background, lineWidth: 2 * metrics.scale,
                        filled: false))
            }
            // A name goes above the dot and a tag below, so the two never land
            // on each other.
            // A commit that has a name is named under the graph, whether its
            // author named it or not: a row of unlabelled dots says nothing
            // about which commit is which. What stands there is the commit's
            // place in the graph. Mermaid writes that place and then a random
            // string — "a unique & random ID", as its own documentation puts it
            // — and a string that is different every time the picture is drawn
            // is not a hash of anything. Writing one here would show the reader
            // an identifier that refers to nothing.
            for (words, above) in [(named(order, commit), true), (commit.tag, false)]
            where !words.isEmpty {
                let line = text(
                    words, font: above ? font : tagFont,
                    color: above ? theme.palette.secondaryText : colour)
                let size = measure(line)
                decorations.append(
                    .glyphs(
                        line,
                        origin: CGPoint(
                            x: here.x - size.width / 2,
                            y: above
                                ? here.y - radius - 4 * metrics.scale - descent(line)
                                : here.y + radius + 4 * metrics.scale + size.height - descent(line)
                        )
                    )
                )
            }
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    // MARK: - Flowchart

    private struct Placed {
        var frame: CGRect
        /// One entry per written line: a label may be broken with `<br/>`, and
        /// a C4 element's description is a line of its own under its name.
        var lines: [CTLine]
        /// The whole stack of lines: as wide as the widest, as tall as all.
        var labelSize: CGSize
        var shape: Flowchart.Shape
        var style: Flowchart.Style
    }

    /// A run of words, already broken, written in the middle of the room it is
    /// given.
    private static func centred(_ lines: [CTLine], size: CGSize, in rect: CGRect)
        -> [BlockBox.Decoration]
    {
        var decorations: [BlockBox.Decoration] = []
        var y = rect.midY - size.height / 2
        for line in lines {
            let one = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(x: rect.midX - one.width / 2, y: y + one.height - descent(line))
                )
            )
            y += one.height
        }
        return decorations
    }

    /// A node's words, broken where the author broke them.
    private static func labelLines(_ words: String, font: CTFont, color: CGColor)
        -> (lines: [CTLine], size: CGSize)
    {
        // A label written between backticks is markdown, and only there does a
        // `**` mean anything other than two stars on the page.
        var words = words
        var markdown = false
        if words.count >= 2, words.hasPrefix("`"), words.hasSuffix("`") {
            markdown = true
            words = String(words.dropFirst().dropLast())
        }
        var parts = [words]
        for separator in ["<br/>", "<br />", "<br>", "\\n"] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let lines = parts.map { part -> CTLine in
            let one = part.trimmingCharacters(in: .whitespaces)
            return markdown
                ? marked(one, font: font, color: color) : text(one, font: font, color: color)
        }
        let sizes = lines.map(measure)
        return (
            lines,
            CGSize(
                width: sizes.map(\.width).max() ?? 0,
                height: sizes.reduce(0) { $0 + $1.height }
            )
        )
    }

    private static func flowchart(
        _ chart: Flowchart, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale)
        var boxes: [Placed] = []
        for node in chart.nodes {
            let colour = faded(node.style.text.map(cgColor) ?? theme.palette.text, by: node.style)
            let (lines, size) = labelLines(node.label, font: font, color: colour)
            var box = CGSize(
                width: max(metrics.minimumNodeWidth, size.width + metrics.nodePaddingX * 2),
                height: size.height + metrics.nodePaddingY * 2
            )
            // A shape that cuts its own corners has to be given the room back,
            // or the words run out through the slant.
            switch node.shape {
            case .diamond:
                box.width += size.width * 0.5 + 12 * metrics.scale
                box.height += size.height * 0.7
            case .hexagon, .parallelogram, .parallelogramAlt, .trapezoid, .trapezoidAlt:
                box.width += box.height * 0.5
            case .subroutine, .cylinder:
                box.width += 12 * metrics.scale
            case .circle, .doubleCircle:
                let side = max(box.width, box.height + size.width * 0.3)
                box = CGSize(width: side, height: side)
            case .flag:
                box.width += 10 * metrics.scale
            case .point, .endPoint:
                let side = 16 * metrics.scale
                box = CGSize(width: side, height: side)
            case .bar:
                // A fork carries no words: it is the bar itself that is read.
                box = CGSize(width: 70 * metrics.scale, height: 8 * metrics.scale)
            case .cloud, .bang:
                // The bumps stand outside the words, so the words need room.
                box.width += size.width * 0.4 + 20 * metrics.scale
                box.height += size.height * 0.8
            case .note:
                box.width += 10 * metrics.scale
                box.height += 6 * metrics.scale
            case .blockArrow(let up, let down, let left, let right):
                // The words sit in the bar, so the arrow needs room for its
                // points on top of them, on whichever sides it has points.
                if up || down { box.height += size.height * 1.4 }
                if left || right { box.width += size.width * 0.6 + 20 * metrics.scale }
            // A named shape gets back whatever its own drawing takes away: the
            // corner it cuts, the wave along its foot, the rule down its side,
            // the copies stacked behind it.
            case .card, .loopLimit:
                box.height += 8 * metrics.scale
            case .linedProcess, .dividedProcess, .taggedProcess, .linedDocument,
                .taggedDocument:
                box.width += 12 * metrics.scale
                box.height += 8 * metrics.scale
            case .windowPane:
                box.width += 14 * metrics.scale
                box.height += 12 * metrics.scale
            case .stackedProcess, .stackedDocument:
                box.width += 12 * metrics.scale
                box.height += 14 * metrics.scale
            case .document:
                box.height += 10 * metrics.scale
            case .paperTape:
                box.height += 18 * metrics.scale
            case .storedData, .display, .delay, .dataStore, .horizontalCylinder:
                box.width += 22 * metrics.scale
            case .linedCylinder:
                box.width += 12 * metrics.scale
                box.height += 10 * metrics.scale
            case .manualInput:
                box.height += 10 * metrics.scale
            case .braceLeft, .braceRight:
                box.width += 14 * metrics.scale
            case .braces:
                box.width += 28 * metrics.scale
            case .triangle, .flippedTriangle:
                // Only the base of a triangle is wide enough for words, so it
                // is given the width twice over and room to move them there.
                box.width += size.width * 1.6 + 30 * metrics.scale
                box.height += size.height * 1.1
            case .hourglass:
                // A collate mark carries no words: the two triangles are read.
                box = CGSize(width: 44 * metrics.scale, height: 44 * metrics.scale)
            case .bolt:
                // Nor does a com link: the bolt is the whole of it.
                box = CGSize(width: 34 * metrics.scale, height: 46 * metrics.scale)
            case .junction:
                let side = 16 * metrics.scale
                box = CGSize(width: side, height: side)
            case .summary:
                let side = max(box.width, box.height + size.width * 0.3)
                box = CGSize(width: side, height: side)
            case .pictureBox:
                box.height += 46 * metrics.scale
                box.width = max(box.width, 62 * metrics.scale)
            case .text:
                // The words alone, with nothing drawn around them to make room
                // for.
                box = CGSize(width: size.width, height: size.height)
            case .rectangle, .rounded, .stadium:
                break
            }
            boxes.append(
                Placed(
                    frame: CGRect(origin: .zero, size: box),
                    lines: lines,
                    labelSize: size,
                    shape: node.shape,
                    style: node.style
                )
            )
        }

        // An edge's words are written across the gap between two ranks, so the
        // gap has to be wide enough to hold them. The gap holds the words *and*
        // the line: an arrowhead at one end, and a visible run of line on both
        // sides of the label. A gap sized to the words alone leaves a labelled
        // edge looking like a chip with a stub either side of it.
        let labelFont = scaled(theme.controlLabel, by: metrics.scale)
        // An edge's words are a block of the layout, broken into short lines so
        // the block is narrow: a long label on one line pushes every box beside
        // it out of the way.
        var labelSizes: [Int: CGSize] = [:]
        for (index, edge) in chart.edges.enumerated()
        where !edge.label.isEmpty && edge.from != edge.to {
            let size = edgeWords(edge.label, font: labelFont, color: theme.palette.text).size
            labelSizes[index] = plate(size, centred: .zero).size
        }
        // A loop stands out beside its box, and that room is the box's own:
        // to its right when the layers run down the page, below it when they
        // run across, so the loop never stands in the gap the lines cross.
        var loops: [Int: CGSize] = [:]
        for edge in chart.edges where edge.from == edge.to {
            guard case .node(let node) = edge.from else { continue }
            let said =
                edge.label.isEmpty
                ? .zero
                : measure(text(edge.label, font: labelFont, color: theme.palette.text))
            let beside =
                loopReach(metrics) + metrics.arrowLength
                + (said.width > 0 ? said.width + 12 * metrics.scale : 0)
            let below =
                loopReach(metrics) + metrics.arrowLength
                + (said.height > 0 ? said.height + 6 * metrics.scale : 0)
            let known = loops[node] ?? .zero
            loops[node] = CGSize(width: max(known.width, beside), height: max(known.height, below))
        }
        // A frame's name is written above it, and a name broken over two lines
        // needs twice the room, so the deepest of them decides how far every
        // frame stands from what is over it.
        let titleRoom =
            chart.groups.isEmpty
            ? 0
            : (chart.groups.map {
                labelLines($0.title, font: labelFont, color: theme.palette.text).size.height
            }.max() ?? 0) + 7 * metrics.scale
        let placement = placed(
            chart: chart, sizes: boxes.map(\.frame.size), labels: labelSizes, loops: loops,
            metrics: metrics, titleRoom: titleRoom, inset: metrics.siblingGap / 2,
            layerGap: metrics.rankGap, lineGap: 10 * metrics.scale)
        for (index, frame) in placement.nodes { boxes[index].frame = frame }
        // A loop stands out beside the box it returns to, and that room is part
        // of the picture: without it the loop is cut off at the edge.
        var content = placement.size
        for edge in chart.edges where edge.from == edge.to {
            let said =
                edge.label.isEmpty
                ? 0
                : measure(text(edge.label, font: labelFont, color: theme.palette.text)).width
                    + 12 * metrics.scale
            let loopRoom = loopReach(metrics) + metrics.arrowLength + said
            switch edge.from {
            case .node(let index) where placement.below.contains(index):
                content.height = max(
                    content.height, boxes[index].frame.maxY + (loops[index]?.height ?? 0))
            case .node(let index) where boxes.indices.contains(index):
                content.width = max(content.width, boxes[index].frame.maxX + loopRoom)
            case .frame(let group):
                guard let rect = placement.frames[group] else { continue }
                content.width = max(content.width, rect.maxX + loopRoom)
            default: continue
            }
        }

        // Centre the picture in the reading column, and never let it run out of
        // it: a diagram wider than the column starts at the margin instead of
        // being pushed off the left edge.
        let left = max(metrics.padding, (width - content.width) / 2)
        for index in boxes.indices { boxes[index].frame.origin.x += left }
        let frames = placement.frames.mapValues { $0.offsetBy(dx: left, dy: 0) }
        let routes = placement.routes.mapValues { $0.map { CGPoint(x: $0.x + left, y: $0.y) } }
        let wordPlaces = placement.labels.mapValues { $0.offsetBy(dx: left, dy: 0) }
        // Where every box came to rest, taken once and not read again from the
        // array they live in. An edge asks this while it is being routed, and a
        // closure that reaches back into a variable the surrounding code can
        // still write to is a closure sharing something that may change.
        let placed = boxes.map(\.frame)

        // Where an edge starts and stops: a box's own frame, or the border of
        // the frame it names.
        func rect(_ end: Flowchart.End) -> CGRect? {
            switch end {
            case .node(let index): return boxes.indices.contains(index) ? boxes[index].frame : nil
            case .frame(let group): return frames[group]
            }
        }
        // A frame's name is written in the strip over its border, and a line
        // coming in from above crosses that strip. The name moves along it to
        // where no line runs; where there is no such place, a line that ends on
        // the frame itself stops over the name instead of running through it.
        var nameAt: [Int: CGFloat] = [:]
        var shortOf = Set<Int>()
        for group in chart.groups.indices where !chart.groups[group].title.isEmpty {
            guard let border = frames[group] else { continue }
            let width =
                labelLines(
                    chart.groups[group].title, font: scaled(theme.controlLabel, by: metrics.scale),
                    color: theme.palette.text
                ).size.width
            let top = border.minY - titleRoom
            var passing: [[CGPoint]] = []
            var ending: [(edge: Int, x: CGFloat)] = []
            for (index, route) in routes {
                guard let last = route.last, let first = route.first else { continue }
                let edge = chart.edges[index]
                if edge.to == .frame(group), abs(last.y - top) < 1 {
                    ending.append((index, last.x))
                    continue
                }
                if edge.from == .frame(group), abs(first.y - top) < 1 {
                    ending.append((index, first.x))
                    continue
                }
                if let from = rect(edge.from), let to = rect(edge.to) {
                    passing.append(carried(route, from: from, to: to, boxes: placed))
                }
            }
            let through = crossings(
                of: passing, strip: top, border.minY, from: border.minX, to: border.maxX)
            let clearance = 4 * metrics.scale
            func spot(clear of: [CGFloat]) -> CGFloat? {
                Self.spot(
                    width, from: border.minX + 4, to: border.maxX - 4, clear: of, by: clearance)
            }
            if let x = spot(clear: through + ending.map(\.x)) {
                nameAt[group] = x
            } else {
                let x = spot(clear: through) ?? border.minX + 4
                nameAt[group] = x
                for line in ending where line.x > x - clearance && line.x < x + width + clearance {
                    shortOf.insert(line.edge)
                }
            }
        }

        var decorations: [BlockBox.Decoration] = []
        // Frames first: everything else in the diagram stands on top of them,
        // and an inner frame after the one that holds it.
        for group in chart.groups.indices.sorted(by: {
            depth(of: $0, in: chart) < depth(of: $1, in: chart)
        }) {
            guard let rect = frames[group] else { continue }
            decorations += frame(
                chart.groups[group], rect: rect, theme: theme, metrics: metrics,
                titleRoom: titleRoom, nameAt: nameAt[group])
        }
        var labels: [BlockBox.Decoration] = []
        var geometry = Geometry(
            nodes: placed, frames: chart.groups.indices.compactMap { frames[$0] })
        for (index, edge) in chart.edges.enumerated() {
            guard let from = rect(edge.from), let to = rect(edge.to) else { continue }
            /// A frame is the rectangle it is drawn as, so only a box that is
            /// something other than a rectangle has an outline worth clipping to.
            func outline(of end: Flowchart.End) -> CGPath? {
                guard case .node(let index) = end, index < boxes.count else { return nil }
                switch boxes[index].shape {
                case .rectangle, .rounded, .stadium, .subroutine, .linedProcess, .dividedProcess,
                    .windowPane, .taggedProcess, .stackedProcess, .text:
                    return nil
                default: return shape(boxes[index])
                }
            }
            let drawn = self.edge(
                edge, from: from, to: to, theme: theme, metrics: metrics,
                fromOutline: outline(of: edge.from), toOutline: outline(of: edge.to),
                route: routes[index].map {
                    shortOf.contains(index) ? $0 : carried($0, from: from, to: to, boxes: placed)
                },
                wordsAt: wordPlaces[index],
                loopBelow: edge.from == edge.to
                    && {
                        if case .node(let node) = edge.from {
                            return placement.below.contains(node)
                        }
                        return false
                    }())
            decorations += drawn.shaft
            labels += drawn.label
            if !drawn.path.isEmpty {
                var ends = held(by: edge, chart: chart)
                for end in [edge.from, edge.to] {
                    if case .node(let node) = end { ends.insert(node) }
                }
                geometry.lines.append(
                    Geometry.Line(
                        points: drawn.path, label: drawn.plate, ends: ends.sorted(),
                        loop: edge.from == edge.to))
            }
        }
        for box in boxes { decorations += node(box, theme: theme, metrics: metrics) }
        // An edge that skips a rank passes over whatever stands between, so its
        // words are written last and keep their own plate under them.
        decorations += labels
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: content.height + metrics.padding * 2),
            contentWidth: content.width,
            geometry: geometry
        )
    }

    /// Whether one frame holds another, however deep.
    private static func reaches(_ outer: Int, _ inner: Int, in chart: Flowchart) -> Bool {
        var walk = chart.groups[inner].parent
        var steps = 0
        while let parent = walk, steps <= chart.groups.count {
            if parent == outer { return true }
            walk = chart.groups[parent].parent
            steps += 1
        }
        return false
    }

    /// Every box inside a frame either end of an edge names.
    private static func held(by edge: Flowchart.Edge, chart: Flowchart) -> Set<Int> {
        var inside: Set<Int> = []
        for end in [edge.from, edge.to] {
            guard case .frame(let group) = end else { continue }
            var wanted = [group]
            while let next = wanted.popLast() {
                inside.formUnion(chart.groups[next].members)
                wanted += chart.groups.indices.filter { chart.groups[$0].parent == next }
            }
        }
        return inside
    }

    /// How many frames a frame is written inside.
    private static func depth(of group: Int, in chart: Flowchart) -> Int {
        var depth = 0
        var walk = chart.groups[group].parent
        while let parent = walk, depth < chart.groups.count {
            depth += 1
            walk = chart.groups[parent].parent
        }
        return depth
    }

    /// Where every box and every frame of a flowchart ends up.
    private struct Placement {
        var size: CGSize
        var nodes: [Int: CGRect]
        /// A frame's own box — what gets drawn — without the strip above it
        /// that its title is written in.
        var frames: [Int: CGRect]
        /// Per edge, the line the layout ran for it, from the border of the
        /// block it leaves to the border of the block it reaches. An edge into
        /// a frame's contents stops at the frame here and is carried on to its
        /// box once every box has its place.
        var routes: [Int: [CGPoint]] = [:]
        /// Per edge, where its words go.
        var labels: [Int: CGRect] = [:]
        /// Boxes laid out in a container whose layers run across the page,
        /// whose loops therefore stand below them rather than beside them.
        var below: Set<Int> = []
        /// Per edge with one end inside this frame and the other outside it,
        /// the part of its line inside: from the point on the frame's border
        /// where it comes in or goes out to the box, in the edge's direction.
        var stubs: [Int: [CGPoint]] = [:]
    }

    /// A flowchart placed frame by frame.
    ///
    /// A frame is a graph in its own right: it is laid out on its own, in its
    /// own direction, and then stands in whatever holds it as a single block
    /// the size of everything it came to. That is what lets a frame hold a
    /// frame, and what lets `direction TB` inside one turn that frame's
    /// contents without turning the graph around it. An edge between two boxes
    /// in different frames is, at this level, an edge between the two blocks,
    /// so the frames themselves fall into ranks the same way boxes do.
    private static func placed(
        chart: Flowchart, sizes boxSizes: [CGSize], labels: [Int: CGSize], loops: [Int: CGSize],
        metrics: Metrics, titleRoom: CGFloat, inset: CGFloat, layerGap: CGFloat,
        lineGap: CGFloat, endRoom: CGFloat = 0, inTextOrder: Bool = false
    ) -> Placement {
        var owner = [Int?](repeating: nil, count: boxSizes.count)
        for (index, group) in chart.groups.enumerated() {
            for member in group.members where member < owner.count { owner[member] = index }
        }
        // Every box a frame holds, however deep — what an edge crossing frames
        // has to be resolved against.
        var reach = [Set<Int>](repeating: [], count: chart.groups.count)
        for index in boxSizes.indices {
            var walk = owner[index]
            while let group = walk {
                reach[group].insert(index)
                walk = chart.groups[group].parent
            }
        }

        func direction(of container: Int?) -> Flowchart.Direction {
            container.map { chart.groups[$0].direction ?? chart.direction } ?? chart.direction
        }
        func opposite(_ side: Flowchart.Direction) -> Flowchart.Direction {
            switch side {
            case .down: return .up
            case .up: return .down
            case .right: return .left
            case .left: return .right
            }
        }
        // The side of the picture a layout's first layer stands against,
        // named by the way one would leave the picture through it.
        func start(_ turn: Flowchart.Direction) -> Flowchart.Direction {
            switch turn {
            case .down: return .up
            case .up: return .down
            case .right: return .left
            case .left: return .right
            }
        }

        // Where an edge is laid out as one line — the innermost container in
        // which its two ends are different blocks — and whether it is turned
        // round there. Every frame it crosses on the way to a box is entered
        // from the side that layout reaches it from.
        func laidOut(_ edge: Flowchart.Edge) -> (level: Int?, turned: Bool) {
            func enclosing(_ end: Flowchart.End) -> [Int?] {
                var walk: Int?
                switch end {
                case .node(let node): walk = owner[node]
                case .frame(let group): walk = chart.groups[group].parent
                }
                var chain: [Int?] = []
                while let group = walk {
                    chain.insert(group, at: 0)
                    walk = chart.groups[group].parent
                }
                return [nil] + chain
            }
            func key(_ end: Flowchart.End) -> Int {
                switch end {
                case .node(let node): return node
                case .frame(let group): return reach[group].min() ?? Int.max
                }
            }
            let one = enclosing(edge.from)
            let other = enclosing(edge.to)
            var depth = 0
            while depth + 1 < min(one.count, other.count), one[depth + 1] == other[depth + 1] {
                depth += 1
            }
            func unit(_ chain: [Int?], _ end: Flowchart.End) -> Int {
                depth + 1 < chain.count ? key(.frame(chain[depth + 1]!)) : key(end)
            }
            return (one[depth], inTextOrder && unit(one, edge.from) > unit(other, edge.to))
        }

        func layout(container: Int?) -> Placement {
            let children = chart.groups.indices.filter { chart.groups[$0].parent == container }
            let loose = boxSizes.indices.filter { owner[$0] == container }
            enum Unit {
                case node(Int)
                case frame(Int)
                /// Where an edge crosses this frame's border.
                case port(Int)
            }
            // In the order the author wrote them: a frame stands where the
            // first box it holds was written, so text order breaks ties for
            // frames as it does for boxes.
            var units: [Unit] =
                (loose.map { (Unit.node($0), $0) }
                + children.map { (Unit.frame($0), reach[$0].min() ?? Int.max) })
                .sorted { $0.1 < $1.1 }.map(\.0)
            var inner: [Int: Placement] = [:]
            var sizes: [CGSize] = []
            for unit in units {
                switch unit {
                case .node(let index):
                    sizes.append(boxSizes[index])
                case .frame(let group):
                    let laid = layout(container: group)
                    inner[group] = laid
                    sizes.append(
                        CGSize(
                            width: laid.size.width + inset * 2,
                            height: laid.size.height + inset * 2 + titleRoom))
                case .port:
                    sizes.append(.zero)
                }
            }
            // Which block of this container each end of an edge belongs to, so
            // an edge between two boxes deep in different frames ranks the
            // frames, and an edge that names a frame ranks the frame itself.
            var unitOf: [Flowchart.End: Int] = [:]
            for (index, unit) in units.enumerated() {
                switch unit {
                case .port: continue
                case .node(let node): unitOf[.node(node)] = index
                case .frame(let group):
                    unitOf[.frame(group)] = index
                    for member in reach[group] { unitOf[.node(member)] = index }
                    for inner in chart.groups.indices where reaches(group, inner, in: chart) {
                        unitOf[.frame(inner)] = index
                    }
                }
            }
            // An edge is laid out in the innermost container where its two ends
            // are different blocks; deeper down they are the same block, and
            // further out the edge is inside one.
            var here: [Int] = []
            var links: [LayeredLayout.Edge] = []
            let turn = direction(of: container)
            let down = turn == .down || turn == .up
            // The pipeline lays everything out down the page; across the page
            // is the same layout with the two axes swapped on the way in and
            // swapped back on the way out.
            func across(_ size: CGSize) -> CGSize {
                down ? size : CGSize(width: size.height, height: size.width)
            }
            // Where on a frame's block the line of an edge has to arrive or
            // leave: the point its layout ran the line up to, measured across
            // this layout from the block's left.
            func port(_ unit: Int, _ edge: Int, entering: Bool) -> CGFloat? {
                guard case .frame(let group) = units[unit], let stub = inner[group]?.stubs[edge],
                    let point = entering ? stub.first : stub.last
                else { return nil }
                return down ? inset + point.x : titleRoom + inset + point.y
            }
            for (index, edge) in chart.edges.enumerated() {
                guard let from = unitOf[edge.from], let to = unitOf[edge.to], from != to
                else { continue }
                here.append(index)
                links.append(
                    LayeredLayout.Edge(
                        from: from, to: to, label: labels[index].map(across),
                        fromPort: port(from, index, entering: false),
                        toPort: port(to, index, entering: true)))
            }
            // An edge with one end inside this frame and the other outside it
            // comes in on the side the layout around the frame starts from and
            // goes out on the side it ends at. When that side is one this
            // frame's own layers stand against, the line is laid out in here
            // too, to a point held to that edge; across the layers there is no
            // such point, and the line is joined to its box once every box has
            // its place.
            var pinned: [Int: LayeredLayout.Pin] = [:]
            var crossing: [Int] = []
            var against = Set<Int>()
            if let container {
                func outside(_ end: Flowchart.End) -> Bool {
                    guard unitOf[end] == nil else { return false }
                    if case .frame(let group) = end {
                        return group != container && !reaches(group, container, in: chart)
                    }
                    return true
                }
                for (index, edge) in chart.edges.enumerated() {
                    let entering = outside(edge.from) && unitOf[edge.to] != nil
                    let leaving = unitOf[edge.from] != nil && outside(edge.to)
                    guard entering || leaving else { continue }
                    let whole = laidOut(edge)
                    let outer = start(direction(of: whole.level))
                    let side = entering != whole.turned ? outer : opposite(outer)
                    let first = start(turn)
                    let pin: LayeredLayout.Pin
                    if side == first {
                        pin = .first
                    } else if side == opposite(first) {
                        pin = .last
                    } else {
                        continue
                    }
                    let point = units.count
                    units.append(.port(index))
                    sizes.append(.zero)
                    pinned[point] = pin
                    crossing.append(index)
                    let inside = unitOf[entering ? edge.to : edge.from]!
                    let at = port(inside, index, entering: entering)
                    // A line coming in at the last layer runs against the
                    // layers, and is laid out the other way round.
                    if (pin == .first) == entering {
                        links.append(
                            entering
                                ? LayeredLayout.Edge(
                                    from: point, to: inside, label: nil, toPort: at)
                                : LayeredLayout.Edge(
                                    from: inside, to: point, label: nil, fromPort: at))
                    } else {
                        against.insert(index)
                        links.append(
                            entering
                                ? LayeredLayout.Edge(
                                    from: inside, to: point, label: nil, fromPort: at)
                                : LayeredLayout.Edge(
                                    from: point, to: inside, label: nil, toPort: at))
                    }
                }
            }
            // The pipeline keeps a loop's room on the right of a box; laid
            // across the page, that right is the box's underside.
            var loopRoom = [CGFloat](repeating: 0, count: units.count)
            for (index, unit) in units.enumerated() {
                if case .node(let node) = unit, let room = loops[node] {
                    loopRoom[index] = down ? room.width : room.height
                }
            }
            // A state machine reads from its start to its end, and the two read
            // best one under the other, the way the picture is entered and left.
            var stacked: [(anchor: Int, moved: Int)] = []
            // A class or entity diagram is laid out here with no nodes of its
            // own, only sizes.
            func shaped(_ shape: Flowchart.Shape) -> [Int] {
                units.indices.filter {
                    guard case .node(let node) = units[$0], node < chart.nodes.count else {
                        return false
                    }
                    return chart.nodes[node].shape == shape
                }
            }
            let starts = shaped(.point)
            let ends = shaped(.endPoint)
            if starts.count == 1, ends.count == 1 { stacked.append((starts[0], ends[0])) }
            let laid = LayeredLayout.layout(
                sizes: sizes.map(across), edges: links, loopRoom: loopRoom, pinned: pinned,
                inTextOrder: inTextOrder, stacked: stacked,
                spacing: LayeredLayout.Spacing(
                    node: metrics.siblingGap, layer: layerGap, edge: lineGap, end: endRoom))
            let along = laid.size.height
            // `BT` and `RL` are the same graph read from the other end, so the
            // layer axis is turned over once every block is placed.
            let flipped = turn == .up || turn == .left
            func back(_ point: CGPoint) -> CGPoint {
                let y = flipped ? along - point.y : point.y
                return down ? CGPoint(x: point.x, y: y) : CGPoint(x: y, y: point.x)
            }
            func back(_ rect: CGRect) -> CGRect {
                let one = back(rect.origin)
                let other = back(CGPoint(x: rect.maxX, y: rect.maxY))
                return CGRect(
                    x: min(one.x, other.x), y: min(one.y, other.y), width: abs(one.x - other.x),
                    height: abs(one.y - other.y))
            }
            let origins = laid.frames.map { back($0).origin }
            var placement = Placement(
                size: down ? laid.size : CGSize(width: laid.size.height, height: laid.size.width),
                nodes: [:], frames: [:])
            // A frame's own part of a line, moved to where the frame stands
            // here, and joined on when the line here reached the very point
            // it starts from; otherwise the line is left at the border.
            func stub(_ unit: Int, _ edge: Int) -> [CGPoint]? {
                guard case .frame(let group) = units[unit], let part = inner[group]?.stubs[edge]
                else { return nil }
                let shift = CGPoint(
                    x: origins[unit].x + inset, y: origins[unit].y + titleRoom + inset)
                return part.map { CGPoint(x: $0.x + shift.x, y: $0.y + shift.y) }
            }
            func joined(_ route: [CGPoint], from: Int, to: Int, edge: Int) -> [CGPoint] {
                var route = route
                func meets(_ a: CGPoint, _ b: CGPoint) -> Bool {
                    let gap =
                        down ? (abs(a.x - b.x), abs(a.y - b.y)) : (abs(a.y - b.y), abs(a.x - b.x))
                    return gap.0 < 0.5 && gap.1 <= inset + 0.5
                }
                if let part = stub(to, edge), let last = route.last, let first = part.first,
                    meets(last, first)
                {
                    route += part
                }
                if let part = stub(from, edge), let first = route.first, let last = part.last,
                    meets(first, last)
                {
                    route = part + route
                }
                return LayeredLayout.simplified(route)
            }
            for (position, index) in here.enumerated() {
                if !laid.routes[position].isEmpty {
                    placement.routes[index] = joined(
                        laid.routes[position].map(back), from: links[position].from,
                        to: links[position].to, edge: index)
                }
                if let label = laid.labels[position] { placement.labels[index] = back(label) }
            }
            for (offset, index) in crossing.enumerated() {
                let position = here.count + offset
                guard !laid.routes[position].isEmpty else { continue }
                let link = links[position]
                let turned = against.contains(index)
                let route = laid.routes[position].map(back)
                placement.stubs[index] = joined(
                    turned ? route.reversed() : route, from: turned ? link.to : link.from,
                    to: turned ? link.from : link.to, edge: index)
            }
            for (index, unit) in units.enumerated() {
                switch unit {
                case .node(let node):
                    if !down { placement.below.insert(node) }
                    placement.nodes[node] = CGRect(
                        origin: origins[index], size: boxSizes[node])
                case .frame(let group):
                    guard let laid = inner[group] else { continue }
                    let box = CGRect(
                        x: origins[index].x, y: origins[index].y + titleRoom,
                        width: sizes[index].width, height: sizes[index].height - titleRoom)
                    placement.frames[group] = box
                    let shift = CGPoint(x: box.minX + inset, y: box.minY + inset)
                    for (node, rect) in laid.nodes {
                        placement.nodes[node] = rect.offsetBy(dx: shift.x, dy: shift.y)
                    }
                    for (frame, rect) in laid.frames {
                        placement.frames[frame] = rect.offsetBy(dx: shift.x, dy: shift.y)
                    }
                    for (edge, route) in laid.routes {
                        placement.routes[edge] = route.map {
                            CGPoint(x: $0.x + shift.x, y: $0.y + shift.y)
                        }
                    }
                    for (edge, label) in laid.labels {
                        placement.labels[edge] = label.offsetBy(dx: shift.x, dy: shift.y)
                    }
                    placement.below.formUnion(laid.below)
                case .port:
                    continue
                }
            }
            return placement
        }

        var placement = layout(container: nil)
        // The whole picture sits inside the block's own margin. A frame's name
        // needs no room reserved here: the strip it is written in is already
        // part of the block the frame stands in.
        let margin = metrics.padding
        placement.nodes = placement.nodes.mapValues { $0.offsetBy(dx: margin, dy: margin) }
        placement.frames = placement.frames.mapValues { $0.offsetBy(dx: margin, dy: margin) }
        placement.routes = placement.routes.mapValues {
            $0.map { CGPoint(x: $0.x + margin, y: $0.y + margin) }
        }
        placement.labels = placement.labels.mapValues { $0.offsetBy(dx: margin, dy: margin) }
        placement.size = CGSize(
            width: placement.size.width + margin * 2,
            height: placement.size.height + margin * 2)
        return placement
    }

    private static func ranks(count: Int, edges: [(from: Int, to: Int)]) -> [[Int]] {
        var rank = [Int](repeating: 0, count: count)
        let forward = withoutBackEdges(count: count, edges: edges)
        for _ in 0..<count {
            var moved = false
            for edge in forward where edge.from < rank.count && edge.to < rank.count {
                if rank[edge.to] < rank[edge.from] + 1 {
                    rank[edge.to] = rank[edge.from] + 1
                    moved = true
                }
            }
            if !moved { break }
        }
        var grouped: [[Int]] = []
        for (index, level) in rank.enumerated() {
            while grouped.count <= level { grouped.append([]) }
            grouped[level].append(index)
        }
        return grouped.filter { !$0.isEmpty }
    }

    /// The graph with the edges that close a cycle left out.
    ///
    /// Relaxing over a cycle terminates, but the answer it settles on is the
    /// order the edges happened to be written in: a state machine with
    /// `Still --> Moving` and `Moving --> Still` came out with `Moving` above
    /// the state that reaches it, and the arrow from the start ran through it.
    /// A walk from the entry points settles that instead — an edge back to a
    /// node the walk is still inside is the one that closes the cycle, and it is
    /// still drawn, just not counted when the ranks are worked out.
    private static func withoutBackEdges(count: Int, edges: [(from: Int, to: Int)])
        -> [(from: Int, to: Int)]
    {
        var out = [[Int]](repeating: [], count: count)
        for (index, edge) in edges.enumerated()
        where edge.from < count && edge.to < count {
            out[edge.from].append(index)
        }
        var incoming = [Int](repeating: 0, count: count)
        for edge in edges where edge.from < count && edge.to < count { incoming[edge.to] += 1 }
        // 0 not walked, 1 on the walk, 2 done.
        var state = [Int](repeating: 0, count: count)
        var back = Set<Int>()
        // Entry points first, so the walk starts where the graph does.
        let order = (0..<count).filter { incoming[$0] == 0 } + (0..<count)
        for root in order where state[root] == 0 {
            var stack: [(node: Int, next: Int)] = [(root, 0)]
            state[root] = 1
            while let top = stack.last {
                if top.next == out[top.node].count {
                    state[top.node] = 2
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].next += 1
                let index = out[top.node][top.next]
                let target = edges[index].to
                switch state[target] {
                case 0:
                    state[target] = 1
                    stack.append((target, 0))
                case 1:
                    back.insert(index)
                default:
                    break
                }
            }
        }
        return edges.enumerated().filter { !back.contains($0.offset) }.map(\.element)
    }

    /// The titled frame a `subgraph` draws around its own nodes.
    private static func frame(
        _ group: Flowchart.Group, rect bounds: CGRect, theme: Theme, metrics: Metrics,
        titleRoom: CGFloat, nameAt: CGFloat? = nil
    ) -> [BlockBox.Decoration] {
        let path = CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        var decorations: [BlockBox.Decoration] = [
            .path(
                path,
                color: faded(
                    authorFill(
                        group.style, or: theme.palette.codeBackground,
                        ink: theme.palette.secondaryText, theme: theme), by: group.style),
                lineWidth: 0, filled: true),
            .path(
                path,
                color: faded(
                    group.style.stroke.map(cgColor) ?? theme.palette.tableBorder, by: group.style),
                lineWidth: group.style.strokeWidth ?? 1, filled: false),
        ]
        guard !group.title.isEmpty else { return decorations }
        let (lines, size) = labelLines(
            group.title,
            font: scaled(theme.controlLabel, by: metrics.scale),
            color: faded(
                group.style.text.map(cgColor) ?? theme.palette.secondaryText, by: group.style)
        )
        var top = bounds.minY - max(3, titleRoom - size.height) - size.height
        for line in lines {
            let one = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: nameAt ?? bounds.minX + 4, y: top + one.height - descent(line))))
            top += one.height
        }
        return decorations
    }

    private static func node(_ box: Placed, theme: Theme, metrics: Metrics)
        -> [BlockBox.Decoration]
    {
        let path = shape(box)
        // A state machine's ends are marks, not boxes: a filled dot where it
        // starts and a ring where it stops.
        if box.shape == .point || box.shape == .endPoint {
            var decorations: [BlockBox.Decoration] = [
                .path(
                    CGPath(ellipseIn: box.frame, transform: nil), color: theme.palette.text,
                    lineWidth: 0, filled: true)
            ]
            if box.shape == .endPoint {
                decorations.append(
                    .path(
                        CGPath(
                            ellipseIn: box.frame.insetBy(
                                dx: 3 * metrics.scale, dy: 3 * metrics.scale), transform: nil),
                        color: theme.palette.background, lineWidth: 0, filled: true))
                decorations.append(
                    .path(
                        CGPath(
                            ellipseIn: box.frame.insetBy(
                                dx: 5 * metrics.scale, dy: 5 * metrics.scale), transform: nil),
                        color: theme.palette.text, lineWidth: 0, filled: true))
            }
            return decorations
        }
        // A collate mark, a com link and a junction are read as the symbol they
        // are; a name written on one belongs to the diagram, not inside it.
        if box.shape == .hourglass || box.shape == .bolt || box.shape == .junction {
            let outline = faded(
                box.style.stroke.map(cgColor) ?? theme.palette.tableBorder, by: box.style)
            var marks: [BlockBox.Decoration] = [
                .path(
                    path,
                    color: faded(
                        box.style.fill.map(cgColor) ?? theme.palette.background,
                        by: box.style), lineWidth: 0, filled: box.shape != .junction)
            ]
            if box.shape == .junction {
                marks = [.path(path, color: outline, lineWidth: 0, filled: true)]
            } else {
                marks.append(
                    .path(
                        path, color: outline,
                        lineWidth: (box.style.strokeWidth.map { CGFloat($0) } ?? 1) * metrics.scale,
                        filled: false))
            }
            return marks
        }
        // A fork is read as a bar and nothing else, so it is drawn solid.
        if box.shape == .bar {
            return [
                .path(
                    path,
                    color: faded(box.style.fill.map(cgColor) ?? theme.palette.text, by: box.style),
                    lineWidth: 0, filled: true)
            ]
        }
        var decorations: [BlockBox.Decoration] = []
        let outline = faded(
            box.style.stroke.map(cgColor) ?? theme.palette.tableBorder, by: box.style)
        let pen = (box.style.strokeWidth.map { CGFloat($0) } ?? 1) * metrics.scale
        let filling = faded(
            authorFill(
                box.style, or: theme.palette.tableHeaderBackground, ink: theme.palette.text,
                theme: theme), by: box.style)
        let solid = !(box.style.fill?.isTransparent ?? false)
        // The copies stacked behind a multi-process stand under the front one,
        // so they are filled and outlined before it is.
        if box.shape == .stackedProcess || box.shape == .stackedDocument {
            for behind in inner(box) {
                if solid {
                    decorations.append(.path(behind, color: filling, lineWidth: 0, filled: true))
                }
                decorations.append(
                    .path(behind, color: outline, lineWidth: pen, filled: false))
            }
        }
        // A `fill:transparent` is the author asking for the page to show
        // through, which is not the same as filling it with the page's colour.
        if solid {
            decorations.append(.path(path, color: filling, lineWidth: 0, filled: true))
        }
        decorations.append(.path(path, color: outline, lineWidth: pen, filled: false))
        if box.shape != .stackedProcess, box.shape != .stackedDocument {
            for mark in inner(box) {
                decorations.append(.path(mark, color: outline, lineWidth: pen, filled: false))
            }
        }
        // The stack is centred on the box, and each line is centred in the
        // stack, so a two-line label sits the way a one-line label does. A
        // triangle is only wide enough for words at one end, so its words are
        // moved down to the base — or up to it, when it stands on its point.
        var y = box.frame.midY - box.labelSize.height / 2
        switch box.shape {
        case .triangle: y += box.frame.height * 0.2
        case .flippedTriangle: y -= box.frame.height * 0.2
        case .stackedProcess, .stackedDocument: y += 4
        default: break
        }
        for line in box.lines {
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: box.frame.midX - size.width / 2, y: y + size.height - descent(line))))
            y += size.height
        }
        if box.shape == .subroutine {
            let inset = 6 * metrics.scale
            let bars = CGMutablePath()
            for x in [box.frame.minX + inset, box.frame.maxX - inset] {
                bars.move(to: CGPoint(x: x, y: box.frame.minY))
                bars.addLine(to: CGPoint(x: x, y: box.frame.maxY))
            }
            decorations.append(
                .path(bars, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
        }
        if box.shape == .doubleCircle {
            let inner = box.frame.insetBy(dx: 4 * metrics.scale, dy: 4 * metrics.scale)
            decorations.append(
                .path(
                    CGPath(ellipseIn: inner, transform: nil),
                    color: theme.palette.tableBorder, lineWidth: 1, filled: false))
        }
        return decorations
    }

    /// A closed ring of arcs or spikes around the ellipse inside `frame`: a
    /// cloud when the bumps are rounded, a starburst when they are points.
    private static func bumpy(
        _ frame: CGRect, bumps: Int, out: CGFloat, filled rounded: Bool
    ) -> CGPath {
        let path = CGMutablePath()
        let radiusX = frame.width / 2 / (1 + out)
        let radiusY = frame.height / 2 / (1 + out)
        func point(_ step: CGFloat, _ reach: CGFloat) -> CGPoint {
            let angle = step / CGFloat(bumps) * 2 * .pi
            return CGPoint(
                x: frame.midX + cos(angle) * radiusX * reach,
                y: frame.midY + sin(angle) * radiusY * reach)
        }
        path.move(to: point(0, 1))
        for step in 0..<bumps {
            let next = CGFloat(step + 1)
            if rounded {
                let bulge = point(CGFloat(step) + 0.5, 1 + out * 2.4)
                path.addQuadCurve(to: point(next, 1), control: bulge)
            } else {
                path.addLine(to: point(CGFloat(step) + 0.5, 1 + out * 2))
                path.addLine(to: point(next, 1))
            }
        }
        path.closeSubpath()
        return path
    }

    private static func cgColor(_ colour: Flowchart.Colour) -> CGColor {
        CGColor(
            red: max(0, colour.red), green: max(0, colour.green), blue: max(0, colour.blue),
            alpha: colour.alpha)
    }

    /// A style's `opacity` lets the page through everything that style paints,
    /// the colours the theme supplied included, so it is applied last of all.
    /// A fill an author wrote, kept readable under the lettering that goes on
    /// it.
    ///
    /// Mermaid hands `style` and `classDef` straight to the renderer, so
    /// `fill:#111` arrives with the theme's dark ink still on top of it and the
    /// label disappears. Every fill an author chose passes through here; a
    /// colour the theme itself picked does not, because the palette was chosen
    /// against this bar already.
    private static func authorFill(
        _ style: Flowchart.Style, or fallback: CGColor, ink: CGColor, theme: Theme
    ) -> CGColor {
        guard let written = style.fill.map(cgColor) else { return fallback }
        return wash(
            written, on: theme.palette.codeBackground, under: style.text.map(cgColor) ?? ink)
    }

    private static func faded(_ color: CGColor, by style: Flowchart.Style) -> CGColor {
        guard let share = style.opacity else { return color }
        return color.copy(alpha: color.alpha * share) ?? color
    }

    private static func shape(_ box: Placed) -> CGPath {
        let frame = box.frame
        func polygon(_ points: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
            return path
        }
        // How far a slanted side leans in, kept in proportion to the height so
        // the lean looks the same at every scale.
        let lean = frame.height * 0.28
        switch box.shape {
        case .rectangle:
            return CGPath(roundedRect: frame, cornerWidth: 3, cornerHeight: 3, transform: nil)
        case .rounded:
            return CGPath(roundedRect: frame, cornerWidth: 9, cornerHeight: 9, transform: nil)
        case .stadium:
            let radius = frame.height / 2
            return CGPath(
                roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .circle, .doubleCircle, .point, .endPoint:
            return CGPath(ellipseIn: frame, transform: nil)
        case .diamond:
            return polygon([
                CGPoint(x: frame.midX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.midY),
                CGPoint(x: frame.midX, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.midY),
            ])
        case .hexagon:
            return polygon([
                CGPoint(x: frame.minX + lean, y: frame.minY),
                CGPoint(x: frame.maxX - lean, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.midY),
                CGPoint(x: frame.maxX - lean, y: frame.maxY),
                CGPoint(x: frame.minX + lean, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.midY),
            ])
        case .parallelogram:
            return polygon([
                CGPoint(x: frame.minX + lean, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.minY),
                CGPoint(x: frame.maxX - lean, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.maxY),
            ])
        case .parallelogramAlt:
            return polygon([
                CGPoint(x: frame.minX, y: frame.minY),
                CGPoint(x: frame.maxX - lean, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.maxY),
                CGPoint(x: frame.minX + lean, y: frame.maxY),
            ])
        case .trapezoid:
            return polygon([
                CGPoint(x: frame.minX + lean, y: frame.minY),
                CGPoint(x: frame.maxX - lean, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.maxY),
            ])
        case .trapezoidAlt:
            return polygon([
                CGPoint(x: frame.minX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.minY),
                CGPoint(x: frame.maxX - lean, y: frame.maxY),
                CGPoint(x: frame.minX + lean, y: frame.maxY),
            ])
        case .flag:
            return polygon([
                CGPoint(x: frame.minX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.maxY),
                CGPoint(x: frame.minX + lean, y: frame.midY),
            ])
        case .cloud:
            // Eleven bumps around the ellipse the words sit in.
            return bumpy(frame, bumps: 11, out: 0.16, filled: true)
        case .bang:
            // The same ring of points, alternating in and out: a starburst.
            return bumpy(frame, bumps: 14, out: 0.2, filled: false)
        case .bar:
            return CGPath(
                roundedRect: frame, cornerWidth: frame.height / 2,
                cornerHeight: frame.height / 2, transform: nil)
        case .note:
            // A slip of paper with its top-right corner turned back.
            let fold = min(12 * frame.height / max(frame.height, 1), frame.width / 4)
            return polygon([
                CGPoint(x: frame.minX, y: frame.minY),
                CGPoint(x: frame.maxX - fold, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.minY + fold),
                CGPoint(x: frame.maxX, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.maxY),
            ])
        case .blockArrow(let up, let down, let left, let right):
            // A fat arrow: a bar across the middle with a point on every side it
            // names. The point's base is as wide as the room left over once the
            // other axis has taken its own points, so a cross of four arrows
            // never runs outside itself.
            let headX = left || right ? min(frame.width * 0.35, frame.height / 2) : 0
            let headY = up || down ? min(frame.height * 0.35, frame.width / 2) : 0
            let insideLeft = frame.minX + (left ? headX : 0)
            let insideRight = frame.maxX - (right ? headX : 0)
            let insideTop = frame.minY + (up ? headY : 0)
            let insideBottom = frame.maxY - (down ? headY : 0)
            let baseX = (insideRight - insideLeft) / 2
            let baseY = (insideBottom - insideTop) / 2
            let barX = (insideRight - insideLeft) * 0.25
            let barY = (insideBottom - insideTop) * 0.35
            let middleX = frame.midX
            let middleY = frame.midY
            var points: [CGPoint] = [CGPoint(x: insideLeft, y: middleY - barY)]
            if up {
                points += [
                    CGPoint(x: middleX - barX, y: middleY - barY),
                    CGPoint(x: middleX - barX, y: insideTop),
                    CGPoint(x: middleX - baseX, y: insideTop),
                    CGPoint(x: middleX, y: frame.minY),
                    CGPoint(x: middleX + baseX, y: insideTop),
                    CGPoint(x: middleX + barX, y: insideTop),
                    CGPoint(x: middleX + barX, y: middleY - barY),
                ]
            }
            points.append(CGPoint(x: insideRight, y: middleY - barY))
            if right {
                points += [
                    CGPoint(x: insideRight, y: middleY - baseY),
                    CGPoint(x: frame.maxX, y: middleY),
                    CGPoint(x: insideRight, y: middleY + baseY),
                ]
            }
            points.append(CGPoint(x: insideRight, y: middleY + barY))
            if down {
                points += [
                    CGPoint(x: middleX + barX, y: middleY + barY),
                    CGPoint(x: middleX + barX, y: insideBottom),
                    CGPoint(x: middleX + baseX, y: insideBottom),
                    CGPoint(x: middleX, y: frame.maxY),
                    CGPoint(x: middleX - baseX, y: insideBottom),
                    CGPoint(x: middleX - barX, y: insideBottom),
                    CGPoint(x: middleX - barX, y: middleY + barY),
                ]
            }
            points.append(CGPoint(x: insideLeft, y: middleY + barY))
            if left {
                points += [
                    CGPoint(x: insideLeft, y: middleY + baseY),
                    CGPoint(x: frame.minX, y: middleY),
                    CGPoint(x: insideLeft, y: middleY - baseY),
                ]
            }
            return polygon(points)
        case .cylinder:
            // A drum seen from the side: an ellipse for the lid, straight sides,
            // and the same curve again at the foot.
            return drum(frame)
        case .card:
            // A card is a rectangle with its top-left corner cut away.
            let cut = min(frame.height * 0.3, 16)
            return polygon([
                CGPoint(x: frame.minX + cut, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.minY + cut),
            ])
        case .loopLimit:
            // A pentagon with both top corners cut.
            let cut = min(frame.height * 0.3, 16)
            return polygon([
                CGPoint(x: frame.minX + cut, y: frame.minY),
                CGPoint(x: frame.maxX - cut, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.minY + cut),
                CGPoint(x: frame.maxX, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.minY + cut),
            ])
        case .linedProcess, .dividedProcess, .taggedProcess, .windowPane, .subroutine:
            // The rules these carry are drawn over the box, not cut out of it.
            return CGPath(roundedRect: frame, cornerWidth: 3, cornerHeight: 3, transform: nil)
        case .stackedProcess:
            // The front of the stack; the two behind it are drawn separately.
            let step = 6 * frame.height / max(frame.height, 1)
            return CGPath(
                roundedRect: CGRect(
                    x: frame.minX, y: frame.minY + step * 2, width: frame.width - step * 2,
                    height: frame.height - step * 2), cornerWidth: 3, cornerHeight: 3,
                transform: nil)
        case .document, .linedDocument, .taggedDocument:
            return sheet(frame)
        case .stackedDocument:
            let step = 6 * frame.height / max(frame.height, 1)
            return sheet(
                CGRect(
                    x: frame.minX, y: frame.minY + step * 2, width: frame.width - step * 2,
                    height: frame.height - step * 2))
        case .paperTape:
            // A wave along the top and another along the foot.
            let wave = min(frame.height * 0.16, 12)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.minX, y: frame.minY + wave))
            path.addCurve(
                to: CGPoint(x: frame.maxX, y: frame.minY + wave),
                control1: CGPoint(x: frame.minX + frame.width / 3, y: frame.minY - wave),
                control2: CGPoint(x: frame.maxX - frame.width / 3, y: frame.minY + wave * 3))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - wave))
            path.addCurve(
                to: CGPoint(x: frame.minX, y: frame.maxY - wave),
                control1: CGPoint(x: frame.maxX - frame.width / 3, y: frame.maxY + wave),
                control2: CGPoint(x: frame.minX + frame.width / 3, y: frame.maxY - wave * 3))
            path.closeSubpath()
            return path
        case .storedData:
            // Both sides bow the same way, so the shape leans as it stands.
            let bow = min(frame.width * 0.1, 16)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.minX + bow, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX - bow, y: frame.minY))
            path.addQuadCurve(
                to: CGPoint(x: frame.maxX - bow, y: frame.maxY),
                control: CGPoint(x: frame.maxX + bow * 2.4, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.minX + bow, y: frame.maxY))
            path.addQuadCurve(
                to: CGPoint(x: frame.minX + bow, y: frame.minY),
                control: CGPoint(x: frame.minX + bow * 3.4, y: frame.midY))
            path.closeSubpath()
            return path
        case .manualInput:
            // The top edge slopes up towards the right.
            let slope = min(frame.height * 0.28, 16)
            return polygon([
                CGPoint(x: frame.minX, y: frame.minY + slope),
                CGPoint(x: frame.maxX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.maxY),
            ])
        case .delay:
            // Square at the left, rounded right off at the right.
            let radius = frame.height / 2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.minX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX - radius, y: frame.minY))
            path.addArc(
                center: CGPoint(x: frame.maxX - radius, y: frame.midY), radius: radius,
                startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            path.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
            path.closeSubpath()
            return path
        case .horizontalCylinder, .linedCylinder, .dataStore:
            if box.shape == .linedCylinder {
                // A drum standing up, like a database; the second line under its
                // lid is drawn over it.
                return drum(frame)
            }
            // A drum lying on its side: a curve at each end.
            // Each end cap bulges out by exactly the lid, so the ends read as
            // halves of an ellipse rather than as clipped corners.
            let lid = min(frame.width * 0.12, 16)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.minX + lid, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX - lid, y: frame.minY))
            path.addCurve(
                to: CGPoint(x: frame.maxX - lid, y: frame.maxY),
                control1: CGPoint(x: frame.maxX + lid * 0.34, y: frame.minY),
                control2: CGPoint(x: frame.maxX + lid * 0.34, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX + lid, y: frame.maxY))
            path.addCurve(
                to: CGPoint(x: frame.minX + lid, y: frame.minY),
                control1: CGPoint(x: frame.minX - lid * 0.34, y: frame.maxY),
                control2: CGPoint(x: frame.minX - lid * 0.34, y: frame.minY))
            path.closeSubpath()
            return path
        case .display:
            // Flat down the left, bulging out at the right.
            let bulge = min(frame.width * 0.16, 22)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.minX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX - bulge, y: frame.minY))
            path.addQuadCurve(
                to: CGPoint(x: frame.maxX - bulge, y: frame.maxY),
                control: CGPoint(x: frame.maxX + bulge * 1.8, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
            path.closeSubpath()
            return path
        case .triangle:
            return polygon([
                CGPoint(x: frame.midX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.maxY),
                CGPoint(x: frame.minX, y: frame.maxY),
            ])
        case .flippedTriangle:
            return polygon([
                CGPoint(x: frame.minX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.minY),
                CGPoint(x: frame.midX, y: frame.maxY),
            ])
        case .hourglass:
            return polygon([
                CGPoint(x: frame.minX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.minY),
                CGPoint(x: frame.minX, y: frame.maxY),
                CGPoint(x: frame.maxX, y: frame.maxY),
            ])
        case .bolt:
            // A lightning bolt: down the left, back across, and down to a point.
            let across = frame.width
            let down = frame.height
            return polygon([
                CGPoint(x: frame.minX + across * 0.55, y: frame.minY),
                CGPoint(x: frame.minX + across * 0.1, y: frame.minY + down * 0.55),
                CGPoint(x: frame.minX + across * 0.45, y: frame.minY + down * 0.55),
                CGPoint(x: frame.minX + across * 0.3, y: frame.maxY),
                CGPoint(x: frame.maxX, y: frame.minY + down * 0.4),
                CGPoint(x: frame.minX + across * 0.6, y: frame.minY + down * 0.4),
                CGPoint(x: frame.maxX - across * 0.1, y: frame.minY),
            ])
        case .braceLeft, .braceRight, .braces:
            // The braces themselves are strokes drawn beside the words, so the
            // box behind them holds nothing.
            return CGMutablePath()
        case .junction:
            return CGPath(ellipseIn: frame, transform: nil)
        case .summary:
            return CGPath(ellipseIn: frame, transform: nil)
        case .text:
            return CGMutablePath()
        case .pictureBox:
            return CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil)
        }
    }

    /// The marks that stand a shape apart from a plain box: the rule down a
    /// lined process, the copies behind a stacked one, the tag at a corner, the
    /// cross through a summary, the braces beside a comment.
    ///
    /// They are drawn over the box rather than cut out of it, so the fill and
    /// the outline stay one path and one colour each.
    private static func inner(_ box: Placed) -> [CGPath] {
        let frame = box.frame
        func line(_ from: CGPoint, _ to: CGPoint) -> CGPath {
            let path = CGMutablePath()
            path.move(to: from)
            path.addLine(to: to)
            return path
        }
        let step = min(frame.height * 0.16, 12)
        // A sheet of paper waves along its foot, so a mark that would meet the
        // bottom edge stops where the wave starts instead of hanging past it.
        let foot: CGFloat =
            box.shape == .linedDocument || box.shape == .taggedDocument
            ? min(frame.height * 0.16, 12) : 0
        switch box.shape {
        case .subroutine:
            // A call to something described elsewhere: a wall at each end.
            return [
                line(
                    CGPoint(x: frame.minX + step, y: frame.minY),
                    CGPoint(x: frame.minX + step, y: frame.maxY)),
                line(
                    CGPoint(x: frame.maxX - step, y: frame.minY),
                    CGPoint(x: frame.maxX - step, y: frame.maxY)),
            ]
        case .linedProcess, .linedDocument:
            return [
                line(
                    CGPoint(x: frame.minX + step, y: frame.minY),
                    CGPoint(x: frame.minX + step, y: frame.maxY - foot))
            ]
        case .dividedProcess:
            return [
                line(
                    CGPoint(x: frame.minX, y: frame.minY + step),
                    CGPoint(x: frame.maxX, y: frame.minY + step))
            ]
        case .windowPane:
            return [
                line(
                    CGPoint(x: frame.minX + step, y: frame.minY),
                    CGPoint(x: frame.minX + step, y: frame.maxY)),
                line(
                    CGPoint(x: frame.minX, y: frame.minY + step),
                    CGPoint(x: frame.maxX, y: frame.minY + step)),
            ]
        case .linedCylinder:
            // A second line under the lid, so the drum reads as a disk.
            let lid = min(frame.height * 0.18, 10)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.minX, y: frame.minY + lid * 2.2))
            path.addCurve(
                to: CGPoint(x: frame.maxX, y: frame.minY + lid * 2.2),
                control1: CGPoint(x: frame.minX, y: frame.minY + lid * 0.2),
                control2: CGPoint(x: frame.maxX, y: frame.minY + lid * 0.2))
            return [path]
        case .dataStore:
            // Open at the left: the near curve is drawn inside the drum.
            let lid = min(frame.width * 0.12, 16)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.minX + lid, y: frame.minY))
            path.addCurve(
                to: CGPoint(x: frame.minX + lid, y: frame.maxY),
                control1: CGPoint(x: frame.minX + lid * 2.34, y: frame.minY),
                control2: CGPoint(x: frame.minX + lid * 2.34, y: frame.maxY))
            return [path]
        case .stackedProcess, .stackedDocument:
            // Two copies behind, each offset up and to the right.
            let offset = 6 * min(frame.height / max(frame.height, 1), 1)
            let body = CGRect(
                x: frame.minX, y: frame.minY + offset * 2, width: frame.width - offset * 2,
                height: frame.height - offset * 2)
            return (1...2).map { number in
                let shifted = body.offsetBy(
                    dx: offset * CGFloat(number), dy: -offset * CGFloat(number))
                return box.shape == .stackedDocument
                    ? sheet(shifted)
                    : CGPath(roundedRect: shifted, cornerWidth: 3, cornerHeight: 3, transform: nil)
            }.reversed()
        case .taggedProcess, .taggedDocument:
            // A tag folded over the bottom-left corner.
            let tag = min(frame.width * 0.18, 20)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.minX, y: frame.maxY - foot - tag))
            path.addLine(to: CGPoint(x: frame.minX + tag, y: frame.maxY - foot))
            return [path]
        case .summary:
            // A cross through the circle, corner to corner of its square.
            let reach = frame.width / 2 * 0.7071
            return [
                line(
                    CGPoint(x: frame.midX - reach, y: frame.midY - reach),
                    CGPoint(x: frame.midX + reach, y: frame.midY + reach)),
                line(
                    CGPoint(x: frame.midX + reach, y: frame.midY - reach),
                    CGPoint(x: frame.midX - reach, y: frame.midY + reach)),
            ]
        case .braceLeft, .braceRight, .braces:
            var paths: [CGPath] = []
            if box.shape != .braceRight { paths.append(brace(frame, facing: 1)) }
            if box.shape != .braceLeft { paths.append(brace(frame, facing: -1)) }
            return paths
        case .pictureBox:
            // A framed square where the picture would have gone, with a
            // question mark where its subject would have been.
            let side = min(34, frame.width - 12)
            let tile = CGRect(
                x: frame.midX - side / 2, y: frame.minY + 8, width: side, height: side)
            let path = CGMutablePath()
            path.addRoundedRect(in: tile, cornerWidth: 4, cornerHeight: 4)
            let radius = side * 0.18
            let top = CGPoint(x: tile.midX, y: tile.midY - radius * 0.6)
            path.addArc(
                center: top, radius: radius, startAngle: .pi, endAngle: 0.6, clockwise: false)
            path.addLine(to: CGPoint(x: tile.midX, y: tile.midY + radius * 0.7))
            path.move(to: CGPoint(x: tile.midX, y: tile.maxY - side * 0.16))
            path.addLine(to: CGPoint(x: tile.midX, y: tile.maxY - side * 0.14))
            return [path]
        default:
            return []
        }
    }

    /// One curly brace, `facing: 1` opening to the right and `-1` to the left.
    private static func brace(_ frame: CGRect, facing: CGFloat) -> CGPath {
        let x = facing > 0 ? frame.minX : frame.maxX
        let reach = 9 * facing
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x + reach, y: frame.minY))
        path.addQuadCurve(
            to: CGPoint(x: x + reach / 2, y: frame.minY + frame.height / 4),
            control: CGPoint(x: x + reach / 3, y: frame.minY))
        path.addLine(to: CGPoint(x: x + reach / 2, y: frame.midY - 4))
        path.addLine(to: CGPoint(x: x, y: frame.midY))
        path.addLine(to: CGPoint(x: x + reach / 2, y: frame.midY + 4))
        path.addLine(to: CGPoint(x: x + reach / 2, y: frame.maxY - frame.height / 4))
        path.addQuadCurve(
            to: CGPoint(x: x + reach, y: frame.maxY),
            control: CGPoint(x: x + reach / 3, y: frame.maxY))
        return path
    }

    /// What is drawn where a link meets what it joins: a filled head, a ring or
    /// a cross. The mark stands at `point`, facing the way the line runs.
    private static func linkEnd(
        _ mark: Flowchart.Head, at point: CGPoint, from base: CGPoint, along direction: CGPoint,
        color: CGColor, width: CGFloat, metrics: Metrics
    ) -> [BlockBox.Decoration] {
        let side = CGPoint(x: -direction.y, y: direction.x)
        switch mark {
        case .none:
            return []
        case .arrow:
            let path = CGMutablePath()
            path.move(to: point)
            path.addLine(
                to: CGPoint(
                    x: base.x + side.x * metrics.arrowWidth / 2,
                    y: base.y + side.y * metrics.arrowWidth / 2))
            path.addLine(
                to: CGPoint(
                    x: base.x - side.x * metrics.arrowWidth / 2,
                    y: base.y - side.y * metrics.arrowWidth / 2))
            path.closeSubpath()
            return [.path(path, color: color, lineWidth: 0, filled: true)]
        case .circle:
            let radius = metrics.arrowWidth / 2
            let centre = CGPoint(
                x: point.x - direction.x * radius, y: point.y - direction.y * radius)
            let path = CGPath(
                ellipseIn: CGRect(
                    x: centre.x - radius, y: centre.y - radius, width: radius * 2,
                    height: radius * 2), transform: nil)
            return [.path(path, color: color, lineWidth: width, filled: false)]
        case .cross:
            let reach = metrics.arrowWidth / 2
            let centre = CGPoint(
                x: point.x - direction.x * reach, y: point.y - direction.y * reach)
            let path = CGMutablePath()
            for arm in [
                (CGPoint(x: direction.x + side.x, y: direction.y + side.y)),
                (CGPoint(x: direction.x - side.x, y: direction.y - side.y)),
            ] {
                path.move(to: CGPoint(x: centre.x - arm.x * reach, y: centre.y - arm.y * reach))
                path.addLine(to: CGPoint(x: centre.x + arm.x * reach, y: centre.y + arm.y * reach))
            }
            return [.path(path, color: color, lineWidth: width, filled: false)]
        }
    }

    /// A sheet of paper: square on three sides and waved along its foot.
    private static func sheet(_ frame: CGRect) -> CGPath {
        let wave = min(frame.height * 0.16, 12)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: frame.minX, y: frame.minY))
        path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
        path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - wave))
        path.addCurve(
            to: CGPoint(x: frame.minX, y: frame.maxY - wave),
            control1: CGPoint(x: frame.maxX - frame.width / 3, y: frame.maxY + wave),
            control2: CGPoint(x: frame.minX + frame.width / 3, y: frame.maxY - wave * 3))
        path.closeSubpath()
        return path
    }

    /// A drum seen from the side, standing on end.
    private static func drum(_ frame: CGRect) -> CGPath {
        let lid = min(frame.height * 0.18, 10)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: frame.minX, y: frame.minY + lid))
        path.addCurve(
            to: CGPoint(x: frame.maxX, y: frame.minY + lid),
            control1: CGPoint(x: frame.minX, y: frame.minY - lid),
            control2: CGPoint(x: frame.maxX, y: frame.minY - lid))
        path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - lid))
        path.addCurve(
            to: CGPoint(x: frame.minX, y: frame.maxY - lid),
            control1: CGPoint(x: frame.maxX, y: frame.maxY + lid),
            control2: CGPoint(x: frame.minX, y: frame.maxY + lid))
        path.closeSubpath()
        return path
    }

    /// The unit vector at a right angle to the line from one point to another.
    private static func normal(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let direction = normalized(CGPoint(x: end.x - start.x, y: end.y - start.y))
        return CGPoint(x: -direction.y, y: direction.x)
    }

    /// A quadratic curve as a run of points. Everything downstream — dashes,
    /// the arrowhead, where the words sit — walks the line, so it is flattened
    /// once here rather than being asked of `CGPath` afterwards.
    private static func samples(from start: CGPoint, through control: CGPoint, to end: CGPoint)
        -> [CGPoint]
    {
        let steps = 24
        return (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            let u = 1 - t
            return CGPoint(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
            )
        }
    }

    private static func length(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// The same run of points with its tail cut back, which is where an
    /// arrowhead goes.
    private static func shortened(_ points: [CGPoint], by amount: CGFloat) -> [CGPoint] {
        guard amount > 0, points.count >= 2 else { return points }
        var remaining = amount
        var out = points
        while out.count >= 2 {
            let last = out[out.count - 1]
            let previous = out[out.count - 2]
            let segment = distance(previous, last)
            if segment > remaining {
                let t = (segment - remaining) / segment
                out[out.count - 1] = CGPoint(
                    x: previous.x + (last.x - previous.x) * t,
                    y: previous.y + (last.y - previous.y) * t)
                return out
            }
            remaining -= segment
            out.removeLast()
        }
        return points
    }

    /// Where a given distance along the line falls, and which way the line is
    /// going there.
    private static func point(along points: [CGPoint], at distance: CGFloat)
        -> (point: CGPoint, heading: CGPoint)
    {
        var remaining = distance
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = self.distance(a, b)
            guard segment > 0 else { continue }
            if remaining <= segment {
                let t = remaining / segment
                return (
                    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                    normalized(CGPoint(x: b.x - a.x, y: b.y - a.y))
                )
            }
            remaining -= segment
        }
        let last = points[points.count - 1]
        let previous = points[max(0, points.count - 2)]
        return (last, normalized(CGPoint(x: last.x - previous.x, y: last.y - previous.y)))
    }

    /// A run of points drawn as dashes, the gaps carried from one segment to the
    /// next so a curve dashes as evenly as a straight line does.
    private static func dashed(along points: [CGPoint], dash: CGFloat, gap: CGFloat) -> CGPath {
        let path = CGMutablePath()
        var travelled: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = distance(a, b)
            guard segment > 0 else { continue }
            var offset: CGFloat = 0
            while offset < segment {
                let position = travelled + offset
                let phase = position.truncatingRemainder(dividingBy: dash + gap)
                let step =
                    phase < dash
                    ? min(dash - phase, segment - offset)
                    : min(dash + gap - phase, segment - offset)
                if phase < dash {
                    let from = offset / segment
                    let to = (offset + step) / segment
                    path.move(to: CGPoint(x: a.x + (b.x - a.x) * from, y: a.y + (b.y - a.y) * from))
                    path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * to, y: a.y + (b.y - a.y) * to))
                }
                offset += max(step, 0.01)
            }
            travelled += segment
        }
        return path
    }

    /// How far out beside a box a line that returns to it stands.
    private static func loopReach(_ metrics: Metrics) -> CGFloat { 26 * metrics.scale }

    /// The run of a line from one box to another: where it leaves, how it goes,
    /// where it arrives. Every diagram that joins two rectangles asks this same
    /// question, so a class relation and a flowchart edge are answered alike.
    private static func connection(
        from: CGRect, to: CGRect, metrics: Metrics, fromOutline: CGPath? = nil,
        toOutline: CGPath? = nil
    ) -> [CGPoint] {
        // A line from a box to itself has no two sides to cross between, so it
        // stands out beside the box and comes back to it. Mermaid draws the same
        // loop, and without one such an edge is written and never seen.
        if from == to {
            let reach = loopReach(metrics) * 4 / 3
            let high = from.minY + from.height / 4
            let low = from.maxY - from.height / 4
            return samples(
                from: CGPoint(x: from.maxX, y: high),
                out: CGPoint(x: from.maxX + reach, y: high),
                in: CGPoint(x: from.maxX + reach, y: low),
                to: CGPoint(x: from.maxX, y: low))
        }
        let joining = route(from, to)
        let start = onOutline(joining.start, of: fromOutline, from: from.center)
        let end = onOutline(joining.end, of: toOutline, from: to.center)
        guard joining.turns else { return [start, end] }
        // Half way is where the turn goes: the line runs straight out of the
        // side it left by, bends once, and comes in straight at the other end
        // rather than crossing both boxes on the slant.
        let reach = joining.sideways ? (end.x - start.x) / 2 : (end.y - start.y) / 2
        return samples(
            from: start,
            out: joining.sideways
                ? CGPoint(x: start.x + reach, y: start.y) : CGPoint(x: start.x, y: start.y + reach),
            in: joining.sideways
                ? CGPoint(x: end.x - reach, y: end.y) : CGPoint(x: end.x, y: end.y - reach),
            to: end)
    }

    /// One line of a flowchart: its shaft, the marks on its ends and its words.
    ///
    /// The layered layout routes almost every line and leaves a place for its
    /// words; this draws what it was given. What the layout leaves unrouted —
    /// a loop, a line between a frame and a box inside it — is joined box to
    /// box by `connection`.
    private static func edge(
        _ edge: Flowchart.Edge, from: CGRect, to: CGRect, theme: Theme, metrics: Metrics,
        fromOutline: CGPath? = nil, toOutline: CGPath? = nil,
        route: [CGPoint]? = nil, wordsAt: CGRect? = nil, loopBelow: Bool = false
    ) -> (
        shaft: [BlockBox.Decoration], label: [BlockBox.Decoration], plate: CGRect?,
        path: [CGPoint]
    ) {
        // `A ~~~ B` is written to hold one box under another and nothing more,
        // so it has already done its work by the time there is a line to draw.
        guard edge.stroke != .invisible else { return (shaft: [], label: [], plate: nil, path: []) }
        // A line the layout routed is drawn as routed, its corners rounded; one
        // it did not — a loop, a line between a frame and what it holds — is
        // joined box to box.
        let path: [CGPoint]
        if let route, route.count >= 2 {
            path = rounded(
                onOutlines(route, from: fromOutline, to: toOutline), radius: 12 * metrics.scale)
        } else if loopBelow {
            let reach = loopReach(metrics) * 4 / 3
            let left = from.minX + from.width / 4
            let right = from.maxX - from.width / 4
            path = samples(
                from: CGPoint(x: right, y: from.maxY),
                out: CGPoint(x: right, y: from.maxY + reach),
                in: CGPoint(x: left, y: from.maxY + reach),
                to: CGPoint(x: left, y: from.maxY))
        } else {
            path = connection(
                from: from, to: to, metrics: metrics, fromOutline: fromOutline,
                toOutline: toOutline)
        }
        let start = path[0]
        let end = path[path.count - 1]
        var decorations: [BlockBox.Decoration] = []
        let color = faded(
            edge.style.stroke.map(cgColor) ?? theme.palette.secondaryText, by: edge.style)
        let width: CGFloat = (edge.stroke == .thick ? 2.5 : 1.3) * metrics.scale
        let shaft = CGMutablePath()
        // The line stops short of whatever stands at its ends, so a mark is
        // drawn in clear space rather than over the shaft.
        func room(for mark: Flowchart.Head) -> CGFloat {
            switch mark {
            case .none: return 0
            case .arrow: return metrics.arrowLength
            case .circle, .cross: return metrics.arrowWidth
            }
        }
        let tip = end
        let foot = start
        var body = shortened(path, by: room(for: edge.head))
        if edge.tail != .none {
            body = shortened(body.reversed(), by: room(for: edge.tail)).reversed()
        }
        let last = body.count >= 2 ? body[body.count - 2] : start
        let direction = normalized(CGPoint(x: tip.x - last.x, y: tip.y - last.y))
        let first = body.count >= 2 ? body[1] : end
        let backwards = normalized(CGPoint(x: foot.x - first.x, y: foot.y - first.y))
        if edge.stroke == .dotted {
            shaft.addPath(dashed(along: body, dash: 4, gap: 4))
        } else {
            shaft.move(to: body[0])
            for point in body.dropFirst() { shaft.addLine(to: point) }
        }
        decorations.append(.path(shaft, color: color, lineWidth: width, filled: false))
        decorations += linkEnd(
            edge.head, at: tip, from: body.last ?? start, along: direction, color: color,
            width: width, metrics: metrics)
        decorations += linkEnd(
            edge.tail, at: foot, from: body.first ?? end, along: backwards, color: color,
            width: width, metrics: metrics)
        guard !edge.label.isEmpty else { return (decorations, [], nil, path) }
        // The layout made a block for the words; they are written in it, on
        // the line they belong to.
        if let wordsAt {
            let colour = faded(
                edge.style.text.map(cgColor) ?? theme.palette.secondaryText, by: edge.style)
            let said = edgeWords(
                edge.label, font: scaled(theme.controlLabel, by: metrics.scale), color: colour)
            let written =
                [
                    BlockBox.Decoration.fill(
                        rect: wordsAt, color: theme.palette.background, cornerRadius: 2)
                ] + centred(said.lines, size: said.size, in: wordsAt)
            return (decorations, written, wordsAt, path)
        }
        let line = text(
            edge.label,
            font: scaled(theme.controlLabel, by: metrics.scale),
            color: faded(
                edge.style.text.map(cgColor) ?? theme.palette.secondaryText, by: edge.style)
        )
        let size = measure(line)
        // A loop's words stand past its furthest point: inside a curve barely
        // wider than they are they would be read as words on the box.
        if from == to {
            let apex = point(along: path, at: length(of: path) / 2).point
            let middle =
                loopBelow
                ? CGPoint(x: apex.x, y: apex.y + size.height / 2 + 6 * metrics.scale)
                : CGPoint(x: apex.x + size.width / 2 + 6 * metrics.scale, y: apex.y)
            return (
                decorations, words(line, size: size, centred: middle, theme: theme),
                plate(size, centred: middle), path
            )
        }
        // A line the layout did not route — one between a frame and a box it
        // holds — carries its words half way along it.
        let middle = point(along: path, at: length(of: path) / 2).point
        return (
            decorations, words(line, size: size, centred: middle, theme: theme),
            plate(size, centred: middle), path
        )
    }

    /// An edge's words broken into lines of at most twelve characters, on top
    /// of any break the author wrote. A word longer than that keeps its line.
    private static func edgeWords(_ words: String, font: CTFont, color: CGColor)
        -> (lines: [CTLine], size: CGSize)
    {
        var parts = [words]
        for separator in ["<br/>", "<br />", "<br>", "\\n"] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        var broken: [String] = []
        for part in parts {
            var current = ""
            for word in part.split(separator: " ", omittingEmptySubsequences: true) {
                if !current.isEmpty, current.count + 1 + word.count > 12 {
                    broken.append(current)
                    current = String(word)
                } else {
                    current = current.isEmpty ? String(word) : current + " " + word
                }
            }
            if !current.isEmpty { broken.append(current) }
        }
        let lines = broken.map { text($0, font: font, color: color) }
        let sizes = lines.map(measure)
        return (
            lines,
            CGSize(
                width: sizes.map(\.width).max() ?? 0, height: sizes.reduce(0) { $0 + $1.height })
        )
    }

    /// A line the layout ran to the border of a frame, carried on to the box
    /// inside the frame it is really for — at either end. A line that already
    /// stops on its box's border is left as it is. `boxes` are what the carried
    /// line must not run through.
    private static func carried(
        _ route: [CGPoint], from: CGRect, to: CGRect, boxes: [CGRect]
    ) -> [CGPoint] {
        let forwards = reached(route, to, boxes: boxes)
        return reached(forwards.reversed(), from, boxes: boxes).reversed()
    }

    private static func reached(_ points: [CGPoint], _ target: CGRect, boxes: [CGRect])
        -> [CGPoint]
    {
        guard points.count >= 2, let end = points.last else { return points }
        let onBorder =
            target.insetBy(dx: -1, dy: -1).contains(end)
            && !target.insetBy(dx: 1, dy: 1).contains(end)
        guard !onBorder else { return points }
        let before = points[points.count - 2]
        // A box straight ahead is simply run on into. Only when it is not does
        // the run that brought the line to the frame slide across to the middle
        // of the box: the turn before that run already points the right way, so
        // the line arrives with the turns it had rather than a step of two more.
        // Sliding a line that could run straight on pulls every line into one
        // side onto its middle, where they lie on top of one another.
        let ahead =
            abs(end.x - before.x) < 0.5
            ? end.x > target.minX + 4 && end.x < target.maxX - 4
            : end.y > target.minY + 4 && end.y < target.maxY - 4
        if !ahead, points.count >= 3, let slid = slid(points, onto: target, boxes: boxes) {
            return slid
        }
        var out = points
        // The line keeps going the way it was going, into the side of the box
        // that faces it; when the box is not straight ahead it turns half way.
        if abs(end.x - before.x) < 0.5 {
            let side = end.y < target.minY ? target.minY : target.maxY
            if end.x > target.minX + 4, end.x < target.maxX - 4 {
                out.append(CGPoint(x: end.x, y: side))
            } else {
                let turn = (end.y + side) / 2
                out += [
                    CGPoint(x: end.x, y: turn), CGPoint(x: target.midX, y: turn),
                    CGPoint(x: target.midX, y: side),
                ]
            }
        } else {
            let side = end.x < target.minX ? target.minX : target.maxX
            if end.y > target.minY + 4, end.y < target.maxY - 4 {
                out.append(CGPoint(x: side, y: end.y))
            } else {
                let turn = (end.x + side) / 2
                out += [
                    CGPoint(x: turn, y: end.y), CGPoint(x: turn, y: target.midY),
                    CGPoint(x: side, y: target.midY),
                ]
            }
        }
        return LayeredLayout.simplified(out)
    }

    /// The line with its last run moved across onto the middle of `target`'s
    /// facing side, or `nil` when the run does not head for that side or the
    /// moved line would cross a box.
    private static func slid(_ points: [CGPoint], onto target: CGRect, boxes: [CGRect])
        -> [CGPoint]?
    {
        let count = points.count
        let end = points[count - 1]
        let before = points[count - 2]
        let earlier = points[count - 3]
        let level = abs(end.y - before.y) < 0.5
        // The run before the last has to be the other way round, or there is
        // no turn to move the last one along.
        guard level ? abs(before.x - earlier.x) < 0.5 : abs(before.y - earlier.y) < 0.5
        else { return nil }
        let corner: CGPoint
        let arrival: CGPoint
        if level {
            let side = end.x < target.minX ? target.minX : target.maxX
            guard (side - before.x) * (end.x - before.x) > 0, abs(side - before.x) > 1
            else { return nil }
            corner = CGPoint(x: before.x, y: target.midY)
            arrival = CGPoint(x: side, y: target.midY)
        } else {
            let side = end.y < target.minY ? target.minY : target.maxY
            guard (side - before.y) * (end.y - before.y) > 0, abs(side - before.y) > 1
            else { return nil }
            corner = CGPoint(x: target.midX, y: before.y)
            arrival = CGPoint(x: target.midX, y: side)
        }
        // The run before keeps its direction: turned round, it would double
        // back over itself, or into the box it left.
        let kept =
            level
            ? (corner.y - earlier.y) * (before.y - earlier.y) > 0
            : (corner.x - earlier.x) * (before.x - earlier.x) > 0
        guard kept else { return nil }
        func span(_ one: CGPoint, _ other: CGPoint) -> CGRect {
            CGRect(
                x: min(one.x, other.x), y: min(one.y, other.y), width: abs(one.x - other.x),
                height: abs(one.y - other.y)
            ).insetBy(dx: -2, dy: -2)
        }
        let runs = [span(earlier, corner), span(corner, arrival)]
        let clear = !boxes.contains { box in
            box != target && !box.insetBy(dx: -1, dy: -1).contains(earlier)
                && runs.contains { $0.intersects(box) }
        }
        guard clear else { return nil }
        return LayeredLayout.simplified(Array(points.dropLast(2)) + [corner, arrival])
    }

    /// A routed line whose ends stop on a box's rectangle, carried on along its
    /// last stretch to the shape actually drawn there — a diamond or a circle
    /// stands well inside its rectangle.
    private static func onOutlines(_ route: [CGPoint], from: CGPath?, to: CGPath?) -> [CGPoint] {
        var points = route
        func inwards(_ end: CGPoint, from before: CGPoint, outline: CGPath) -> CGPoint {
            let run = hypot(end.x - before.x, end.y - before.y)
            guard run > 0, !outline.contains(end) else { return end }
            let step = CGPoint(x: (end.x - before.x) / run, y: (end.y - before.y) / run)
            let reach = max(outline.boundingBox.width, outline.boundingBox.height)
            var outside: CGFloat = 0
            var inside: CGFloat?
            var probe: CGFloat = 1
            while probe <= reach {
                if outline.contains(CGPoint(x: end.x + step.x * probe, y: end.y + step.y * probe)) {
                    inside = probe
                    break
                }
                outside = probe
                probe += 1
            }
            guard var inside else { return end }
            for _ in 0..<8 {
                let middle = (outside + inside) / 2
                if outline.contains(CGPoint(x: end.x + step.x * middle, y: end.y + step.y * middle))
                {
                    inside = middle
                } else {
                    outside = middle
                }
            }
            return CGPoint(x: end.x + step.x * outside, y: end.y + step.y * outside)
        }
        if let to, points.count >= 2 {
            points[points.count - 1] = inwards(
                points[points.count - 1], from: points[points.count - 2], outline: to)
        }
        if let from, points.count >= 2 {
            points[0] = inwards(points[0], from: points[1], outline: from)
        }
        return points
    }

    /// A line of straight runs with every corner turned on an arc, flattened
    /// into points. The arc is never wider than half of either run it joins,
    /// so two corners close together still meet in a straight piece.
    static func rounded(_ points: [CGPoint], radius: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var out = [points[0]]
        for index in 1..<(points.count - 1) {
            let before = points[index - 1]
            let corner = points[index]
            let after = points[index + 1]
            let inLength = hypot(corner.x - before.x, corner.y - before.y)
            let outLength = hypot(after.x - corner.x, after.y - corner.y)
            guard inLength > 0, outLength > 0 else { continue }
            let r = min(radius, inLength / 2, outLength / 2)
            let start = CGPoint(
                x: corner.x - (corner.x - before.x) / inLength * r,
                y: corner.y - (corner.y - before.y) / inLength * r)
            let end = CGPoint(
                x: corner.x + (after.x - corner.x) / outLength * r,
                y: corner.y + (after.y - corner.y) / outLength * r)
            let curve = samples(from: start, through: corner, to: end)
            out += stride(from: 0, to: curve.count, by: 3).map { curve[$0] } + [end]
        }
        out.append(points[points.count - 1])
        return out
    }

    /// The rectangle an edge's words cover: the plate `words` draws under them.
    private static func plate(_ size: CGSize, centred middle: CGPoint) -> CGRect {
        CGRect(
            x: middle.x - size.width / 2 - 3, y: middle.y - size.height / 2 - 1,
            width: size.width + 6, height: size.height + 2)
    }

    /// An edge's words on their own plate: the label sits on the line, so it
    /// needs the page under it.
    private static func words(
        _ line: CTLine, size: CGSize, centred middle: CGPoint, theme: Theme
    ) -> [BlockBox.Decoration] {
        [
            .fill(
                rect: plate(size, centred: middle),
                color: theme.palette.background, cornerRadius: 2),
            .glyphs(
                line,
                origin: CGPoint(
                    x: middle.x - size.width / 2, y: middle.y + size.height / 2 - descent(line))),
        ]
    }

    // MARK: - Sequence diagram

    /// Every message in a diagram, however deep in blocks it was written.
    private static func messages(_ items: [SequenceDiagram.Item])
        -> [SequenceDiagram.Message]
    {
        items.flatMap { item -> [SequenceDiagram.Message] in
            switch item {
            case .message(let message): return [message]
            case .block(let block): return block.sections.flatMap { messages($0.items) }
            case .note, .activate, .deactivate, .comment, .create, .destroy: return []
            }
        }
    }

    /// WCAG 2.1 relative luminance, which contrast is defined in terms of.
    static func luminance(_ color: CGColor) -> CGFloat {
        let rgb =
            color.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
            ?? color
        let parts = (rgb.components ?? [0, 0, 0, 1]).prefix(3).map { part -> CGFloat in
            part <= 0.03928 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4)
        }
        guard parts.count == 3 else { return 1 }
        return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]
    }

    static func contrast(_ one: CGColor, _ other: CGColor) -> CGFloat {
        let first = luminance(one)
        let second = luminance(other)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// The lettering a diagram's own ink is held to: AAA for body text, which
    /// is what the palette is chosen against, and what a colour an author
    /// wrote must not undo.
    static let readableContrast: CGFloat = 7

    /// The strongest tint of a colour an author chose that still leaves the
    /// faintest lettering on it readable.
    ///
    /// A `box` colour used to sit behind a band of heading and nothing else,
    /// where the only thing over it was the group's own name. Run down the
    /// whole column it is behind every message, every lifeline and every note
    /// in the group, so a saturated or dark colour would take the picture with
    /// it. The colour is therefore mixed with the page until the faintest ink
    /// drawn over it — a message label — still stands at `readableContrast`. A
    /// pale colour is already there and passes through untouched.
    static func wash(_ fill: CGColor, on page: CGColor, keeping theme: Theme) -> CGColor {
        wash(fill, on: page, under: theme.palette.secondaryText)
    }

    /// The same rule for a colour that has one particular ink written on it:
    /// a node's fill under the node's own label.
    ///
    /// A colour is only moved toward the page when the page is somewhere worth
    /// moving to. An author who wrote both halves of a pair — a dark fill and
    /// the pale lettering that goes on it — has already answered the question,
    /// and washing that fill would erase their answer and their words with it.
    /// A colour laid over another at a given strength, as the eye meets it.
    static func over(_ colour: CGColor, at strength: CGFloat, on page: CGColor) -> CGColor {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let under = page.converted(to: space, intent: .defaultIntent, options: nil) ?? page
        let top = colour.converted(to: space, intent: .defaultIntent, options: nil) ?? colour
        guard let start = under.components, let end = top.components, start.count >= 3,
            end.count >= 3
        else { return page }
        return CGColor(
            srgbRed: start[0] + (end[0] - start[0]) * strength,
            green: start[1] + (end[1] - start[1]) * strength,
            blue: start[2] + (end[2] - start[2]) * strength, alpha: 1)
    }

    /// `shownAt` is the alpha the colour will be drawn with: a tile painted at
    /// half strength is half way to the page already, and washing it as if it
    /// were solid would take a perfectly readable colour and pale it for
    /// nothing.
    static func wash(
        _ fill: CGColor, on page: CGColor, under ink: CGColor, shownAt alpha: CGFloat = 1
    ) -> CGColor {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let from = page.converted(to: space, intent: .defaultIntent, options: nil) ?? page
        let to = fill.converted(to: space, intent: .defaultIntent, options: nil) ?? fill
        guard let start = from.components, let end = to.components, start.count >= 3,
            end.count >= 3
        else { return fill }
        /// The colour as the eye meets it: mixed toward the fill by `strength`,
        /// then laid over the page at `alpha`.
        func shown(_ strength: CGFloat) -> CGColor {
            let share = strength * alpha
            return CGColor(
                srgbRed: start[0] + (end[0] - start[0]) * share,
                green: start[1] + (end[1] - start[1]) * share,
                blue: start[2] + (end[2] - start[2]) * share,
                alpha: 1)
        }
        guard contrast(ink, shown(1)) < readableContrast else { return fill }
        guard contrast(ink, page) >= readableContrast else { return fill }
        var strength: CGFloat = 1
        // The page itself always passes, so a colour that never does becomes
        // no colour at all rather than an unreadable one.
        var mixed = page
        // Twelve halvings settle it to a thousandth, which is finer than a
        // colour can be written in the first place.
        var stride: CGFloat = 0.5
        for _ in 0..<12 {
            if contrast(ink, shown(strength)) >= readableContrast {
                mixed = CGColor(
                    srgbRed: start[0] + (end[0] - start[0]) * strength,
                    green: start[1] + (end[1] - start[1]) * strength,
                    blue: start[2] + (end[2] - start[2]) * strength,
                    alpha: 1)
                strength += stride
            } else {
                strength -= stride
            }
            stride /= 2
        }
        return mixed
    }

    /// How far apart two neighbouring lifelines stand, gap by gap.
    ///
    /// A sequence diagram usually gets one spacing for all of its columns, and
    /// the widest message anywhere is what sets it: a diagram with one wordy
    /// message and a dozen short ones spreads all dozen as far apart as the
    /// wordy one needs, and the picture is two or three times the width it has
    /// anything to say in. Each gap is given the room its own traffic asks for
    /// instead. A message crossing several gaps asks them together and takes
    /// only what is still missing, so the ones already widened by their own
    /// messages are not widened twice; short crossings are settled first, for
    /// the same reason.
    ///
    /// A note written over two or more participants is traffic too — it is
    /// centred on them and would otherwise lie across a neighbour.
    private static func spacing(
        _ diagram: SequenceDiagram, count: Int, boxWidth: CGFloat, theme: Theme, font: CTFont,
        metrics: Metrics
    ) -> [CGFloat] {
        guard count > 1 else { return [] }
        // Two boxes side by side with room to breathe: the floor under every
        // gap, whatever crosses it.
        var gaps = Array(repeating: boxWidth + metrics.columnGap, count: count - 1)

        func room(_ text: String, padding: CGFloat) -> CGFloat {
            measure(MermaidLayout.text(text, font: font, color: theme.palette.text)).width
                + padding * metrics.scale
        }
        var wanted: [(span: Range<Int>, width: CGFloat)] = []
        for message in messages(diagram.items) where message.from != message.to {
            let low = min(message.from, message.to)
            let high = max(message.from, message.to)
            guard low >= 0, high < count else { continue }
            wanted.append((low..<high, room(message.text, padding: 26)))
        }
        for case .note(let note) in diagram.items {
            let anchors = note.participants.filter { $0 >= 0 && $0 < count }.sorted()
            guard let low = anchors.first, let high = anchors.last, low < high else { continue }
            wanted.append((low..<high, room(note.text, padding: 16)))
        }

        for asked in wanted.sorted(by: { $0.span.count < $1.span.count }) {
            let have = asked.span.reduce(CGFloat(0)) { $0 + gaps[$1] }
            guard have < asked.width else { continue }
            let share = (asked.width - have) / CGFloat(asked.span.count)
            for gap in asked.span { gaps[gap] += share }
        }
        return gaps
    }

    private static func sequence(
        _ diagram: SequenceDiagram, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.bodyBold, by: metrics.scale)
        let small = scaled(theme.controlLabel, by: metrics.scale)
        var labels: [CTLine] = []
        var sizes: [CGSize] = []
        for participant in diagram.participants {
            let line = text(participant.label, font: font, color: theme.palette.text)
            labels.append(line)
            sizes.append(measure(line))
        }
        let boxWidth =
            (sizes.map { $0.width }.max() ?? 40) + metrics.nodePaddingX * 2
        let boxHeight = (sizes.map { $0.height }.max() ?? 16) + metrics.nodePaddingY * 2
        let gaps = spacing(
            diagram, count: diagram.participants.count, boxWidth: boxWidth, theme: theme,
            font: small, metrics: metrics)
        let content = gaps.reduce(boxWidth, +)
        var titleLine: CTLine?
        var titleRoom: CGFloat = 0
        if !diagram.title.isEmpty {
            let line = text(
                diagram.title, font: scaled(theme.bodyBold, by: metrics.scale * 1.1),
                color: theme.palette.text)
            titleLine = line
            titleRoom = measure(line).height + 12 * metrics.scale
        }
        // A `box` stands above the participants it holds, and its name needs a
        // line of its own there.
        let groupRoom =
            diagram.groups.isEmpty
            ? 0
            : measure(text("X", font: small, color: theme.palette.text)).height
                + 14 * metrics.scale
        let top = metrics.padding + titleRoom + groupRoom
        let firstMessage = top + boxHeight + metrics.messageGap

        // The body is walked before anything is drawn: a lifeline has to reach
        // the last message, a block's frame has to know where its contents
        // ended, and a note beside the outermost lifeline decides how wide the
        // picture really is.
        let left = max(metrics.padding, (width - content) / 2)
        var centres: [CGFloat] = []
        var standing = left + boxWidth / 2
        for index in 0..<diagram.participants.count {
            if index > 0 { standing += gaps[index - 1] }
            centres.append(standing)
        }
        let body = script(
            diagram, centres: centres, boxWidth: boxWidth, boxHeight: boxHeight,
            from: firstMessage, theme: theme, font: small, metrics: metrics)
        let height = body.bottom + metrics.padding

        var decorations: [BlockBox.Decoration] = []
        if let titleLine {
            let size = measure(titleLine)
            decorations.append(
                .glyphs(
                    titleLine,
                    origin: CGPoint(
                        x: left + (content - size.width) / 2,
                        y: metrics.padding + size.height - descent(titleLine))))
        }
        for group in diagram.groups {
            let members = group.members.sorted()
            guard let first = members.first, let last = members.last, last < centres.count else {
                continue
            }
            // A `box` names a column of the picture, not a row of it: the
            // colour runs the whole height, so a reader following a lifeline
            // down can see which group it belongs to at any point.
            let column = CGRect(
                x: centres[first] - boxWidth / 2 - 6 * metrics.scale, y: top - groupRoom,
                width: centres[last] - centres[first] + boxWidth + 12 * metrics.scale,
                height: height - metrics.padding - (top - groupRoom))
            let rect = column
            // A group is its colour and nothing else. An outline around a
            // column the height of the picture crosses every message that
            // passes between two groups, and a word written over that line is
            // the one word in the diagram nobody can read. A box left without a
            // colour takes the faintest tint the theme has, so that removing
            // the outline does not leave it invisible.
            let colour = group.fill.map(cgColor) ?? theme.palette.tableHeaderBackground
            decorations.append(
                .path(
                    CGPath(rect: column, transform: nil),
                    color: wash(colour, on: theme.palette.codeBackground, keeping: theme),
                    lineWidth: 0, filled: true))
            let lines = labelLines(
                group.label, font: small, color: theme.palette.secondaryText
            ).lines
            var top = rect.minY + 4 * metrics.scale
            for line in lines {
                let one = measure(line)
                decorations.append(
                    .glyphs(
                        line,
                        origin: CGPoint(
                            x: rect.midX - one.width / 2, y: top + one.height - descent(line))))
                top += one.height
            }
        }
        decorations += body.tints
        for (index, centre) in centres.enumerated() {
            // Somebody made partway through the picture has a box where they
            // were made rather than at the top, and somebody destroyed has a
            // second box where their lifeline ends.
            let bornAt = body.born[index] ?? top
            let diedAt = body.died[index]
            // An actor's name is written under the figure, so the lifeline
            // starts under the name rather than striking through it.
            let nameRoom =
                diagram.participants[index].isActor && !diagram.participants[index].label.isEmpty
                ? sizes[index].height + 4 * metrics.scale : 0
            let lifeline = dashed(
                from: CGPoint(x: centre, y: bornAt + boxHeight + nameRoom),
                to: CGPoint(x: centre, y: diedAt ?? (height - metrics.padding)),
                dash: 4,
                gap: 4
            )
            decorations.append(
                .path(lifeline, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
            decorations += participant(
                diagram.participants[index], label: labels[index], size: sizes[index],
                in: CGRect(
                    x: centre - boxWidth / 2, y: bornAt, width: boxWidth, height: boxHeight),
                theme: theme, metrics: metrics)
            if let diedAt {
                decorations += participant(
                    diagram.participants[index], label: labels[index], size: sizes[index],
                    in: CGRect(
                        x: centre - boxWidth / 2, y: diedAt, width: boxWidth, height: boxHeight),
                    theme: theme, metrics: metrics)
            }
        }

        decorations += body.frames
        decorations += body.bars
        decorations += body.body
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content + body.reach * 2
        )
    }

    /// One participant's box, or the stick figure that stands in for it, with
    /// the name written where that kind of picture writes it. Somebody made or
    /// destroyed partway through a diagram has two of these, so it is drawn from
    /// a rectangle rather than from where they stand.
    private static func participant(
        _ participant: SequenceDiagram.Participant, label: CTLine, size: CGSize, in frame: CGRect,
        theme: Theme, metrics: Metrics
    ) -> [BlockBox.Decoration] {
        var decorations: [BlockBox.Decoration] = []
        if participant.isActor {
            // A stick figure, which is how Mermaid draws somebody rather than
            // something.
            decorations += figure(in: frame, theme: theme, metrics: metrics)
        } else {
            let path = CGPath(roundedRect: frame, cornerWidth: 4, cornerHeight: 4, transform: nil)
            decorations.append(
                .path(path, color: theme.palette.tableHeaderBackground, lineWidth: 0, filled: true))
            decorations.append(
                .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
        }
        guard !participant.label.isEmpty else { return decorations }
        decorations.append(
            .glyphs(
                label,
                origin: CGPoint(
                    x: frame.midX - size.width / 2,
                    y: participant.isActor
                        ? frame.maxY + size.height - descent(label)
                        : frame.midY + size.height / 2 - descent(label)
                )
            )
        )
        return decorations
    }

    /// The diameter of a stick figure's head, which every other part of the
    /// figure is measured from.
    private static func figureHead(in size: CGSize) -> CGFloat {
        min(size.height * 0.34, size.width * 0.3)
    }

    /// How far a stick figure reaches either side of its middle: the ends of
    /// its arms, which is where a message to it arrives.
    private static func figureReach(in size: CGSize) -> CGFloat {
        figureHead(in: size) * 0.8
    }

    /// A stick figure standing in the room a participant box would take.
    private static func figure(
        in frame: CGRect, theme: Theme, metrics: Metrics
    ) -> [BlockBox.Decoration] {
        let ink = theme.palette.secondaryText
        let head = figureHead(in: frame.size)
        let centre = frame.midX
        let top = frame.minY + 2 * metrics.scale
        let body = CGMutablePath()
        let neck = top + head
        body.move(to: CGPoint(x: centre, y: neck))
        body.addLine(to: CGPoint(x: centre, y: frame.maxY - head * 0.8))
        let arms = figureReach(in: frame.size)
        body.move(to: CGPoint(x: centre - arms, y: neck + head * 0.5))
        body.addLine(to: CGPoint(x: centre + arms, y: neck + head * 0.5))
        body.move(to: CGPoint(x: centre, y: frame.maxY - head * 0.8))
        body.addLine(to: CGPoint(x: centre - head * 0.7, y: frame.maxY))
        body.move(to: CGPoint(x: centre, y: frame.maxY - head * 0.8))
        body.addLine(to: CGPoint(x: centre + head * 0.7, y: frame.maxY))
        return [
            .path(
                CGPath(
                    ellipseIn: CGRect(
                        x: centre - head / 2, y: top, width: head, height: head), transform: nil),
                color: ink, lineWidth: 1.4 * metrics.scale, filled: false),
            .path(body, color: ink, lineWidth: 1.4 * metrics.scale, filled: false),
        ]
    }

    /// Everything below the participant boxes, in document order.
    ///
    /// Frames, activation bars and messages come back apart because they are
    /// painted in that order: a frame is behind its contents, and a bar is
    /// behind the arrows that start and end it.
    private static func script(
        _ diagram: SequenceDiagram, centres: [CGFloat], boxWidth: CGFloat, boxHeight: CGFloat,
        from top: CGFloat, theme: Theme, font: CTFont, metrics: Metrics
    ) -> (
        tints: [BlockBox.Decoration], frames: [BlockBox.Decoration], bars: [BlockBox.Decoration],
        body: [BlockBox.Decoration], bottom: CGFloat, reach: CGFloat,
        born: [Int: CGFloat], died: [Int: CGFloat]
    ) {
        var tints: [BlockBox.Decoration] = []
        var frames: [BlockBox.Decoration] = []
        var body: [BlockBox.Decoration] = []
        var bars: [BlockBox.Decoration] = []
        var open: [Int: [CGFloat]] = [:]
        /// Where a participant's box stands when it is not at the top of the
        /// picture, and where its lifeline stops when somebody ends it.
        var born: [Int: CGFloat] = [:]
        var died: [Int: CGFloat] = [:]
        var number = 1
        var y = top
        var reach: CGFloat = 10
        let colour = theme.palette.secondaryText
        let left = (centres.first ?? 0) - boxWidth / 2
        let right = (centres.last ?? 0) + boxWidth / 2
        let barWidth = 6 * metrics.scale

        func start(_ participant: Int, at y: CGFloat) {
            open[participant, default: []].append(y)
        }
        func finish(_ participant: Int, at y: CGFloat) {
            guard var stack = open[participant], let from = stack.popLast() else { return }
            open[participant] = stack
            guard participant < centres.count else { return }
            let depth = CGFloat(stack.count)
            let rect = CGRect(
                x: centres[participant] - barWidth / 2 + depth * barWidth / 2,
                y: from - 4,
                width: barWidth,
                height: max(8, y - from + 8)
            )
            bars.append(
                .fill(rect: rect, color: theme.palette.tableHeaderBackground, cornerRadius: 1))
            bars.append(
                .path(
                    CGPath(rect: rect, transform: nil), color: theme.palette.tableBorder,
                    lineWidth: 1, filled: false))
        }

        func walk(_ items: [SequenceDiagram.Item], depth: Int) {
            for item in items {
                switch item {
                case .activate(let participant):
                    start(participant, at: y)
                case .deactivate(let participant):
                    finish(participant, at: y)
                case .message(let message):
                    if message.activates { start(message.to, at: y) }
                    let words =
                        diagram.autonumber ? "\(number). \(message.text)" : message.text
                    number += 1
                    // A box drawn on this row belongs to somebody made or ended
                    // here: its middle is exactly where the message runs.
                    let row = y - boxHeight / 2
                    var boxed: [Int: CGFloat] = [:]
                    for who in born.filter({ $0.value == row }).map(\.key)
                        + died.filter({ $0.value == row }).map(\.key)
                    where who < diagram.participants.count {
                        boxed[who] =
                            diagram.participants[who].isActor
                            ? figureReach(in: CGSize(width: boxWidth, height: boxHeight))
                            : boxWidth / 2
                    }
                    body += arrow(
                        message, words: words, centres: centres, y: y, boxed: boxed,
                        theme: theme, font: font, metrics: metrics)
                    if message.deactivates { finish(message.from, at: y) }
                    y += message.from == message.to ? metrics.messageGap * 1.5 : metrics.messageGap
                case .create(let who):
                    // The box is drawn on the message that makes it, so half of
                    // it stands above that message and needs the room.
                    y += boxHeight / 2
                    born[who] = y - boxHeight / 2
                case .destroy(let who):
                    y += boxHeight / 2
                    died[who] = y - boxHeight / 2
                case .comment(let lines):
                    // A comment is written over the picture in the faint ink a
                    // note's words use, not in a box: it belongs to the message
                    // under it rather than to a participant.
                    let lineHeight = measure(text("X", font: font, color: colour)).height
                    for words in lines {
                        var x = left
                        for (bold, run) in emphasised(words) where !run.isEmpty {
                            let line = text(
                                run, font: bold ? scaled(theme.bodyBold, by: metrics.scale) : font,
                                color: theme.palette.secondaryText)
                            let size = measure(line)
                            body.append(
                                .glyphs(
                                    line,
                                    origin: CGPoint(x: x, y: y + size.height - descent(line))))
                            x += size.width
                        }
                        reach = max(reach, x - right)
                        y += lineHeight + 2 * metrics.scale
                    }
                    // The message this belongs to writes its own words above its
                    // arrow, so the room for them is left here.
                    y += lineHeight + metrics.messageGap * 0.25
                case .note(let note):
                    let drawn = self.note(
                        note, centres: centres, boxWidth: boxWidth, y: y, theme: theme,
                        font: font, metrics: metrics)
                    body += drawn.decorations
                    // A note beside the last lifeline sticks out of the picture,
                    // and the picture has to know so it can be drawn smaller.
                    reach = max(reach, drawn.rect.maxX - right, left - drawn.rect.minX)
                    y += drawn.height + metrics.messageGap * 0.4
                case .block(let block):
                    // A `rect` is a wash of colour and never a labelled frame,
                    // so one written without a colour takes the faintest tint
                    // the theme has rather than a word saying "rect".
                    let wash: CGColor? =
                        block.fill.map { cgColor($0) }
                        ?? (block.kind == "rect"
                            ? (theme.palette.tableHeaderBackground.copy(alpha: 0.55)
                                ?? theme.palette.tableHeaderBackground) : nil)
                    let inset = CGFloat(depth) * 9 * metrics.scale
                    let frameTop = y - metrics.messageGap * 0.55
                    var dividers: [(CGFloat, String)] = []
                    y += 6 * metrics.scale
                    for (index, section) in block.sections.enumerated() {
                        if index == 0 {
                            if wash == nil {
                                body += tag(
                                    block.kind, title: section.title,
                                    at: CGPoint(x: left - 10 + inset, y: frameTop), theme: theme,
                                    font: font, metrics: metrics)
                                y += 12 * metrics.scale
                            }
                        } else {
                            // An arm with no condition of its own is still an
                            // arm, and without a word on it the two halves of an
                            // `alt` read as one run of messages.
                            let words =
                                section.title.isEmpty
                                ? (block.kind == "par" ? "and" : "else") : section.title
                            dividers.append((y - metrics.messageGap * 0.4, words))
                            // The arm's plate hangs from its divider, and the
                            // first message under it keeps the distance the
                            // block's own tag keeps from the message under it.
                            y += 18 * metrics.scale + metrics.messageGap * 0.15
                        }
                        walk(section.items, depth: depth + 1)
                    }
                    let frameBottom = y - metrics.messageGap * 0.4
                    let rect = CGRect(
                        x: left - 10 + inset, y: frameTop,
                        width: right - left + 20 - inset * 2, height: frameBottom - frameTop)
                    if let wash {
                        // A `rect` is a wash of colour behind its messages and
                        // nothing else: no outline, and no word on it.
                        tints.append(
                            .path(
                                CGPath(rect: rect, transform: nil), color: wash,
                                lineWidth: 0, filled: true))
                        y += 6 * metrics.scale
                        continue
                    }
                    // The frame around a block is drawn as a dotted rectangle,
                    // the way Mermaid draws it: it fences the messages off
                    // without reading as a box they are inside.
                    let corners = [
                        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                        CGPoint(x: rect.minX, y: rect.minY),
                    ]
                    frames.append(
                        .path(
                            dashed(along: corners, dash: 3, gap: 3),
                            color: theme.palette.tableBorder, lineWidth: 1, filled: false))
                    for (lineY, title) in dividers {
                        frames.append(
                            .path(
                                dashed(
                                    from: CGPoint(x: rect.minX, y: lineY),
                                    to: CGPoint(x: rect.maxX, y: lineY), dash: 4, gap: 3),
                                color: theme.palette.tableBorder, lineWidth: 1, filled: false))
                        guard !title.isEmpty else { continue }
                        // An arm's condition sits on a plate like the block's
                        // own tag above it. Written straight on the page it
                        // stood across the first lifeline, which ran through
                        // its words.
                        body += tag(
                            "[\(title)]", title: "", at: CGPoint(x: rect.minX, y: lineY),
                            theme: theme, font: font, metrics: metrics)
                    }
                    // One block must not stand on the next: without room
                    // between them two frames read as one.
                    y += metrics.messageGap * 0.6
                }
            }
        }
        walk(diagram.items, depth: 0)
        // A bar nobody turned off runs to the end of the diagram.
        for participant in open.keys.sorted() {
            while !(open[participant]?.isEmpty ?? true) { finish(participant, at: y) }
        }
        return (tints, frames, bars, body, y, reach, born, died)
    }

    /// The corner tag that names a block: `loop`, `alt`, `opt`.
    private static func tag(
        _ kind: String, title: String, at corner: CGPoint, theme: Theme, font: CTFont,
        metrics: Metrics
    ) -> [BlockBox.Decoration] {
        let words = title.isEmpty ? kind : "\(kind) [\(title)]"
        let line = text(words, font: font, color: theme.palette.secondaryText)
        let size = measure(line)
        let plate = CGRect(
            x: corner.x, y: corner.y, width: size.width + 14, height: size.height + 6)
        return [
            .fill(rect: plate, color: theme.palette.tableHeaderBackground, cornerRadius: 3),
            .glyphs(
                line,
                origin: CGPoint(x: plate.minX + 7, y: plate.midY + size.height / 2 - descent(line))
            ),
        ]
    }

    private static func note(
        _ note: SequenceDiagram.Note, centres: [CGFloat], boxWidth: CGFloat, y: CGFloat,
        theme: Theme, font: CTFont, metrics: Metrics
    ) -> (decorations: [BlockBox.Decoration], height: CGFloat, rect: CGRect) {
        let line = text(note.text, font: font, color: theme.palette.text)
        let size = measure(line)
        let padding = 8 * metrics.scale
        let width = size.width + padding * 2
        let height = size.height + padding
        let anchors = note.participants.filter { $0 < centres.count }.map { centres[$0] }
        guard let first = anchors.first else { return ([], 0, .zero) }
        let x: CGFloat
        switch note.placement {
        case .over:
            let centre = ((anchors.min() ?? first) + (anchors.max() ?? first)) / 2
            x = centre - width / 2
        case .leftOf:
            x = first - boxWidth / 2 - 6 - width
        case .rightOf:
            x = first + boxWidth / 2 + 6
        }
        let rect = CGRect(x: x, y: y - height / 2, width: width, height: height)
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        return (
            [
                .path(path, color: theme.palette.codeBackground, lineWidth: 0, filled: true),
                .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false),
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: rect.minX + padding, y: rect.midY + size.height / 2 - descent(line))),
            ], height, rect
        )
    }

    private static func arrow(
        _ message: SequenceDiagram.Message, words: String, centres: [CGFloat], y: CGFloat,
        boxed: [Int: CGFloat] = [:], theme: Theme, font: CTFont, metrics: Metrics
    ) -> [BlockBox.Decoration] {
        guard message.from < centres.count, message.to < centres.count else { return [] }
        var decorations: [BlockBox.Decoration] = []
        let color = theme.palette.secondaryText
        let line = text(words, font: font, color: color)
        let size = measure(line)
        // Somebody made or ended by this very message has their box sitting on
        // the line, so the arrow stops at its edge instead of running through
        // the name written inside it. `boxed` says how far that edge is from
        // the lifeline: half a box, or the reach of a stick figure's arms.
        let towards: CGFloat = centres[message.to] > centres[message.from] ? 1 : -1
        let start = centres[message.from] + towards * (boxed[message.from] ?? 0)
        let end = centres[message.to] - towards * (boxed[message.to] ?? 0)
        if message.from == message.to {
            // A message to itself turns round beside its own lifeline.
            let loop = CGMutablePath()
            let reach = start + 26 * metrics.scale
            loop.move(to: CGPoint(x: start, y: y - 8))
            loop.addLine(to: CGPoint(x: reach, y: y - 8))
            loop.addLine(to: CGPoint(x: reach, y: y + 6))
            loop.addLine(to: CGPoint(x: start + metrics.arrowLength, y: y + 6))
            decorations.append(.path(loop, color: color, lineWidth: 1.3, filled: false))
            decorations.append(
                head(
                    message.head, at: CGPoint(x: start, y: y + 6),
                    direction: CGPoint(x: -1, y: 0), color: color, metrics: metrics))
            decorations.append(.glyphs(line, origin: CGPoint(x: reach + 8, y: y - 2)))
            return decorations
        }
        let direction: CGFloat = end > start ? 1 : -1
        // The head touches what it points at. A cross is drawn round its
        // middle, so it is pulled back by half its width to touch rather than
        // overlap, and the line runs into it.
        let arm = metrics.arrowWidth / 2
        let tip = CGPoint(x: message.head == .cross ? end - direction * arm : end, y: y)
        let shaftEnd = CGPoint(
            x: message.head == .cross ? tip.x : tip.x - direction * metrics.arrowLength, y: y)
        let shaft = CGMutablePath()
        if message.dashed {
            shaft.addPath(dashed(from: CGPoint(x: start, y: y), to: shaftEnd, dash: 5, gap: 4))
        } else {
            shaft.move(to: CGPoint(x: start, y: y))
            shaft.addLine(to: shaftEnd)
        }
        decorations.append(.path(shaft, color: color, lineWidth: 1.3, filled: false))
        decorations.append(
            head(
                message.head, at: tip, direction: CGPoint(x: direction, y: 0), color: color,
                metrics: metrics))
        // The words stand clear of the line by their own descenders: a baseline
        // a fixed few points up puts the tail of a `y` through the arrow.
        decorations.append(
            .glyphs(
                line,
                origin: CGPoint(
                    x: (start + end) / 2 - size.width / 2,
                    y: y - descent(line) - 4 * metrics.scale)
            )
        )
        return decorations
    }

    private static func head(
        _ kind: SequenceDiagram.Head, at tip: CGPoint, direction: CGPoint, color: CGColor,
        metrics: Metrics
    ) -> BlockBox.Decoration {
        switch kind {
        case .arrow:
            return arrowHead(at: tip, direction: direction, color: color, metrics: metrics)
        case .cross:
            let arm = metrics.arrowWidth / 2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: tip.x - arm, y: tip.y - arm))
            path.addLine(to: CGPoint(x: tip.x + arm, y: tip.y + arm))
            path.move(to: CGPoint(x: tip.x - arm, y: tip.y + arm))
            path.addLine(to: CGPoint(x: tip.x + arm, y: tip.y - arm))
            return .path(path, color: color, lineWidth: 1.5, filled: false)
        case .open:
            let back = CGPoint(
                x: tip.x - direction.x * metrics.arrowLength,
                y: tip.y - direction.y * metrics.arrowLength)
            let side = CGPoint(x: -direction.y, y: direction.x)
            let path = CGMutablePath()
            path.move(
                to: CGPoint(
                    x: back.x + side.x * metrics.arrowWidth / 2,
                    y: back.y + side.y * metrics.arrowWidth / 2))
            path.addLine(to: tip)
            path.addLine(
                to: CGPoint(
                    x: back.x - side.x * metrics.arrowWidth / 2,
                    y: back.y - side.y * metrics.arrowWidth / 2))
            return .path(path, color: color, lineWidth: 1.3, filled: false)
        }
    }

    // MARK: - Geometry

    private static func arrowHead(
        at tip: CGPoint, direction: CGPoint, color: CGColor, metrics: Metrics
    ) -> BlockBox.Decoration {
        let back = CGPoint(
            x: tip.x - direction.x * metrics.arrowLength,
            y: tip.y - direction.y * metrics.arrowLength
        )
        let side = CGPoint(x: -direction.y, y: direction.x)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(
            to: CGPoint(
                x: back.x + side.x * metrics.arrowWidth / 2,
                y: back.y + side.y * metrics.arrowWidth / 2))
        path.addLine(
            to: CGPoint(
                x: back.x - side.x * metrics.arrowWidth / 2,
                y: back.y - side.y * metrics.arrowWidth / 2))
        path.closeSubpath()
        return .path(path, color: color, lineWidth: 0, filled: true)
    }

    /// How far in from either end of a side a line may land, as a share of that
    /// side. Nearer than this and the line reads as one that missed the box.
    private static let corner: CGFloat = 0.3

    /// The same point pulled back onto the box's own outline.
    ///
    /// A line is cut off at the box's rectangle, which is the box itself only
    /// when the box is one. A diamond touches its rectangle at four points and
    /// stands well inside it everywhere else, so a line aimed at the rectangle
    /// begins in mid-air; walking it back to where it crosses the outline is
    /// what makes it start on the shape whatever the shape is.
    private static func onOutline(_ point: CGPoint, of outline: CGPath?, from centre: CGPoint)
        -> CGPoint
    {
        guard let outline, !outline.contains(point) else { return point }
        var inside: CGFloat = 0
        var outside: CGFloat = 1
        for _ in 0..<12 {
            let middle = (inside + outside) / 2
            let probe = CGPoint(
                x: centre.x + (point.x - centre.x) * middle,
                y: centre.y + (point.y - centre.y) * middle)
            if outline.contains(probe) { inside = middle } else { outside = middle }
        }
        return CGPoint(
            x: centre.x + (point.x - centre.x) * inside,
            y: centre.y + (point.y - centre.y) * inside)
    }

    /// Which sides two boxes are joined by, and whether the line between them
    /// has to turn to get there.
    ///
    /// Boxes that stand one over the other, or side by side, are joined by the
    /// sides that face each other and the line between them is straight. Boxes
    /// that stand corner to corner have no facing sides at all, and a line
    /// drawn straight between them leaves through a corner, which reads as a
    /// line that missed the box. Such a line leaves by the side across the
    /// wider of the two gaps — the way the graph is flowing — and turns on its
    /// way, which is what Mermaid draws for it.
    private static func route(_ from: CGRect, _ to: CGRect)
        -> (start: CGPoint, end: CGPoint, turns: Bool, sideways: Bool)
    {
        let sharedX = min(from.maxX, to.maxX) - max(from.minX, to.minX)
        let sharedY = min(from.maxY, to.maxY) - max(from.minY, to.minY)
        // Where the two boxes overlap is not enough on its own: two boxes may
        // overlap by a hair at one end, and a line drawn down the middle of
        // that hair leaves both of them by a corner. The crossing has to stand
        // on the flat of both boxes, so the overlap is narrowed to the part
        // that is clear of every corner, and a pair with nothing left over is
        // joined the way boxes standing corner to corner are.
        if sharedX > 0, sharedY <= 0 {
            let low = max(
                max(from.minX, to.minX),
                max(
                    from.minX + from.width * corner,
                    to.minX + to.width * corner))
            let high = min(
                min(from.maxX, to.maxX),
                min(
                    from.maxX - from.width * corner,
                    to.maxX - to.width * corner))
            if low <= high {
                let x = (low + high) / 2
                let below = to.midY > from.midY
                return (
                    CGPoint(x: x, y: below ? from.maxY : from.minY),
                    CGPoint(x: x, y: below ? to.minY : to.maxY),
                    false, false
                )  // leaves by the top or the bottom, so the flow is down the page
            }
        }
        if sharedY > 0, sharedX <= 0 {
            let low = max(
                max(from.minY, to.minY),
                max(
                    from.minY + from.height * corner,
                    to.minY + to.height * corner))
            let high = min(
                min(from.maxY, to.maxY),
                min(
                    from.maxY - from.height * corner,
                    to.maxY - to.height * corner))
            if low <= high {
                let y = (low + high) / 2
                let right = to.midX > from.midX
                return (
                    CGPoint(x: right ? from.maxX : from.minX, y: y),
                    CGPoint(x: right ? to.minX : to.maxX, y: y),
                    false, true
                )  // leaves by a left or right side, so the flow is across
            }
        }
        let acrossX = max(to.minX - from.maxX, from.minX - to.maxX)
        let acrossY = max(to.minY - from.maxY, from.minY - to.maxY)
        if acrossX >= acrossY {
            let right = to.midX > from.midX
            return (
                CGPoint(x: right ? from.maxX : from.minX, y: from.midY),
                CGPoint(x: right ? to.minX : to.maxX, y: to.midY),
                true, true
            )
        }
        let below = to.midY > from.midY
        return (
            CGPoint(x: from.midX, y: below ? from.maxY : from.minY),
            CGPoint(x: to.midX, y: below ? to.minY : to.maxY),
            true, false
        )
    }

    /// A run of points along a cubic, for a line that leaves one box straight
    /// and arrives at the next straight with a single turn in between.
    private static func samples(
        from start: CGPoint, out first: CGPoint, in second: CGPoint, to end: CGPoint
    ) -> [CGPoint] {
        let steps = 24
        return (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            let u = 1 - t
            return CGPoint(
                x: u * u * u * start.x + 3 * u * u * t * first.x + 3 * u * t * t * second.x + t * t
                    * t * end.x,
                y: u * u * u * start.y + 3 * u * u * t * first.y + 3 * u * t * t * second.y + t * t
                    * t * end.y
            )
        }
    }

    /// A dashed line as a path of short segments: `Decoration` has no dash
    /// pattern, and one more case would have to be honoured by every renderer.
    private static func dashed(from: CGPoint, to: CGPoint, dash: CGFloat, gap: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let span = CGPoint(x: to.x - from.x, y: to.y - from.y)
        let length = (span.x * span.x + span.y * span.y).squareRoot()
        guard length > 0 else { return path }
        let step = CGPoint(x: span.x / length, y: span.y / length)
        var travelled: CGFloat = 0
        while travelled < length {
            let end = min(length, travelled + dash)
            path.move(to: CGPoint(x: from.x + step.x * travelled, y: from.y + step.y * travelled))
            path.addLine(to: CGPoint(x: from.x + step.x * end, y: from.y + step.y * end))
            travelled = end + gap
        }
        return path
    }

    private static func distance(_ from: CGPoint, _ to: CGPoint) -> CGFloat {
        let span = CGPoint(x: to.x - from.x, y: to.y - from.y)
        return (span.x * span.x + span.y * span.y).squareRoot()
    }

    private static func normalized(_ point: CGPoint) -> CGPoint {
        let length = (point.x * point.x + point.y * point.y).squareRoot()
        guard length > 0 else { return CGPoint(x: 0, y: 1) }
        return CGPoint(x: point.x / length, y: point.y / length)
    }

    // MARK: - Radar

    /// A spoke per axis and a closed shape per curve.
    private static func radar(
        _ chart: RadarChart, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.controlLabel, by: metrics.scale)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale)
        let names = chart.axes.map { text($0, font: font, color: theme.palette.secondaryText) }
        let nameSizes = names.map(measure)
        let widest = nameSizes.map(\.width).max() ?? 0
        let radius = 130 * metrics.scale
        // The names stand outside the outer ring, so the picture is wider than
        // the circle by the longest of them on either side.
        let content = (radius + widest + 14 * metrics.scale) * 2
        let centre = CGPoint(x: max(metrics.padding, (width - content) / 2) + content / 2, y: 0)

        var decorations: [BlockBox.Decoration] = []
        var top = metrics.padding
        if !chart.title.isEmpty {
            let line = text(chart.title, font: titleFont, color: theme.palette.text)
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: centre.x - size.width / 2, y: top + size.height - descent(line))
                ))
            top += size.height + 12 * metrics.scale
        }
        let middle = CGPoint(x: centre.x, y: top + radius + nameSizes[0].height)

        func point(axis: Int, at fraction: CGFloat) -> CGPoint {
            let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(axis) / CGFloat(chart.axes.count)
            return CGPoint(
                x: middle.x + cos(angle) * radius * fraction,
                y: middle.y + sin(angle) * radius * fraction)
        }

        // The rings, then the spokes, then the curves on top of both.
        for tick in stride(from: 1, through: chart.ticks, by: 1) {
            let fraction = CGFloat(tick) / CGFloat(chart.ticks)
            let ring = CGMutablePath()
            if chart.polygon {
                for axis in chart.axes.indices {
                    let at = point(axis: axis, at: fraction)
                    if axis == 0 { ring.move(to: at) } else { ring.addLine(to: at) }
                }
                ring.closeSubpath()
            } else {
                ring.addEllipse(
                    in: CGRect(
                        x: middle.x - radius * fraction, y: middle.y - radius * fraction,
                        width: radius * fraction * 2, height: radius * fraction * 2))
            }
            decorations.append(
                .path(ring, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
        }
        let spokes = CGMutablePath()
        for axis in chart.axes.indices {
            spokes.move(to: middle)
            spokes.addLine(to: point(axis: axis, at: 1))
        }
        decorations.append(
            .path(spokes, color: theme.palette.tableBorder, lineWidth: 1, filled: false))

        let outer = chart.high ?? 1
        let span = outer - chart.low
        for (index, curve) in chart.curves.enumerated() {
            let shape = CGMutablePath()
            for (axis, value) in curve.values.enumerated() {
                let fraction = max(0, min(1, CGFloat((value - chart.low) / span)))
                let at = point(axis: axis, at: fraction)
                if axis == 0 { shape.move(to: at) } else { shape.addLine(to: at) }
            }
            shape.closeSubpath()
            let colour = theme.diagramWheel[index % theme.diagramWheel.count]
            decorations.append(
                .path(shape, color: colour.copy(alpha: 0.22) ?? colour, lineWidth: 0, filled: true))
            decorations.append(
                .path(shape, color: colour, lineWidth: 2 * metrics.scale, filled: false))
        }

        // Each axis is named just outside its own tip, pulled towards whichever
        // side of the circle it is on so the words never cross the drawing.
        for (axis, line) in names.enumerated() {
            let tip = point(axis: axis, at: 1)
            let size = nameSizes[axis]
            let away = CGPoint(x: tip.x - middle.x, y: tip.y - middle.y)
            let anchor = CGPoint(
                x: tip.x
                    + (away.x > 1
                        ? 6 * metrics.scale
                        : away.x < -1 ? -6 * metrics.scale - size.width : -size.width / 2),
                y: tip.y
                    + (away.y > 1
                        ? size.height : away.y < -1 ? -3 * metrics.scale : size.height / 2)
            )
            decorations.append(
                .glyphs(line, origin: CGPoint(x: anchor.x, y: anchor.y - descent(line))))
        }

        var height = middle.y + radius + nameSizes[0].height + metrics.padding
        if chart.showLegend {
            var y = height
            let swatch = 10 * metrics.scale
            // Every entry starts at the same edge, so the swatches make a column
            // rather than a ragged stack of centred rows.
            let entries = chart.curves.map { text($0.label, font: font, color: theme.palette.text) }
            let entryWidth = entries.map { measure($0).width }.max() ?? 0
            let start = middle.x - (entryWidth + swatch + 6 * metrics.scale) / 2
            for (index, line) in entries.enumerated() {
                let size = measure(line)
                let box = CGRect(x: start, y: y, width: swatch, height: swatch)
                decorations.append(
                    .fill(
                        rect: box, color: theme.diagramWheel[index % theme.diagramWheel.count],
                        cornerRadius: 2))
                decorations.append(
                    .glyphs(
                        line,
                        origin: CGPoint(
                            x: box.maxX + 6 * metrics.scale, y: y + size.height - descent(line))))
                y += max(swatch, size.height) + 4 * metrics.scale
            }
            height = y + metrics.padding
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    // MARK: - Block diagram

    /// Cells filling a grid of a stated width, with arrows between them.
    private static func blocks(
        _ diagram: BlockDiagram, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale)
        var labels: [(lines: [CTLine], size: CGSize)] = []
        for node in diagram.chart.nodes {
            let colour = faded(node.style.text.map(cgColor) ?? theme.palette.text, by: node.style)
            labels.append(labelLines(node.label, font: font, color: colour))
        }
        // Every column is the same width: a grid whose columns drifted would
        // stop being the grid the author counted out.
        let cellWidth = max(
            metrics.minimumNodeWidth,
            (labels.map(\.size.width).max() ?? 0) + metrics.nodePaddingX * 2)
        let cellHeight = (labels.map(\.size.height).max() ?? 0) + metrics.nodePaddingY * 2
        var gap = 10 * metrics.scale
        // A frame stands this far out from what it holds however wide the gaps
        // grow: the room a walked line needs is the line's, not the frame's.
        let framing = gap / 2
        // A framed block holds a row of its own, so the grid is measured in the
        // narrowest column any of them needs and a plain cell takes several of
        // them. The author's own column count still says where a row wraps.
        let unit = max(1, diagram.cells.map { columnsWide(of: $0, in: diagram) }.max() ?? 1)
        let columns = diagram.columns * unit
        var content: CGFloat = 0
        var left: CGFloat = 0

        // Cells fill the row until the next one would not fit, and then wrap. A
        // framed block is laid out the same way inside its own share of the
        // grid, so a block inside a block is one more turn of the same routine.
        var boxes: [Int: Placed] = [:]
        var frames: [Int: CGRect] = [:]
        func rect(column: Int, row: Int, wide: Int, tall: Int) -> CGRect {
            CGRect(
                x: left + CGFloat(column) * (cellWidth + gap),
                y: metrics.padding + CGFloat(row) * (cellHeight + gap),
                width: cellWidth * CGFloat(wide) + gap * CGFloat(wide - 1),
                height: cellHeight * CGFloat(tall) + gap * CGFloat(tall - 1))
        }
        /// Lays a container's cells out from a corner of the grid, and says how
        /// many rows it took.
        func place(
            _ cells: [BlockDiagram.Cell], columns: Int, atColumn: Int, atRow: Int, unit: Int
        ) -> Int {
            var column = 0
            var row = 0
            for cell in cells {
                let wide = min(
                    cell.block == nil
                        ? cell.span * unit : columnsWide(of: cell, in: diagram), columns)
                if column + wide > columns {
                    column = 0
                    row += 1
                }
                let tall = rowsTall(of: cell, in: diagram)
                if let node = cell.node {
                    var frame = rect(
                        column: atColumn + column, row: atRow + row, wide: wide, tall: tall)
                    // A fat arrow keeps its own girth: stretched across a whole
                    // row it would read as a band rather than an arrow.
                    switch diagram.chart.nodes[node].shape {
                    case .blockArrow(let up, let down, let left, let right)
                    where (up || down) && !left && !right:
                        let side = min(frame.width, frame.height * 1.6)
                        frame = CGRect(
                            x: frame.midX - side / 2, y: frame.minY, width: side,
                            height: frame.height)
                    default:
                        break
                    }
                    boxes[node] = Placed(
                        frame: frame,
                        lines: labels[node].lines, labelSize: labels[node].size,
                        shape: diagram.chart.nodes[node].shape,
                        style: diagram.chart.nodes[node].style)
                } else if let block = cell.block {
                    let inner = diagram.blocks[block]
                    frames[block] = rect(
                        column: atColumn + column, row: atRow + row, wide: wide, tall: tall
                    )
                    .insetBy(dx: -framing, dy: -framing)
                    _ = place(
                        inner.cells, columns: inner.columns ?? wide, atColumn: atColumn + column,
                        atRow: atRow + row, unit: 1)
                }
                column += wide
                if column >= columns {
                    column = 0
                    row += 1
                }
            }
            return column == 0 ? row : row + 1
        }
        func arrange() -> Int {
            boxes = [:]
            frames = [:]
            content = cellWidth * CGFloat(columns) + gap * CGFloat(columns - 1)
            left = max(metrics.padding, (width - content) / 2)
            return place(diagram.cells, columns: columns, atColumn: 0, atRow: 0, unit: unit)
        }
        var rows = arrange()

        func end(_ end: Flowchart.End) -> CGRect? {
            switch end {
            case .node(let node): return boxes[node]?.frame
            case .frame(let block): return frames[block]
            }
        }
        // Boxes stand where the author counted them out, so a line between two
        // that are not neighbours may have one in its way. Then every line is
        // walked through the gaps of the grid — all of them, so lines meeting
        // one side of a box share it out between them — and the gaps are
        // widened to hold the end marks and the words. A diagram where nothing
        // is in any line's way joins its boxes directly, as before.
        let wordFont = scaled(theme.controlLabel, by: metrics.scale)
        let stub = metrics.arrowLength + 4 * metrics.scale
        let spacing = 8 * metrics.scale
        func obstacles() -> [CGRect] {
            diagram.chart.nodes.indices.compactMap { boxes[$0]?.frame }
                + diagram.blocks.indices.compactMap { frames[$0] }
        }
        func exempt(_ from: CGRect, _ to: CGRect, in all: [CGRect]) -> Set<Int> {
            let firstFrame = all.count - diagram.blocks.indices.compactMap { frames[$0] }.count
            return Set(
                all.indices.filter { index in
                    index >= firstFrame && all[index] != from && all[index] != to
                        && (all[index].contains(from) || all[index].contains(to))
                })
        }
        let walkable = diagram.chart.edges.indices.filter { index in
            let edge = diagram.chart.edges[index]
            return edge.stroke != .invisible && edge.from != edge.to && end(edge.from) != nil
                && end(edge.to) != nil
        }
        let blocked = walkable.contains { index in
            let edge = diagram.chart.edges[index]
            guard let from = end(edge.from), let to = end(edge.to) else { return false }
            let all = obstacles()
            let free = exempt(from, to, in: all)
            let path = connection(from: from, to: to, metrics: metrics)
            return all.indices.contains { index in
                guard !free.contains(index), all[index] != from, all[index] != to,
                    !all[index].contains(from), !all[index].contains(to)
                else { return false }
                let inner = all[index].insetBy(dx: 2, dy: 2)
                return zip(path, path.dropFirst()).contains { a, b in
                    CGRect(
                        x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x),
                        height: abs(a.y - b.y)
                    ).intersects(inner)
                }
            }
        }
        let detoured = blocked ? walkable : []
        let wordsHigh =
            detoured.map {
                edgeWords(diagram.chart.edges[$0].label, font: wordFont, color: theme.palette.text)
                    .size.height
            }.max() ?? 0
        var routes: [Int: [CGPoint]] = [:]
        func detour() -> Int {
            let all = obstacles()
            let lines = detoured.compactMap { index -> GridRouter.Line? in
                let edge = diagram.chart.edges[index]
                guard let from = end(edge.from), let to = end(edge.to) else { return nil }
                return GridRouter.Line(from: from, to: to, exempt: exempt(from, to, in: all))
            }
            let found = GridRouter.route(
                lines, obstacles: all, margin: gap / 2 + spacing, spacing: spacing, stub: stub,
                bend: cellHeight)
            routes = [:]
            for (index, route) in zip(detoured, found.routes) { routes[index] = route }
            return found.tracks
        }
        if !detoured.isEmpty {
            func needed(_ tracks: Int) -> CGFloat {
                max(
                    gap, 2 * stub + CGFloat(tracks - 1) * spacing,
                    wordsHigh + 8 * metrics.scale)
            }
            gap = needed(1)
            rows = arrange()
            let wider = needed(detour())
            if wider > gap + 0.5 {
                gap = wider
                rows = arrange()
                _ = detour()
            }
        }
        let height =
            metrics.padding * 2 + CGFloat(rows) * cellHeight + CGFloat(max(0, rows - 1)) * gap

        var decorations: [BlockBox.Decoration] = []
        var labelDecorations: [BlockBox.Decoration] = []
        // A frame first: everything written inside it stands on top of it.
        for block in diagram.blocks.indices.sorted(by: {
            depth(of: $0, in: diagram) < depth(of: $1, in: diagram)
        }) {
            guard let frame = frames[block] else { continue }
            let path = CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil)
            decorations.append(
                .path(path, color: theme.palette.codeBackground, lineWidth: 0, filled: true))
            decorations.append(
                .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
        }
        var geometry = Geometry(
            nodes: diagram.chart.nodes.indices.map { boxes[$0]?.frame ?? .zero },
            frames: diagram.blocks.indices.compactMap { frames[$0] })
        // The boxes a line may touch: its own ends, and whatever stands inside
        // a frame it ends on.
        func owned(_ end: Flowchart.End) -> [Int] {
            switch end {
            case .node(let node): return [node]
            case .frame(let block):
                guard let frame = frames[block] else { return [] }
                return boxes.filter { frame.contains($0.value.frame) }.map(\.key)
            }
        }
        for (index, edge) in diagram.chart.edges.enumerated() {
            guard let from = end(edge.from), let to = end(edge.to) else { continue }
            // A walked line carries its words where they cover the fewest
            // boxes and other lines — slid along any of its runs, level runs
            // first, since those lie along a gap rather than across one.
            let route = routes[index]
            var wordsAt: CGRect?
            if let route, !edge.label.isEmpty {
                let size = edgeWords(edge.label, font: wordFont, color: theme.palette.text).size
                let others = routes.filter { $0.key != index }.values.flatMap {
                    zip($0, $0.dropFirst()).map { a, b in
                        CGRect(
                            x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x),
                            height: abs(a.y - b.y))
                    }
                }
                let cells = boxes.values.map(\.frame)
                let borders = frames.values
                var best: (score: (Int, Int, CGFloat), place: CGRect)?
                for (a, b) in zip(route, route.dropFirst()) {
                    let level = abs(a.y - b.y) < 0.01
                    let length = hypot(b.x - a.x, b.y - a.y)
                    let extent = (level ? size.width : size.height) + 8 * metrics.scale
                    let room = max(0, length - extent)
                    let steps = Int(room / (8 * metrics.scale))
                    for step in 0...steps {
                        let t =
                            steps == 0
                            ? 0.5 : (extent / 2 + room * CGFloat(step) / CGFloat(steps)) / length
                        let place = plate(
                            size,
                            centred: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                        let inner = place.insetBy(dx: 1, dy: 1)
                        // Inside a frame is fine; across its border is not.
                        let covered =
                            cells.filter { $0.intersects(inner) }.count
                            + borders.filter { $0.intersects(inner) && !$0.contains(inner) }.count
                            + others.filter { $0.intersects(inner) }.count
                        let score = (covered, level ? 0 : 1, -length)
                        if best.map({ score < $0.score }) ?? true { best = (score, place) }
                    }
                }
                wordsAt = best?.place
            }
            let drawn = self.edge(
                edge, from: from, to: to, theme: theme, metrics: metrics, route: route,
                wordsAt: wordsAt)
            decorations += drawn.shaft
            labelDecorations += drawn.label
            if !drawn.path.isEmpty {
                geometry.lines.append(
                    Geometry.Line(
                        points: drawn.path, label: drawn.plate,
                        ends: Set(owned(edge.from) + owned(edge.to)).sorted(),
                        loop: edge.from == edge.to))
            }
        }
        for index in diagram.chart.nodes.indices {
            guard let box = boxes[index] else { continue }
            decorations += node(box, theme: theme, metrics: metrics)
        }
        return Drawing(
            decorations: decorations + labelDecorations,
            size: CGSize(width: width, height: height),
            contentWidth: content,
            geometry: geometry
        )
    }

    /// How many columns of the grid a cell takes: its own span, or, for a framed
    /// block, as many as the widest row written inside it.
    private static func columnsWide(of cell: BlockDiagram.Cell, in diagram: BlockDiagram) -> Int {
        guard let block = cell.block else { return cell.span }
        let inner = diagram.blocks[block]
        let total = inner.cells.reduce(0) { $0 + columnsWide(of: $1, in: diagram) }
        return max(1, min(total, inner.columns ?? total))
    }

    /// How many rows of the grid a cell takes: one, or, for a framed block, as
    /// many as its own cells wrap into.
    private static func rowsTall(of cell: BlockDiagram.Cell, in diagram: BlockDiagram) -> Int {
        guard let block = cell.block else { return 1 }
        let inner = diagram.blocks[block]
        let columns =
            inner.columns ?? inner.cells.reduce(0) { $0 + columnsWide(of: $1, in: diagram) }
        guard columns > 0 else { return 1 }
        var column = 0
        var rows = 0
        var tallest = 1
        for cell in inner.cells {
            let wide = min(columnsWide(of: cell, in: diagram), columns)
            if column + wide > columns {
                column = 0
                rows += tallest
                tallest = 1
            }
            tallest = max(tallest, rowsTall(of: cell, in: diagram))
            column += wide
            if column >= columns {
                column = 0
                rows += tallest
                tallest = 1
            }
        }
        return max(1, column == 0 ? rows : rows + tallest)
    }

    /// How many frames a block stands inside, so the outermost is drawn first.
    private static func depth(of block: Int, in diagram: BlockDiagram) -> Int {
        var depth = 0
        var walk = block
        var steps = 0
        while steps <= diagram.blocks.count {
            guard
                let holder = diagram.blocks.firstIndex(where: { candidate in
                    candidate.cells.contains { $0.block == walk }
                })
            else { return depth }
            depth += 1
            walk = holder
            steps += 1
        }
        return depth
    }

    // MARK: - Architecture

    /// Services on the grid their edges put them on, framed by group.
    ///
    /// The parser has already worked out which cell each service sits in, so
    /// what is left here is turning cells into rectangles: a column is as wide
    /// as its widest tile, a row as tall as its tallest, and the gaps are wide
    /// enough for a group's frame to stand in without touching its neighbours.
    private static func architecture(
        _ diagram: ArchitectureDiagram, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.controlLabel, by: metrics.scale)
        let iconSide = 30 * metrics.scale
        let tilePadding = 8 * metrics.scale
        let columnGap = 56 * metrics.scale
        let rowGap = 52 * metrics.scale
        let framePadding = 12 * metrics.scale

        let labels = diagram.services.map { text($0.label, font: font, color: theme.palette.text) }
        let sizes = labels.map(measure)
        var tiles = diagram.services.indices.map { index -> CGRect in
            // A junction is a corner rather than a thing: it takes a cell so the
            // lines meeting there have somewhere to meet, and nothing is drawn.
            guard diagram.services[index].icon != .junction else {
                return CGRect(x: 0, y: 0, width: 2 * metrics.scale, height: 2 * metrics.scale)
            }
            return CGRect(
                x: 0, y: 0,
                width: max(iconSide, sizes[index].width) + tilePadding * 2,
                height: iconSide + 5 * metrics.scale + sizes[index].height + tilePadding * 2)
        }

        let titles = diagram.groups.map {
            text($0.label, font: font, color: theme.palette.secondaryText)
        }
        let titleRoom = (titles.map { measure($0).height }.max() ?? 0) + 5 * metrics.scale

        let columns = (diagram.services.map(\.column).max() ?? 0) + 1
        let rows = (diagram.services.map(\.row).max() ?? 0) + 1
        var columnWidths = [CGFloat](repeating: 0, count: columns)
        var rowHeights = [CGFloat](repeating: 0, count: rows)
        for (index, service) in diagram.services.enumerated() {
            columnWidths[service.column] = max(columnWidths[service.column], tiles[index].width)
            rowHeights[service.row] = max(rowHeights[service.row], tiles[index].height)
        }
        // A group's frame stands outside its tiles and carries its name above
        // them. Without that room the frame — and the name with it — is drawn
        // off the top of the picture, and a group inside a group needs a strip
        // for every frame between it and the outside.
        let levels =
            diagram.groups.isEmpty
            ? 0 : (diagram.groups.indices.map { diagram.depth(of: $0) }.max() ?? 0) + 1
        let frameRoom = CGFloat(levels) * (titleRoom + framePadding)
        let content =
            columnWidths.reduce(0, +) + columnGap * CGFloat(columns - 1)
            + CGFloat(levels) * framePadding * 2
        let height =
            rowHeights.reduce(0, +) + rowGap * CGFloat(rows - 1) + metrics.padding * 2
            + frameRoom + CGFloat(levels) * framePadding
        let left = max(metrics.padding, (width - content) / 2)

        var columnStarts = [CGFloat](repeating: 0, count: columns)
        var x = left
        for column in 0..<columns {
            columnStarts[column] = x
            x += columnWidths[column] + columnGap
        }
        var rowStarts = [CGFloat](repeating: 0, count: rows)
        var y = metrics.padding + frameRoom
        for row in 0..<rows {
            rowStarts[row] = y
            y += rowHeights[row] + rowGap
        }
        for (index, service) in diagram.services.enumerated() {
            tiles[index].origin = CGPoint(
                x: columnStarts[service.column]
                    + (columnWidths[service.column] - tiles[index].width) / 2,
                y: rowStarts[service.row] + (rowHeights[service.row] - tiles[index].height) / 2)
        }

        var decorations: [BlockBox.Decoration] = []
        // Frames first, and the outermost first of all, so a group inside a
        // group is drawn over the one that holds it rather than under it.
        for group in diagram.groups.indices.sorted(by: {
            diagram.depth(of: $0) < diagram.depth(of: $1)
        }) {
            let members = diagram.members(of: group)
            guard let first = members.first else { continue }
            // A frame inside a frame stands in from the one around it, and its
            // own name needs the room above its tiles that the outer one took.
            let outward = CGFloat(levels - diagram.depth(of: group))
            var bounds = tiles[first]
            for member in members.dropFirst() { bounds = bounds.union(tiles[member]) }
            bounds = bounds.insetBy(dx: -framePadding * outward, dy: -framePadding * outward)
            bounds.origin.y -= titleRoom * outward
            bounds.size.height += titleRoom * outward
            let path = CGPath(
                roundedRect: bounds, cornerWidth: 6 * metrics.scale,
                cornerHeight: 6 * metrics.scale, transform: nil)
            decorations.append(
                .path(path, color: theme.palette.codeBackground, lineWidth: 0, filled: true))
            decorations.append(
                .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
            let title = titles[group]
            let size = measure(title)
            let badge = CGRect(
                x: bounds.minX + 6 * metrics.scale, y: bounds.minY + 4 * metrics.scale,
                width: size.height, height: size.height)
            decorations += icon(diagram.groups[group].icon, in: badge, theme: theme)
            decorations.append(
                .glyphs(
                    title,
                    origin: CGPoint(
                        x: badge.maxX + 5 * metrics.scale, y: badge.maxY - descent(title))))
        }

        for (index, service) in diagram.services.enumerated() where service.icon != .junction {
            let tile = tiles[index]
            let path = CGPath(
                roundedRect: tile, cornerWidth: 6 * metrics.scale,
                cornerHeight: 6 * metrics.scale, transform: nil)
            decorations.append(
                .path(
                    path, color: theme.palette.tableHeaderBackground, lineWidth: 0, filled: true))
            decorations.append(
                .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
            decorations += icon(
                service.icon,
                in: CGRect(
                    x: tile.midX - iconSide / 2, y: tile.minY + tilePadding, width: iconSide,
                    height: iconSide),
                theme: theme)
            decorations.append(
                .glyphs(
                    labels[index],
                    origin: CGPoint(
                        x: tile.midX - sizes[index].width / 2,
                        y: tile.maxY - tilePadding - descent(labels[index]))))
        }

        let stub = 14 * metrics.scale
        for edge in diagram.edges {
            let start = anchor(of: tiles[edge.from], on: edge.fromSide)
            let end = anchor(of: tiles[edge.to], on: edge.toSide)
            let out = outward(edge.fromSide)
            let back = outward(edge.toSide)
            let first = CGPoint(x: start.x + out.x * stub, y: start.y + out.y * stub)
            let last = CGPoint(x: end.x + back.x * stub, y: end.y + back.y * stub)
            let route = CGMutablePath()
            route.move(to: start)
            route.addLine(to: first)
            // The elbow turns away from the side the line left by, so a stub
            // never doubles back over the tile it just came out of.
            let elbow =
                out.x != 0
                ? CGPoint(x: last.x, y: first.y) : CGPoint(x: first.x, y: last.y)
            route.addLine(to: elbow)
            route.addLine(to: last)
            route.addLine(to: end)
            decorations.append(
                .path(
                    route, color: theme.palette.tableBorder, lineWidth: 1.5 * metrics.scale,
                    filled: false))
            if edge.toArrow {
                decorations.append(
                    arrowHead(
                        at: end, direction: CGPoint(x: -back.x, y: -back.y),
                        color: theme.palette.tableBorder, metrics: metrics))
            }
            if edge.fromArrow {
                decorations.append(
                    arrowHead(
                        at: start, direction: CGPoint(x: -out.x, y: -out.y),
                        color: theme.palette.tableBorder, metrics: metrics))
            }
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    /// The middle of the named side of a tile.
    private static func anchor(of tile: CGRect, on side: ArchitectureDiagram.Side) -> CGPoint {
        switch side {
        case .left: return CGPoint(x: tile.minX, y: tile.midY)
        case .right: return CGPoint(x: tile.maxX, y: tile.midY)
        case .top: return CGPoint(x: tile.midX, y: tile.minY)
        case .bottom: return CGPoint(x: tile.midX, y: tile.maxY)
        }
    }

    /// Which way is away from the tile at that side. The renderer's y grows
    /// down, so the top side points at a smaller y.
    private static func outward(_ side: ArchitectureDiagram.Side) -> CGPoint {
        switch side {
        case .left: return CGPoint(x: -1, y: 0)
        case .right: return CGPoint(x: 1, y: 0)
        case .top: return CGPoint(x: 0, y: -1)
        case .bottom: return CGPoint(x: 0, y: 1)
        }
    }

    /// One of the five shapes Mermaid ships, drawn as a filled silhouette with
    /// its detail cut back out in the page's own colour.
    private static func icon(
        _ kind: ArchitectureDiagram.Icon, in rect: CGRect, theme: Theme
    ) -> [BlockBox.Decoration] {
        let colours: [ArchitectureDiagram.Icon: Int] = [
            .cloud: 0, .database: 1, .disk: 2, .internet: 3, .server: 4,
        ]
        // Every icon is drawn in one ink. A colour per kind would say something
        // about the thing it stands for that its author never wrote down.
        _ = colours
        let ink = theme.diagramWheel[0]
        let cut = theme.palette.background
        let body = CGMutablePath()
        var detail: CGPath?
        /// What is cut out of the body rather than drawn on it: the dots on a
        /// rack's shelves, the spindle of a disk.
        var cutouts: CGPath?
        switch kind {
        case .junction:
            // A junction is a corner where lines meet; the picture of it is the
            // lines themselves.
            return []
        case .unknown:
            // An icon out of a pack nobody registered, which Mermaid draws as a
            // question mark and so does this.
            body.addRoundedRect(
                in: rect, cornerWidth: rect.width * 0.12, cornerHeight: rect.width * 0.12)
            let mark = text(
                "?",
                font: CTFontCreateWithName(
                    "Helvetica-Bold" as CFString, rect.height * 0.7, nil), color: cut)
            let size = measure(mark)
            return [
                .path(body, color: ink, lineWidth: 0, filled: true),
                .glyphs(
                    mark,
                    origin: CGPoint(
                        x: rect.midX - size.width / 2,
                        y: rect.midY + size.height / 2 - descent(mark))),
            ]
        case .server:
            // A rack: three shelves, each with its lamp at the left, which is
            // the picture everyone draws a server as.
            body.addRoundedRect(
                in: rect.insetBy(dx: rect.width * 0.04, dy: 0), cornerWidth: rect.width * 0.08,
                cornerHeight: rect.width * 0.08)
            let shelves = CGMutablePath()
            let lamps = CGMutablePath()
            let left = rect.minX + rect.width * 0.17
            let right = rect.maxX - rect.width * 0.17
            let tall = rect.height * 0.19
            let dot = rect.width * 0.035
            for share in [0.15, 0.405, 0.66] as [CGFloat] {
                let top = rect.minY + rect.height * share
                shelves.addRect(CGRect(x: left, y: top, width: right - left, height: tall))
                for step in [0, 1, 2] as [CGFloat] {
                    lamps.addEllipse(
                        in: CGRect(
                            x: left + rect.width * 0.07 + step * dot * 3 - dot,
                            y: top + tall / 2 - dot, width: dot * 2, height: dot * 2))
                }
            }
            detail = shelves
            cutouts = lamps
        case .disk:
            // A hard drive: the case, the platter inside it and the spindle it
            // turns on.
            body.addRoundedRect(
                in: rect, cornerWidth: rect.width * 0.1, cornerHeight: rect.width * 0.1)
            let platter = CGMutablePath()
            platter.addEllipse(in: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2))
            let arm = CGMutablePath()
            arm.move(to: CGPoint(x: rect.midX, y: rect.midY))
            arm.addLine(
                to: CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.maxY - rect.height * 0.16))
            platter.addPath(arm)
            detail = platter
            let spindle = rect.width * 0.07
            cutouts = CGPath(
                ellipseIn: CGRect(
                    x: rect.midX - spindle, y: rect.midY - spindle, width: spindle * 2,
                    height: spindle * 2), transform: nil)
        case .database:
            // A cylinder seen from the side: a lid, two walls and a curved foot.
            let lid = rect.height * 0.26
            body.move(to: CGPoint(x: rect.minX, y: rect.minY + lid / 2))
            body.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - lid / 2))
            body.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY - lid / 2),
                control1: CGPoint(x: rect.minX, y: rect.maxY + lid / 2),
                control2: CGPoint(x: rect.maxX, y: rect.maxY + lid / 2))
            body.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + lid / 2))
            body.addEllipse(
                in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lid))
            let seam = CGMutablePath()
            seam.addEllipse(
                in: CGRect(
                    x: rect.minX + rect.width * 0.14, y: rect.minY + lid * 0.28,
                    width: rect.width * 0.72, height: lid * 0.5))
            detail = seam
        case .cloud:
            let base = rect.minY + rect.height * 0.78
            body.addRoundedRect(
                in: CGRect(
                    x: rect.minX, y: base - rect.height * 0.24, width: rect.width,
                    height: rect.height * 0.24),
                cornerWidth: rect.height * 0.12, cornerHeight: rect.height * 0.12)
            for bump in [(0.24, 0.50, 0.20), (0.50, 0.38, 0.26), (0.75, 0.52, 0.18)]
                as [(CGFloat, CGFloat, CGFloat)]
            {
                let radius = rect.width * bump.2
                body.addEllipse(
                    in: CGRect(
                        x: rect.minX + rect.width * bump.0 - radius,
                        y: rect.minY + rect.height * bump.1 - radius,
                        width: radius * 2, height: radius * 2))
            }
        case .internet:
            body.addEllipse(in: rect)
            let meridians = CGMutablePath()
            meridians.addEllipse(in: rect.insetBy(dx: rect.width * 0.32, dy: 0))
            meridians.move(to: CGPoint(x: rect.minX, y: rect.midY))
            meridians.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            detail = meridians
        }
        var decorations: [BlockBox.Decoration] = [
            .path(body, color: ink, lineWidth: 0, filled: true)
        ]
        if let detail {
            decorations.append(
                .path(detail, color: cut, lineWidth: max(1, rect.width * 0.06), filled: false))
        }
        if let cutouts {
            decorations.append(.path(cutouts, color: cut, lineWidth: 0, filled: true))
        }
        return decorations
    }

    // MARK: - Text

    private static func scaled(_ font: CTFont, by scale: CGFloat) -> CTFont {
        guard scale != 1 else { return font }
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil)
    }

    /// A comment's words split into runs, each with whether it is emphasised.
    ///
    /// ZenUML renders Markdown inside a comment, and `**bold**` is the part of
    /// it a reader would miss: printed as written, the stars are noise, and
    /// dropped without a change of weight the author's emphasis is gone. A
    /// marker nobody closed is not emphasis, so the words are left as typed.
    private static func emphasised(_ words: String) -> [(bold: Bool, run: String)] {
        let parts = words.components(separatedBy: "**")
        guard parts.count > 2, parts.count % 2 == 1 else { return [(false, words)] }
        return parts.enumerated().map { (index, part) in (index % 2 == 1, part) }
    }

    /// One line of markdown: `**bold**`, `*italic*` and `_italic_` written in
    /// the face each asks for, and everything else in the face it was given.
    private static func marked(_ string: String, font: CTFont, color: CGColor) -> CTLine {
        var runs: [(text: String, bold: Bool, italic: Bool)] = []
        var current = ""
        var bold = false
        var italic = false
        var index = string.startIndex
        func close() {
            guard !current.isEmpty else { return }
            runs.append((current, bold, italic))
            current = ""
        }
        while index < string.endIndex {
            let rest = string[index...]
            if rest.hasPrefix("**") {
                close()
                bold.toggle()
                index = string.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("*") || rest.hasPrefix("_") {
                close()
                italic.toggle()
                index = string.index(after: index)
                continue
            }
            current.append(string[index])
            index = string.index(after: index)
        }
        close()
        let written = NSMutableAttributedString()
        for run in runs {
            written.append(
                NSAttributedString(
                    string: run.text,
                    attributes: [
                        AttributedBuilder.fontKey: face(font, bold: run.bold, italic: run.italic),
                        AttributedBuilder.colorKey: color,
                    ]))
        }
        return CTLineCreateWithAttributedString(written)
    }

    /// The same face, asked to stand up or lean over.
    private static func face(_ font: CTFont, bold: Bool, italic: Bool) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return font }
        if let asked = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits),
            CTFontCopyPostScriptName(asked) != CTFontCopyPostScriptName(font)
        {
            return asked
        }
        // The system face at a set weight will not be turned by traits at all —
        // the label fonts are made that way — so the bold one is asked for by
        // weight instead, and the lean is put on top of it.
        let size = CTFontGetSize(font)
        let heavy = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular) as CTFont
        guard italic else { return heavy }
        return CTFontCreateCopyWithSymbolicTraits(heavy, 0, nil, .traitItalic, .traitItalic)
            ?? heavy
    }

    private static func text(_ string: String, font: CTFont, color: CGColor) -> CTLine {
        // Words written between backticks are markdown wherever they stand — a
        // node's name, an edge's, a frame's — so they are read as markdown here
        // rather than at each of those places.
        if string.count >= 2, string.hasPrefix("`"), string.hasSuffix("`") {
            return marked(String(string.dropFirst().dropLast()), font: font, color: color)
        }
        return CTLineCreateWithAttributedString(
            NSAttributedString(
                string: string,
                attributes: [
                    AttributedBuilder.fontKey: font,
                    AttributedBuilder.colorKey: color,
                ]
            )
        )
    }

    private static func measure(_ line: CTLine) -> CGSize {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return CGSize(width: width, height: ascent + descent)
    }

    private static func descent(_ line: CTLine) -> CGFloat {
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, nil, &descent, nil)
        return descent
    }
}

extension CGRect {
    fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}
