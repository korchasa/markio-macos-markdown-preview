import AppKit
import CoreText
import MarkdownKit

/// Lays out one block at a time.
///
/// Every block is independent: it knows its own indentation from its container
/// chain and nothing about its neighbours. That independence is what allows the
/// document view to lay out only what is on screen, in any order, and to throw
/// the result away without invalidating anything else.
@MainActor
struct BlockLayoutEngine {
    let document: Document
    let theme: Theme
    /// Width available for content, gutters included.
    let width: CGFloat
    /// The document's own location, so a relative image path can be resolved.
    /// Nil for a document with no file behind it, which simply has no images.
    let baseURL: URL?
    private let syntax: SyntaxHighlighter.Palette

    init(document: Document, theme: Theme, width: CGFloat, baseURL: URL?) {
        self.document = document
        self.theme = theme
        self.width = width
        self.baseURL = baseURL
        self.syntax = SyntaxHighlighter.Palette(isDark: theme.isDark)
    }

    /// The picture for an inline image, fitted to the height a line can give
    /// it. Nil when there is no document location, when the destination is not
    /// a local file, or when nothing there can be decoded.
    func inlineImage(link: InlineLink, maxHeight: CGFloat) -> CGImage? {
        guard link.isImage, let base = baseURL,
            let url = Builder.imageURL(destination: link.destination, base: base)
        else { return nil }
        // Ask for twice the height in width: a wide picture is capped by the
        // reading column anyway, and asking small keeps the decode cheap.
        return ImageLoader.image(at: url, maxWidth: min(width, maxHeight * 4))
    }

    // MARK: - Estimation

    /// A height guess made without typesetting anything.
    ///
    /// Scrolling needs a total document height before a single block has been
    /// measured, and the closer the guess, the less the scrollbar shifts as
    /// real measurements replace it. Guessing from byte counts and an average
    /// glyph width gets within a few percent on prose, which is close enough
    /// that the correction is invisible.
    func estimatedHeight(for leaf: Int32, isFirst: Bool) -> CGFloat {
        let block = document.block(leaf)
        let context = document.context(of: leaf)
        let indent = self.indent(for: context)
        let available = max(40, width - indent)
        let spacing = spacingBefore(block: block, context: context, isFirst: isFirst)

        switch block.kind {
        case .thematicBreak:
            return spacing + theme.metrics.paragraphSpacing * 2

        case .codeBlock, .htmlBlock, .frontMatter:
            let lines = max(1, Int(block.lineCount))
            return spacing + CGFloat(lines) * theme.monoLineHeight + theme.metrics.codePadding * 2

        case .table:
            let rows = max(1, Int(block.lineCount) - 1)
            let rowHeight = theme.lineHeight + theme.metrics.tableCellPadding * 2
            return spacing + CGFloat(rows) * rowHeight

        case .heading:
            let font = theme.heading(level: Int(block.level))
            let size = CTFontGetSize(font)
            let perLine = max(8, available / (size * 0.52))
            let lines = ceil(CGFloat(byteCount(of: leaf)) / perLine)
            return spacing + max(1, lines) * (size * 1.35) + theme.metrics.headingSpacingAfter

        default:
            let perLine = max(8, available / (theme.metrics.bodySize * 0.5))
            let lines = ceil(CGFloat(byteCount(of: leaf)) / perLine)
            return spacing + max(1, lines) * theme.lineHeight
        }
    }

    private func byteCount(of leaf: Int32) -> Int {
        let range = document.sourceRange(of: leaf)
        return max(1, range.count)
    }

    // MARK: - Layout

    func box(for leaf: Int32, isFirst: Bool) -> BlockBox {
        let block = document.block(leaf)
        let context = document.context(of: leaf)
        let indent = self.indent(for: context)
        let spacing = spacingBefore(block: block, context: context, isFirst: isFirst)
        var builder = Builder(engine: self, leaf: leaf, indent: indent, top: spacing)

        switch block.kind {
        case .heading:
            builder.layoutHeading(block)
        case .codeBlock:
            builder.layoutCode(block, language: document.text(block.info))
        case .htmlBlock:
            builder.layoutCode(block, language: "html", dimmed: true)
        case .frontMatter:
            builder.layoutCode(block, language: "yaml", dimmed: true)
        case .thematicBreak:
            builder.layoutRule()
        case .table:
            builder.layoutTable(leaf: leaf)
        default:
            builder.layoutParagraph(block)
        }
        builder.addListMarker(context: context, block: block)
        builder.addQuoteBars(context: context)
        return builder.finish()
    }

    private func indent(for context: Document.LeafContext) -> CGFloat {
        CGFloat(context.quoteDepth) * theme.metrics.quoteIndent
            + CGFloat(context.listDepth) * theme.metrics.listIndent
    }

    private func spacingBefore(
        block: Block,
        context: Document.LeafContext,
        isFirst: Bool
    ) -> CGFloat {
        guard !isFirst else { return 0 }
        if block.kind == .heading { return theme.metrics.headingSpacingBefore }
        if block.flags.contains(.itemHead), context.isTight {
            return theme.metrics.blockSpacingTight
        }
        return theme.metrics.paragraphSpacing
    }

    // MARK: - Builder

    /// Accumulates the pieces of one box. A struct so the whole layout of a
    /// block happens on the stack, with one array growth per block at most.
    @MainActor
    private struct Builder {
        let engine: BlockLayoutEngine
        let leaf: Int32
        let indent: CGFloat
        var y: CGFloat
        var segments: [BlockBox.Segment] = []
        var decorations: [BlockBox.Decoration] = []
        var links: [BlockBox.LinkRegion] = []
        var linkTargets: [InlineLink] = []
        var plainText = ""
        var codeRegion: BlockBox.CodeRegion?

        var theme: Theme { engine.theme }
        var document: Document { engine.document }
        var available: CGFloat { max(40, engine.width - indent) }

        init(engine: BlockLayoutEngine, leaf: Int32, indent: CGFloat, top: CGFloat) {
            self.engine = engine
            self.leaf = leaf
            self.indent = indent
            self.y = top
        }

        mutating func finish() -> BlockBox {
            BlockBox(
                leaf: leaf,
                width: engine.width,
                height: max(y, 1),
                segments: segments,
                decorations: decorations,
                links: links,
                linkTargets: linkTargets,
                plainText: plainText,
                codeRegion: codeRegion
            )
        }

        // MARK: Text blocks

        mutating func layoutParagraph(_ block: Block) {
            let content = document.content(of: leaf)
            var skip = 0
            if let task = document.taskMarker(in: content, leaf: leaf) {
                addCheckbox(checked: task.isChecked)
                skip = task.contentStart
            }
            let inline = parseInline(content)
            if skip == 0, layoutLoneImage(content: content, inline: inline) { return }
            let styled = AttributedBuilder.build(
                content: content,
                inline: inline,
                theme: theme,
                baseFont: theme.body,
                baseColor: theme.palette.text,
                skipBytes: skip,
                image: { [engine] link, maxHeight in
                    engine.inlineImage(link: link, maxHeight: maxHeight)
                }
            )
            place(
                styled, inline: inline, width: available, x: indent,
                lineHeight: theme.metrics.lineHeightMultiple)
        }

        // MARK: Images

        /// A paragraph that is nothing but one image becomes that image.
        ///
        /// Only a paragraph on its own: an image sitting inside a sentence has
        /// no sensible line box without a text attachment, and a picture
        /// interrupting a line reads worse than the marker it replaces. This is
        /// how images are written in practice anyway — on a line of their own.
        ///
        /// Returns false when the block is not a lone image, or when the file
        /// cannot be read, so the caller falls back to ordinary text and the
        /// alt text still says what was meant to be there.
        mutating func layoutLoneImage(content: [UInt8], inline: InlineContent) -> Bool {
            guard let link = soleImageLink(content: content, inline: inline),
                let base = engine.baseURL,
                let url = Self.imageURL(destination: link.destination, base: base)
            else { return false }

            let maxWidth = available
            guard let image = ImageLoader.image(at: url, maxWidth: maxWidth) else { return false }

            let aspect = CGFloat(image.height) / CGFloat(max(1, image.width))
            let width = min(maxWidth, CGFloat(image.width) / 2)
            let height = (width * aspect).rounded()
            let top = y + theme.metrics.paragraphSpacing
            decorations.append(
                .image(image, rect: CGRect(x: indent, y: top, width: width, height: height))
            )
            y = top + height + theme.metrics.paragraphSpacing
            // The alt text is what Copy and Find see: the picture itself has no
            // characters, and its description is the only text the block has.
            plainText = BlockPlainText.inlineText(content: content, inline: inline, skipBytes: 0)
            return true
        }

        /// The image link of a block whose only content is that image.
        private func soleImageLink(content: [UInt8], inline: InlineContent) -> InlineLink? {
            var found: Int32 = -1
            for run in inline.runs {
                switch run.kind {
                case .image:
                    guard found < 0 else { return nil }
                    found = run.link
                case .text:
                    // Text belonging to the image is its alt text; anything
                    // else means the picture shares the paragraph with prose.
                    guard
                        run.link == found || content.text(in: run.range).allSatisfy(\.isWhitespace)
                    else { return nil }
                case .entity, .softBreak, .hardBreak:
                    return nil
                }
            }
            guard found >= 0, Int(found) < inline.links.count else { return nil }
            let link = inline.links[Int(found)]
            return link.isImage ? link : nil
        }

        /// Resolve a destination against the document, refusing anything that
        /// is not a local file beside it — the same default-deny rule links get.
        static func imageURL(destination: String, base: URL) -> URL? {
            let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return nil }
            if let scheme = URL(string: trimmed)?.scheme?.lowercased() {
                // A remote image cannot be fetched: there is no network path.
                guard scheme == "file" else { return nil }
                return URL(string: trimmed)
            }
            let decoded = trimmed.removingPercentEncoding ?? trimmed
            let directory = base.deletingLastPathComponent()
            return URL(fileURLWithPath: decoded, relativeTo: directory).standardizedFileURL
        }

        mutating func layoutHeading(_ block: Block) {
            let content = document.content(of: leaf)
            let inline = parseInline(content)
            let styled = AttributedBuilder.build(
                content: content,
                inline: inline,
                theme: theme,
                baseFont: theme.heading(level: Int(block.level)),
                baseColor: theme.palette.text
            )
            place(styled, inline: inline, width: available, x: indent, lineHeight: 1.25)
            y += theme.metrics.headingSpacingAfter
            // A rule under the top two levels, the way long documents are set.
            if block.level <= 2 {
                let ruleY = y - theme.metrics.headingSpacingAfter / 2
                decorations.append(
                    .fill(
                        rect: CGRect(
                            x: indent,
                            y: ruleY,
                            width: available,
                            height: theme.metrics.ruleThickness
                        ),
                        color: theme.palette.rule,
                        cornerRadius: 0
                    )
                )
            }
        }

        /// Code, raw HTML and front matter all render the same way: a tinted
        /// box of monospaced text, wrapped rather than clipped so the reader
        /// never has to scroll sideways.
        mutating func layoutCode(_ block: Block, language: String, dimmed: Bool = false) {
            let code = CodeText.build(
                content: document.content(of: leaf),
                language: language,
                dimmed: dimmed,
                theme: theme,
                syntax: engine.syntax
            )
            let attributed = code.attributed
            let padding = theme.metrics.codePadding
            let boxTop = y
            let result = Typesetter.layout(
                attributed,
                width: available - padding * 2,
                x: indent + padding,
                y: y + padding,
                lineHeightMultiple: 1.45
            )
            segments.append(
                BlockBox.Segment(attributed: attributed, lines: result.lines, textOffset: 0)
            )
            plainText = code.text
            y += result.height + padding * 2
            let frame = CGRect(x: indent, y: boxTop, width: available, height: y - boxTop)
            decorations.insert(
                .fill(
                    rect: frame,
                    color: theme.palette.codeBackground,
                    cornerRadius: theme.metrics.codeCornerRadius
                ),
                at: 0
            )
            codeRegion = BlockBox.CodeRegion(rect: frame, language: language)
            addCodeTints(code.tints, lines: result.lines, padding: padding)
        }

        /// Paint the bands a diff or a terminal log carries.
        ///
        /// Inserted right after the block's own background so they sit under
        /// the text: decorations are drawn in order, and a band painted after
        /// the glyphs would erase them.
        private mutating func addCodeTints(
            _ tints: [CodeText.Tint],
            lines: [TextLine],
            padding: CGFloat
        ) {
            guard !tints.isEmpty else { return }
            var insertAt = 1
            for tint in tints {
                for rect in SpanGeometry.rects(for: tint.range, lines: lines) {
                    let band =
                        tint.fullWidth
                        ? CGRect(
                            x: indent,
                            y: rect.minY,
                            width: available,
                            height: rect.height
                        )
                        : rect.insetBy(dx: -1, dy: -1)
                    decorations.insert(
                        .fill(rect: band, color: tint.color, cornerRadius: 0),
                        at: insertAt
                    )
                    insertAt += 1
                }
            }
        }

        mutating func layoutRule() {
            let spacing = theme.metrics.paragraphSpacing
            y += spacing
            decorations.append(
                .fill(
                    rect: CGRect(
                        x: indent,
                        y: y,
                        width: available,
                        height: theme.metrics.ruleThickness
                    ),
                    color: theme.palette.rule,
                    cornerRadius: 0
                )
            )
            y += spacing
        }

        // MARK: Tables

        mutating func layoutTable(leaf: Int32) {
            let table = document.table(at: leaf)
            let columns = max(1, table.columnCount)
            let padding = theme.metrics.tableCellPadding
            let widths = columnWidths(table, total: available, padding: padding)

            var rows: [[ByteRange]] = [table.header]
            rows.append(contentsOf: table.rows)
            let tableTop = y

            for (rowIndex, row) in rows.enumerated() {
                let rowTop = y
                var rowHeight: CGFloat = 0
                var x = indent
                for column in 0..<columns {
                    let cell = column < row.count ? row[column] : .empty
                    let cellBytes = Array(document.bytes[cell.lowerBound..<cell.upperBound])
                    let inline = parseInline(cellBytes)
                    let styled = AttributedBuilder.build(
                        content: cellBytes,
                        inline: inline,
                        theme: theme,
                        baseFont: rowIndex == 0 ? theme.bodyBold : theme.body,
                        baseColor: theme.palette.text
                    )
                    let alignment: LineAlignment
                    switch table.alignments[min(column, table.alignments.count - 1)] {
                    case .right: alignment = .right
                    case .center: alignment = .center
                    default: alignment = .left
                    }
                    let result = Typesetter.layout(
                        styled.attributed,
                        width: widths[column] - padding * 2,
                        x: x + padding,
                        y: rowTop + padding,
                        lineHeightMultiple: theme.metrics.lineHeightMultiple,
                        alignment: alignment
                    )
                    let offset = plainText.utf16.count
                    segments.append(
                        BlockBox.Segment(
                            attributed: styled.attributed,
                            lines: result.lines,
                            textOffset: offset
                        )
                    )
                    plainText += styled.attributed.string
                    plainText += column == columns - 1 ? "\n" : "\t"
                    recordSpans(
                        styled, result: result, inline: inline, segmentIndex: segments.count - 1)
                    rowHeight = max(rowHeight, result.height + padding * 2)
                    x += widths[column]
                }
                rowHeight = max(rowHeight, theme.lineHeight + padding * 2)
                if rowIndex == 0 {
                    decorations.insert(
                        .fill(
                            rect: CGRect(x: indent, y: rowTop, width: available, height: rowHeight),
                            color: theme.palette.tableHeaderBackground,
                            cornerRadius: 0
                        ),
                        at: 0
                    )
                }
                y = rowTop + rowHeight
                if rowIndex < rows.count - 1 {
                    decorations.append(
                        .fill(
                            rect: CGRect(x: indent, y: y, width: available, height: 1),
                            color: theme.palette.tableBorder,
                            cornerRadius: 0
                        ),
                    )
                }
            }
            decorations.append(
                .stroke(
                    rect: CGRect(x: indent, y: tableTop, width: available, height: y - tableTop),
                    color: theme.palette.tableBorder,
                    width: 1
                )
            )
            var x = indent
            for column in 0..<(columns - 1) {
                x += widths[column]
                decorations.append(
                    .fill(
                        rect: CGRect(x: x, y: tableTop, width: 1, height: y - tableTop),
                        color: theme.palette.tableBorder,
                        cornerRadius: 0
                    )
                )
            }
        }

        /// Column widths from the natural width of each column's widest cell,
        /// scaled to the available width. Narrow columns keep their size; wide
        /// ones give up the difference, which is what keeps a table of short
        /// numbers from stretching across the page.
        private func columnWidths(
            _ table: Table,
            total: CGFloat,
            padding: CGFloat
        ) -> [CGFloat] {
            let columns = max(1, table.columnCount)
            var natural = [CGFloat](repeating: 0, count: columns)
            var rows: [[ByteRange]] = [table.header]
            rows.append(contentsOf: table.rows.prefix(50))
            for row in rows {
                for column in 0..<min(columns, row.count) {
                    let bytes = row[column].count
                    natural[column] = max(
                        natural[column],
                        CGFloat(bytes) * theme.metrics.bodySize * 0.55 + padding * 2
                    )
                }
            }
            let sum = natural.reduce(0, +)
            guard sum > 0 else {
                return [CGFloat](repeating: total / CGFloat(columns), count: columns)
            }
            let minimum = theme.metrics.bodySize * 3
            if sum <= total {
                let extra = (total - sum) / CGFloat(columns)
                return natural.map { $0 + extra }
            }
            // Shrink proportionally, but never below a readable minimum.
            var widths = natural.map { max(minimum, $0 * total / sum) }
            let overflow = widths.reduce(0, +) - total
            if overflow > 0 {
                let shrinkable = widths.filter { $0 > minimum }.reduce(0, +)
                if shrinkable > 0 {
                    widths = widths.map { current in
                        current > minimum
                            ? max(minimum, current - overflow * current / shrinkable)
                            : current
                    }
                }
            }
            return widths
        }

        // MARK: Decorations

        mutating func addListMarker(context: Document.LeafContext, block: Block) {
            guard context.isItemHead, context.list >= 0 else { return }
            let content = document.content(of: leaf)
            if document.taskMarker(in: content, leaf: leaf) != nil { return }
            let ordered = document.block(context.list).flags.contains(.ordered)
            let text = ordered ? "\(context.ordinal)." : "•"
            let attributes: [NSAttributedString.Key: Any] = [
                AttributedBuilder.fontKey: ordered ? theme.body : theme.bodyBold,
                AttributedBuilder.colorKey: theme.palette.secondaryText,
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let gutter = theme.metrics.listIndent
            guard
                let line = Typesetter.singleLine(
                    attributed,
                    x: indent - gutter,
                    width: gutter - 7,
                    baseline: firstLineBaseline(),
                    alignment: ordered ? .right : .center
                )
            else { return }
            segments.append(
                BlockBox.Segment(attributed: attributed, lines: [line], textOffset: -1)
            )
        }

        mutating func addCheckbox(checked: Bool) {
            let size = theme.metrics.bodySize * 0.85
            let box = CGRect(
                x: indent - theme.metrics.listIndent + 4,
                y: firstLineTop() + (theme.lineHeight - size) / 2,
                width: size,
                height: size
            )
            let rounded = CGPath(
                roundedRect: box,
                cornerWidth: 3,
                cornerHeight: 3,
                transform: nil
            )
            if checked {
                decorations.append(
                    .path(rounded, color: theme.palette.link, lineWidth: 0, filled: true))
                let tick = CGMutablePath()
                tick.move(to: CGPoint(x: box.minX + size * 0.24, y: box.midY + size * 0.02))
                tick.addLine(to: CGPoint(x: box.midX - size * 0.02, y: box.maxY - size * 0.26))
                tick.addLine(to: CGPoint(x: box.maxX - size * 0.2, y: box.minY + size * 0.28))
                decorations.append(
                    .path(tick, color: CGColor(gray: 1, alpha: 1), lineWidth: 1.8, filled: false)
                )
            } else {
                decorations.append(
                    .path(rounded, color: theme.palette.quoteBar, lineWidth: 1.4, filled: false)
                )
            }
        }

        mutating func addQuoteBars(context: Document.LeafContext) {
            guard context.quoteDepth > 0 else { return }
            for level in 0..<context.quoteDepth {
                let x = CGFloat(level) * theme.metrics.quoteIndent
                decorations.insert(
                    .fill(
                        rect: CGRect(
                            x: x,
                            y: 0,
                            width: theme.metrics.quoteBarWidth,
                            height: max(y, 1)
                        ),
                        color: theme.palette.quoteBar,
                        cornerRadius: theme.metrics.quoteBarWidth / 2
                    ),
                    at: 0
                )
            }
        }

        /// Top of the first line's box — where a checkbox is centred.
        private func firstLineTop() -> CGFloat {
            segments.first?.lines.first.map { $0.origin.y - $0.ascent } ?? y
        }

        /// Baseline of the first line — where a list marker sits.
        private func firstLineBaseline() -> CGFloat {
            segments.first?.lines.first?.origin.y ?? y
        }

        // MARK: Shared

        private func parseInline(_ content: [UInt8]) -> InlineContent {
            InlineParser.parse(
                content: content,
                references: document.references,
                documentBytes: document.bytes
            )
        }

        private mutating func place(
            _ styled: StyledText,
            inline: InlineContent,
            width: CGFloat,
            x: CGFloat,
            lineHeight: CGFloat
        ) {
            guard !styled.isEmpty else {
                y += theme.lineHeight
                return
            }
            let result = Typesetter.layout(
                styled.attributed,
                width: width,
                x: x,
                y: y,
                lineHeightMultiple: lineHeight
            )
            segments.append(
                BlockBox.Segment(
                    attributed: styled.attributed,
                    lines: result.lines,
                    textOffset: plainText.utf16.count
                )
            )
            plainText += styled.attributed.string
            recordSpans(styled, result: result, inline: inline, segmentIndex: segments.count - 1)
            recordInlineImages(result: result, inline: inline)
            y += result.height
        }

        /// Find the pictures CoreText reserved room for, and say where they go.
        ///
        /// The space is already there — the run delegate reserved it — so this
        /// only has to read back where the line put it. A picture that failed to
        /// load leaves its frame empty rather than shifting the text around it.
        private mutating func recordInlineImages(result: Typesetter.Result, inline: InlineContent) {
            for line in result.lines {
                for run in (CTLineGetGlyphRuns(line.line) as? [CTRun] ?? []) {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    guard let index = attributes[InlineImage.key] as? Int32,
                        index >= 0, Int(index) < inline.links.count
                    else { continue }
                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    let width = CGFloat(
                        CTRunGetTypographicBounds(run, CFRange(), &ascent, &descent, nil))
                    let stringRange = CTRunGetStringRange(run)
                    let x =
                        line.origin.x
                        + CTLineGetOffsetForStringIndex(line.line, stringRange.location, nil)
                    let rect = CGRect(
                        x: x,
                        y: line.origin.y - ascent,
                        width: width,
                        height: ascent + descent
                    )
                    guard
                        let image = engine.inlineImage(
                            link: inline.links[Int(index)],
                            maxHeight: rect.height
                        )
                    else {
                        // The room is reserved whether or not the file was
                        // readable, so an outline says a picture belongs here
                        // rather than leaving a gap that reads as a typo.
                        decorations.append(
                            .stroke(rect: rect, color: theme.palette.rule, width: 1)
                        )
                        continue
                    }
                    decorations.append(.image(image, rect: rect))
                }
            }
        }

        /// Turn style spans into the geometry that has to be drawn behind or
        /// under the text: inline-code backgrounds, highlights, link underlines
        /// and the rectangles a click is tested against.
        private mutating func recordSpans(
            _ styled: StyledText,
            result: Typesetter.Result,
            inline: InlineContent,
            segmentIndex: Int
        ) {
            guard !styled.spans.isEmpty else { return }
            let base = linkTargets.count
            linkTargets.append(contentsOf: inline.links)
            for span in styled.spans {
                let rects = SpanGeometry.rects(for: span.range, lines: result.lines)
                guard !rects.isEmpty else { continue }
                if span.style.contains(.code) || span.style.contains(.keyboard) {
                    let color =
                        span.style.contains(.keyboard)
                        ? theme.palette.keyboardBackground
                        : theme.palette.inlineCodeBackground
                    for rect in rects {
                        decorations.insert(
                            .fill(
                                rect: rect.insetBy(dx: -2.5, dy: -1),
                                color: color,
                                cornerRadius: 3
                            ),
                            at: 0
                        )
                    }
                }
                if span.style.contains(.highlight) {
                    for rect in rects {
                        decorations.insert(
                            .fill(
                                rect: rect.insetBy(dx: -1, dy: -1),
                                color: theme.palette.highlightBackground,
                                cornerRadius: 2
                            ),
                            at: 0
                        )
                    }
                }
                if span.style.contains(.link), span.link >= 0 {
                    for rect in rects {
                        decorations.append(
                            .fill(
                                rect: CGRect(
                                    x: rect.minX,
                                    y: rect.maxY - 1,
                                    width: rect.width,
                                    height: 1
                                ),
                                color: theme.palette.link,
                                cornerRadius: 0
                            )
                        )
                        links.append(
                            BlockBox.LinkRegion(
                                rect: rect.insetBy(dx: 0, dy: -2),
                                link: Int32(base) + span.link
                            )
                        )
                    }
                }
                if span.style.contains(.underline) {
                    for rect in rects {
                        decorations.append(
                            .fill(
                                rect: CGRect(
                                    x: rect.minX,
                                    y: rect.maxY - 1,
                                    width: rect.width,
                                    height: 1
                                ),
                                color: theme.palette.text,
                                cornerRadius: 0
                            )
                        )
                    }
                }
            }
        }

        /// Build the attributed string of a code block, colouring the spans the
        /// highlighter found. Text is appended span by span so byte offsets
        /// never have to be converted into UTF-16 offsets.
    }
}

/// Maps a range of an attributed string onto the rectangles its glyphs occupy.
enum SpanGeometry {
    static func rects(for range: NSRange, lines: [TextLine]) -> [CGRect] {
        var rects: [CGRect] = []
        let spanStart = range.location
        let spanEnd = range.location + range.length
        for line in lines {
            let lineStart = line.range.location
            let lineEnd = lineStart + line.range.length
            guard spanStart < lineEnd, spanEnd > lineStart else { continue }
            let from = max(spanStart, lineStart)
            let to = min(spanEnd, lineEnd)
            let startX = CTLineGetOffsetForStringIndex(line.line, from, nil)
            let endX = CTLineGetOffsetForStringIndex(line.line, to, nil)
            guard endX > startX else { continue }
            rects.append(
                CGRect(
                    x: line.origin.x + startX,
                    y: line.origin.y - line.ascent,
                    width: endX - startX,
                    height: line.ascent + line.descent
                )
            )
        }
        return rects
    }
}
