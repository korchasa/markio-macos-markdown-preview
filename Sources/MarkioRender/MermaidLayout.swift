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

    static func draw(_ diagram: MermaidDiagram, theme: Theme, width: CGFloat) -> Drawing {
        let first = settled(
            draw(diagram, theme: theme, width: width, metrics: Metrics()), width: width)
        let room = width - Metrics().padding * 2
        guard first.contentWidth > room, first.contentWidth > 0 else { return first }
        // Never below two thirds: past that the labels stop being readable, and
        // a diagram that runs a little wide is better than one nobody can read.
        let scale = max(0.66, room / first.contentWidth)
        return settled(
            draw(diagram, theme: theme, width: width, metrics: Metrics(scale: scale)), width: width)
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
    /// same as the width of the picture: a line bowed around a box reaches past
    /// them, and so does a word that outgrew the card it was written in. Both
    /// used to be cut off by the edge of the bitmap — a picture the reader could
    /// see was incomplete. Measuring the decorations catches every such case at
    /// once, including the kinds nobody has thought about yet.
    private static func settled(_ drawing: Drawing, width: CGFloat) -> Drawing {
        var drawing = drawing
        guard let box = bounds(of: drawing.decorations) else { return drawing }
        let padding = Metrics().padding
        drawing.contentWidth = max(drawing.contentWidth, box.width)
        let wanted = max(padding, (width - box.width) / 2)
        let right = box.minX < wanted ? wanted - box.minX : 0
        let down = box.minY < padding ? padding - box.minY : 0
        if right > 0.5 || down > 0.5 {
            drawing.decorations = drawing.decorations.map { moved($0, right: right, down: down) }
        }
        drawing.size.height = max(drawing.size.height, box.maxY + down + padding)
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
                    "«\(box.stereotype)»", font: rowFont, color: theme.palette.secondaryText)
                stereotype = line
                stereotypeSize = measure(line)
            }
            var widest = max(titleSize.width, stereotypeSize.width)
            var compartments: [Compartment] = []
            for rows in box.compartments where !rows.isEmpty {
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

        let down = diagram.direction == .down || diagram.direction == .up
        var frames: [CGRect]
        var content: CGSize
        var walls: [(rect: CGRect, name: String)] = []
        if diagram.namespaces.isEmpty {
            (frames, content) = ranked(
                sizes: entities.map(\.frame.size), links: diagram.links.map { ($0.from, $0.to) },
                down: down, metrics: metrics)
        } else {
            (frames, content, walls) = walled(
                diagram, sizes: entities.map(\.frame.size), down: down, theme: theme,
                font: rowFont, metrics: metrics)
        }
        let left = max(metrics.padding, (width - content.width) / 2)
        for index in frames.indices {
            frames[index].origin.x += left
            frames[index].origin.y += metrics.padding
        }
        for index in walls.indices {
            walls[index].rect.origin.x += left
            walls[index].rect.origin.y += metrics.padding
        }
        for index in entities.indices { entities[index].frame = frames[index] }

        let slips = notes(
            diagram.notes, beside: entities.map(\.frame), theme: theme, font: rowFont,
            metrics: metrics)

        var decorations: [BlockBox.Decoration] = []
        for wall in walls {
            decorations += namespace(
                wall.rect, named: wall.name, theme: theme, font: rowFont, metrics: metrics)
        }
        for link in diagram.links {
            guard link.from < entities.count, link.to < entities.count else { continue }
            decorations += relation(
                link, from: entities[link.from].frame, to: entities[link.to].frame, theme: theme,
                font: rowFont, metrics: metrics)
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
            contentWidth: content.width
        )
    }

    /// The same ranking a flowchart uses: a box sits one rank below whatever
    /// points at it, and a cycle cannot spin it. Frames come back measured from
    /// the picture's own corner, so a caller may place them anywhere.
    private static func ranked(
        sizes: [CGSize], links: [(Int, Int)], down: Bool, metrics: Metrics
    ) -> (frames: [CGRect], content: CGSize) {
        var frames = sizes.map { CGRect(origin: .zero, size: $0) }
        let ranks = self.ranks(count: sizes.count, edges: links)
        let depths = ranks.map { rank in
            rank.map { down ? sizes[$0].height : sizes[$0].width }.max() ?? 0
        }
        let extents = ranks.map { rank in
            rank.reduce(CGFloat(0)) { $0 + (down ? sizes[$1].width : sizes[$1].height) }
                + metrics.siblingGap * CGFloat(max(0, rank.count - 1))
        }
        let crossExtent = extents.max() ?? 0
        let rankGap = metrics.rankGap * 1.3
        var rankOffset: CGFloat = 0
        for (level, rank) in ranks.enumerated() {
            var cross = (crossExtent - extents[level]) / 2
            for index in rank {
                let size = sizes[index]
                frames[index].origin =
                    down
                    ? CGPoint(x: cross, y: rankOffset + (depths[level] - size.height) / 2)
                    : CGPoint(x: rankOffset + (depths[level] - size.width) / 2, y: cross)
                cross += (down ? size.width : size.height) + metrics.siblingGap
            }
            rankOffset += depths[level] + rankGap
        }
        let along = max(0, rankOffset - rankGap)
        return (
            frames,
            CGSize(width: down ? crossExtent : along, height: down ? along : crossExtent)
        )
    }

    /// A class diagram whose classes live in namespaces.
    ///
    /// Each namespace is laid out as a picture of its own and then placed as one
    /// box, exactly the way a subgraph inside a flowchart is: it is the only way
    /// a frame can be sure to hold its own classes and nobody else's.
    private static func walled(
        _ diagram: BoxDiagram, sizes: [CGSize], down: Bool, theme: Theme, font: CTFont,
        metrics: Metrics
    ) -> (frames: [CGRect], content: CGSize, walls: [(rect: CGRect, name: String)]) {
        let inset = 12 * metrics.scale
        let titleRoom =
            measure(text("X", font: font, color: theme.palette.text)).height
            + 10 * metrics.scale
        /// Which top-level unit each box belongs to, and where inside it stands.
        var unitOf = [Int](repeating: 0, count: sizes.count)
        var inside = [CGRect](repeating: .zero, count: sizes.count)
        var unitSizes: [CGSize] = []
        var wallOf: [Int: Int] = [:]
        for (index, space) in diagram.namespaces.enumerated() {
            let members = space.members
            let local = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1, $0) })
            let links = diagram.links.compactMap { link -> (Int, Int)? in
                guard let from = local[link.from], let to = local[link.to] else { return nil }
                return (from, to)
            }
            let (laid, content) = ranked(
                sizes: members.map { sizes[$0] }, links: links, down: down, metrics: metrics)
            for (offset, member) in members.enumerated() {
                unitOf[member] = unitSizes.count
                inside[member] = laid[offset].offsetBy(dx: inset, dy: inset + titleRoom)
            }
            wallOf[unitSizes.count] = index
            unitSizes.append(
                CGSize(
                    width: content.width + inset * 2,
                    height: content.height + inset * 2 + titleRoom))
        }
        for (index, box) in diagram.boxes.enumerated() where box.namespace == nil {
            unitOf[index] = unitSizes.count
            inside[index] = CGRect(origin: .zero, size: sizes[index])
            unitSizes.append(sizes[index])
        }
        let between = diagram.links.compactMap { link -> (Int, Int)? in
            let from = unitOf[link.from]
            let to = unitOf[link.to]
            return from == to ? nil : (from, to)
        }
        let (units, content) = ranked(
            sizes: unitSizes, links: between, down: down, metrics: metrics)
        let frames = inside.enumerated().map { index, local in
            local.offsetBy(
                dx: units[unitOf[index]].minX, dy: units[unitOf[index]].minY)
        }
        let walls = wallOf.keys.sorted().map {
            (rect: units[$0], name: diagram.namespaces[wallOf[$0]!].name)
        }
        return (frames, content, walls)
    }

    /// The titled frame a `namespace` draws around the classes inside it.
    private static func namespace(
        _ rect: CGRect, named name: String, theme: Theme, font: CTFont, metrics: Metrics
    ) -> [BlockBox.Decoration] {
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        let line = text(name, font: font, color: theme.palette.secondaryText)
        let size = measure(line)
        return [
            .path(path, color: theme.palette.codeBackground, lineWidth: 0, filled: true),
            .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false),
            .glyphs(
                line,
                origin: CGPoint(
                    x: rect.midX - size.width / 2, y: rect.minY + 6 * metrics.scale + size.height)),
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
                path, color: faded(style.fill.map(cgColor) ?? theme.palette.background, by: style),
                lineWidth: 0, filled: true),
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
        _ link: BoxDiagram.Link, from: CGRect, to: CGRect, theme: Theme, font: CTFont,
        metrics: Metrics
    ) -> [BlockBox.Decoration] {
        let colour = theme.palette.secondaryText
        let (start, end) = joined(from, to)
        let direction = normalized(CGPoint(x: end.x - start.x, y: end.y - start.y))
        let backwards = CGPoint(x: -direction.x, y: -direction.y)
        let headRoom = 11 * metrics.scale
        let shaftStart = CGPoint(
            x: start.x + direction.x * inset(link.fromEnd, room: headRoom),
            y: start.y + direction.y * inset(link.fromEnd, room: headRoom))
        let shaftEnd = CGPoint(
            x: end.x - direction.x * inset(link.toEnd, room: headRoom),
            y: end.y - direction.y * inset(link.toEnd, room: headRoom))
        var decorations: [BlockBox.Decoration] = []
        if link.dashed {
            decorations.append(
                .path(
                    dashed(from: shaftStart, to: shaftEnd, dash: 5, gap: 4), color: colour,
                    lineWidth: 1.3, filled: false))
        } else {
            let shaft = CGMutablePath()
            shaft.move(to: shaftStart)
            shaft.addLine(to: shaftEnd)
            decorations.append(.path(shaft, color: colour, lineWidth: 1.3, filled: false))
        }
        decorations += terminal(
            link.fromEnd, at: start, direction: backwards, theme: theme, metrics: metrics)
        decorations += terminal(
            link.toEnd, at: end, direction: direction, theme: theme, metrics: metrics)

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
        guard !link.label.isEmpty else { return decorations }
        let line = text(link.label, font: font, color: colour)
        let size = measure(line)
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        decorations.append(
            .fill(
                rect: CGRect(
                    x: middle.x - size.width / 2 - 3, y: middle.y - size.height / 2 - 1,
                    width: size.width + 6, height: size.height + 2),
                color: theme.palette.background, cornerRadius: 2))
        decorations.append(
            .glyphs(
                line,
                origin: CGPoint(
                    x: middle.x - size.width / 2, y: middle.y + size.height / 2 - descent(line))))
        return decorations
    }

    /// How far the shaft stops short of the box, to leave the end its room.
    private static func inset(_ end: BoxDiagram.End, room: CGFloat) -> CGFloat {
        switch end {
        case .none: return 0
        case .arrow, .triangle: return room
        case .diamond, .hollowDiamond: return room * 1.3
        case .one, .zeroOrOne, .oneOrMore, .zeroOrMore: return room
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
            let path = CGMutablePath()
            path.move(to: tip)
            path.addLine(to: point(length, half))
            path.addLine(to: point(length, -half))
            path.closeSubpath()
            return [.path(path, color: colour, lineWidth: 0, filled: true)]
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
                let crow = CGMutablePath()
                for across in [half, 0, -half] {
                    crow.move(to: tip)
                    crow.addLine(to: point(length, across))
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
        let font = scaled(theme.body, by: metrics.scale * 0.94)
        let periodFont = scaled(theme.bodyBold, by: metrics.scale)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale * 1.1)
        let pad = 8 * metrics.scale
        let gap = 12 * metrics.scale

        struct Column {
            var head: CTLine
            var headSize: CGSize
            var events: [(line: CTLine, size: CGSize)]
            var frame: CGRect
            var tint: CGColor
        }
        var columns: [Column] = []
        for (index, period) in timeline.periods.enumerated() {
            let head = text(period.title, font: periodFont, color: theme.palette.text)
            var widest = measure(head).width
            var events: [(line: CTLine, size: CGSize)] = []
            var stack: CGFloat = 0
            for event in period.events {
                let line = text(event, font: font, color: theme.palette.text)
                let size = measure(line)
                widest = max(widest, size.width)
                stack += size.height + pad * 2 + 6 * metrics.scale
                events.append((line, size))
            }
            columns.append(
                Column(
                    head: head,
                    headSize: measure(head),
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
            timeline.sections.isEmpty ? 0 : headHeight * 0.9 + 8 * metrics.scale
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
            decorations.append(
                .glyphs(
                    column.head,
                    origin: CGPoint(
                        x: head.midX - column.headSize.width / 2,
                        y: head.midY + column.headSize.height / 2 - descent(column.head)
                    )
                )
            )
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
                decorations.append(
                    .glyphs(
                        event.line,
                        origin: CGPoint(
                            x: card.midX - event.size.width / 2,
                            y: card.midY + event.size.height / 2 - descent(event.line)
                        )
                    )
                )
                y = card.maxY + 6 * metrics.scale
            }
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    // MARK: - User journey

    /// A journey: how each step of it felt, drawn as a line that rises and falls
    /// over the steps it is scored on.
    private static func journey(
        _ journey: UserJourney, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale * 0.94)
        let smallFont = scaled(theme.controlLabel, by: metrics.scale * 0.9)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale * 1.1)
        let pad = 8 * metrics.scale

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
                        84 * metrics.scale, max(nameSize.width, actorsSize.width) + pad * 2),
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
        let bandHeight = journey.sections.isEmpty ? 0 : measure(steps[0].name).height + pad * 2
        let plotHeight = 130 * metrics.scale
        let labelHeight =
            (steps.map(\.nameSize.height).max() ?? 0) + (steps.map(\.actorsSize.height).max() ?? 0)
            + pad * 2
        let height = metrics.padding * 2 + titleRoom + bandHeight + plotHeight + labelHeight

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
        for (index, name) in journey.sections.enumerated() {
            let owned = steps.indices.filter { journey.tasks[$0].section == index }
            guard let first = owned.first, let last = owned.last else { continue }
            let band = CGRect(
                x: left + steps[first].column,
                y: bandTop,
                width: steps[last].column + steps[last].columnWidth - steps[first].column,
                height: bandHeight - 6 * metrics.scale
            )
            decorations.append(
                .fill(
                    rect: band,
                    color: theme.diagramWheel[index % theme.diagramWheel.count].copy(alpha: 0.22)
                        ?? theme.diagramWheel[0],
                    cornerRadius: 4 * metrics.scale))
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

        // Five rules, one per score, so the height of a point can be read off
        // the picture rather than guessed at. The top and bottom rules are held
        // a dot's radius inside the plot, or a five would ride up into the band
        // above it and a one would sit on the names below.
        let plotBottom = bandTop + bandHeight + plotHeight
        let dotRadius = 11 * metrics.scale
        // The scale runs from one to five, so a score written outside it sits on
        // the nearest line rather than off the picture.
        func level(_ score: Int) -> CGFloat {
            let placed = min(max(score, 1), 5)
            return (plotBottom - dotRadius) - (plotHeight - dotRadius * 2) * CGFloat(placed - 1)
                / 4
        }
        for score in 1...5 {
            let y = level(score)
            let rule = CGMutablePath()
            rule.move(to: CGPoint(x: left, y: y))
            rule.addLine(to: CGPoint(x: left + content, y: y))
            decorations.append(
                .path(
                    rule, color: theme.palette.tableBorder,
                    lineWidth: score == 1 ? 1 : 0.5, filled: false))
        }
        func point(_ step: Step) -> CGPoint {
            CGPoint(x: left + step.column + step.columnWidth / 2, y: level(step.score))
        }
        if steps.count > 1 {
            let path = CGMutablePath()
            path.move(to: point(steps[0]))
            for step in steps.dropFirst() { path.addLine(to: point(step)) }
            decorations.append(
                .path(
                    path, color: theme.palette.secondaryText, lineWidth: 1.5 * metrics.scale,
                    filled: false))
        }
        for step in steps {
            let centre = point(step)
            let dot = CGRect(
                x: centre.x - 11 * metrics.scale, y: centre.y - 11 * metrics.scale,
                width: 22 * metrics.scale, height: 22 * metrics.scale)
            decorations.append(
                .path(
                    CGPath(ellipseIn: dot, transform: nil), color: step.tint, lineWidth: 0,
                    filled: true))
            let score = text(
                "\(step.score)", font: scaled(theme.bodyBold, by: metrics.scale * 0.85),
                color: theme.palette.background)
            let size = measure(score)
            decorations.append(
                .glyphs(
                    score,
                    origin: CGPoint(
                        x: dot.midX - size.width / 2,
                        y: dot.midY + size.height / 2 - descent(score)
                    )
                )
            )
            var y = plotBottom + pad
            for (line, size) in [(step.name, step.nameSize)]
                + (step.actors.map {
                    [($0, step.actorsSize)]
                } ?? [])
            {
                decorations.append(
                    .glyphs(
                        line,
                        origin: CGPoint(
                            x: centre.x - size.width / 2,
                            y: y + size.height
                                - descent(line))))
                y += size.height
            }
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
    }

    // MARK: - Gantt chart

    /// A Gantt chart: one row per task, its bar spanning the days it takes.
    private static func gantt(
        _ chart: GanttChart, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale * 0.94)
        let smallFont = scaled(theme.controlLabel, by: metrics.scale * 0.85)
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
            return GanttChart.date(origin + Int(day.rounded()), format: chart.axisFormat)
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
        var tickStep = span / Double(max(2, min(4, Int(plotWidth / dateWidth))))
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
        let ticks = max(1, Int((span / max(tickStep, 0.0001)).rounded(.down)))
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
        let height = metrics.padding * 2 + titleRoom + axisHeight + CGFloat(rows) * rowHeight

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
        for step in 0...ticks {
            let day = min(span, tickStep * Double(step))
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
            let today = Double(GanttChart.today() - origin)
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

        lastSection = nil
        for (index, task) in chart.tasks.enumerated() {
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
                // No length to draw, so a milestone is the diamond the day it
                // falls on, not a bar of zero width nobody would see.
                let centre = CGPoint(
                    x: plotLeft + CGFloat(task.start) * perDay, y: barTop + barHeight / 2)
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
        for (index, node) in map.nodes.enumerated() where index > 0 || !node.label.isEmpty {
            let frame = frames[index]
            guard frame.width > 2, frame.height > 2 else { continue }
            let colour = theme.diagramWheel[index % theme.diagramWheel.count]
            let branch = !node.children.isEmpty
            decorations.append(
                .fill(
                    rect: frame.insetBy(dx: 1, dy: 1),
                    color: colour.copy(alpha: branch ? 0.18 : 0.55) ?? colour,
                    cornerRadius: 3 * metrics.scale))
            decorations.append(
                .path(
                    CGPath(rect: frame, transform: nil), color: theme.palette.background,
                    lineWidth: 1.5, filled: false))
            // A branch is named along its own top edge, above what it holds; a
            // leaf gets its name in the middle. Both carry their number: a
            // branch's is the sum of what it holds, and that is what the map is
            // about.
            let words = "\(node.label)  \(number(node.value))"
            let line = text(words, font: branch ? headFont : font, color: theme.palette.text)
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
        let font = scaled(theme.controlLabel, by: metrics.scale * 0.85)
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
        var wantedNumbers: [(row: Int, value: Int, x: CGFloat, opening: Bool, top: CGFloat)] = []
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
            // The bit each end of the field stands on, above its own edge.
            for (number, x) in [
                (piece.row * packet.bitsPerRow + piece.first, frame.minX),
                (piece.row * packet.bitsPerRow + piece.last, frame.maxX),
            ] {
                wantedNumbers.append(
                    (row: piece.row, value: number, x: x, opening: x == frame.minX, top: top))
            }
        }
        // A row of one-bit fields wants more numbers over it than the row is
        // wide, and printed as asked they run into each other and become a
        // smear. The two ends of the row are placed first — they are what says
        // how long the row is — and after them each number is placed only where
        // it is still clear of the ones already there.
        for row in 0..<rows {
            var placed: [CGRect] = []
            let candidates = wantedNumbers.filter { $0.row == row }
            let ends = row * packet.bitsPerRow
            let ordered = candidates.sorted { a, b in
                func rank(_ item: (row: Int, value: Int, x: CGFloat, opening: Bool, top: CGFloat))
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
                let anchor =
                    candidate.opening ? candidate.x + 1 : candidate.x - 1 - size.width
                let originX = min(left + content - size.width, max(left, anchor))
                let box = CGRect(
                    x: originX - 2 * metrics.scale, y: 0, width: size.width + 4 * metrics.scale,
                    height: 1)
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
        let smallFont = scaled(theme.controlLabel, by: metrics.scale * 0.85)
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
                if !card.priority.isEmpty {
                    decorations.append(
                        .fill(
                            rect: CGRect(
                                x: frame.minX, y: frame.minY, width: 4 * metrics.scale,
                                height: frame.height),
                            color: priorityColour(card.priority, theme: theme),
                            cornerRadius: 2 * metrics.scale))
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

    private static func priorityColour(_ priority: String, theme: Theme) -> CGColor {
        switch priority.lowercased() {
        case "very high", "high": return CGColor(red: 0.85, green: 0.33, blue: 0.33, alpha: 1)
        case "low", "very low": return CGColor(red: 0.45, green: 0.70, blue: 0.50, alpha: 1)
        default: return theme.palette.secondaryText
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
        for (index, corner) in corners.enumerated() {
            decorations.append(
                .fill(
                    rect: corner.insetBy(dx: 1, dy: 1),
                    color: theme.diagramWheel[index % theme.diagramWheel.count].copy(alpha: 0.14)
                        ?? theme.diagramWheel[index],
                    cornerRadius: 0))
            let name = chart.quadrants[index]
            guard !name.isEmpty else { continue }
            let line = text(name, font: quadrantFont, color: theme.palette.secondaryText)
            let size = measure(line)
            // Along the top of its own quarter rather than through the middle
            // of it, which is where the points are.
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: corner.midX - size.width / 2,
                        y: corner.minY + 10 * metrics.scale + size.height - descent(line))))
        }
        let frame = CGMutablePath()
        frame.addRect(plot)
        frame.move(to: CGPoint(x: plot.midX, y: plot.minY))
        frame.addLine(to: CGPoint(x: plot.midX, y: plot.maxY))
        frame.move(to: CGPoint(x: plot.minX, y: plot.midY))
        frame.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        decorations.append(
            .path(frame, color: theme.palette.tableBorder, lineWidth: 1, filled: false))

        // What is already on the square: every dot, and every name written so
        // far. A name goes where it runs into neither.
        var written: [CGRect] = []
        var centres: [CGPoint] = []
        for point in chart.points {
            // y grows up the page here and down everywhere else, so a point
            // written at 1 belongs at the top.
            let centre = CGPoint(
                x: plot.minX + CGFloat(point.x) * side,
                y: plot.maxY - CGFloat(point.y) * side
            )
            centres.append(centre)
            let dot = CGRect(
                x: centre.x - 5 * metrics.scale, y: centre.y - 5 * metrics.scale,
                width: 10 * metrics.scale, height: 10 * metrics.scale)
            written.append(dot)
            decorations.append(
                .path(
                    CGPath(ellipseIn: dot, transform: nil), color: theme.diagramWheel[0],
                    lineWidth: 0,
                    filled: true))
        }
        for (index, point) in chart.points.enumerated() {
            let centre = centres[index]
            let line = text(point.label, font: font, color: theme.palette.text)
            let size = measure(line)
            // Beside its dot, and on the other side of it when the name would
            // otherwise run out of the square. Where that place is already taken
            // by another name — two campaigns a few points apart — the name
            // steps a line up or down until it is clear, because two names on
            // top of each other say less than one.
            let step = size.height + 3 * metrics.scale
            var places: [CGPoint] = []
            for lift in [0, -step, step, -step * 2, step * 2] {
                let right = centre.x + 8 * metrics.scale
                let left = centre.x - 8 * metrics.scale - size.width
                places.append(CGPoint(x: right, y: centre.y + lift))
                places.append(CGPoint(x: left, y: centre.y + lift))
            }
            var origin = places[0]
            for place in places {
                let x = max(plot.minX, min(place.x, plot.maxX - size.width))
                let box = CGRect(
                    x: x, y: place.y - size.height / 2, width: size.width, height: size.height)
                guard plot.contains(box) else { continue }
                if !written.contains(where: { $0.intersects(box.insetBy(dx: -2, dy: -1)) }) {
                    origin = CGPoint(x: x, y: place.y)
                    written.append(box)
                    break
                }
            }
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: max(plot.minX, min(origin.x, plot.maxX - size.width)),
                        y: origin.y + size.height / 2 - descent(line))))
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
        let gutter =
            (graph.branches.map {
                measure(text($0, font: branchFont, color: theme.palette.text)).width
            }.max() ?? 0) + 14 * metrics.scale
        let step = 56 * metrics.scale
        let lane = 46 * metrics.scale
        let radius = 7 * metrics.scale
        let columns = (graph.commits.map(\.column).max() ?? 0) + 1
        // Turned on its side the lanes run down the page: what was a column of
        // commits becomes a row of them, and the branch names sit above their
        // lanes rather than beside them.
        let down = graph.vertical
        let nameHeight =
            (graph.branches.map {
                measure(text($0, font: branchFont, color: theme.palette.text)).height
            }.max() ?? 0) + 10 * metrics.scale
        let content =
            down
            ? CGFloat(graph.branches.count) * lane : gutter + CGFloat(columns) * step
        let height =
            down
            ? metrics.padding * 2 + nameHeight + CGFloat(columns) * step
            : metrics.padding * 2 + CGFloat(graph.branches.count) * lane

        let left = max(metrics.padding, (width - content) / 2)
        /// How far along its lane a commit stands, and how far across the lanes.
        func along(_ column: Int) -> CGFloat {
            (down ? metrics.padding + nameHeight : left + gutter) + step * (CGFloat(column) + 0.5)
        }
        func across(_ branch: Int) -> CGFloat {
            (down ? left : metrics.padding) + lane * (CGFloat(branch) + 0.5)
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
            let line = text(name, font: branchFont, color: colour)
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: down
                        ? CGPoint(
                            x: side - size.width / 2,
                            y: metrics.padding + size.height - descent(line))
                        : CGPoint(
                            x: left + gutter - 10 * metrics.scale - size.width,
                            y: side + size.height / 2 - descent(line))))
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
        for commit in graph.commits {
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
            for (words, above) in [(commit.label, true), (commit.tag, false)] where !words.isEmpty {
                let line = text(
                    words, font: above ? font : scaled(theme.bodyBold, by: metrics.scale * 0.8),
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

    /// A node's words, broken where the author broke them.
    private static func labelLines(_ words: String, font: CTFont, color: CGColor)
        -> (lines: [CTLine], size: CGSize)
    {
        var parts = [words]
        for separator in ["<br/>", "<br />", "<br>", "\\n"] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let lines = parts.map {
            text($0.trimmingCharacters(in: .whitespaces), font: font, color: color)
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
            case .arrowUp, .arrowDown:
                box.height += size.height * 1.4
            case .arrowLeft, .arrowRight:
                box.width += size.width * 0.6 + 20 * metrics.scale
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
        let labelSizes =
            chart.edges.filter { !$0.label.isEmpty }
            .map { measure(text($0.label, font: labelFont, color: theme.palette.text)) }
        let titleRoom = chart.groups.isEmpty ? 0 : 20 * metrics.scale
        let placement = placed(
            chart: chart, boxes: boxes, labels: labelSizes, metrics: metrics, titleRoom: titleRoom)
        for (index, frame) in placement.nodes { boxes[index].frame = frame }
        let content = placement.size

        // Centre the picture in the reading column, and never let it run out of
        // it: a diagram wider than the column starts at the margin instead of
        // being pushed off the left edge.
        let left = max(metrics.padding, (width - content.width) / 2)
        for index in boxes.indices { boxes[index].frame.origin.x += left }
        let frames = placement.frames.mapValues { $0.offsetBy(dx: left, dy: 0) }

        var decorations: [BlockBox.Decoration] = []
        // Frames first: everything else in the diagram stands on top of them,
        // and an inner frame after the one that holds it.
        for group in chart.groups.indices.sorted(by: {
            depth(of: $0, in: chart) < depth(of: $1, in: chart)
        }) {
            guard let rect = frames[group] else { continue }
            decorations += frame(
                chart.groups[group], rect: rect, theme: theme, metrics: metrics,
                titleRoom: titleRoom)
        }
        var labels: [BlockBox.Decoration] = []
        // Where an edge starts and stops: a box's own frame, or the border of
        // the frame it names.
        func rect(_ end: Flowchart.End) -> CGRect? {
            switch end {
            case .node(let index): return boxes.indices.contains(index) ? boxes[index].frame : nil
            case .frame(let group):
                // The strip the frame's name is written in belongs to the frame:
                // a line stopping at the border alone would cross the name.
                guard let rect = frames[group] else { return nil }
                return CGRect(
                    x: rect.minX, y: rect.minY - titleRoom, width: rect.width,
                    height: rect.height + titleRoom)
            }
        }
        // Two labelled edges leaving one node run side by side, so their words
        // are spaced out along the line instead of landing on each other.
        var written: [Flowchart.End: Int] = [:]
        // Two nodes joined both ways — a state and the state it goes back to —
        // have their words laid either side of the line rather than on top of
        // each other.
        struct Pair: Hashable {
            var one: Flowchart.End
            var other: Flowchart.End

            init(_ edge: Flowchart.Edge) {
                let ends = [edge.from, edge.to].sorted { Pair.order($0) < Pair.order($1) }
                one = ends[0]
                other = ends[1]
            }

            private static func order(_ end: Flowchart.End) -> Int {
                switch end {
                case .node(let index): return index
                case .frame(let group): return 1_000_000 + group
                }
            }
        }
        var pairs: [Pair: Int] = [:]
        for edge in chart.edges where !edge.label.isEmpty {
            pairs[Pair(edge), default: 0] += 1
        }
        // Every edge between the same two nodes, labelled or not: two states
        // that go back and forth would otherwise be one line drawn twice.
        var lanes: [Pair: Int] = [:]
        for edge in chart.edges { lanes[Pair(edge), default: 0] += 1 }
        var lanesSeen: [Pair: Int] = [:]
        var seen: [Pair: Int] = [:]
        for edge in chart.edges {
            guard let from = rect(edge.from), let to = rect(edge.to) else { continue }
            var order = 0
            var side: CGFloat = 0
            if !edge.label.isEmpty {
                order = written[edge.from, default: 0]
                written[edge.from] = order + 1
                let key = Pair(edge)
                let index = seen[key, default: 0]
                seen[key] = index + 1
                let count = pairs[key] ?? 1
                side = CGFloat(index) - CGFloat(count - 1) / 2
            }
            let key = Pair(edge)
            let taken = lanesSeen[key, default: 0]
            lanesSeen[key] = taken + 1
            let lane = CGFloat(taken) - CGFloat((lanes[key] ?? 1) - 1) / 2
            // A frame's own boxes are not obstacles for an edge that ends on
            // that frame: the line stops at the border and never reaches them.
            let inside = held(by: edge, chart: chart)
            let obstacles = boxes.indices
                .filter { !inside.contains($0) && boxes[$0].frame != from && boxes[$0].frame != to }
                .map { boxes[$0].frame }
            let drawn = self.edge(
                edge, from: from, to: to, theme: theme, metrics: metrics,
                order: order, side: side, lane: lane, obstacles: obstacles)
            decorations += drawn.shaft
            labels += drawn.label
        }
        for box in boxes { decorations += node(box, theme: theme, metrics: metrics) }
        // An edge that skips a rank passes over whatever stands between, so its
        // words are written last and keep their own plate under them.
        decorations += labels
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: content.height + metrics.padding * 2),
            contentWidth: content.width
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
        chart: Flowchart, boxes: [Placed], labels: [CGSize], metrics: Metrics, titleRoom: CGFloat
    ) -> Placement {
        var owner = [Int?](repeating: nil, count: boxes.count)
        for (index, group) in chart.groups.enumerated() {
            for member in group.members where member < owner.count { owner[member] = index }
        }
        // Every box a frame holds, however deep — what an edge crossing frames
        // has to be resolved against.
        var reach = [Set<Int>](repeating: [], count: chart.groups.count)
        for index in boxes.indices {
            var walk = owner[index]
            while let group = walk {
                reach[group].insert(index)
                walk = chart.groups[group].parent
            }
        }
        let inset = metrics.siblingGap / 2

        func layout(container: Int?) -> Placement {
            let children = chart.groups.indices.filter { chart.groups[$0].parent == container }
            let loose = boxes.indices.filter { owner[$0] == container }
            enum Unit {
                case node(Int)
                case frame(Int)
            }
            let units: [Unit] = loose.map { .node($0) } + children.map { .frame($0) }
            var inner: [Int: Placement] = [:]
            var sizes: [CGSize] = []
            for unit in units {
                switch unit {
                case .node(let index):
                    sizes.append(boxes[index].frame.size)
                case .frame(let group):
                    let laid = layout(container: group)
                    inner[group] = laid
                    sizes.append(
                        CGSize(
                            width: laid.size.width + inset * 2,
                            height: laid.size.height + inset * 2 + titleRoom))
                }
            }
            // Which block of this container each end of an edge belongs to, so
            // an edge between two boxes deep in different frames ranks the
            // frames, and an edge that names a frame ranks the frame itself.
            var unitOf: [Flowchart.End: Int] = [:]
            for (index, unit) in units.enumerated() {
                switch unit {
                case .node(let node): unitOf[.node(node)] = index
                case .frame(let group):
                    unitOf[.frame(group)] = index
                    for member in reach[group] { unitOf[.node(member)] = index }
                    for inner in chart.groups.indices where reaches(group, inner, in: chart) {
                        unitOf[.frame(inner)] = index
                    }
                }
            }
            let edges = chart.edges.compactMap { edge -> (from: Int, to: Int)? in
                guard let from = unitOf[edge.from], let to = unitOf[edge.to], from != to
                else { return nil }
                return (from, to)
            }
            let ranks = self.ranks(count: units.count, edges: edges)
            let turn =
                container.map { chart.groups[$0].direction ?? chart.direction }
                ?? chart.direction
            let down = turn == .down || turn == .up
            let labelRoom = labels.map { down ? $0.height : $0.width }.max() ?? 0
            let rankGap = max(
                metrics.rankGap * (chart.groups.isEmpty ? 1 : 1.6),
                labelRoom + metrics.arrowLength + 40 * metrics.scale
            )
            func extent(_ unit: Int) -> CGFloat {
                down ? sizes[unit].width : sizes[unit].height
            }
            func span(_ indices: [Int]) -> CGFloat {
                indices.reduce(0) { $0 + extent($1) }
                    + metrics.siblingGap * CGFloat(max(0, indices.count - 1))
            }
            let depths = ranks.map { rank in
                rank.map { down ? sizes[$0].height : sizes[$0].width }.max() ?? 0
            }
            let crossExtent = ranks.map(span).max() ?? 0
            var origins = [CGPoint](repeating: .zero, count: units.count)
            var rankOffset: CGFloat = 0
            for level in ranks.indices {
                var cross = (crossExtent - span(ranks[level])) / 2
                for unit in ranks[level] {
                    origins[unit] =
                        down
                        ? CGPoint(
                            x: cross, y: rankOffset + (depths[level] - sizes[unit].height) / 2)
                        : CGPoint(x: rankOffset + (depths[level] - sizes[unit].width) / 2, y: cross)
                    cross += extent(unit) + metrics.siblingGap
                }
                rankOffset += depths[level] + rankGap
            }
            let along = max(0, rankOffset - rankGap)
            // `BT` and `RL` are the same graph read from the other end, so the
            // rank axis is turned over once every block is placed.
            if turn == .up || turn == .left {
                for unit in origins.indices {
                    if down {
                        origins[unit].y = along - origins[unit].y - sizes[unit].height
                    } else {
                        origins[unit].x = along - origins[unit].x - sizes[unit].width
                    }
                }
            }
            var placement = Placement(
                size: CGSize(
                    width: down ? crossExtent : along, height: down ? along : crossExtent),
                nodes: [:], frames: [:])
            for (index, unit) in units.enumerated() {
                switch unit {
                case .node(let node):
                    placement.nodes[node] = CGRect(
                        origin: origins[index], size: boxes[node].frame.size)
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
        titleRoom: CGFloat
    ) -> [BlockBox.Decoration] {
        let path = CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        var decorations: [BlockBox.Decoration] = [
            .path(
                path,
                color: faded(
                    group.style.fill.map(cgColor) ?? theme.palette.codeBackground, by: group.style),
                lineWidth: 0, filled: true),
            .path(
                path,
                color: faded(
                    group.style.stroke.map(cgColor) ?? theme.palette.tableBorder, by: group.style),
                lineWidth: group.style.strokeWidth ?? 1, filled: false),
        ]
        guard !group.title.isEmpty else { return decorations }
        let line = text(
            group.title,
            font: scaled(theme.controlLabel, by: metrics.scale),
            color: faded(
                group.style.text.map(cgColor) ?? theme.palette.secondaryText, by: group.style)
        )
        let size = measure(line)
        decorations.append(
            .glyphs(
                line,
                origin: CGPoint(
                    x: bounds.minX + 4,
                    y: bounds.minY - max(3, titleRoom - size.height) - descent(line)
                )
            )
        )
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
            box.style.fill.map(cgColor) ?? theme.palette.tableHeaderBackground, by: box.style)
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
        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight:
            // A fat arrow: a shaft half the width across, and a head that takes
            // the last third of the length.
            let along = box.shape == .arrowUp || box.shape == .arrowDown
            let length = along ? frame.height : frame.width
            let across = along ? frame.width : frame.height
            let head = min(length * 0.42, across / 2)
            let shaft = across * 0.24
            // Points along the arrow measured from its tail, then turned to
            // face whichever way it points.
            func at(_ forward: CGFloat, _ side: CGFloat) -> CGPoint {
                switch box.shape {
                case .arrowDown: return CGPoint(x: frame.midX + side, y: frame.minY + forward)
                case .arrowUp: return CGPoint(x: frame.midX + side, y: frame.maxY - forward)
                case .arrowRight: return CGPoint(x: frame.minX + forward, y: frame.midY + side)
                default: return CGPoint(x: frame.maxX - forward, y: frame.midY + side)
                }
            }
            return polygon([
                at(0, -shaft), at(length - head, -shaft), at(length - head, -across / 2),
                at(length, 0), at(length - head, across / 2), at(length - head, shaft),
                at(0, shaft),
            ])
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

    /// How far to one side a line has to bow: enough to clear whatever stands
    /// on it, plus its own lane when two nodes are joined more than once.
    ///
    /// The side chosen is whichever needs less deviation. The clearance is asked
    /// for at the apex of the curve, which the obstacle usually sits near but
    /// not exactly at, so it is taken with room to spare.
    private static func bow(
        from start: CGPoint, to end: CGPoint, lane: CGFloat, obstacles: [CGRect], metrics: Metrics
    ) -> CGFloat {
        let laneOffset = lane * metrics.siblingGap
        let across = normal(from: start, to: end)
        let margin = 10 * metrics.scale
        var plus: CGFloat = 0
        var minus: CGFloat = 0
        for rect in obstacles where crosses(rect, from: start, to: end) {
            var high = -CGFloat.greatestFiniteMagnitude
            var low = CGFloat.greatestFiniteMagnitude
            for corner in [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            ] {
                let offset = (corner.x - start.x) * across.x + (corner.y - start.y) * across.y
                high = max(high, offset)
                low = min(low, offset)
            }
            plus = max(plus, (high + margin) * 1.6)
            minus = max(minus, (margin - low) * 1.6)
        }
        guard plus > 0 || minus > 0 else { return laneOffset }
        return laneOffset + (plus <= minus ? plus : -minus)
    }

    /// Whether a straight line from one point to another passes over a box.
    private static func crosses(_ rect: CGRect, from start: CGPoint, to end: CGPoint) -> Bool {
        let box = rect.insetBy(dx: -1, dy: -1)
        guard
            box.intersects(
                CGRect(
                    x: min(start.x, end.x), y: min(start.y, end.y),
                    width: abs(end.x - start.x), height: abs(end.y - start.y)
                ).insetBy(dx: -1, dy: -1))
        else { return false }
        let steps = 48
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if box.contains(point) { return true }
        }
        return false
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
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

    /// A line between two centres, cut off at each box's edge.
    ///
    /// Clipping to the boxes rather than joining named sides is what lets the
    /// same routine draw an edge down a rank, across one, or back up the graph.
    private static func edge(
        _ edge: Flowchart.Edge, from: CGRect, to: CGRect, theme: Theme, metrics: Metrics,
        order: Int, side: CGFloat, lane: CGFloat, obstacles: [CGRect]
    ) -> (shaft: [BlockBox.Decoration], label: [BlockBox.Decoration]) {
        // `A ~~~ B` is written to hold one box under another and nothing more,
        // so it has already done its work by the time there is a line to draw.
        guard edge.stroke != .invisible else { return (shaft: [], label: []) }
        var (start, end) = joined(from, to)
        // An edge that skips a rank would otherwise run straight through
        // whatever stands between, which reads as an edge to that box; and two
        // nodes joined both ways would put one line exactly on top of the other.
        // Both are answered the same way: the line is bowed to one side.
        let curveOut = bow(from: start, to: end, lane: lane, obstacles: obstacles, metrics: metrics)
        var control = midpoint(start, end)
        if curveOut != 0 {
            let across = normal(from: start, to: end)
            control = CGPoint(
                x: control.x + across.x * curveOut * 2, y: control.y + across.y * curveOut * 2)
            start = exit(of: from, towards: control)
            end = exit(of: to, towards: control)
        }
        let path = curveOut == 0 ? [start, end] : samples(from: start, through: control, to: end)
        var decorations: [BlockBox.Decoration] = []
        let color = faded(
            edge.style.stroke.map(cgColor) ?? theme.palette.secondaryText, by: edge.style)
        let width: CGFloat = (edge.stroke == .thick ? 2.5 : 1.3) * metrics.scale
        let shaft = CGMutablePath()
        let head = edge.arrow ? metrics.arrowLength : 0
        let tip = end
        let body = shortened(path, by: head)
        let last = body.count >= 2 ? body[body.count - 2] : start
        let direction = normalized(CGPoint(x: tip.x - last.x, y: tip.y - last.y))
        let shaftEnd = body.last ?? start
        if edge.stroke == .dotted {
            shaft.addPath(dashed(along: body, dash: 4, gap: 4))
        } else {
            shaft.move(to: body[0])
            for point in body.dropFirst() { shaft.addLine(to: point) }
        }
        decorations.append(.path(shaft, color: color, lineWidth: width, filled: false))
        if edge.arrow {
            let side = CGPoint(x: -direction.y, y: direction.x)
            let arrow = CGMutablePath()
            arrow.move(to: tip)
            arrow.addLine(
                to: CGPoint(
                    x: shaftEnd.x + side.x * metrics.arrowWidth / 2,
                    y: shaftEnd.y + side.y * metrics.arrowWidth / 2
                ))
            arrow.addLine(
                to: CGPoint(
                    x: shaftEnd.x - side.x * metrics.arrowWidth / 2,
                    y: shaftEnd.y - side.y * metrics.arrowWidth / 2
                ))
            arrow.closeSubpath()
            decorations.append(.path(arrow, color: color, lineWidth: 0, filled: true))
        }
        guard !edge.label.isEmpty else { return (decorations, []) }
        let line = text(
            edge.label,
            font: scaled(theme.controlLabel, by: metrics.scale),
            color: faded(
                edge.style.text.map(cgColor) ?? theme.palette.secondaryText, by: edge.style)
        )
        let size = measure(line)
        // An edge between neighbouring ranks is labelled in the middle; one that
        // skips a rank is labelled in the first gap it crosses, where there is
        // nothing else to sit on. Either way the words keep clear of both boxes,
        // so a label never ends up touching the box it points at.
        let length = self.length(of: path)
        // The arrowhead counts as part of the end: words that stop where the
        // head begins read as a label on the head rather than on the line.
        let clearance = size.width / 2 + 8 * metrics.scale + head
        let base = min(length / 2, metrics.rankGap / 2 + 6) + CGFloat(order) * (size.width + 10)
        // On a line too short to hold the words clear of both ends, the middle
        // is the least bad place: better over the line than over a box.
        let along =
            length <= clearance * 2
            ? length / 2 : min(max(clearance, base), length - clearance)
        let (anchor, heading) = point(along: path, at: along)
        // Sideways room is the label's own size, so two words either side of a
        // vertical line clear each other however long they are.
        let across = CGPoint(x: -heading.y, y: heading.x)
        let step = abs(heading.y) > abs(heading.x) ? size.width + 10 : size.height + 6
        let middle = CGPoint(
            x: anchor.x + across.x * side * step,
            y: anchor.y + across.y * side * step
        )
        let plate = CGRect(
            x: middle.x - size.width / 2 - 3,
            y: middle.y - size.height / 2 - 1,
            width: size.width + 6,
            height: size.height + 2
        )
        // The label sits on the line, so it needs the page under it.
        return (
            decorations,
            [
                .fill(rect: plate, color: theme.palette.background, cornerRadius: 2),
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: middle.x - size.width / 2,
                        y: middle.y + size.height / 2 - descent(line)
                    )
                ),
            ]
        )
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
            case .note, .activate, .deactivate: return []
            }
        }
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
        // A message's words are written over its arrow, so a column has to be
        // wide enough to hold them. A message that reaches across several
        // columns has all of them to spread over, which is why the room it asks
        // for is divided by how many it crosses.
        let messageRoom =
            messages(diagram.items).filter { $0.from != $0.to }
            .map {
                (measure(text($0.text, font: small, color: theme.palette.text)).width
                    + 26 * metrics.scale) / CGFloat(max(1, abs($0.to - $0.from)))
            }.max() ?? 0
        let step = max(boxWidth + metrics.columnGap, messageRoom)
        let content = step * CGFloat(max(0, diagram.participants.count - 1)) + boxWidth
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
        let centres = (0..<diagram.participants.count).map {
            left + boxWidth / 2 + step * CGFloat($0)
        }
        let body = script(
            diagram, centres: centres, boxWidth: boxWidth, from: firstMessage, theme: theme,
            font: small, metrics: metrics)
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
            let rect = CGRect(
                x: centres[first] - boxWidth / 2 - 6 * metrics.scale, y: top - groupRoom,
                width: centres[last] - centres[first] + boxWidth + 12 * metrics.scale,
                height: groupRoom + boxHeight + 6 * metrics.scale)
            decorations.append(
                .path(
                    CGPath(rect: rect, transform: nil),
                    color: group.fill.map(cgColor) ?? theme.palette.codeBackground,
                    lineWidth: 0, filled: true))
            decorations.append(
                .path(
                    CGPath(rect: rect, transform: nil), color: theme.palette.tableBorder,
                    lineWidth: 1, filled: false))
            let line = text(group.label, font: small, color: theme.palette.secondaryText)
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: rect.midX - size.width / 2,
                        y: rect.minY + 4 * metrics.scale + size.height - descent(line))))
        }
        decorations += body.tints
        for (index, centre) in centres.enumerated() {
            let lifeline = dashed(
                from: CGPoint(x: centre, y: top + boxHeight),
                to: CGPoint(x: centre, y: height - metrics.padding),
                dash: 4,
                gap: 4
            )
            decorations.append(
                .path(lifeline, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
            let frame = CGRect(
                x: centre - boxWidth / 2, y: top, width: boxWidth, height: boxHeight)
            if diagram.participants[index].isActor {
                // A stick figure, which is how Mermaid draws somebody rather
                // than something.
                decorations += figure(in: frame, theme: theme, metrics: metrics)
            } else {
                let path = CGPath(
                    roundedRect: frame, cornerWidth: 4, cornerHeight: 4, transform: nil)
                decorations.append(
                    .path(
                        path, color: theme.palette.tableHeaderBackground, lineWidth: 0,
                        filled: true))
                decorations.append(
                    .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
            }
            guard !diagram.participants[index].label.isEmpty else { continue }
            decorations.append(
                .glyphs(
                    labels[index],
                    origin: CGPoint(
                        x: centre - sizes[index].width / 2,
                        y: diagram.participants[index].isActor
                            ? frame.maxY + sizes[index].height - descent(labels[index])
                            : frame.midY + sizes[index].height / 2 - descent(labels[index])
                    )
                )
            )
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

    /// A stick figure standing in the room a participant box would take.
    private static func figure(
        in frame: CGRect, theme: Theme, metrics: Metrics
    ) -> [BlockBox.Decoration] {
        let ink = theme.palette.secondaryText
        let head = min(frame.height * 0.34, frame.width * 0.3)
        let centre = frame.midX
        let top = frame.minY + 2 * metrics.scale
        let body = CGMutablePath()
        let neck = top + head
        body.move(to: CGPoint(x: centre, y: neck))
        body.addLine(to: CGPoint(x: centre, y: frame.maxY - head * 0.8))
        body.move(to: CGPoint(x: centre - head * 0.8, y: neck + head * 0.5))
        body.addLine(to: CGPoint(x: centre + head * 0.8, y: neck + head * 0.5))
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
        _ diagram: SequenceDiagram, centres: [CGFloat], boxWidth: CGFloat, from top: CGFloat,
        theme: Theme, font: CTFont, metrics: Metrics
    ) -> (
        tints: [BlockBox.Decoration], frames: [BlockBox.Decoration], bars: [BlockBox.Decoration],
        body: [BlockBox.Decoration], bottom: CGFloat, reach: CGFloat
    ) {
        var tints: [BlockBox.Decoration] = []
        var frames: [BlockBox.Decoration] = []
        var body: [BlockBox.Decoration] = []
        var bars: [BlockBox.Decoration] = []
        var open: [Int: [CGFloat]] = [:]
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
                    body += arrow(
                        message, words: words, centres: centres, y: y, theme: theme, font: font,
                        metrics: metrics)
                    if message.deactivates { finish(message.from, at: y) }
                    y += message.from == message.to ? metrics.messageGap * 1.5 : metrics.messageGap
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
                            y += 14 * metrics.scale
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
                    frames.append(
                        .path(
                            CGPath(
                                roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil),
                            color: theme.palette.tableBorder, lineWidth: 1, filled: false))
                    for (lineY, title) in dividers {
                        frames.append(
                            .path(
                                dashed(
                                    from: CGPoint(x: rect.minX, y: lineY),
                                    to: CGPoint(x: rect.maxX, y: lineY), dash: 4, gap: 3),
                                color: theme.palette.tableBorder, lineWidth: 1, filled: false))
                        guard !title.isEmpty else { continue }
                        let line = text("[\(title)]", font: font, color: colour)
                        frames.append(
                            .glyphs(line, origin: CGPoint(x: rect.minX + 8, y: lineY + 12)))
                    }
                    y += 6 * metrics.scale
                }
            }
        }
        walk(diagram.items, depth: 0)
        // A bar nobody turned off runs to the end of the diagram.
        for participant in open.keys.sorted() {
            while !(open[participant]?.isEmpty ?? true) { finish(participant, at: y) }
        }
        return (tints, frames, bars, body, y, reach)
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
        theme: Theme, font: CTFont, metrics: Metrics
    ) -> [BlockBox.Decoration] {
        guard message.from < centres.count, message.to < centres.count else { return [] }
        var decorations: [BlockBox.Decoration] = []
        let color = theme.palette.secondaryText
        let line = text(words, font: font, color: color)
        let size = measure(line)
        let start = centres[message.from]
        let end = centres[message.to]
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
        let tip = CGPoint(x: end - direction * 2, y: y)
        let shaftEnd = CGPoint(x: tip.x - direction * metrics.arrowLength, y: y)
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

    /// Where a line towards `target` leaves a box. Rectangles only — a diamond
    /// or a circle is close enough at this size that the difference is a pixel.
    private static func exit(of frame: CGRect, towards target: CGPoint) -> CGPoint {
        let centre = frame.center
        let delta = CGPoint(x: target.x - centre.x, y: target.y - centre.y)
        guard delta.x != 0 || delta.y != 0 else { return centre }
        let scaleX = delta.x == 0 ? CGFloat.infinity : frame.width / 2 / abs(delta.x)
        let scaleY = delta.y == 0 ? CGFloat.infinity : frame.height / 2 / abs(delta.y)
        let scale = min(scaleX, scaleY)
        return CGPoint(x: centre.x + delta.x * scale, y: centre.y + delta.y * scale)
    }

    /// Where a straight line between two boxes starts and ends.
    ///
    /// Aiming each end at the other box's centre slants the line whenever the
    /// two boxes are not the same size, so a column of pairs comes out with one
    /// line leaning and the rest upright — which reads as a mistake, because it
    /// is one. Boxes that stand over each other are joined down the middle of
    /// what they share; anything else is aimed at the centre as before.
    private static func joined(_ from: CGRect, _ to: CGRect) -> (CGPoint, CGPoint) {
        let sharedX = min(from.maxX, to.maxX) - max(from.minX, to.minX)
        let sharedY = min(from.maxY, to.maxY) - max(from.minY, to.minY)
        if sharedX > 0, sharedY <= 0 {
            let x = (max(from.minX, to.minX) + min(from.maxX, to.maxX)) / 2
            let below = to.midY > from.midY
            return (
                CGPoint(x: x, y: below ? from.maxY : from.minY),
                CGPoint(x: x, y: below ? to.minY : to.maxY)
            )
        }
        if sharedY > 0, sharedX <= 0 {
            let y = (max(from.minY, to.minY) + min(from.maxY, to.maxY)) / 2
            let right = to.midX > from.midX
            return (
                CGPoint(x: right ? from.maxX : from.minX, y: y),
                CGPoint(x: right ? to.minX : to.maxX, y: y)
            )
        }
        return (exit(of: from, towards: to.center), exit(of: to, towards: from.center))
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
        let gap = 10 * metrics.scale
        // A framed block holds a row of its own, so the grid is measured in the
        // narrowest column any of them needs and a plain cell takes several of
        // them. The author's own column count still says where a row wraps.
        let unit = max(1, diagram.cells.map { columnsWide(of: $0, in: diagram) }.max() ?? 1)
        let columns = diagram.columns * unit
        let content = cellWidth * CGFloat(columns) + gap * CGFloat(columns - 1)
        let left = max(metrics.padding, (width - content) / 2)

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
                    case .arrowUp, .arrowDown:
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
                    .insetBy(dx: -gap / 2, dy: -gap / 2)
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
        let rows = place(diagram.cells, columns: columns, atColumn: 0, atRow: 0, unit: unit)
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
        func end(_ end: Flowchart.End) -> CGRect? {
            switch end {
            case .node(let node): return boxes[node]?.frame
            case .frame(let block): return frames[block]
            }
        }
        for edge in diagram.chart.edges {
            guard let from = end(edge.from), let to = end(edge.to) else { continue }
            let drawn = self.edge(
                edge, from: from, to: to, theme: theme, metrics: metrics, order: 0,
                side: 1, lane: 0,
                obstacles: boxes.values.map(\.frame).filter { !$0.intersects(from) }
                    .filter { !$0.intersects(to) })
            decorations += drawn.shaft
            labelDecorations += drawn.label
        }
        for index in diagram.chart.nodes.indices {
            guard let box = boxes[index] else { continue }
            decorations += node(box, theme: theme, metrics: metrics)
        }
        return Drawing(
            decorations: decorations + labelDecorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
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
        var tiles = diagram.services.indices.map { index in
            CGRect(
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

        for (index, service) in diagram.services.enumerated() {
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
        let ink = theme.diagramWheel[(colours[kind] ?? 0) % theme.diagramWheel.count]
        let cut = theme.palette.background
        let body = CGMutablePath()
        var detail: CGPath?
        switch kind {
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
            body.addRoundedRect(
                in: rect.insetBy(dx: rect.width * 0.08, dy: 0), cornerWidth: rect.width * 0.1,
                cornerHeight: rect.width * 0.1)
            let shelves = CGMutablePath()
            for share in [0.36, 0.68] as [CGFloat] {
                let y = rect.minY + rect.height * share
                shelves.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: y))
                shelves.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.14, y: y))
            }
            detail = shelves
        case .database, .disk:
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
        return decorations
    }

    // MARK: - Text

    private static func scaled(_ font: CTFont, by scale: CGFloat) -> CTFont {
        guard scale != 1 else { return font }
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil)
    }

    private static func text(_ string: String, font: CTFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(
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
