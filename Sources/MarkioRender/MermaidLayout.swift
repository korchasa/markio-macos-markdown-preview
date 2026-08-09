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
        var siblingGap: CGFloat { 26 * scale }
        var arrowLength: CGFloat { 9 * scale }
        var arrowWidth: CGFloat { 7 * scale }
        var messageGap: CGFloat { 34 * scale }
        var columnGap: CGFloat { 40 * scale }
        /// The margin around the picture is the block's, not the diagram's, so
        /// it does not shrink with the drawing.
        let padding: CGFloat = 16
    }

    static func draw(_ diagram: MermaidDiagram, theme: Theme, width: CGFloat) -> Drawing {
        let first = draw(diagram, theme: theme, width: width, metrics: Metrics())
        let room = width - Metrics().padding * 2
        guard first.contentWidth > room, first.contentWidth > 0 else { return first }
        // Never below two thirds: past that the labels stop being readable, and
        // a diagram that runs a little wide is better than one nobody can read.
        let scale = max(0.66, room / first.contentWidth)
        return draw(diagram, theme: theme, width: width, metrics: Metrics(scale: scale))
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
        case .titled(let title, let inner):
            return titled(title, inner, theme: theme, width: width, metrics: metrics)
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

    private static func moved(_ decoration: BlockBox.Decoration, down: CGFloat)
        -> BlockBox.Decoration
    {
        switch decoration {
        case .fill(let rect, let color, let cornerRadius):
            return .fill(
                rect: rect.offsetBy(dx: 0, dy: down), color: color, cornerRadius: cornerRadius)
        case .stroke(let rect, let color, let width):
            return .stroke(rect: rect.offsetBy(dx: 0, dy: down), color: color, width: width)
        case .path(let path, let color, let lineWidth, let filled):
            var shift = CGAffineTransform(translationX: 0, y: down)
            return .path(
                path.copy(using: &shift) ?? path, color: color, lineWidth: lineWidth,
                filled: filled)
        case .image(let image, let rect):
            return .image(image, rect: rect.offsetBy(dx: 0, dy: down))
        case .glyphs(let line, let origin):
            return .glyphs(line, origin: CGPoint(x: origin.x, y: origin.y + down))
        }
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

        // The same ranking a flowchart uses: a box sits one rank below whatever
        // points at it, and a cycle cannot spin it.
        let ranks = self.ranks(
            count: entities.count, edges: diagram.links.map { ($0.from, $0.to) })
        let down = diagram.direction == .down || diagram.direction == .up
        let depths = ranks.map { rank in
            rank.map { down ? entities[$0].frame.height : entities[$0].frame.width }.max() ?? 0
        }
        let extents = ranks.map { rank in
            rank.reduce(CGFloat(0)) {
                $0 + (down ? entities[$1].frame.width : entities[$1].frame.height)
            } + metrics.siblingGap * CGFloat(max(0, rank.count - 1))
        }
        let crossExtent = extents.max() ?? 0
        let rankGap = metrics.rankGap * 1.3
        var rankOffset = metrics.padding
        for (level, rank) in ranks.enumerated() {
            var cross = (crossExtent - extents[level]) / 2
            for index in rank {
                let size = entities[index].frame.size
                entities[index].frame.origin =
                    down
                    ? CGPoint(x: cross, y: rankOffset + (depths[level] - size.height) / 2)
                    : CGPoint(x: rankOffset + (depths[level] - size.width) / 2, y: cross)
                cross += (down ? size.width : size.height) + metrics.siblingGap
            }
            rankOffset += depths[level] + rankGap
        }
        let along = rankOffset - rankGap - metrics.padding
        let content = CGSize(
            width: down ? crossExtent : along, height: down ? along : crossExtent)
        let left = max(metrics.padding, (width - content.width) / 2)
        for index in entities.indices {
            if down {
                entities[index].frame.origin.x += left
            } else {
                entities[index].frame.origin.x += left - metrics.padding
                entities[index].frame.origin.y += metrics.padding
            }
        }

        var decorations: [BlockBox.Decoration] = []
        for link in diagram.links {
            guard link.from < entities.count, link.to < entities.count else { continue }
            decorations += relation(
                link, from: entities[link.from].frame, to: entities[link.to].frame, theme: theme,
                font: rowFont, metrics: metrics)
        }
        for entity in entities {
            decorations += self.entity(
                entity, theme: theme, padding: padding, metrics: metrics)
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: content.height + metrics.padding * 2),
            contentWidth: content.width
        )
    }

    private static func entity(
        _ entity: Entity, theme: Theme, padding: CGFloat, metrics: Metrics
    ) -> [BlockBox.Decoration] {
        let frame = entity.frame
        let path = CGPath(roundedRect: frame, cornerWidth: 3, cornerHeight: 3, transform: nil)
        var decorations: [BlockBox.Decoration] = [
            .path(path, color: theme.palette.background, lineWidth: 0, filled: true),
            .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false),
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
        let start = exit(of: from, towards: to.center)
        let end = exit(of: to, towards: from.center)
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
    private static let wheel: [CGColor] = [
        CGColor(red: 0.30, green: 0.55, blue: 0.90, alpha: 1),
        CGColor(red: 0.95, green: 0.60, blue: 0.25, alpha: 1),
        CGColor(red: 0.35, green: 0.72, blue: 0.50, alpha: 1),
        CGColor(red: 0.85, green: 0.40, blue: 0.45, alpha: 1),
        CGColor(red: 0.60, green: 0.50, blue: 0.85, alpha: 1),
        CGColor(red: 0.45, green: 0.75, blue: 0.80, alpha: 1),
        CGColor(red: 0.90, green: 0.75, blue: 0.30, alpha: 1),
        CGColor(red: 0.65, green: 0.55, blue: 0.45, alpha: 1),
    ]

    private static func pie(
        _ chart: PieChart, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale)
        let titleFont = scaled(theme.bodyBold, by: metrics.scale)
        let diameter = 180 * metrics.scale
        let swatch = 12 * metrics.scale
        let total = chart.total

        var entries: [(line: CTLine, size: CGSize)] = []
        for slice in chart.slices {
            let share = Int((slice.value / total * 100).rounded())
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
        for (index, slice) in chart.slices.enumerated() {
            let sweep = CGFloat(slice.value / total) * .pi * 2
            let wedge = CGMutablePath()
            wedge.move(to: centre)
            wedge.addArc(
                center: centre, radius: diameter / 2, startAngle: angle, endAngle: angle + sweep,
                clockwise: false)
            wedge.closeSubpath()
            decorations.append(
                .path(wedge, color: wheel[index % wheel.count], lineWidth: 0, filled: true))
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
                .fill(rect: box, color: wheel[index % wheel.count], cornerRadius: 2))
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
            boxes.append(
                Placed(
                    frame: CGRect(origin: .zero, size: box),
                    lines: lines,
                    labelSize: size,
                    shape: node.shape,
                    style: Flowchart.Style(stroke: colour(wheel[branch[index] % wheel.count]))
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
                        color: wheel[branch[child] % wheel.count],
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
                    tint: wheel[(period.section ?? index) % wheel.count]
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
                    rect: band, color: wheel[index % wheel.count].copy(alpha: 0.22) ?? wheel[0],
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
                    tint: wheel[(task.section ?? index) % wheel.count]
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
                    rect: band, color: wheel[index % wheel.count].copy(alpha: 0.22) ?? wheel[0],
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
        func level(_ score: Int) -> CGFloat {
            (plotBottom - dotRadius) - (plotHeight - dotRadius * 2) * CGFloat(score - 1) / 4
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
        // A day gets at least a hair of width, and the plot never gets so wide
        // that the caller's shrinking cannot bring it back.
        let plotWidth = max(
            240 * metrics.scale, min(430 * metrics.scale, span * 14 * metrics.scale))
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
            measure(text("00-00", font: smallFont, color: theme.palette.text)).height
            + 10 * metrics.scale
        // A section takes a row of its own before the tasks under it.
        var rows = chart.tasks.count
        var lastSection: Int?
        for task in chart.tasks where task.section != lastSection {
            rows += 1
            lastSection = task.section
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

        // Five ticks across the span, each with the day it stands for. Without a
        // date in the source the axis counts days from the first task instead.
        let axisTop = metrics.padding + titleRoom
        let bodyTop = axisTop + axisHeight
        let bodyBottom = bodyTop + CGFloat(rows) * rowHeight
        for step in 0...4 {
            let day = span * Double(step) / 4
            let x = plotLeft + CGFloat(day) * perDay
            let rule = CGMutablePath()
            rule.move(to: CGPoint(x: x, y: bodyTop))
            rule.addLine(to: CGPoint(x: x, y: bodyBottom))
            decorations.append(
                .path(rule, color: theme.palette.tableBorder, lineWidth: 0.5, filled: false))
            let words =
                chart.origin.map { GanttChart.date($0 + Int(day.rounded())) }
                ?? "day \(Int(day.rounded()))"
            let line = text(words, font: smallFont, color: theme.palette.secondaryText)
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

        var y = bodyTop
        lastSection = nil
        for (index, task) in chart.tasks.enumerated() {
            if task.section != lastSection {
                lastSection = task.section
                if let section = task.section {
                    let line = sectionNames[section]
                    let size = measure(line)
                    let band = CGRect(
                        x: left, y: y, width: content, height: rowHeight - 2 * metrics.scale)
                    decorations.append(
                        .fill(
                            rect: band,
                            color: wheel[section % wheel.count].copy(alpha: 0.16) ?? wheel[0],
                            cornerRadius: 3 * metrics.scale))
                    decorations.append(
                        .glyphs(
                            line,
                            origin: CGPoint(
                                x: left + 6 * metrics.scale,
                                y: band.midY + size.height / 2 - descent(line))))
                }
                y += rowHeight
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
                        ? wheel[0]
                        : wheel[(task.section ?? 0) % wheel.count]
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
            y += rowHeight
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

        let labels = diagram.nodes.map { text($0, font: font, color: theme.palette.text) }
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
            let colour = wheel[flow.from % wheel.count]
            decorations.append(
                .path(ribbon, color: colour.copy(alpha: 0.4) ?? colour, lineWidth: 0, filled: true))
        }
        for (index, frame) in frames.enumerated() {
            decorations.append(
                .fill(
                    rect: frame, color: wheel[index % wheel.count],
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
        squarify(map.nodes[0].children, in: frames[0])

        var decorations: [BlockBox.Decoration] = []
        for (index, node) in map.nodes.enumerated() where index > 0 {
            let frame = frames[index]
            guard frame.width > 2, frame.height > 2 else { continue }
            let colour = wheel[index % wheel.count]
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
            // leaf gets its name and its number in the middle.
            let words = branch ? node.label : "\(node.label)  \(number(node.value))"
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
        let bit = 15 * metrics.scale
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
                    color: wheel[piece.field % wheel.count].copy(alpha: 0.2)
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
                let line = text("\(number)", font: font, color: theme.palette.secondaryText)
                let size = measure(line)
                let anchor = x == frame.minX ? x + 1 : x - 1 - size.width
                decorations.append(
                    .glyphs(
                        line,
                        origin: CGPoint(
                            x: min(left + content - size.width, max(left, anchor)),
                            y: top + numberRoom - 3 * metrics.scale - descent(line))))
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
        let columnWidth = 150 * metrics.scale

        struct Card {
            var label: CTLine
            var labelSize: CGSize
            var details: CTLine?
            var detailsSize: CGSize
            var priority: String
            var height: CGFloat
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
                let label = text(card.label, font: font, color: theme.palette.text)
                var details: CTLine?
                var detailsSize = CGSize.zero
                if !card.details.isEmpty {
                    let line = text(
                        card.details.joined(separator: " · "), font: smallFont,
                        color: theme.palette.secondaryText)
                    details = line
                    detailsSize = measure(line)
                }
                let labelSize = measure(label)
                let height =
                    pad * 2 + labelSize.height + (details == nil ? 0 : detailsSize.height + 2)
                cards.append(
                    Card(
                        label: label, labelSize: labelSize, details: details,
                        detailsSize: detailsSize, priority: card.priority, height: height))
                stack += height + 6 * metrics.scale
            }
            columns.append(
                Column(head: head, headSize: measure(head), cards: cards, height: stack))
        }
        let headHeight = (columns.map(\.headSize.height).max() ?? 0) + pad * 2
        let bodyHeight = columns.map(\.height).max() ?? 0
        let content = CGFloat(columns.count) * columnWidth + CGFloat(columns.count - 1) * gap
        let height = metrics.padding * 2 + headHeight + 8 * metrics.scale + bodyHeight

        let left = max(metrics.padding, (width - content) / 2)
        var decorations: [BlockBox.Decoration] = []
        for (index, column) in columns.enumerated() {
            let x = left + CGFloat(index) * (columnWidth + gap)
            let tint = wheel[index % wheel.count]
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
                decorations.append(
                    .glyphs(
                        card.label,
                        origin: CGPoint(
                            x: frame.minX + pad + 4 * metrics.scale,
                            y: frame.minY + pad + card.labelSize.height - descent(card.label))))
                if let details = card.details {
                    decorations.append(
                        .glyphs(
                            details,
                            origin: CGPoint(
                                x: frame.minX + pad + 4 * metrics.scale,
                                y: frame.minY + pad + card.labelSize.height + 2
                                    + card.detailsSize.height - descent(details))))
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
                    color: wheel[index % wheel.count].copy(alpha: 0.14) ?? wheel[index],
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

        for point in chart.points {
            // y grows up the page here and down everywhere else, so a point
            // written at 1 belongs at the top.
            let centre = CGPoint(
                x: plot.minX + CGFloat(point.x) * side,
                y: plot.maxY - CGFloat(point.y) * side
            )
            let dot = CGRect(
                x: centre.x - 5 * metrics.scale, y: centre.y - 5 * metrics.scale,
                width: 10 * metrics.scale, height: 10 * metrics.scale)
            decorations.append(
                .path(
                    CGPath(ellipseIn: dot, transform: nil), color: wheel[0], lineWidth: 0,
                    filled: true))
            let line = text(point.label, font: font, color: theme.palette.text)
            let size = measure(line)
            // Beside its dot, and on the other side of it when the name would
            // otherwise run out of the square.
            let right = centre.x + 8 * metrics.scale
            let x =
                right + size.width <= plot.maxX ? right : centre.x - 8 * metrics.scale - size.width
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: max(plot.minX, x), y: centre.y + size.height / 2 - descent(line))))
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
            let colour = wheel[index % wheel.count]
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

    /// A number for an axis: no decimal point where it does not need one.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
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
        let content = gutter + CGFloat(columns) * step
        let height = metrics.padding * 2 + CGFloat(graph.branches.count) * lane

        let left = max(metrics.padding, (width - content) / 2)
        func centre(of commit: GitGraph.Commit) -> CGPoint {
            CGPoint(
                x: left + gutter + step * (CGFloat(commit.column) + 0.5),
                y: metrics.padding + lane * (CGFloat(commit.branch) + 0.5)
            )
        }

        var decorations: [BlockBox.Decoration] = []
        for (index, name) in graph.branches.enumerated() {
            let y = metrics.padding + lane * (CGFloat(index) + 0.5)
            let colour = wheel[index % wheel.count]
            let own = graph.commits.filter { $0.branch == index }
            guard let first = own.first, let last = own.last else { continue }
            let rail = CGMutablePath()
            rail.move(to: CGPoint(x: centre(of: first).x, y: y))
            rail.addLine(to: CGPoint(x: centre(of: last).x, y: y))
            decorations.append(
                .path(rail, color: colour, lineWidth: 2.5 * metrics.scale, filled: false))
            let line = text(name, font: branchFont, color: colour)
            let size = measure(line)
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: left + gutter - 10 * metrics.scale - size.width,
                        y: y + size.height / 2 - descent(line))))
        }
        // A branch is drawn from where it left its parent and a merge back to
        // where it rejoined, so a lane is never a line floating on its own.
        for (index, commit) in graph.commits.enumerated() {
            let here = centre(of: commit)
            let opened = !graph.commits[..<index].contains { $0.branch == commit.branch }
            let source =
                commit.merges
                ?? (opened
                    ? graph.commits[..<index].lastIndex(where: { $0.branch != commit.branch })
                    : nil)
            guard let source else { continue }
            let from = centre(of: graph.commits[source])
            let path = CGMutablePath()
            path.move(to: from)
            path.addCurve(
                to: here,
                control1: CGPoint(x: (from.x + here.x) / 2, y: from.y),
                control2: CGPoint(x: (from.x + here.x) / 2, y: here.y))
            decorations.append(
                .path(
                    path, color: wheel[commit.branch % wheel.count],
                    lineWidth: 2 * metrics.scale, filled: false))
        }
        for commit in graph.commits {
            let here = centre(of: commit)
            let colour = wheel[commit.branch % wheel.count]
            let dot = CGRect(
                x: here.x - radius, y: here.y - radius, width: radius * 2, height: radius * 2)
            decorations.append(
                .path(
                    CGPath(ellipseIn: dot, transform: nil), color: colour, lineWidth: 0,
                    filled: true))
            if commit.highlighted {
                decorations.append(
                    .path(
                        CGPath(
                            ellipseIn: dot.insetBy(dx: -3 * metrics.scale, dy: -3 * metrics.scale),
                            transform: nil),
                        color: colour, lineWidth: 1.5 * metrics.scale, filled: false))
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
            let colour = node.style.text.map(cgColor) ?? theme.palette.text
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

        let ranks = self.ranks(chart)
        let down = chart.direction == .down || chart.direction == .up
        // An edge's words are written across the gap between two ranks, so the
        // gap has to be wide enough to hold them.
        let labelFont = scaled(theme.controlLabel, by: metrics.scale)
        let labelRoom =
            chart.edges.filter { !$0.label.isEmpty }
            .map { measure(text($0.label, font: labelFont, color: theme.palette.text)) }
            .map { down ? $0.height : $0.width }.max() ?? 0
        let rankGap = max(
            metrics.rankGap * (chart.groups.isEmpty ? 1 : 1.6),
            labelRoom + 20 * metrics.scale
        )
        // Rank runs down the page for `TD` and across it for `LR`; laying the
        // graph out in rank and cross axes and swapping at the end is what keeps
        // one placement routine instead of two. Every rank is measured before
        // any is placed, because a rank is centred against the widest one and
        // that is not known until the last has been measured.
        let depths = ranks.map { rank in
            rank.map { down ? boxes[$0].frame.height : boxes[$0].frame.width }.max() ?? 0
        }
        func extent(_ index: Int) -> CGFloat {
            down ? boxes[index].frame.width : boxes[index].frame.height
        }
        func span(_ indices: [Int]) -> CGFloat {
            indices.reduce(0) { $0 + extent($1) }
                + metrics.siblingGap * CGFloat(max(0, indices.count - 1))
        }

        // A subgraph gets a strip of the cross axis to itself, the same strip on
        // every rank. That is what makes its frame enclose its own members and
        // nothing else: no node outside the group is ever placed in the strip.
        var groupOf = [Int?](repeating: nil, count: boxes.count)
        for (index, group) in chart.groups.enumerated() {
            for member in group.members where member < groupOf.count { groupOf[member] = index }
        }
        let perRank = ranks.map { rank in
            (
                grouped: chart.groups.indices.map { group in
                    rank.filter { groupOf[$0] == group }
                },
                loose: rank.filter { groupOf[$0] == nil }
            )
        }
        let groupWidths = chart.groups.indices.map { group in
            perRank.map { span($0.grouped[group]) }.max() ?? 0
        }
        let looseWidth = perRank.map { span($0.loose) }.max() ?? 0
        // Strips are laid out in the order the flow reaches them, so a graph
        // still reads from its first node onwards instead of jumping about.
        var strips: [(group: Int?, width: CGFloat, rank: Int, order: Int)] = []
        for group in chart.groups.indices where groupWidths[group] > 0 {
            let rank = perRank.firstIndex { !$0.grouped[group].isEmpty } ?? 0
            strips.append((group, groupWidths[group], rank, strips.count))
        }
        if looseWidth > 0 {
            let rank = perRank.firstIndex { !$0.loose.isEmpty } ?? 0
            strips.append((nil, looseWidth, rank, strips.count))
        }
        strips.sort { ($0.rank, $0.order) < ($1.rank, $1.order) }

        var starts = [CGFloat](repeating: 0, count: chart.groups.count)
        var looseStart: CGFloat = 0
        var cursor: CGFloat = 0
        for strip in strips {
            if let group = strip.group { starts[group] = cursor } else { looseStart = cursor }
            cursor += strip.width + metrics.siblingGap * 2
        }
        // A subgraph's title is written above its frame, so the room for it is
        // on whichever axis runs down the page.
        let titleRoom = chart.groups.isEmpty ? 0 : 20 * metrics.scale
        let crossBase = down ? 0 : titleRoom
        let crossExtent = crossBase + max(0, cursor - metrics.siblingGap * 2)

        var rankOffset = metrics.padding + (down ? titleRoom : 0)
        for level in ranks.indices {
            func place(_ index: Int, at cross: CGFloat) {
                let size = boxes[index].frame.size
                boxes[index].frame.origin =
                    down
                    ? CGPoint(
                        x: crossBase + cross, y: rankOffset + (depths[level] - size.height) / 2)
                    : CGPoint(
                        x: rankOffset + (depths[level] - size.width) / 2, y: crossBase + cross)
            }
            for group in chart.groups.indices {
                let members = perRank[level].grouped[group]
                var cross = starts[group] + (groupWidths[group] - span(members)) / 2
                for index in members {
                    place(index, at: cross)
                    cross += extent(index) + metrics.siblingGap
                }
            }
            let loose = perRank[level].loose
            var cross = looseStart + (looseWidth - span(loose)) / 2
            for index in loose {
                place(index, at: cross)
                cross += extent(index) + metrics.siblingGap
            }
            rankOffset += depths[level] + rankGap
        }

        let along = rankOffset - rankGap - metrics.padding
        // `BT` and `RL` are the same graph read from the other end, so the rank
        // axis is turned over once every box has been placed.
        if chart.direction == .up || chart.direction == .left {
            for index in boxes.indices {
                let frame = boxes[index].frame
                if down {
                    boxes[index].frame.origin.y =
                        metrics.padding * 2 + along - frame.maxY
                } else {
                    boxes[index].frame.origin.x =
                        metrics.padding * 2 + along - frame.maxX
                }
            }
        }
        // A subgraph's frame stands a little outside the boxes it holds, and the
        // picture has to be that much wider or the frame runs off the column.
        let groupInset = chart.groups.isEmpty ? 0 : metrics.siblingGap
        let content = CGSize(
            width: (down ? crossExtent : along) + groupInset,
            height: (down ? along : crossExtent) + groupInset
        )
        // Centre the picture in the reading column, and never let it run out of
        // it: a diagram wider than the column starts at the margin instead of
        // being pushed off the left edge.
        let left = max(metrics.padding, (width - content.width) / 2)
        for index in boxes.indices {
            if down {
                boxes[index].frame.origin.x += left
            } else {
                boxes[index].frame.origin.x += left - metrics.padding
                boxes[index].frame.origin.y += metrics.padding
            }
        }

        var decorations: [BlockBox.Decoration] = []
        // Frames first: everything else in the diagram stands on top of them.
        for group in chart.groups {
            decorations += frame(
                group, boxes: boxes, theme: theme, metrics: metrics, titleRoom: titleRoom)
        }
        var labels: [BlockBox.Decoration] = []
        // Two labelled edges leaving one node run side by side, so their words
        // are spaced out along the line instead of landing on each other.
        var written: [Int: Int] = [:]
        // Two nodes joined both ways — a state and the state it goes back to —
        // have their words laid either side of the line rather than on top of
        // each other.
        func pair(_ edge: Flowchart.Edge) -> Int {
            min(edge.from, edge.to) &* 100_003 &+ max(edge.from, edge.to)
        }
        var pairs: [Int: Int] = [:]
        for edge in chart.edges where !edge.label.isEmpty {
            pairs[pair(edge), default: 0] += 1
        }
        var seen: [Int: Int] = [:]
        for edge in chart.edges {
            guard edge.from < boxes.count, edge.to < boxes.count else { continue }
            var order = 0
            var side: CGFloat = 0
            if !edge.label.isEmpty {
                order = written[edge.from, default: 0]
                written[edge.from] = order + 1
                let key = pair(edge)
                let index = seen[key, default: 0]
                seen[key] = index + 1
                let count = pairs[key] ?? 1
                side = CGFloat(index) - CGFloat(count - 1) / 2
            }
            let drawn = self.edge(
                edge, from: boxes[edge.from], to: boxes[edge.to], theme: theme, metrics: metrics,
                order: order, side: side)
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

    /// Longest-path ranking: a node sits one rank below everything that points
    /// at it. Relaxing the edges `|V|` times gives the same answer as a
    /// topological sweep and, unlike one, cannot spin on a cycle.
    private static func ranks(_ chart: Flowchart) -> [[Int]] {
        ranks(count: chart.nodes.count, edges: chart.edges.map { ($0.from, $0.to) })
    }

    private static func ranks(count: Int, edges: [(from: Int, to: Int)]) -> [[Int]] {
        var rank = [Int](repeating: 0, count: count)
        for _ in 0..<count {
            var moved = false
            for edge in edges where edge.from < rank.count && edge.to < rank.count {
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

    /// The titled frame a `subgraph` draws around its own nodes.
    private static func frame(
        _ group: Flowchart.Group, boxes: [Placed], theme: Theme, metrics: Metrics,
        titleRoom: CGFloat
    ) -> [BlockBox.Decoration] {
        let frames = group.members.filter { $0 < boxes.count }.map { boxes[$0].frame }
        guard var bounds = frames.first else { return [] }
        for frame in frames.dropFirst() { bounds = bounds.union(frame) }
        bounds = bounds.insetBy(dx: -metrics.siblingGap / 2, dy: -metrics.siblingGap / 2)
        let path = CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        var decorations: [BlockBox.Decoration] = [
            .path(path, color: theme.palette.codeBackground, lineWidth: 0, filled: true),
            .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false),
        ]
        guard !group.title.isEmpty else { return decorations }
        let line = text(
            group.title,
            font: scaled(theme.controlLabel, by: metrics.scale),
            color: theme.palette.secondaryText
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
        var decorations: [BlockBox.Decoration] = []
        // A `fill:transparent` is the author asking for the page to show
        // through, which is not the same as filling it with the page's colour.
        if let fill = box.style.fill, fill.isTransparent {
            // Nothing to fill.
        } else {
            let colour = box.style.fill.map(cgColor) ?? theme.palette.tableHeaderBackground
            decorations.append(.path(path, color: colour, lineWidth: 0, filled: true))
        }
        decorations.append(
            .path(
                path,
                color: box.style.stroke.map(cgColor) ?? theme.palette.tableBorder,
                lineWidth: (box.style.strokeWidth.map { CGFloat($0) } ?? 1) * metrics.scale,
                filled: false
            )
        )
        // The stack is centred on the box, and each line is centred in the
        // stack, so a two-line label sits the way a one-line label does.
        var y = box.frame.midY - box.labelSize.height / 2
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

    private static func cgColor(_ colour: Flowchart.Colour) -> CGColor {
        CGColor(
            red: max(0, colour.red), green: max(0, colour.green), blue: max(0, colour.blue),
            alpha: 1)
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
        case .rectangle, .subroutine:
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
        case .cylinder:
            // A drum seen from the side: an ellipse for the lid, straight sides,
            // and the same curve again at the foot.
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
    }

    /// A line between two centres, cut off at each box's edge.
    ///
    /// Clipping to the boxes rather than joining named sides is what lets the
    /// same routine draw an edge down a rank, across one, or back up the graph.
    private static func edge(
        _ edge: Flowchart.Edge, from: Placed, to: Placed, theme: Theme, metrics: Metrics,
        order: Int, side: CGFloat
    ) -> (shaft: [BlockBox.Decoration], label: [BlockBox.Decoration]) {
        let start = exit(of: from.frame, towards: to.frame.center)
        let end = exit(of: to.frame, towards: from.frame.center)
        var decorations: [BlockBox.Decoration] = []
        let color = theme.palette.secondaryText
        let width: CGFloat = (edge.stroke == .thick ? 2.5 : 1.3) * metrics.scale
        let shaft = CGMutablePath()
        let head = edge.arrow ? metrics.arrowLength : 0
        let tip = end
        let direction = normalized(CGPoint(x: end.x - start.x, y: end.y - start.y))
        let shaftEnd = CGPoint(x: tip.x - direction.x * head, y: tip.y - direction.y * head)
        if edge.stroke == .dotted {
            shaft.addPath(dashed(from: start, to: shaftEnd, dash: 4, gap: 4))
        } else {
            shaft.move(to: start)
            shaft.addLine(to: shaftEnd)
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
            color: theme.palette.secondaryText
        )
        let size = measure(line)
        // An edge between neighbouring ranks is labelled in the middle; one that
        // skips a rank is labelled in the first gap it crosses, where there is
        // nothing else to sit on.
        let length = distance(start, end)
        let base = min(length / 2, metrics.rankGap / 2 + 6) + CGFloat(order) * (size.width + 10)
        let along = max(size.width / 2 + 2, min(base, length - size.width / 2 - 2))
        // Sideways room is the label's own size, so two words either side of a
        // vertical line clear each other however long they are.
        let across = CGPoint(x: -direction.y, y: direction.x)
        let step = abs(direction.y) > abs(direction.x) ? size.width + 10 : size.height + 6
        let middle = CGPoint(
            x: start.x + direction.x * along + across.x * side * step,
            y: start.y + direction.y * along + across.y * side * step
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
        let step = boxWidth + metrics.columnGap
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
        let top = metrics.padding + titleRoom
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
            let path = CGPath(roundedRect: frame, cornerWidth: 4, cornerHeight: 4, transform: nil)
            decorations.append(
                .path(path, color: theme.palette.tableHeaderBackground, lineWidth: 0, filled: true))
            decorations.append(
                .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false))
            decorations.append(
                .glyphs(
                    labels[index],
                    origin: CGPoint(
                        x: centre - sizes[index].width / 2,
                        y: frame.midY + sizes[index].height / 2 - descent(labels[index])
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

    /// Everything below the participant boxes, in document order.
    ///
    /// Frames, activation bars and messages come back apart because they are
    /// painted in that order: a frame is behind its contents, and a bar is
    /// behind the arrows that start and end it.
    private static func script(
        _ diagram: SequenceDiagram, centres: [CGFloat], boxWidth: CGFloat, from top: CGFloat,
        theme: Theme, font: CTFont, metrics: Metrics
    ) -> (
        frames: [BlockBox.Decoration], bars: [BlockBox.Decoration],
        body: [BlockBox.Decoration], bottom: CGFloat, reach: CGFloat
    ) {
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
                    let inset = CGFloat(depth) * 9 * metrics.scale
                    let frameTop = y - metrics.messageGap * 0.55
                    var dividers: [(CGFloat, String)] = []
                    y += 6 * metrics.scale
                    for (index, section) in block.sections.enumerated() {
                        if index == 0 {
                            body += tag(
                                block.kind, title: section.title,
                                at: CGPoint(x: left - 10 + inset, y: frameTop), theme: theme,
                                font: font, metrics: metrics)
                            y += 12 * metrics.scale
                        } else {
                            dividers.append((y - metrics.messageGap * 0.4, section.title))
                            y += 14 * metrics.scale
                        }
                        walk(section.items, depth: depth + 1)
                    }
                    let frameBottom = y - metrics.messageGap * 0.4
                    let rect = CGRect(
                        x: left - 10 + inset, y: frameTop,
                        width: right - left + 20 - inset * 2, height: frameBottom - frameTop)
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
        return (frames, bars, body, y, reach)
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
        decorations.append(
            .glyphs(
                line,
                origin: CGPoint(x: (start + end) / 2 - size.width / 2, y: y - 5)
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
        for tick in 1...chart.ticks {
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
            let colour = wheel[index % wheel.count]
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
                    .fill(rect: box, color: wheel[index % wheel.count], cornerRadius: 2))
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
            let colour = node.style.text.map(cgColor) ?? theme.palette.text
            labels.append(labelLines(node.label, font: font, color: colour))
        }
        // Every column is the same width: a grid whose columns drifted would
        // stop being the grid the author counted out.
        let cellWidth = max(
            metrics.minimumNodeWidth,
            (labels.map(\.size.width).max() ?? 0) + metrics.nodePaddingX * 2)
        let cellHeight = (labels.map(\.size.height).max() ?? 0) + metrics.nodePaddingY * 2
        let gap = 10 * metrics.scale
        let content = cellWidth * CGFloat(diagram.columns) + gap * CGFloat(diagram.columns - 1)
        let left = max(metrics.padding, (width - content) / 2)

        // Cells fill the row until the next one would not fit, and then wrap.
        var boxes: [Int: Placed] = [:]
        var column = 0
        var row = 0
        for cell in diagram.cells {
            let span = min(cell.span, diagram.columns)
            if column + span > diagram.columns {
                column = 0
                row += 1
            }
            if let node = cell.node {
                let frame = CGRect(
                    x: left + CGFloat(column) * (cellWidth + gap),
                    y: metrics.padding + CGFloat(row) * (cellHeight + gap),
                    width: cellWidth * CGFloat(span) + gap * CGFloat(span - 1),
                    height: cellHeight)
                boxes[node] = Placed(
                    frame: frame, lines: labels[node].lines, labelSize: labels[node].size,
                    shape: diagram.chart.nodes[node].shape, style: diagram.chart.nodes[node].style)
            }
            column += span
            if column >= diagram.columns {
                column = 0
                row += 1
            }
        }
        let rows = column == 0 ? row : row + 1
        let height =
            metrics.padding * 2 + CGFloat(rows) * cellHeight + CGFloat(max(0, rows - 1)) * gap

        var decorations: [BlockBox.Decoration] = []
        var labelDecorations: [BlockBox.Decoration] = []
        for edge in diagram.chart.edges {
            guard let from = boxes[edge.from], let to = boxes[edge.to] else { continue }
            let drawn = self.edge(
                edge, from: from, to: to, theme: theme, metrics: metrics, order: 0, side: 1)
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
        let content =
            columnWidths.reduce(0, +) + columnGap * CGFloat(columns - 1)
        let height =
            rowHeights.reduce(0, +) + rowGap * CGFloat(rows - 1) + metrics.padding * 2
        let left = max(metrics.padding, (width - content) / 2)

        var columnStarts = [CGFloat](repeating: 0, count: columns)
        var x = left
        for column in 0..<columns {
            columnStarts[column] = x
            x += columnWidths[column] + columnGap
        }
        var rowStarts = [CGFloat](repeating: 0, count: rows)
        var y = metrics.padding
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
        // Frames first, so a tile is never drawn under its own group's fill.
        for group in diagram.groups.indices {
            let members = diagram.services.indices.filter { diagram.services[$0].group == group }
            guard let first = members.first else { continue }
            var bounds = tiles[first]
            for member in members.dropFirst() { bounds = bounds.union(tiles[member]) }
            bounds = bounds.insetBy(dx: -framePadding, dy: -framePadding)
            bounds.origin.y -= titleRoom
            bounds.size.height += titleRoom
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
        let ink = wheel[(colours[kind] ?? 0) % wheel.count]
        let cut = theme.palette.background
        let body = CGMutablePath()
        var detail: CGPath?
        switch kind {
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
