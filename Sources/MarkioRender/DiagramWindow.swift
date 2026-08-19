import AppKit

/// A diagram shown on its own, large, over the document it came from.
///
/// A diagram in the reading column is as wide as the column, and a graph with
/// twenty boxes in it is drawn small enough to fit. This is where the reader
/// gets to see it properly — not merely laid out again at a greater width,
/// which spreads a sequence diagram sideways and leaves its lettering exactly
/// as small as it was, but magnified, with the room to move around inside it.
@MainActor
final class DiagramWindow: NSPanel {
    /// The source of the diagram on show, so a second click on the same one
    /// closes it instead of opening it again.
    private(set) var source: String = ""

    /// Magnification the scroll view will accept. The floor lets a diagram
    /// taller than the screen be taken in whole; the ceiling is where even a
    /// six-point label has become a headline.
    static let magnificationRange: ClosedRange<CGFloat> = 0.2...8

    static func present(source: String, theme: Theme, over host: NSWindow) -> DiagramWindow? {
        guard let screen = host.screen ?? NSScreen.main else { return nil }
        // Room enough to be worth opening, never so much that the panel runs
        // past the edge of the screen it is shown on.
        let room = screen.visibleFrame.insetBy(dx: 60, dy: 60)
        // Room enough that the layout never shrinks the picture to fit: this
        // window is where a diagram is seen at its own size, and the panel
        // magnifies from there rather than the layout shrinking beforehand.
        guard let canvas = Canvas(source: source, theme: theme, width: naturalRoom)
        else { return nil }
        let size = panelSize(picture: canvas.pictureSize, room: room.size)
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
        panel.hidesOnDeactivate = true
        panel.canvas = canvas
        panel.contentView = canvas
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
        canvas.showWhole()
        return panel
    }

    /// A width no diagram is expected to want, so the layout lays one out at
    /// its natural size instead of shrinking it into a column.
    static let naturalRoom: CGFloat = 20000

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

    /// The bitmap scale worth holding for a given magnification.
    ///
    /// A picture drawn for the screen it sat in goes soft the moment it is
    /// blown up, and lettering is the first thing to go. Rather than keep one
    /// enormous bitmap against a zoom the reader may never ask for, the drawing
    /// is made again at the density the current magnification actually needs,
    /// in whole steps so that a slow pinch does not redraw continuously.
    static func bitmapScale(for magnification: CGFloat) -> CGFloat {
        let wanted = (2 * max(1, magnification)).rounded(.up)
        return min(8, max(2, wanted))
    }

    private var canvas: Canvas?

    // A borderless panel refuses the key window by default, and without it the
    // Escape key never reaches anything.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    /// A click anywhere on the picture puts it away, which is what a reader who
    /// opened it with a click reaches for first.
    override func mouseDown(with event: NSEvent) { close() }

    /// And a click on the document behind it: the document window taking the
    /// key status is what that click looks like from here.
    override func resignKey() {
        super.resignKey()
        // Not from inside the change of key window itself — closing a window
        // while AppKit is still settling which one is key unwinds a state it
        // is in the middle of setting.
        DispatchQueue.main.async { [weak self] in self?.close() }
    }

    override func keyDown(with event: NSEvent) {
        // Escape reaches a window as a plain key press. Only a text view turns
        // one into `cancelOperation`, so a panel that waits for that call waits
        // for ever.
        if event.charactersIgnoringModifiers == "\u{1b}" {
            close()
            return
        }
        guard let canvas else { return super.keyDown(with: event) }
        // The three commands every viewer on this system answers to.
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                canvas.zoom(by: 1.4)
                return
            case "-":
                canvas.zoom(by: 1 / 1.4)
                return
            case "0":
                canvas.showWhole()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    /// The picture inside something that scrolls and magnifies, on the same
    /// background a fenced block has — so an enlarged diagram still looks like
    /// the one in the document.
    final class Canvas: NSView {
        private let scrollView = NSScrollView()
        private let picture = NSImageView()
        private let source: String
        private let theme: Theme
        private let width: CGFloat
        /// The picture's size in points, which never changes: magnification is
        /// what changes, and the bitmap behind it is redrawn to suit.
        let pictureSize: CGSize
        private var bitmapScale: CGFloat
        private var redraw: DispatchWorkItem?

        init?(source: String, theme: Theme, width: CGFloat) {
            let scale = DiagramWindow.bitmapScale(for: 1)
            guard
                let image = DocumentRenderer.diagram(
                    source: source, theme: theme, width: width, scale: scale)
            else { return nil }
            self.source = source
            self.theme = theme
            self.width = width
            self.bitmapScale = scale
            self.pictureSize = CGSize(
                width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            super.init(frame: .zero)

            wantsLayer = true
            layer?.cornerRadius = 12
            layer?.masksToBounds = true
            layer?.backgroundColor = theme.palette.codeBackground
            layer?.borderColor = theme.palette.tableBorder
            layer?.borderWidth = 1

            picture.image = NSImage(cgImage: image, size: pictureSize)
            picture.imageScaling = .scaleAxesIndependently
            picture.frame = CGRect(origin: .zero, size: pictureSize)

            scrollView.documentView = picture
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.allowsMagnification = true
            scrollView.minMagnification = DiagramWindow.magnificationRange.lowerBound
            scrollView.maxMagnification = DiagramWindow.magnificationRange.upperBound
            scrollView.autoresizingMask = [.width, .height]
            addSubview(scrollView)

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(magnificationChanged),
                name: NSScrollView.didEndLiveMagnifyNotification,
                object: scrollView
            )
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            scrollView.frame = bounds
        }

        /// Fit the whole diagram in the panel — what the reader sees first, and
        /// what ⌘0 goes back to.
        func showWhole() {
            layoutSubtreeIfNeeded()
            let room = scrollView.contentView.bounds.size
            guard pictureSize.width > 0, pictureSize.height > 0, room.width > 0 else { return }
            let fit = min(room.width / pictureSize.width, room.height / pictureSize.height)
            setMagnification(min(max(fit, scrollView.minMagnification), 1))
        }

        func zoom(by factor: CGFloat) {
            setMagnification(scrollView.magnification * factor)
        }

        private func setMagnification(_ value: CGFloat) {
            let clamped = min(
                max(value, scrollView.minMagnification), scrollView.maxMagnification)
            scrollView.setMagnification(clamped, centeredAt: centreOfView())
            magnificationChanged()
        }

        private func centreOfView() -> NSPoint {
            let visible = scrollView.contentView.documentVisibleRect
            return NSPoint(x: visible.midX, y: visible.midY)
        }

        /// Draw the picture again at the density the new magnification needs.
        ///
        /// Deferred by a moment so that a pinch, which lands as a run of
        /// changes, costs one drawing and not thirty.
        @objc private func magnificationChanged() {
            let wanted = DiagramWindow.bitmapScale(for: scrollView.magnification)
            guard wanted != bitmapScale else { return }
            redraw?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard
                    let image = DocumentRenderer.diagram(
                        source: self.source, theme: self.theme, width: self.width, scale: wanted)
                else { return }
                self.bitmapScale = wanted
                self.picture.image = NSImage(cgImage: image, size: self.pictureSize)
            }
            redraw = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }
}
