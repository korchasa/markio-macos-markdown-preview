import Foundation
import MarkdownKit

/// Find-in-document, streamed off the main thread.
///
/// Nothing is indexed and nothing is cached. On a normal document the whole
/// search finishes in a few milliseconds; on a very large one the matches
/// arrive in batches while the reader is already looking at the first of them.
/// The alternative — a search index over every block's text — would cost a
/// second copy of the document in memory, which is the one thing Markio is
/// built not to do.
@MainActor
public final class FindEngine {
    public struct Result: Sendable {
        public var matches: [DocumentView.FindMatch]
        public var isComplete: Bool
    }

    private var generation = 0

    public init() {}

    /// Cancel any search in flight. The next batch from it is dropped rather
    /// than merged, so a fast typist never sees results from a stale query.
    public func cancel() {
        generation += 1
    }

    public func search(
        _ query: String,
        in document: Document,
        onBatch: @escaping @MainActor (Result) -> Void
    ) {
        generation += 1
        let token = generation
        let needle = query
        guard !needle.isEmpty else {
            onBatch(Result(matches: [], isComplete: true))
            return
        }
        let leaves = document.leaves
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [DocumentView.FindMatch] = []
            var batch: [DocumentView.FindMatch] = []
            var ordinal = 0
            while ordinal < leaves.count {
                let text =
                    BlockPlainText.text(document: document, leaf: leaves[ordinal])
                    as NSString
                var searchStart = 0
                while searchStart < text.length {
                    let range = text.range(
                        of: needle,
                        options: [.caseInsensitive, .diacriticInsensitive],
                        range: NSRange(location: searchStart, length: text.length - searchStart)
                    )
                    guard range.location != NSNotFound else { break }
                    batch.append(
                        DocumentView.FindMatch(
                            ordinal: ordinal,
                            location: range.location,
                            length: max(1, range.length)
                        )
                    )
                    searchStart = range.location + max(1, range.length)
                }
                ordinal += 1
                // Report early and often at the start, then in larger chunks:
                // the reader wants the first match immediately and does not
                // watch the rest arrive.
                let shouldFlush =
                    (!batch.isEmpty && found.isEmpty) || batch.count >= 200
                    || ordinal == leaves.count
                if shouldFlush {
                    found.append(contentsOf: batch)
                    batch.removeAll(keepingCapacity: true)
                    let snapshot = found
                    let complete = ordinal == leaves.count
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.generation == token else { return }
                            onBatch(Result(matches: snapshot, isComplete: complete))
                        }
                    }
                }
            }
        }
    }
}
