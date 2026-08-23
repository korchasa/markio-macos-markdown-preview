import AppKit
import CoreText

/// The copied selection with its styles kept.
///
/// A block's text is already attributed — it has to be, to be drawn — but with
/// CoreText's own attribute keys, and RTF wants AppKit's. Two of them differ in
/// a way no amount of casting hides: `kCTForegroundColorAttributeName` is not
/// `.foregroundColor`, and its value is a `CGColor` where AppKit wants an
/// `NSColor`. So a translation pass is unavoidable, and this is it.
///
/// Plain text stays on the pasteboard beside the rich flavour, character for
/// character what it was before this existed: a rich paste is an addition, and
/// nothing that pastes today may paste differently.
public enum RichText {
    /// The part of a block's text between two offsets, with its attributes.
    ///
    /// The text comes out identical to the same range of `box.plainText`,
    /// separators included. That is why the gaps between segments — the tabs
    /// and newlines a table puts between its cells — are copied as plain text
    /// rather than skipped: they are part of what the reader selected.
    public static func attributed(box: BlockBox, from: Int, to: Int) -> NSAttributedString {
        let plain = box.plainText as NSString
        let start = min(max(0, from), plain.length)
        let end = min(max(start, to), plain.length)
        let result = NSMutableAttributedString()
        guard end > start else { return result }

        var cursor = start
        for segment in box.segments.filter({ $0.textOffset >= 0 })
            .sorted(by: { $0.textOffset < $1.textOffset })
        {
            let segmentStart = segment.textOffset
            let segmentEnd = segmentStart + segment.attributed.length
            guard segmentEnd > start, segmentStart < end else { continue }
            if segmentStart > cursor {
                result.append(
                    NSAttributedString(
                        string: plain.substring(
                            with: NSRange(
                                location: cursor, length: min(segmentStart, end) - cursor))))
                cursor = min(segmentStart, end)
            }
            let localFrom = max(0, cursor - segmentStart)
            let localTo = min(segment.attributed.length, end - segmentStart)
            guard localTo > localFrom else { continue }
            result.append(
                segment.attributed.attributedSubstring(
                    from: NSRange(location: localFrom, length: localTo - localFrom)))
            cursor = segmentStart + localTo
        }
        if cursor < end {
            result.append(
                NSAttributedString(
                    string: plain.substring(with: NSRange(location: cursor, length: end - cursor))))
        }
        return result
    }

    /// The same text with attributes AppKit understands.
    ///
    /// Whatever is not translated is dropped rather than carried: an RTF writer
    /// given a CoreText colour writes nothing for it, and an attribute nobody
    /// reads is weight on the pasteboard.
    public static func appKit(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text.string)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) {
            attributes, range, _ in
            var translated: [NSAttributedString.Key: Any] = [:]
            for (key, value) in attributes {
                switch key {
                case AttributedBuilder.fontKey:
                    // A CTFont is an NSFont; the keys are what differ.
                    translated[.font] = value
                case AttributedBuilder.colorKey:
                    // The value is a `CGColor` by construction — the key is the
                    // CoreText one — but the type is checked rather than
                    // assumed, because a wrong guess here is a crash.
                    guard CFGetTypeID(value as CFTypeRef) == CGColor.typeID else { continue }
                    guard let color = NSColor(cgColor: value as! CGColor) else { continue }
                    translated[.foregroundColor] = color
                case .link, .strikethroughStyle, .strikethroughColor, .underlineStyle,
                    .paragraphStyle, .attachment:
                    // Already AppKit's own keys. The last two are what the
                    // table and the diagram below put there, and dropping them
                    // here would undo both.
                    translated[key] = value
                default:
                    continue
                }
            }
            result.addAttributes(translated, range: range)
        }
        return result
    }

    /// The richest form of one whole block: a table as a table, a diagram as a
    /// picture, anything else as its styled text.
    ///
    /// Only for a block the reader selected whole. Half a table is not a table
    /// — there is no honest grid to build from three cells of five — and half a
    /// diagram is not a picture, so a partial selection keeps the text it had.
    @MainActor
    public static func block(
        box: BlockBox, from: Int, to: Int, theme: Theme
    ) -> NSAttributedString {
        let whole = from == 0 && to >= (box.plainText as NSString).length
        if whole, let table = table(box: box) { return table }
        if whole, let picture = diagram(box: box, theme: theme) { return picture }
        return attributed(box: box, from: from, to: to)
    }

    /// A table rebuilt as a table, for an application that can show one.
    ///
    /// `NSTextTable` is what RTF's own table is made of, so this is the same
    /// grid the reader is looking at rather than a picture of it: the cells
    /// stay text, and whoever pastes it can edit them.
    public static func table(box: BlockBox) -> NSAttributedString? {
        guard let grid = box.tableGrid, !grid.cells.isEmpty else { return nil }
        // The filter row is a decoration and carries `textOffset: -1`, which is
        // exactly the test that keeps it out of the copy — the document never
        // said it.
        let cells = box.segments.filter { $0.textOffset >= 0 }
            .sorted { $0.textOffset < $1.textOffset }
        guard cells.count >= grid.cells.count else { return nil }

        let table = NSTextTable()
        table.numberOfColumns = max(1, grid.columns)
        let result = NSMutableAttributedString()
        for (index, cell) in grid.cells.enumerated() {
            let piece = NSMutableAttributedString(attributedString: cells[index].attributed)
            // Every cell ends in a paragraph break: that is how a text table
            // marks where one cell stops, not decoration.
            piece.append(NSAttributedString(string: "\n"))
            piece.addAttribute(
                .paragraphStyle,
                value: style(for: cell, in: table),
                range: NSRange(location: 0, length: piece.length))
            result.append(piece)
        }
        return result
    }

    private static func style(
        for cell: BlockBox.TableGrid.Cell, in table: NSTextTable
    ) -> NSParagraphStyle {
        let block = NSTextTableBlock(
            table: table,
            startingRow: cell.row,
            rowSpan: max(1, cell.rowspan),
            startingColumn: cell.column,
            columnSpan: max(1, cell.columnspan))
        block.setBorderColor(.separatorColor)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setWidth(4, type: .absoluteValueType, for: .padding)
        if cell.isHeader { block.backgroundColor = .windowBackgroundColor }
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        switch cell.alignment {
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        default: style.alignment = .left
        }
        return style
    }

    /// A diagram as the picture it is drawn as, rather than its source.
    ///
    /// Carried as a file wrapper and not only as an image, because that is what
    /// survives being written to RTFD; the image is set as well so a paste
    /// straight into an attributed string shows something.
    @MainActor
    public static func diagram(box: BlockBox, theme: Theme) -> NSAttributedString? {
        guard box.codeRegion?.isDiagram == true else { return nil }
        guard
            let image = DocumentRenderer.diagram(
                source: box.plainText, theme: theme, width: max(640, box.width))
        else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let size = NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        bitmap.size = size
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = "diagram.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let picture = NSImage(size: size)
        picture.addRepresentation(bitmap)
        attachment.image = picture
        return NSAttributedString(attachment: attachment)
    }

    /// The RTF flavour, or nil for text nothing could be made of.
    public static func rtf(_ text: NSAttributedString) -> Data? {
        let translated = appKit(text)
        return translated.rtf(
            from: NSRange(location: 0, length: translated.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// The RTFD flavour — the only one that carries a picture.
    ///
    /// Nil when there is no picture to carry: RTFD costs a file wrapper and a
    /// pasteboard flavour, and for text alone it says nothing RTF does not.
    public static func rtfd(_ text: NSAttributedString) -> Data? {
        guard containsAttachment(text) else { return nil }
        let translated = appKit(text)
        return translated.rtfd(
            from: NSRange(location: 0, length: translated.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
    }

    private static func containsAttachment(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: text.length)
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
