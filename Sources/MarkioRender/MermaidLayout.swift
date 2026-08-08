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
        var style: Flowchart.Style
    }

    private static func flowchart(
        _ chart: Flowchart, theme: Theme, width: CGFloat, metrics: Metrics
    ) -> Drawing {
        let font = scaled(theme.body, by: metrics.scale)
        var boxes: [Placed] = []
        for node in chart.nodes {
            let colour = node.style.text.map(cgColor) ?? theme.palette.text
            let line = text(node.label, font: font, color: colour)
            let size = measure(line)
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
            case .rectangle, .rounded, .stadium:
                break
            }
            boxes.append(
                Placed(
                    frame: CGRect(origin: .zero, size: box),
                    label: line,
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
        for edge in chart.edges {
            guard edge.from < boxes.count, edge.to < boxes.count else { continue }
            var order = 0
            if !edge.label.isEmpty {
                order = written[edge.from, default: 0]
                written[edge.from] = order + 1
            }
            let drawn = self.edge(
                edge, from: boxes[edge.from], to: boxes[edge.to], theme: theme, metrics: metrics,
                order: order)
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
        let origin = CGPoint(
            x: box.frame.midX - box.labelSize.width / 2,
            y: box.frame.midY + box.labelSize.height / 2 - descent(box.label)
        )
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
        decorations.append(.glyphs(box.label, origin: origin))
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
        case .circle, .doubleCircle:
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
        order: Int
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
        let middle = CGPoint(x: start.x + direction.x * along, y: start.y + direction.y * along)
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
        let top = metrics.padding
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
