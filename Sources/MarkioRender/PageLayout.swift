import AppKit
import CoreText

/// Cutting a document into pages.
///
/// Blocks are the easy part: a box knows its height, so a break between two of
/// them is arithmetic. The work is a block taller than a page — a long fence, a
/// tall table — which has to break at a line boundary, never through the middle
/// of one. A block with no lines at all to break on (a diagram, a picture) is
/// scaled down to fit instead, the way it already scales for a narrow column.
///
/// **On the invariant.** "Nothing is typeset until it is visible" is about
/// opening a document; this is a command that means "typeset all of it". It
/// still holds the memory line: pages are produced one at a time, each block is
/// laid out as it is reached, and the layout's own eviction drops the boxes
/// behind it — so a 32 MB document paginates in the memory of a few pages
/// rather than of a file.
@MainActor
public enum PageLayout {
    /// A piece of one block on one page. `from` and `to` are in the block's own
    /// coordinates, so a box that spans three pages appears in three slices.
    public struct Slice: Equatable {
        public var ordinal: Int
        public var from: CGFloat
        public var to: CGFloat
        /// Drawn smaller than life, for a picture that fits no page at all.
        public var scale: CGFloat = 1
        /// Where the top of this slice sits on the page.
        public var y: CGFloat = 0

        public var height: CGFloat { (to - from) * scale }
    }

    public struct Page: Equatable {
        public var slices: [Slice]
    }

    /// The room left for content after the margins.
    public struct Geometry {
        public var pageSize: CGSize
        public var margin: CGFloat

        public init(pageSize: CGSize, margin: CGFloat) {
            self.pageSize = pageSize
            self.margin = margin
        }

        public var contentWidth: CGFloat { pageSize.width - margin * 2 }
        public var contentHeight: CGFloat { pageSize.height - margin * 2 }
    }

    /// Break a laid-out document into pages.
    ///
    /// The layout must already be built at the page's content width — this
    /// measures, it does not re-flow.
    public static func paginate(layout: DocumentLayout, geometry: Geometry) -> [Page] {
        let pageHeight = geometry.contentHeight
        guard pageHeight > 40, layout.blockCount > 0 else { return [] }

        var pages: [Page] = []
        var current: [Slice] = []
        var used: CGFloat = 0

        func flush() {
            guard !current.isEmpty else { return }
            pages.append(Page(slices: current))
            current = []
            used = 0
        }

        for ordinal in 0..<layout.blockCount {
            // One block at a time, so the layout evicts what is behind us.
            _ = layout.prepare(range: ordinal..<(ordinal + 1), anchor: ordinal)
            guard let box = layout.box(at: ordinal), box.height > 0 else { continue }
            var from: CGFloat = 0
            while from < box.height - 0.5 {
                let room = pageHeight - used
                // A sliver of a page is not worth filling: anything under a
                // line or so leaves a widow that reads as a mistake.
                if room < 24, used > 0 {
                    flush()
                    continue
                }
                let remaining = box.height - from
                if remaining <= room + 0.5 {
                    current.append(Slice(ordinal: ordinal, from: from, to: box.height, y: used))
                    used += remaining
                    from = box.height
                    continue
                }
                if let cut = cutPoint(box: box, after: from, before: from + room), cut > from + 1 {
                    current.append(Slice(ordinal: ordinal, from: from, to: cut, y: used))
                    from = cut
                    flush()
                    continue
                }
                guard used == 0 else {
                    // It may still break once it has a whole page to itself.
                    flush()
                    continue
                }
                // A whole empty page and it still does not fit and cannot be
                // cut: a diagram or a picture. Shown smaller rather than
                // guillotined.
                current.append(
                    Slice(
                        ordinal: ordinal, from: from, to: box.height,
                        scale: pageHeight / remaining, y: 0))
                from = box.height
                flush()
            }
        }
        flush()
        return pages
    }

    /// The lowest line boundary inside a box that still fits on the page.
    ///
    /// Boundaries are the bottoms of typeset lines: cutting anywhere else puts
    /// half the letters of a line on one page and half on the next.
    static func cutPoint(box: BlockBox, after from: CGFloat, before limit: CGFloat) -> CGFloat? {
        var best: CGFloat?
        for segment in box.segments {
            for line in segment.lines {
                let bottom = line.origin.y + line.descent
                guard bottom > from + 1, bottom <= limit + 0.5 else { continue }
                if best == nil || bottom > best! { best = bottom }
            }
        }
        return best
    }
}
