import MarkdownKit

/// Where a document breaks into slides.
///
/// A deck is a document read at a different size, not a second document: the
/// same blocks, the same layout engine, shown a screenful at a time. So the
/// only question here is where one screenful ends, and the answer follows what
/// the author wrote rather than a setting.
///
/// A thematic break (`---`) is a break the author put there on purpose, so it
/// wins whenever the document has any. Failing that, the top-level headings are
/// the structure the document does have. Failing both, this is not a deck — and
/// the honest answer is to say so rather than to cut the text into screen-sized
/// pieces nobody chose.
public enum Slides {
    /// The slides of a document, as ranges of ordinals, or an empty list when
    /// the document is not a deck.
    public static func split(_ document: Document) -> [Range<Int>] {
        guard !document.leaves.isEmpty else { return [] }
        let breaks = ordinals(of: document) { $0.kind == .thematicBreak }
        if !breaks.isEmpty { return byBreaks(document, at: breaks) }

        // The shallowest level that actually divides the document. A report
        // with one `#` title and eight `##` sections is a deck of eight, not a
        // deck of one: the title is a title, and the sections are the slides.
        var counts: [UInt8: Int] = [:]
        for leaf in document.leaves {
            let block = document.blocks[Int(leaf)]
            guard block.kind == .heading else { continue }
            counts[block.level, default: 0] += 1
        }
        guard let level = counts.filter({ $0.value > 1 }).keys.min() else { return [] }
        return byHeadings(
            document, at: ordinals(of: document) { $0.kind == .heading && $0.level == level })
    }

    private static func ordinals(
        of document: Document, where matches: (Block) -> Bool
    ) -> [Int] {
        document.leaves.indices.filter { matches(document.blocks[Int(document.leaves[$0])]) }
    }

    /// The break itself belongs to neither slide: it is the join, and drawing a
    /// rule across the top of every screen is not what the author meant by it.
    private static func byBreaks(_ document: Document, at breaks: [Int]) -> [Range<Int>] {
        var slides: [Range<Int>] = []
        var start = 0
        for rule in breaks {
            if rule > start { slides.append(start..<rule) }
            start = rule + 1
        }
        if start < document.leaves.count { slides.append(start..<document.leaves.count) }
        return slides.filter { !$0.isEmpty }
    }

    /// A heading opens the slide it belongs to. Anything above the first one is
    /// the title slide.
    private static func byHeadings(_ document: Document, at headings: [Int]) -> [Range<Int>] {
        var slides: [Range<Int>] = []
        if let first = headings.first, first > 0 { slides.append(0..<first) }
        for (index, heading) in headings.enumerated() {
            let end = index + 1 < headings.count ? headings[index + 1] : document.leaves.count
            slides.append(heading..<end)
        }
        return slides.filter { !$0.isEmpty }
    }
}
