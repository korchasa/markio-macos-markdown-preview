import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// The match find has taken the reader to is painted in a strong colour, and
/// the text on it has to stay readable in both appearances.
@MainActor
final class FindHighlightTests: XCTestCase {
    private func view(_ text: String, dark: Bool) -> DocumentView {
        let layout = DocumentLayout(
            document: Document(text: text), theme: Theme(isDark: dark), columnWidth: 420)
        let view = DocumentView(layout: layout)
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        scrollView.documentView = view
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        scrollView.layoutSubtreeIfNeeded()
        view.viewWillDraw()
        return view
    }

    /// WCAG relative luminance of an sRGB colour.
    private func luminance(_ color: CGColor) -> CGFloat {
        let rgb = color.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!
        let channels = rgb.components!.prefix(3).map { value -> CGFloat in
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private func contrast(_ a: CGColor, _ b: CGColor) -> CGFloat {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Draw a block with its highlights, as the view does, and return the
    /// darkest pixel inside the given rectangle and the share of its pixels
    /// that are still the highlight's own colour.
    private func sample(
        of box: BlockBox, highlights: [DocumentRenderer.Highlight], in rect: CGRect,
        background: CGColor, highlight: CGColor
    ) throws -> (darkest: CGFloat, highlighted: Double) {
        let scale: CGFloat = 2
        let width = Int(ceil(max(box.width, rect.maxX) * scale))
        let height = Int(ceil(box.height * scale))
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: box.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        DocumentRenderer.draw(box: box, highlights: highlights, in: context)

        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        var darkest: CGFloat = 1
        var highlighted = 0
        var total = 0
        let target = try XCTUnwrap(
            highlight.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
            )?.components)
        // Bitmap rows run bottom-up; the box's coordinates run top-down.
        let inner = rect.insetBy(dx: 1.5, dy: 1.5)
        for y in Int(inner.minY * scale)..<Int(inner.maxY * scale) {
            let row = height - 1 - y
            for x in Int(inner.minX * scale)..<Int(inner.maxX * scale) {
                let pixel = data + row * stride + x * 4
                let color = CGColor(
                    srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                    blue: CGFloat(pixel[2]) / 255, alpha: 1)
                darkest = min(darkest, luminance(color))
                let channels = [pixel[0], pixel[1], pixel[2]].map { CGFloat($0) / 255 }
                if zip(channels, target).allSatisfy({ abs($0 - $1) < 0.04 }) { highlighted += 1 }
                total += 1
            }
        }
        return (darkest, Double(highlighted) / Double(max(1, total)))
    }

    /// In the dark the text is light and the current match is a bright
    /// orange, so the word find just took the reader to read at about 2:1.
    /// The text on that match is drawn in a dark ink instead.
    func testTheCurrentMatchIsReadableInTheDark() throws {
        for dark in [true, false] {
            let view = view("A sentence with the word ledger in it.\n", dark: dark)
            let palette = view.layout.theme.palette
            let box = try XCTUnwrap(view.layout.box(at: 0))
            let location = box.plainText.distance(
                from: box.plainText.startIndex,
                to: try XCTUnwrap(box.plainText.range(of: "ledger")).lowerBound)
            view.setFindMatches(
                [DocumentView.FindMatch(ordinal: 0, location: location, length: 6)], current: 0)

            let highlights = view.highlights(box: box, ordinal: 0, selection: nil)
            let current = try XCTUnwrap(
                highlights.first { $0.color == palette.findCurrentMatch })
            let ink = try XCTUnwrap(current.ink, "dark: \(dark)")
            XCTAssertGreaterThanOrEqual(
                contrast(ink, palette.findCurrentMatch), 4.5, "dark: \(dark)")

            let rect = current.rects.reduce(CGRect.null) { $0.union($1) }
            let drawn = try sample(
                of: box, highlights: highlights, in: rect, background: palette.background,
                highlight: palette.findCurrentMatch)
            XCTAssertLessThan(
                drawn.darkest, luminance(ink) + 0.05,
                "the glyphs on the match are in the ink, dark: \(dark)")
            // Only the glyphs take the ink: a fill that covered the whole match
            // also passes the check above, and leaves a dark bar with no word.
            XCTAssertGreaterThan(
                drawn.highlighted, 0.4, "the match keeps its own colour, dark: \(dark)")
        }
    }

    /// Only the current match changes its ink: the others stay as they were,
    /// so the one the reader is on still stands out.
    func testOtherMatchesKeepTheirText() throws {
        let view = view("ledger and ledger\n", dark: true)
        view.setFindMatches(
            [
                DocumentView.FindMatch(ordinal: 0, location: 0, length: 6),
                DocumentView.FindMatch(ordinal: 0, location: 11, length: 6),
            ], current: 0)
        let box = try XCTUnwrap(view.layout.box(at: 0))
        let highlights = view.highlights(box: box, ordinal: 0, selection: nil)
        XCTAssertEqual(highlights.count, 2)
        XCTAssertNotNil(highlights[0].ink)
        XCTAssertNil(highlights[1].ink)
    }
}
