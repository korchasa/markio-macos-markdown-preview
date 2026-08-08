/// Lifts link reference definitions (`[label]: url "title"`) out of the
/// paragraphs that hold them.
///
/// The block scanner has no reason to know about them — they are an inline
/// concern that happens to occupy whole lines — so they are stripped in a short
/// pass afterwards, by advancing the paragraph past the definition lines rather
/// than by rewriting any text. A paragraph that was nothing but definitions
/// ends up with zero lines and is skipped when the leaf list is built.
///
/// Only the one-line form is recognised. The spec also allows the title to sit
/// on the following line; that spelling does not appear in documents people
/// write, and supporting it would make every paragraph pay a two-line lookahead.
enum ReferenceCollector {
    static func collect(
        blocks: inout [Block],
        lines: LineIndex,
        bytes: UnsafeBufferPointer<UInt8>
    ) -> [String: Document.LinkReference] {
        var references: [String: Document.LinkReference] = [:]
        for index in blocks.indices {
            guard blocks[index].kind == .paragraph, blocks[index].lineCount > 0 else { continue }
            var line = Int(blocks[index].firstLine)
            let lastLine = Int(blocks[index].lastLine)
            while line <= lastLine {
                let range = lines.contentRange(of: line, bytes: bytes)
                guard let definition = parse(bytes: bytes, range: range) else { break }
                // First definition wins, matching every other implementation.
                if references[definition.label] == nil {
                    references[definition.label] = Document.LinkReference(
                        destination: definition.destination,
                        title: definition.title
                    )
                }
                line += 1
            }
            let consumed = line - Int(blocks[index].firstLine)
            if consumed > 0 {
                blocks[index].firstLine += Int32(consumed)
                blocks[index].lineCount -= Int32(consumed)
            }
        }
        return references
    }

    private struct Definition {
        var label: String
        var destination: ByteRange
        var title: ByteRange
    }

    private static func parse(
        bytes: UnsafeBufferPointer<UInt8>,
        range: ByteRange
    ) -> Definition? {
        var index = range.lowerBound
        let end = range.upperBound
        guard index < end, bytes[index] == ASCII.leftBracket else { return nil }
        index += 1
        let labelStart = index
        while index < end, bytes[index] != ASCII.rightBracket {
            if bytes[index] == ASCII.leftBracket { return nil }
            if bytes[index] == ASCII.backslash { index += 1 }
            index += 1
        }
        guard index < end, index > labelStart else { return nil }
        let label = LinkLabel.normalize(bytes.textSlice(ByteRange(labelStart, index)))
        index += 1
        guard index < end, bytes[index] == ASCII.colon else { return nil }
        index += 1
        while index < end, isSpaceOrTab(bytes[index]) { index += 1 }
        guard index < end else { return nil }

        var destination: ByteRange
        if bytes[index] == ASCII.lessThan {
            let open = index + 1
            index = open
            while index < end, bytes[index] != ASCII.greaterThan { index += 1 }
            guard index < end else { return nil }
            destination = ByteRange(open, index)
            index += 1
        } else {
            let open = index
            while index < end, !isSpaceOrTab(bytes[index]) { index += 1 }
            destination = ByteRange(open, index)
        }
        guard !destination.isEmpty else { return nil }

        while index < end, isSpaceOrTab(bytes[index]) { index += 1 }
        var title = ByteRange.empty
        if index < end {
            let quote = bytes[index]
            guard quote == ASCII.quote || quote == ASCII.apostrophe || quote == ASCII.leftParen
            else { return nil }
            let closer = quote == ASCII.leftParen ? ASCII.rightParen : quote
            let open = index + 1
            index = open
            while index < end, bytes[index] != closer {
                if bytes[index] == ASCII.backslash { index += 1 }
                index += 1
            }
            guard index < end else { return nil }
            title = ByteRange(open, index)
            index += 1
            // Anything after the title means this was never a definition.
            while index < end, isSpaceOrTab(bytes[index]) { index += 1 }
            guard index >= end else { return nil }
        }
        return Definition(label: label, destination: destination, title: title)
    }
}
