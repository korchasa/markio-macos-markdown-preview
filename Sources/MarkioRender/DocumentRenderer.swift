import AppKit
import CoreText

/// Draws laid-out blocks into a Core Graphics context.
///
/// Separated from the view so the exact same code paints the window and paints
/// an offscreen bitmap. A renderer that only exists inside an `NSView` cannot
/// be checked without a screen, and a viewer's output is the thing most worth
/// checking.
public enum DocumentRenderer {
    /// Highlight ranges to paint behind the text, in block-local coordinates.
    public struct Highlight {
        public var rects: [CGRect]
        public var color: CGColor

        public init(rects: [CGRect], color: CGColor) {
            self.rects = rects
            self.color = color
        }
    }

    /// Draw one block. The context must already be translated so that the
    /// block's top-left corner is the origin.
    public static func draw(
        box: BlockBox,
        highlights: [Highlight],
        in context: CGContext
    ) {
        shapes(box.decorations, in: context)
        for highlight in highlights {
            context.setFillColor(highlight.color)
            for rect in highlight.rects { context.fill(rect) }
        }
        for segment in box.segments {
            for line in segment.lines {
                context.textPosition = line.origin
                CTLineDraw(line.line, context)
            }
        }
        for case .glyphs(let line, let origin) in box.decorations {
            context.textPosition = origin
            CTLineDraw(line, context)
        }
    }

    /// Everything in a list of decorations except its glyphs, which are drawn
    /// last so a highlight tints them instead of covering them.
    private static func shapes(_ decorations: [BlockBox.Decoration], in context: CGContext) {
        for decoration in decorations {
            switch decoration {
            case .glyphs:
                // Formula glyphs are drawn after the highlights, below.
                continue
            case .fill(let rect, let color, let radius):
                context.setFillColor(color)
                if radius > 0 {
                    context.addPath(
                        CGPath(
                            roundedRect: rect,
                            cornerWidth: radius,
                            cornerHeight: radius,
                            transform: nil
                        )
                    )
                    context.fillPath()
                } else {
                    context.fill(rect)
                }
            case .stroke(let rect, let color, let width):
                context.setStrokeColor(color)
                context.setLineWidth(width)
                context.stroke(rect.insetBy(dx: width / 2, dy: width / 2))
            case .image(let image, let rect):
                // The context is flipped for text, so an image drawn straight
                // into it comes out upside down.
                context.saveGState()
                context.translateBy(x: 0, y: rect.midY)
                context.scaleBy(x: 1, y: -1)
                context.draw(
                    image,
                    in: CGRect(origin: CGPoint(x: rect.minX, y: -rect.height / 2), size: rect.size))
                context.restoreGState()
            case .path(let path, let color, let lineWidth, let filled):
                context.addPath(path)
                if filled {
                    context.setFillColor(color)
                    context.fillPath()
                } else {
                    context.setStrokeColor(color)
                    context.setLineWidth(lineWidth)
                    context.setLineJoin(.round)
                    context.setLineCap(.round)
                    context.strokePath()
                }
            }
        }
    }

    /// The room a diagram is given when it is drawn for its own sake rather
    /// than for a column — enlarged, copied, or written out as a file.
    ///
    /// Not unlimited: the width is what decides whether a message label wraps,
    /// so a diagram offered a whole screen of room spreads its columns out to
    /// the width of its longest sentence. Six thousand points is past the point
    /// where any of this project's diagrams still grows — measured, not guessed
    /// — and stops the ones that would from running to a bitmap nobody can look
    /// at.
    public static let naturalWidth: CGFloat = 6000

    /// The bitmap density worth using for a picture of a given size, and the
    /// resolution to record with it.
    ///
    /// Two device pixels per point is what a Retina screen wants, but a diagram
    /// four thousand points across then becomes a bitmap eight thousand pixels
    /// wide, which is a slow file and an unwieldy window. Past that size the
    /// density drops instead, and the file says what it is in dots per inch, so
    /// a viewer showing it at full size still shows it at the size it was drawn.
    public static func density(for size: CGSize, limit: CGFloat = 8000) -> CGFloat {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return 2 }
        return max(1, min(2, limit / longest))
    }

    /// A Mermaid fence drawn on its own, at whatever width is asked for.
    ///
    /// The source is re-read rather than a drawing kept beside the block: a
    /// diagram enlarged has to be laid out again anyway — its type does not
    /// simply scale — and holding a second copy of every picture on screen
    /// would cost exactly what this viewer refuses to spend.
    @MainActor
    public static func diagram(
        source: String, theme: Theme, width: CGFloat, scale: CGFloat = 2
    ) -> CGImage? {
        guard let parsed = MermaidDiagram.parse(source) else { return nil }
        let drawing = MermaidLayout.cropped(
            MermaidLayout.draw(parsed, theme: theme, width: width))
        // A picture is centred in the width it is given, so a small diagram
        // asked for at a large one comes back sitting in a field of empty card.
        // Here the width is a limit and not a frame — the enlarged window and
        // Copy PNG both want the picture and nothing else — so the bitmap is cut
        // to what was drawn. Cut, and not laid out again narrower: width decides
        // where labels wrap, so a second layout is a second picture, and the
        // reader would see one of them in the page and the other one enlarged.
        let size = CGSize(width: drawing.size.width, height: drawing.size.height)
        guard size.width > 0, size.height > 0,
            let context = CGContext(
                data: nil,
                width: Int(size.width * scale),
                height: Int(size.height * scale),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(drawing.background)
        context.fill(CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        shapes(drawing.decorations, in: context)
        for case .glyphs(let line, let origin) in drawing.decorations {
            context.textPosition = origin
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }

    /// A picture still too wide for its column after the layout has shrunk it,
    /// squeezed geometrically until it fits.
    ///
    /// The layout shrinks a diagram by drawing it again at a smaller type size,
    /// and that stops being proportional once the type is down near a point:
    /// the widths stop following the size and the picture stays wider than the
    /// column. A diagram that reaches across four thousand points is unreadable
    /// at any column width anyway — what the page owes the reader there is the
    /// whole shape, with the words read in the enlarged window — so whatever
    /// the layout could not fit is scaled as drawn, which fits exactly and
    /// keeps the proportions the diagram was laid out with.
    static func squeezed(
        _ drawing: MermaidLayout.Drawing, theme: Theme, into width: CGFloat, scale: CGFloat = 2
    ) -> (image: CGImage, size: CGSize)? {
        guard drawing.size.width > 0, drawing.size.height > 0, width > 0 else { return nil }
        let factor = width / drawing.size.width
        let size = CGSize(width: width, height: (drawing.size.height * factor).rounded(.up))
        guard
            let context = CGContext(
                data: nil,
                width: Int(size.width * scale),
                height: Int(size.height * scale),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(drawing.background)
        context.fill(CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: factor, y: factor)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        shapes(drawing.decorations, in: context)
        for case .glyphs(let line, let origin) in drawing.decorations {
            context.textPosition = origin
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage() else { return nil }
        return (image, size)
    }

    /// The band behind a block that changed between the compared versions.
    ///
    /// It spans the whole width rather than the reading column: a change is a
    /// property of the page, and a band that stops at the text reads as part of
    /// the block instead of a marker on it. The stripe at the left edge is what
    /// stays visible when the tint is too faint to notice.
    public static func drawCompareBand(
        mark: CompareEngine.Mark,
        theme: Theme,
        rect: CGRect,
        in context: CGContext
    ) {
        let palette = theme.palette
        let added = mark == .added
        context.setFillColor(added ? palette.diffAddedBackground : palette.diffRemovedBackground)
        context.fill(rect)
        context.setFillColor(added ? palette.diffAddedText : palette.diffRemovedText)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height))
    }

    /// Render a window's worth of document into a bitmap.
    ///
    /// Used by the snapshot tool and by tests: it needs no window, no screen
    /// and no run loop.
    @MainActor
    public static func image(
        layout: DocumentLayout,
        size: CGSize,
        scrollOffset: CGFloat = 0,
        verticalPadding: CGFloat = 28
    ) -> CGImage? {
        let scale: CGFloat = 2
        guard
            let context = CGContext(
                data: nil,
                width: Int(size.width * scale),
                height: Int(size.height * scale),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setFillColor(layout.theme.palette.background)
        context.fill(CGRect(origin: .zero, size: size))
        // Flip into the same top-down space the view uses, so block offsets are
        // read straight from the height index.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let originX = max(24, (size.width - layout.columnWidth) / 2)
        let first = layout.index(atOffset: max(0, scrollOffset))
        var ordinal = first
        while ordinal < layout.blockCount {
            let top = layout.offset(of: ordinal) + verticalPadding - scrollOffset
            if top > size.height { break }
            guard let box = layout.box(at: ordinal) else { break }
            if let mark = layout.mark(at: ordinal) {
                drawCompareBand(
                    mark: mark,
                    theme: layout.theme,
                    rect: CGRect(x: 0, y: top, width: size.width, height: box.height),
                    in: context
                )
            }
            context.saveGState()
            context.translateBy(x: originX, y: top)
            draw(box: box, highlights: [], in: context)
            context.restoreGState()
            ordinal += 1
        }
        return context.makeImage()
    }
}
