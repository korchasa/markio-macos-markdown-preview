import CoreText
import Foundation
import MarkdownKit

/// The rule that decides whether an image inside a sentence is drawn as a
/// picture or left as its alt text — and the run delegate that reserves room
/// for it on the line.
///
/// The rule looks at the destination alone. It cannot depend on whether the
/// file decodes, or even on whether the document has a location: `FindEngine`
/// projects the same text on a background queue, with no loader and no window,
/// and a match offset from one has to land on the same character in the other.
/// A picture that turns out to be unreadable therefore draws an empty frame
/// rather than changing the text under the reader's search.
enum InlineImage {
    /// The character a drawn picture occupies — the standard object
    /// replacement, so a copied paragraph shows something happened here.
    static let placeholder = "\u{FFFC}"

    /// The attribute carrying the run's link index, so the laid-out line can be
    /// matched back to the image it came from.
    static let key = NSAttributedString.Key("markio.inlineImage")

    /// Whether this destination is something that could be a file beside the
    /// document. Remote addresses cannot be fetched — there is no network path
    /// — so they keep the marker and the alt text.
    static func isDrawable(destination: String) -> Bool {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return false }
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return true }
        return scheme == "file"
    }

    /// Whether a run is alt text belonging to a picture that will be drawn.
    ///
    /// Alt text describes an image for someone who cannot see it. Once the
    /// picture is on the line, repeating its description beside it is noise —
    /// so both projections drop it, together.
    static func isHiddenAltText(run: InlineRun, inline: InlineContent) -> Bool {
        guard run.link >= 0, Int(run.link) < inline.links.count else { return false }
        let link = inline.links[Int(run.link)]
        return link.isImage && isDrawable(destination: link.destination)
    }

    /// The box a picture takes on a line: tall enough to be seen, short enough
    /// that the line it sits on is still a line of text.
    static func size(image: CGImage?, lineHeight: CGFloat) -> CGSize {
        let maxHeight = lineHeight * 2.4
        guard let image, image.width > 0, image.height > 0 else {
            return CGSize(width: lineHeight * 1.2, height: lineHeight * 1.2)
        }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let height = min(maxHeight, CGFloat(image.height) / 2)
        return CGSize(width: (height * aspect).rounded(), height: height.rounded())
    }

    /// Four fifths of a picture's height sits above the baseline and the rest
    /// hangs below it, the way a letter with a descender does, so a picture on a
    /// line of prose looks seated rather than floating. The fractions are spelled
    /// out in the callbacks below: they are C function pointers, which cannot
    /// capture anything, not even a constant.

    /// A delegate that makes CoreText leave `size` worth of room for the
    /// placeholder character. Without it the picture would be drawn over the
    /// text that follows it.
    static func delegate(size: CGSize) -> CTRunDelegate? {
        let box = UnsafeMutablePointer<CGSize>.allocate(capacity: 1)
        box.initialize(to: size)
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { pointer in
                pointer.assumingMemoryBound(to: CGSize.self).deallocate()
            },
            getAscent: { pointer in
                pointer.assumingMemoryBound(to: CGSize.self).pointee.height * 0.8
            },
            getDescent: { pointer in
                pointer.assumingMemoryBound(to: CGSize.self).pointee.height * 0.2
            },
            getWidth: { pointer in
                pointer.assumingMemoryBound(to: CGSize.self).pointee.width
            }
        )
        return CTRunDelegateCreate(&callbacks, box)
    }
}
