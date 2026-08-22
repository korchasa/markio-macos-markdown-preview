import AppKit
import MarkdownKit

/// The document shown one slide at a time, full screen.
///
/// It is deliberately not the document window with things hidden: no sidebar,
/// no bottom bar, no find, no selection. What it shares is everything that
/// matters — the same parse, the same layout engine, the same renderer — so a
/// deck is the document read at a different size rather than a second way of
/// rendering Markdown.
@MainActor
public final class PresentationWindow: NSWindow {
    private let slideView: SlideView
    private let counter = NSTextField(labelWithString: "")
    private let slides: [Range<Int>]
    private var index: Int {
        didSet { showCurrentSlide() }
    }

    /// Open a deck over the reader's screen, or answer nil when the document is
    /// not one.
    @discardableResult
    public static func present(
        document: Document, baseURL: URL?, over parent: NSWindow?, startingAt slide: Int = 0
    ) -> PresentationWindow? {
        let slides = Slides.split(document)
        guard !slides.isEmpty else { return nil }
        let screen = parent?.screen ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = PresentationWindow(
            document: document, baseURL: baseURL, slides: slides, frame: frame,
            startingAt: slide)
        // A deck takes the screen, so it takes the focus with it — otherwise
        // the arrow keys go to whatever was in front before.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // The menu bar and the Dock would sit on top of a slide otherwise.
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        return window
    }

    private init(
        document: Document, baseURL: URL?, slides: [Range<Int>], frame: CGRect, startingAt: Int
    ) {
        self.slides = slides
        self.index = min(max(0, startingAt), slides.count - 1)
        // A deck is read from across a room, so the type is set large and the
        // column wide; whatever will not fit is scaled down by the view.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let theme = Theme(isDark: dark, metrics: Theme.Metrics().scaled(by: 1.6))
        let layout = DocumentLayout(
            document: document, theme: theme, columnWidth: 820, baseURL: baseURL)
        layout.showsTableFilters = false
        self.slideView = SlideView(layout: layout)
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = .modalPanel
        backgroundColor = NSColor(cgColor: theme.palette.background) ?? .textBackgroundColor
        collectionBehavior = [.fullScreenPrimary, .transient]

        counter.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        counter.textColor = NSColor(cgColor: theme.palette.secondaryText) ?? .secondaryLabelColor
        for view in [slideView, counter] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView?.addSubview(view)
        }
        guard let container = contentView else { return }
        NSLayoutConstraint.activate([
            slideView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            slideView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            slideView.topAnchor.constraint(equalTo: container.topAnchor),
            slideView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            counter.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            counter.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
        ])
        showCurrentSlide()
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public var slideCount: Int { slides.count }
    public var currentSlide: Int { index }

    private func showCurrentSlide() {
        slideView.show(range: slides[index])
        counter.stringValue = "\(index + 1) / \(slides.count)"
    }

    public func advance(by delta: Int) {
        let next = index + delta
        guard next >= 0, next < slides.count else { return }
        index = next
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape
            leave()
        case 123, 116, 51:  // ←, page up, delete
            advance(by: -1)
        case 124, 121, 49, 36:  // →, page down, space, return
            advance(by: 1)
        case 125:  // ↓
            advance(by: 1)
        case 126:  // ↑
            advance(by: -1)
        default:
            super.keyDown(with: event)
        }
    }

    /// A click anywhere moves on, which is what a presenter's remote does too.
    public override func mouseDown(with event: NSEvent) {
        advance(by: 1)
    }

    public func leave() {
        NSApp.presentationOptions = []
        close()
    }
}

/// One slide, drawn to fit.
///
/// The slide is a range of the document's own blocks, laid out at the deck's
/// width by the ordinary engine. All this view does is centre that range and,
/// when it is taller or wider than the screen, scale it down — a slide is shown
/// smaller rather than cut, because a cut slide silently loses a line.
@MainActor
final class SlideView: NSView {
    private let layout: DocumentLayout
    private var range: Range<Int> = 0..<0

    private let padding: CGFloat = 60

    init(layout: DocumentLayout) {
        self.layout = layout
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code only") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func show(range: Range<Int>) {
        self.range = range
        _ = layout.prepare(range: range, anchor: range.lowerBound)
        needsDisplay = true
    }

    /// How tall the slide is, once its blocks have been measured.
    private var slideHeight: CGFloat {
        guard !range.isEmpty else { return 0 }
        let top = layout.offset(of: range.lowerBound)
        let bottom =
            range.upperBound < layout.blockCount
            ? layout.offset(of: range.upperBound) : layout.totalHeight
        return max(0, bottom - top)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(layout.theme.palette.background)
        context.fill(dirtyRect)
        guard !range.isEmpty else { return }

        let height = slideHeight
        guard height > 0 else { return }
        let room = CGSize(
            width: max(100, bounds.width - padding * 2),
            height: max(100, bounds.height - padding * 2))
        let scale = min(1, min(room.height / height, room.width / layout.columnWidth))
        let drawnWidth = layout.columnWidth * scale
        let drawnHeight = height * scale

        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.translateBy(
            x: (bounds.width - drawnWidth) / 2, y: (bounds.height - drawnHeight) / 2)
        context.scaleBy(x: scale, y: scale)
        let top = layout.offset(of: range.lowerBound)
        for ordinal in range {
            guard let box = layout.box(at: ordinal), box.height > 0 else { continue }
            context.saveGState()
            context.translateBy(x: 0, y: layout.offset(of: ordinal) - top)
            DocumentRenderer.draw(box: box, highlights: [], in: context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
