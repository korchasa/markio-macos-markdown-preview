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
        }
    }

    // MARK: - Flowchart

    private struct Placed {
        var frame: CGRect
        var label: CTLine
        var labelSize: CGSize
        var shape: Flowchart.Shape
    }

    private static func flowchart(
        _ chart: Flowchart, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale)
        var boxes: [Placed] = []
        for node in chart.nodes {
            let line = text(node.label, font: font, color: theme.palette.text)
            let size = measure(line)
            var box = CGSize(
                width: max(metrics.minimumNodeWidth, size.width + metrics.nodePaddingX * 2),
                height: size.height + metrics.nodePaddingY * 2
            )
            // A diamond only holds its words across the middle, so it needs the
            // room a rectangle does not.
            if node.shape == .diamond {
                box.width += size.width * 0.5 + 12 * metrics.scale
                box.height += size.height * 0.7
            }
            if node.shape == .circle {
                let side = max(box.width, box.height + size.width * 0.3)
                box = CGSize(width: side, height: side)
            }
            boxes.append(
                Placed(
                    frame: CGRect(origin: .zero, size: box),
                    label: line,
                    labelSize: size,
                    shape: node.shape
                )
            )
        }

        let ranks = self.ranks(chart)
        let down = chart.direction == .down
        // Rank runs down the page for `TD` and across it for `LR`; laying the
        // graph out in rank and cross axes and swapping at the end is what keeps
        // one placement routine instead of two. Every rank is measured before
        // any is placed, because a rank is centred against the widest one and
        // that is not known until the last has been measured.
        let depths = ranks.map { rank in
            rank.map { down ? boxes[$0].frame.height : boxes[$0].frame.width }.max() ?? 0
        }
        let extents = ranks.map { rank in
            rank.reduce(CGFloat(0)) {
                $0 + (down ? boxes[$1].frame.width : boxes[$1].frame.height)
            } + metrics.siblingGap * CGFloat(max(0, rank.count - 1))
        }
        let crossExtent = extents.max() ?? 0

        var rankOffset = metrics.padding
        for (level, rank) in ranks.enumerated() {
            var cross = (crossExtent - extents[level]) / 2
            for index in rank {
                let size = boxes[index].frame.size
                boxes[index].frame.origin =
                    down
                    ? CGPoint(x: cross, y: rankOffset + (depths[level] - size.height) / 2)
                    : CGPoint(x: rankOffset + (depths[level] - size.width) / 2, y: cross)
                cross += (down ? size.width : size.height) + metrics.siblingGap
            }
            rankOffset += depths[level] + metrics.rankGap
        }

        let along = rankOffset - metrics.rankGap - metrics.padding
        let content = CGSize(
            width: down ? crossExtent : along,
            height: down ? along : crossExtent
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
        for edge in chart.edges {
            guard edge.from < boxes.count, edge.to < boxes.count else { continue }
            decorations += self.edge(
                edge, from: boxes[edge.from], to: boxes[edge.to], theme: theme, metrics: metrics)
        }
        for box in boxes { decorations += node(box, theme: theme) }
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
        var rank = [Int](repeating: 0, count: chart.nodes.count)
        for _ in 0..<chart.nodes.count {
            var moved = false
            for edge in chart.edges where edge.from < rank.count && edge.to < rank.count {
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

    private static func node(_ box: Placed, theme: Theme) -> [BlockBox.Decoration] {
        let path = shape(box)
        let origin = CGPoint(
            x: box.frame.midX - box.labelSize.width / 2,
            y: box.frame.midY + box.labelSize.height / 2 - descent(box.label)
        )
        return [
            .path(path, color: theme.palette.tableHeaderBackground, lineWidth: 0, filled: true),
            .path(path, color: theme.palette.tableBorder, lineWidth: 1, filled: false),
            .glyphs(box.label, origin: origin),
        ]
    }

    private static func shape(_ box: Placed) -> CGPath {
        let frame = box.frame
        switch box.shape {
        case .rectangle:
            return CGPath(roundedRect: frame, cornerWidth: 3, cornerHeight: 3, transform: nil)
        case .rounded:
            return CGPath(roundedRect: frame, cornerWidth: 9, cornerHeight: 9, transform: nil)
        case .stadium:
            let radius = frame.height / 2
            return CGPath(
                roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .circle:
            return CGPath(ellipseIn: frame, transform: nil)
        case .diamond:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.midX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.midY))
            path.closeSubpath()
            return path
        }
    }

    /// A line between two centres, cut off at each box's edge.
    ///
    /// Clipping to the boxes rather than joining named sides is what lets the
    /// same routine draw an edge down a rank, across one, or back up the graph.
    private static func edge(
        _ edge: Flowchart.Edge, from: Placed, to: Placed, theme: Theme, metrics: Metrics
    ) -> [BlockBox.Decoration] {
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
        guard !edge.label.isEmpty else { return decorations }
        let line = text(
            edge.label,
            font: scaled(theme.controlLabel, by: metrics.scale),
            color: theme.palette.secondaryText
        )
        let size = measure(line)
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let plate = CGRect(
            x: middle.x - size.width / 2 - 3,
            y: middle.y - size.height / 2 - 1,
            width: size.width + 6,
            height: size.height + 2
        )
        // The label sits on the line, so it needs the page under it.
        decorations.append(.fill(rect: plate, color: theme.palette.background, cornerRadius: 2))
        decorations.append(
            .glyphs(
                line,
                origin: CGPoint(
                    x: middle.x - size.width / 2,
                    y: middle.y + size.height / 2 - descent(line)
                )
            )
        )
        return decorations
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
        let left = max(metrics.padding, (width - content) / 2)
        let centres = (0..<diagram.participants.count).map {
            left + boxWidth / 2 + step * CGFloat($0)
        }

        let top = metrics.padding
        let firstMessage = top + boxHeight + metrics.messageGap
        let height =
            firstMessage + metrics.messageGap * CGFloat(max(0, diagram.messages.count - 1))
            + metrics.padding * 2

        var decorations: [BlockBox.Decoration] = []
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

        for (index, message) in diagram.messages.enumerated() {
            guard message.from < centres.count, message.to < centres.count else { continue }
            let y = firstMessage + metrics.messageGap * CGFloat(index)
            let color = theme.palette.secondaryText
            let line = text(message.text, font: small, color: color)
            let size = measure(line)
            let start = centres[message.from]
            let end = centres[message.to]
            if message.from == message.to {
                // A message to itself turns round beside its own lifeline.
                let loop = CGMutablePath()
                let reach = start + 26
                loop.move(to: CGPoint(x: start, y: y - 8))
                loop.addLine(to: CGPoint(x: reach, y: y - 8))
                loop.addLine(to: CGPoint(x: reach, y: y + 6))
                loop.addLine(to: CGPoint(x: start + metrics.arrowLength, y: y + 6))
                decorations.append(.path(loop, color: color, lineWidth: 1.3, filled: false))
                decorations.append(
                    arrowHead(
                        at: CGPoint(x: start, y: y + 6), direction: CGPoint(x: -1, y: 0),
                        color: color, metrics: metrics))
                decorations.append(
                    .glyphs(
                        line,
                        origin: CGPoint(x: reach + 8, y: y - 2)
                    )
                )
                continue
            }
            let direction: CGFloat = end > start ? 1 : -1
            let tip = CGPoint(x: end - direction * 2, y: y)
            let shaftEnd = CGPoint(x: tip.x - direction * metrics.arrowLength, y: y)
            let shaft = CGMutablePath()
            if message.dashed {
                shaft.addPath(
                    dashed(from: CGPoint(x: start, y: y), to: shaftEnd, dash: 5, gap: 4))
            } else {
                shaft.move(to: CGPoint(x: start, y: y))
                shaft.addLine(to: shaftEnd)
            }
            decorations.append(.path(shaft, color: color, lineWidth: 1.3, filled: false))
            decorations.append(
                arrowHead(
                    at: tip, direction: CGPoint(x: direction, y: 0), color: color,
                    metrics: metrics))
            decorations.append(
                .glyphs(
                    line,
                    origin: CGPoint(
                        x: (start + end) / 2 - size.width / 2,
                        y: y - 5
                    )
                )
            )
        }
        return Drawing(
            decorations: decorations,
            size: CGSize(width: width, height: height),
            contentWidth: content
        )
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

    private static func normalized(_ point: CGPoint) -> CGPoint {
        let length = (point.x * point.x + point.y * point.y).squareRoot()
        guard length > 0 else { return CGPoint(x: 0, y: 1) }
        return CGPoint(x: point.x / length, y: point.y / length)
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
