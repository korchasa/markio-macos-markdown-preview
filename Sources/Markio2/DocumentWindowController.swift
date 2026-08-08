import AppKit
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
    private let findOverview = FindOverview()
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
            columnWidth: DocumentWindowController.columnWidth(for: theme),
            baseURL: document.fileURL
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
        // The reading column is a fixed number of characters wide, so the view
        // has to span the whole scroll area — otherwise there is nothing for
        // `DocumentView.contentX` to centre the column inside and the text sits
        // against the left edge.
        documentView.autoresizingMask = [.width]
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true

        let separator = NSBox()
        separator.boxType = .separator

        let bottomBar = buildBottomBar()

        for view in [outline, separator, scrollView, findOverview, findBar, bottomBar]
            as [NSView]
        {
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

            findOverview.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            findOverview.topAnchor.constraint(equalTo: scrollView.topAnchor),
            findOverview.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            findOverview.widthAnchor.constraint(equalToConstant: 12),

            findBar.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -18),
            findBar.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 14),

            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 30),
        ])

        // AppKit sizes a constraint-driven window to the fitting size of its
        // content. Nothing above gives the reading area a height of its own —
        // every edge is pinned to a neighbour — so without these the window
        // opens as a bare title bar over the bottom strip. The floor keeps it
        // from collapsing on resize; the preference is what the first window
        // opens at, and it yields to the saved frame on every later launch.
        let preferredWidth = scrollView.widthAnchor.constraint(equalToConstant: 900)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = scrollView.heightAnchor.constraint(equalToConstant: 810)
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            preferredWidth,
            preferredHeight,
        ])

        setSidebarVisible(Preferences.outlineVisible, animated: false)
        findBar.isHidden = true
        findOverview.isHidden = true

        documentView.onActivateLink = { [weak self] link in self?.open(link: link) }
        documentView.onVisibleRangeChange = { [weak self] range in
            self?.visibleRangeChanged(range)
        }
        documentView.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        documentView.acceptsFile = LinkResolver.isMarkdown
        documentView.onOpenFiles = { urls in
            for url in urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
                    _, _, _ in
                }
            }
        }

        outline.onSelect = { [weak self] index in self?.jumpToHeading(index) }

        findBar.onQueryChange = { [weak self] query in self?.runSearch(query) }
        findBar.onNext = { [weak self] in self?.step(by: 1) }
        findBar.onPrevious = { [weak self] in self?.step(by: -1) }
        findBar.onClose = { [weak self] in self?.closeFind() }
        findOverview.onSelect = { [weak self] index in self?.jumpToMatch(index) }

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

    /// The reader's chosen width, in points.
    private static func columnWidth(for theme: Theme) -> CGFloat {
        theme.columnWidth(characters: Preferences.readingWidth)
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
        // The heading that owns the top of the view is the current section:
        // the last one at or above it. Binary search, because this runs on
        // every scroll notification and a large document has six figures of
        // headings.
        let top = range.lowerBound + 1
        var low = 0
        var high = outlineOrdinals.count - 1
        var current = -1
        while low <= high {
            let middle = (low + high) / 2
            if outlineOrdinals[middle] <= top {
                current = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
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
        findOverview.setMarks([], current: -1)
        window?.makeFirstResponder(documentView)
    }

    private func runSearch(_ query: String) {
        guard !query.isEmpty else {
            findMatches = []
            currentMatch = -1
            documentView.setFindMatches([], current: -1)
            findOverview.setMarks([], current: -1)
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
            self.updateFindOverview()
            self.findBar.setCounter(
                current: self.currentMatch + 1,
                total: result.matches.count
            )
        }
    }

    /// Where each match sits in the document, as a fraction of its height.
    ///
    /// Heights above the viewport are still estimates, so these positions are
    /// approximate until those blocks have been seen — good enough for a strip
    /// whose job is to show clustering, and it is recomputed on every step.
    private func updateFindOverview() {
        guard !findMatches.isEmpty else {
            findOverview.setMarks([], current: -1)
            return
        }
        let total = max(1, layout.totalHeight)
        let marks = findMatches.map { layout.offset(of: $0.ordinal) / total }
        findOverview.setMarks(marks, current: currentMatch)
    }

    private func jumpToMatch(_ index: Int) {
        guard index >= 0, index < findMatches.count else { return }
        currentMatch = index
        documentView.setFindMatches(findMatches, current: currentMatch)
        documentView.reveal(ordinal: findMatches[currentMatch].ordinal)
        findBar.setCounter(current: currentMatch + 1, total: findMatches.count)
        findOverview.setMarks(
            findMatches.map { layout.offset(of: $0.ordinal) / max(1, layout.totalHeight) },
            current: currentMatch
        )
    }

    private func rerunSearchIfActive() {
        guard !findBar.isHidden, !findBar.query.isEmpty else { return }
        runSearch(findBar.query)
    }

    private func step(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        jumpToMatch((currentMatch + delta + findMatches.count) % findMatches.count)
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
