import AppKit

/// A diagram shown on its own, large, over the document it came from.
///
/// A diagram in the reading column is as wide as the column, and a graph with
/// twenty boxes in it is drawn smaller to fit. This is where the reader gets to
/// see it properly: the same picture laid out again at the width of the window
/// rather than the width of the text.
@MainActor
final class DiagramWindow: NSPanel {
    /// The source of the diagram on show, so a second click on the same one
    /// closes it instead of opening it again.
    private(set) var source: String = ""

    static func present(source: String, theme: Theme, over host: NSWindow) -> DiagramWindow? {
        guard let screen = host.screen ?? NSScreen.main else { return nil }
        // Room enough to be worth opening, never so much that the picture runs
        // past the edge of the screen it is shown on.
        let room = screen.visibleFrame.insetBy(dx: 60, dy: 60)
        let width = min(max(host.frame.width * 0.9, 640), room.width)
        let scale: CGFloat = 2
        guard
            let image = DocumentRenderer.diagram(
                source: source, theme: theme, width: width, scale: scale)
        else { return nil }
        let picture = CGSize(
            width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let size = panelSize(picture: picture, room: room.size)
        guard size.width > 0, size.height > 0 else { return nil }

        let panel = DiagramWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.source = source
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.contentView = Backdrop(image: image, theme: theme)
        panel.setFrame(
            CGRect(
                x: host.frame.midX - size.width / 2,
                y: host.frame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        panel.makeKeyAndOrderFront(nil)
        return panel
    }

    /// The panel's size in points: the picture's own shape, shrunk to fit the
    /// room it is shown in — both sides by the same factor.
    ///
    /// The width handed to the renderer is a limit and not a frame, so a
    /// diagram narrower than the offered room comes back at its own size. A
    /// panel built to the asked-for width and filled with that picture
    /// stretched every diagram that did not happen to fill the column, and a
    /// height clamped on its own squashed every diagram taller than the screen.
    static func panelSize(picture: CGSize, room: CGSize) -> CGSize {
        guard picture.width > 0, picture.height > 0, room.width > 0, room.height > 0 else {
            return .zero
        }
        let fit = min(1, min(room.width / picture.width, room.height / picture.height))
        return CGSize(width: picture.width * fit, height: picture.height * fit)
    }

    // A borderless panel refuses the key window by default, and without it the
    // Escape key never reaches anything.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    override func mouseDown(with event: NSEvent) { close() }

    /// The picture, rounded and inset, on the same background a fenced block
    /// has — so an enlarged diagram looks like the one in the document.
    private final class Backdrop: NSView {
        private let image: CGImage
        private let theme: Theme

        init(image: CGImage, theme: Theme) {
            self.image = image
            self.theme = theme
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let frame = bounds
            let path = CGPath(roundedRect: frame, cornerWidth: 12, cornerHeight: 12, transform: nil)
            context.addPath(path)
            context.setFillColor(theme.palette.codeBackground)
            context.fillPath()
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.draw(image, in: frame)
            context.restoreGState()
            context.addPath(path)
            context.setStrokeColor(theme.palette.tableBorder)
            context.setLineWidth(1)
            context.strokePath()
        }
    }
}
