import Foundation
import MarkdownKit

/// What the document says about itself: how much of the work is ticked off, how
/// long it takes to read, and which sections still carry an open question.
///
/// The first question anyone asks of an agent's report is whether the work is
/// finished, and the document already answers it in checkboxes nobody counts.
///
/// **The invariant is the whole design here.** "Nothing is typeset until it is
/// visible" forbids walking every block when a document opens, and a summary is
/// by definition about every block. So the count runs on a background queue in
/// batches and publishes partial numbers as they arrive: the bar shows the
/// figures settling rather than appearing, and on a 32 MB document they settle
/// late. That is honest, and better than a number that delays the first window.
///
/// Two definitions, written down because a number nobody can define is noise:
///
/// - **Reading time** is words divided by a stated rate. The rate is named in
///   the bar, so it reads as a measurement of the document rather than as a
///   claim about the reader.
/// - **An open question** is a `TODO` or `FIXME` marker in the text, and
///   nothing else. Not an unticked box — those are counted separately, as
///   progress — and not a question mark, which is punctuation, not a state.
@MainActor
public final class DocumentSummary {
    /// Words a minute. Stated rather than hidden, and shown beside the figure
    /// it produces.
    public nonisolated static let readingRate = 220

    public struct Counts: Sendable, Equatable {
        public var tasks = 0
        public var tasksDone = 0
        public var words = 0
        public var openQuestions = 0
        /// How far through the document the count has got, 0…1.
        public var progress: Double = 0

        public init() {}

        public var isComplete: Bool { progress >= 1 }

        /// Minutes to read, rounded up, or nil for a document with no words.
        public var readingMinutes: Int? {
            guard words > 0 else { return nil }
            return max(1, Int((Double(words) / Double(DocumentSummary.readingRate)).rounded(.up)))
        }
    }

    /// Ticked-of-total for one heading's section, in outline order.
    public struct SectionProgress: Sendable, Equatable {
        public var tasks = 0
        public var done = 0
        public var openQuestions = 0
    }

    public struct Result: Sendable, Equatable {
        public var counts = Counts()
        public var sections: [SectionProgress] = []
    }

    private var generation = 0

    public init() {}

    public func cancel() {
        generation += 1
    }

    /// Count a document, reporting as the numbers come in.
    public func count(
        _ document: Document,
        onUpdate: @escaping @MainActor (Result) -> Void
    ) {
        generation += 1
        let token = generation
        let leaves = document.leaves
        guard !leaves.isEmpty else {
            var empty = Counts()
            empty.progress = 1
            onUpdate(Result(counts: empty, sections: []))
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var counts = Counts()
            var sections: [SectionProgress] = []
            var ordinal = 0
            while ordinal < leaves.count {
                let leaf = leaves[ordinal]
                let block = document.blocks[Int(leaf)]
                if block.kind == .heading { sections.append(SectionProgress()) }
                // A checkbox is read from the text, not from a flag: the
                // scanner leaves `[ ]` as ordinary characters, and only a
                // paragraph that heads a list item can be one at all — which is
                // the cheap test that keeps this from reading every block.
                if block.kind == .paragraph, block.flags.contains(.itemHead),
                    let marker = document.taskMarker(in: document.content(of: leaf), leaf: leaf)
                {
                    counts.tasks += 1
                    if !sections.isEmpty { sections[sections.count - 1].tasks += 1 }
                    if marker.isChecked {
                        counts.tasksDone += 1
                        if !sections.isEmpty { sections[sections.count - 1].done += 1 }
                    }
                }
                // The text is read once per block and dropped: this is the
                // expensive half, and the reason the whole pass is off the
                // main thread and in batches.
                let text = BlockPlainText.text(document: document, leaf: leaf)
                counts.words += DocumentSummary.words(in: text)
                let markers = DocumentSummary.markers(in: text)
                counts.openQuestions += markers
                if markers > 0, !sections.isEmpty {
                    sections[sections.count - 1].openQuestions += markers
                }
                ordinal += 1

                // Often at first so the bar fills in while the reader is still
                // on the first screen, then in larger steps.
                let shouldFlush =
                    ordinal == leaves.count || ordinal % 500 == 0
                    || (ordinal < 50 && ordinal % 10 == 0)
                if shouldFlush {
                    var snapshot = counts
                    snapshot.progress = Double(ordinal) / Double(leaves.count)
                    let result = Result(counts: snapshot, sections: sections)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.generation == token else { return }
                            onUpdate(result)
                        }
                    }
                }
            }
        }
    }

    /// Words, counted the way anyone would count them by eye: runs of
    /// non-space. Good enough to divide by a rate, and it costs one pass.
    static func words(in text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(character) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// `TODO` and `FIXME`, as whole words, in any case.
    static func markers(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var found = 0
        let haystack = text as NSString
        for needle in ["TODO", "FIXME"] {
            var start = 0
            while start < haystack.length {
                let range = haystack.range(
                    of: needle,
                    options: [.caseInsensitive],
                    range: NSRange(location: start, length: haystack.length - start))
                guard range.location != NSNotFound else { break }
                if isWholeWord(range, in: haystack) { found += 1 }
                start = range.location + range.length
            }
        }
        return found
    }

    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        let letters = CharacterSet.alphanumerics
        if range.location > 0,
            let before = text.substring(
                with: NSRange(location: range.location - 1, length: 1)
            ).unicodeScalars.first, letters.contains(before)
        {
            return false
        }
        let after = range.location + range.length
        if after < text.length,
            let next = text.substring(with: NSRange(location: after, length: 1))
                .unicodeScalars.first, letters.contains(next)
        {
            return false
        }
        return true
    }
}
