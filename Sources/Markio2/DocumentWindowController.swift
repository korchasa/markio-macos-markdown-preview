import AppKit
import CoreText
import MarkdownKit
import MarkioRender

/// One window, one document.
///
/// Owns the reading surface, the outline sidebar, the find bar and the reading
/// width control, and keeps them in step with each other. All the expensive
/// work lives in `MarkioRender`; this file is wiring.
@MainActor
final class DocumentWindowController: NSWindowController {
    private let markdownDocument: MarkdownDocument
    private var layout: DocumentLayout
    private let documentView: DocumentView
    private let scrollView = NSScrollView()
    private let outline = OutlineSidebar()
    private let findBar = FindBar()
    private let findEngine = FindEngine()
    private let widthSlider = NSSlider()
    private let widthLabel = NSTextField(labelWithString: "")

    private var findMatches: [DocumentView.FindMatch] = []
    private var currentMatch = -1
    private var headings: [Document.Heading] = []
    private var outlineOrdinals: [Int] = []
    private var restoredScroll = false
    private var saveWorkItem: DispatchWorkItem?

    private var sidebarWidthConstraint: NSLayoutConstraint!

    init(document: MarkdownDocument) {
        self.markdownDocument = document
        let theme = Theme(isDark: NSApp.effectiveAppearance.isDark)
        self.layout = DocumentLayout(
            document: document.parsed,
            theme: theme,
            columnWidth: DocumentWindowController.columnWidth(for: theme)
        )
        self.documentView = DocumentView(layout: layout)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 480, height: 320)
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        windowFrameAutosaveName = "MarkioDocumentWindow"
        buildInterface()
        refreshOutline()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code only") }

    // MARK: - Interface

    private func buildInterface() {
        guard let window, let container = window.contentView else { return }
        container.wantsLayer = true

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor =
            NSColor(cgColor: layout.theme.palette.background) ?? .textBackgroundColor
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true

        let separator = NSBox()
        separator.boxType = .separator

        let bottomBar = buildBottomBar()

        for view in [outline, separator, scrollView, findBar, bottomBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        sidebarWidthConstraint = outline.widthAnchor.constraint(equalToConstant: 240)
        NSLayoutConstraint.activate([
            outline.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outline.topAnchor.constraint(equalTo: container.topAnchor),
            outline.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            sidebarWidthConstraint,

            separator.leadingAnchor.constraint(equalTo: outline.trailingAnchor),
            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            scrollView.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            findBar.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -18),
            findBar.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 14),

            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 30),
        ])

        setSidebarVisible(Preferences.outlineVisible, animated: false)
        findBar.isHidden = true

        documentView.onActivateLink = { [weak self] link in self?.open(link: link) }
        documentView.onVisibleRangeChange = { [weak self] range in
            self?.visibleRangeChanged(range)
        }
        documentView.onAppearanceChange = { [weak self] in self?.appearanceChanged() }

        outline.onSelect = { [weak self] index in self?.jumpToHeading(index) }

        findBar.onQueryChange = { [weak self] query in self?.runSearch(query) }
        findBar.onNext = { [weak self] in self?.step(by: 1) }
        findBar.onPrevious = { [weak self] in self?.step(by: -1) }
        findBar.onClose = { [weak self] in self?.closeFind() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        updateTitle()
    }

    private func buildBottomBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow

        widthSlider.minValue = Double(Preferences.widthRange.lowerBound)
        widthSlider.maxValue = Double(Preferences.widthRange.upperBound)
        widthSlider.numberOfTickMarks =
            (Preferences.widthRange.upperBound - Preferences.widthRange.lowerBound)
            / Preferences.widthStep + 1
        widthSlider.allowsTickMarkValuesOnly = true
        widthSlider.doubleValue = Double(Preferences.readingWidth)
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        widthSlider.controlSize = .small

        widthLabel.font = NSFont.systemFont(ofSize: 10)
        widthLabel.textColor = .secondaryLabelColor
        widthLabel.stringValue = "\(Preferences.readingWidth) ch"

        for view in [widthSlider, widthLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            widthLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            widthSlider.trailingAnchor.constraint(equalTo: widthLabel.leadingAnchor, constant: -8),
            widthSlider.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            widthSlider.widthAnchor.constraint(equalToConstant: 120),
        ])
        return bar
    }

    // MARK: - Reading width

    /// Reading width in characters, converted to points using the advance of a
    /// digit in the body font — the same unit CSS calls `ch`.
    private static func columnWidth(for theme: Theme) -> CGFloat {
        let sample = NSAttributedString(
            string: "0",
            attributes: [AttributedBuilderKey.font: theme.body]
        )
        let line = CTLineCreateWithAttributedString(sample)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return CGFloat(Preferences.readingWidth) * max(advance, 6)
    }

    @objc private func widthChanged() {
        let value = Preferences.clampWidth(Int(widthSlider.doubleValue.rounded()))
        guard value != Preferences.readingWidth else { return }
        Preferences.readingWidth = value
        widthLabel.stringValue = "\(value) ch"
        applyColumnWidth()
    }

    private func applyColumnWidth() {
        let anchorOrdinal = layout.index(atOffset: scrollView.contentView.bounds.minY)
        layout.setColumnWidth(DocumentWindowController.columnWidth(for: layout.theme))
        documentView.needsDisplay = true
        // A width change re-measures everything, so the old scroll offset means
        // nothing; the block that was at the top is what the reader tracks.
        documentView.reveal(ordinal: anchorOrdinal)
        rerunSearchIfActive()
    }

    @objc func widenColumn(_ sender: Any?) {
        widthSlider.doubleValue = Double(Preferences.readingWidth + Preferences.widthStep)
        widthChanged()
    }

    @objc func narrowColumn(_ sender: Any?) {
        widthSlider.doubleValue = Double(Preferences.readingWidth - Preferences.widthStep)
        widthChanged()
    }

    // MARK: - Document lifecycle

    func documentDidReload() {
        let anchor = layout.index(atOffset: scrollView.contentView.bounds.minY)
        layout.replace(document: markdownDocument.parsed)
        documentView.needsDisplay = true
        refreshOutline()
        documentView.reveal(ordinal: min(anchor, max(0, layout.blockCount - 1)))
        rerunSearchIfActive()
    }

    private func appearanceChanged() {
        let theme = Theme(isDark: NSApp.effectiveAppearance.isDark)
        layout.setTheme(theme)
        scrollView.backgroundColor =
            NSColor(cgColor: theme.palette.background) ?? .textBackgroundColor
        documentView.needsDisplay = true
    }

    private func updateTitle() {
        window?.title = markdownDocument.fileURL?.path ?? "Markio 2"
        window?.representedURL = nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(documentView)
        restoreScrollPosition()
    }

    private func restoreScrollPosition() {
        guard !restoredScroll, let url = markdownDocument.fileURL else { return }
        restoredScroll = true
        guard let y = Preferences.scrollPosition(for: url), y > 0 else { return }
        // The document view has to know its height before a scroll can land.
        documentView.layoutSubtreeIfNeeded()
        documentView.scroll(NSPoint(x: 0, y: min(y, max(0, documentView.documentHeight - 10))))
    }

    @objc private func scrollDidChange() {
        guard let url = markdownDocument.fileURL, restoredScroll else { return }
        let y = scrollView.contentView.bounds.minY
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard self != nil else { return }
            Preferences.setScrollPosition(y, for: url)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Outline

    private func refreshOutline() {
        headings = markdownDocument.parsed.headings()
        outlineOrdinals = headings.compactMap { layout.ordinal(ofLeaf: $0.block) }
        outline.setHeadings(headings)
    }

    private func visibleRangeChanged(_ range: Range<Int>) {
        guard !outlineOrdinals.isEmpty else { return }
        // The heading that owns the top of the view is the current section.
        var current = -1
        for (index, ordinal) in outlineOrdinals.enumerated() {
            if ordinal <= range.lowerBound + 1 { current = index } else { break }
        }
        outline.setCurrent(current)
    }

    private func jumpToHeading(_ index: Int) {
        guard index >= 0, index < outlineOrdinals.count else { return }
        documentView.reveal(ordinal: outlineOrdinals[index])
    }

    @objc func toggleOutline(_ sender: Any?) {
        setSidebarVisible(!Preferences.outlineVisible, animated: true)
    }

    private func setSidebarVisible(_ visible: Bool, animated: Bool) {
        Preferences.outlineVisible = visible
        sidebarWidthConstraint.constant = visible ? 240 : 0
        outline.isHidden = !visible
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                window?.contentView?.layoutSubtreeIfNeeded()
            }
        }
    }

    // MARK: - Find

    @objc func showFind(_ sender: Any?) {
        findBar.isHidden = false
        findBar.focus()
    }

    private func closeFind() {
        findBar.isHidden = true
        findEngine.cancel()
        findMatches = []
        currentMatch = -1
        documentView.setFindMatches([], current: -1)
        window?.makeFirstResponder(documentView)
    }

    private func runSearch(_ query: String) {
        guard !query.isEmpty else {
            findMatches = []
            currentMatch = -1
            documentView.setFindMatches([], current: -1)
            findBar.setCounter(current: 0, total: 0)
            return
        }
        findEngine.search(query, in: markdownDocument.parsed) { [weak self] result in
            guard let self else { return }
            let firstArrival = self.findMatches.isEmpty && !result.matches.isEmpty
            self.findMatches = result.matches
            if firstArrival {
                self.currentMatch = 0
                self.documentView.reveal(ordinal: result.matches[0].ordinal)
            }
            self.documentView.setFindMatches(result.matches, current: self.currentMatch)
            self.findBar.setCounter(
                current: self.currentMatch + 1,
                total: result.matches.count
            )
        }
    }

    private func rerunSearchIfActive() {
        guard !findBar.isHidden, !findBar.query.isEmpty else { return }
        runSearch(findBar.query)
    }

    private func step(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        currentMatch = (currentMatch + delta + findMatches.count) % findMatches.count
        documentView.setFindMatches(findMatches, current: currentMatch)
        documentView.reveal(ordinal: findMatches[currentMatch].ordinal)
        findBar.setCounter(current: currentMatch + 1, total: findMatches.count)
    }

    @objc func findNext(_ sender: Any?) { step(by: 1) }
    @objc func findPrevious(_ sender: Any?) { step(by: -1) }

    // MARK: - Links and paths

    private func open(link: InlineLink) {
        guard
            let url = LinkResolver.resolve(
                destination: link.destination,
                relativeTo: markdownDocument.fileURL
            )
        else { return }
        switch url {
        case .external(let external):
            NSWorkspace.shared.open(external)
        case .anchor(let slug):
            guard let index = headings.firstIndex(where: { $0.slug == slug }) else { return }
            jumpToHeading(index)
        case .document(let file, let anchor):
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) {
                document, _, _ in
                guard let anchor,
                    let controller = document?.windowControllers.first
                        as? DocumentWindowController
                else { return }
                controller.jumpToAnchor(anchor)
            }
        }
    }

    func jumpToAnchor(_ slug: String) {
        guard let index = headings.firstIndex(where: { $0.slug == slug }) else { return }
        jumpToHeading(index)
    }

    @objc func copyFilePath(_ sender: Any?) {
        guard let path = markdownDocument.fileURL?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

extension DocumentWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        saveWorkItem?.cancel()
        if let url = markdownDocument.fileURL, restoredScroll {
            Preferences.setScrollPosition(scrollView.contentView.bounds.minY, for: url)
        }
        NotificationCenter.default.removeObserver(self)
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// The CoreText attribute key, spelled once here so the app layer does not have
/// to import CoreText just to measure a glyph.
enum AttributedBuilderKey {
    static let font = NSAttributedString.Key(kCTFontAttributeName as String)
}
