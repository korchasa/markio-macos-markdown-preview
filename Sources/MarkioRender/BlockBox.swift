import AppKit
import CoreText
import MarkdownKit

/// Everything needed to draw one block, and nothing that outlives it.
///
/// A box is produced when its block approaches the viewport and dropped when it
/// leaves. That is the whole memory strategy: the document's *structure* is
/// permanent and small, its *rendering* is transient and bounded by the size of
/// the window rather than the size of the file.
public final class BlockBox {
    /// A run of typeset text with its own attributed string — one per block for
    /// ordinary content, one per cell for a table.
    public struct Segment {
        var attributed: NSAttributedString
        var lines: [TextLine]
        /// Where this segment's text starts inside the block's plain text.
        var textOffset: Int
    }

    public enum Decoration {
        case fill(rect: CGRect, color: CGColor, cornerRadius: CGFloat)
        case stroke(rect: CGRect, color: CGColor, width: CGFloat)
        case path(CGPath, color: CGColor, lineWidth: CGFloat, filled: Bool)
    }

    public struct LinkRegion {
        var rect: CGRect
        var link: Int32
    }

    let leaf: Int32
    let width: CGFloat
    let height: CGFloat
    let segments: [Segment]
    let decorations: [Decoration]
    let links: [LinkRegion]
    let linkTargets: [InlineLink]
    /// The block's text with inline markup removed — what Copy and Find work on.
    let plainText: String

    init(
        leaf: Int32,
        width: CGFloat,
        height: CGFloat,
        segments: [Segment],
        decorations: [Decoration],
        links: [LinkRegion],
        linkTargets: [InlineLink],
        plainText: String
    ) {
        self.leaf = leaf
        self.width = width
        self.height = height
        self.segments = segments
        self.decorations = decorations
        self.links = links
        self.linkTargets = linkTargets
        self.plainText = plainText
    }

    /// Rough memory cost, used to bound the box cache.
    var footprint: Int {
        var total = 256
        for segment in segments {
            total += segment.attributed.length * 4 + segment.lines.count * 96
        }
        total += decorations.count * 64 + links.count * 48 + plainText.utf8.count
        return total
    }

    func link(at point: CGPoint) -> InlineLink? {
        for region in links where region.rect.contains(point) {
            guard region.link >= 0, Int(region.link) < linkTargets.count else { continue }
            return linkTargets[Int(region.link)]
        }
        return nil
    }
}
