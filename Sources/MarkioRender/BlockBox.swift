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
        case image(CGImage, rect: CGRect)
        /// Glyphs placed by something other than the line breaker — today that
        /// is a formula, whose pieces sit above and below their own baseline.
        /// Drawn after the highlights, so a selection tints them instead of
        /// covering them.
        case glyphs(CTLine, origin: CGPoint)
    }

    public struct LinkRegion {
        var rect: CGRect
        var link: Int32
    }

    /// A fenced block's own rectangle and the language it declared, so the view
    /// can offer Copy and name the language without re-reading the source.
    public struct CodeRegion {
        public var rect: CGRect
        public var language: String
        /// Whether a picture was drawn in place of the fence. A diagram can be
        /// enlarged and copied as an image; a fence of text cannot.
        public var isDiagram: Bool = false
    }

    /// The header of a collapsible section: what a click on it toggles.
    public struct DisclosureRegion {
        public var rect: CGRect
        public var isExpanded: Bool
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
    let codeRegion: CodeRegion?
    let disclosureRegion: DisclosureRegion?

    init(
        leaf: Int32,
        width: CGFloat,
        height: CGFloat,
        segments: [Segment],
        decorations: [Decoration],
        links: [LinkRegion],
        linkTargets: [InlineLink],
        plainText: String,
        codeRegion: CodeRegion? = nil,
        disclosureRegion: DisclosureRegion? = nil
    ) {
        self.leaf = leaf
        self.width = width
        self.height = height
        self.segments = segments
        self.decorations = decorations
        self.links = links
        self.linkTargets = linkTargets
        self.plainText = plainText
        self.codeRegion = codeRegion
        self.disclosureRegion = disclosureRegion
    }

    /// A block that takes no room and draws nothing — what a block inside a
    /// closed section becomes.
    static func empty(leaf: Int32, width: CGFloat) -> BlockBox {
        BlockBox(
            leaf: leaf,
            width: width,
            height: 0,
            segments: [],
            decorations: [],
            links: [],
            linkTargets: [],
            plainText: ""
        )
    }

    /// Rough memory cost, used to bound the box cache.
    var footprint: Int {
        var total = 256
        for segment in segments {
            total += segment.attributed.length * 4 + segment.lines.count * 96
        }
        total += decorations.count * 64 + links.count * 48 + plainText.utf8.count
        for decoration in decorations {
            // An image dwarfs everything else in a box, and the cache that
            // holds it is bounded separately; count it so eviction sees the
            // real cost of keeping this block around.
            if case .image(let image, _) = decoration {
                total += image.bytesPerRow * image.height
            }
        }
        return total
    }

    /// Move one piece of drawing into the block's coordinates.
    ///
    /// A diagram is laid out from its own corner and then placed, which is what
    /// keeps the geometry readable — the alternative is threading the block's
    /// origin through every line of it.
    static func move(_ decoration: Decoration, dx: CGFloat, dy: CGFloat) -> Decoration {
        switch decoration {
        case .fill(let rect, let color, let radius):
            return .fill(rect: rect.offsetBy(dx: dx, dy: dy), color: color, cornerRadius: radius)
        case .stroke(let rect, let color, let width):
            return .stroke(rect: rect.offsetBy(dx: dx, dy: dy), color: color, width: width)
        case .image(let image, let rect):
            return .image(image, rect: rect.offsetBy(dx: dx, dy: dy))
        case .glyphs(let line, let origin):
            return .glyphs(line, origin: CGPoint(x: origin.x + dx, y: origin.y + dy))
        case .path(let path, let color, let lineWidth, let filled):
            var transform = CGAffineTransform(translationX: dx, y: dy)
            let moved = path.copy(using: &transform) ?? path
            return .path(moved, color: color, lineWidth: lineWidth, filled: filled)
        }
    }

    func link(at point: CGPoint) -> InlineLink? {
        for region in links where region.rect.contains(point) {
            guard region.link >= 0, Int(region.link) < linkTargets.count else { continue }
            return linkTargets[Int(region.link)]
        }
        return nil
    }
}
