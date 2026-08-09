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
    /// The left column while reading two versions side by side. It shows the
    /// baseline and nothing else: find, the outline and every command still work
    /// on the document the window belongs to.
    private let baselineScroll = NSScrollView()
    private var baselineLayout: DocumentLayout
    private let baselineView: DocumentView
    private let paneDivider = NSBox()
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
    /// The document on screen: the file itself, or the merge of it with a
    /// baseline while comparing. The outline and find work over this one, so
    /// both cover the removed text as well.
    private var displayed: MarkdownKit.Document
    /// The baseline being compared against, kept only for the session.
    private var baselineURL: URL?

    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var onePaneConstraint: NSLayoutConstraint!
    private var twoPaneConstraints: [NSLayoutConstraint] = []
    /// Whether the baseline gets a column of its own. Only meaningful while
    /// comparing, and remembered for the session rather than saved.
    private var sideBySide = false
    /// Guards the two scroll views against answering each other for ever.
    private var syncingScroll = false

    init(document: MarkdownDocument) {
        self.markdownDocument = document
        self.displayed = document.parsed
        let theme = Theme(isDark: NSApp.effectiveAppearance.isDark)
        self.layout = DocumentLayout(
            document: document.parsed,
            theme: theme,
            columnWidth: DocumentWindowController.columnWidth(for: theme),
            baseURL: document.fileURL
        )
        self.documentView = DocumentView(layout: layout)
        self.baselineLayout = DocumentLayout(
            document: MarkdownKit.Document(text: ""),
            theme: theme,
            columnWidth: DocumentWindowController.columnWidth(for: theme),
            baseURL: document.fileURL
        )
        self.baselineView = DocumentView(layout: baselineLayout)

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

        baselineScroll.hasVerticalScroller = true
        baselineScroll.hasHorizontalScroller = false
        baselineScroll.autohidesScrollers = true
        baselineScroll.drawsBackground = true
        baselineScroll.backgroundColor = scrollView.backgroundColor
        baselineView.autoresizingMask = [.width]
        baselineScroll.documentView = baselineView
        baselineScroll.contentView.postsBoundsChangedNotifications = true
        baselineScroll.isHidden = true
        paneDivider.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator
        paneDivider.boxType = .separator

        let bottomBar = buildBottomBar()

        for view in [
            outline, separator, baselineScroll, paneDivider, scrollView, findOverview, findBar,
            bottomBar,
        ] as [NSView] {
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

        // One reading column or two, switched by swapping which constraint holds
        // the main pane's leading edge. Both sets are built once; toggling is
        // then two calls and no view surgery.
        onePaneConstraint = scrollView.leadingAnchor.constraint(equalTo: separator.trailingAnchor)
        twoPaneConstraints = [
            baselineScroll.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            baselineScroll.topAnchor.constraint(equalTo: container.topAnchor),
            baselineScroll.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            baselineScroll.trailingAnchor.constraint(equalTo: paneDivider.leadingAnchor),
            paneDivider.topAnchor.constraint(equalTo: container.topAnchor),
            paneDivider.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            paneDivider.widthAnchor.constraint(equalToConstant: 1),
            paneDivider.trailingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            baselineScroll.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ]
        onePaneConstraint.isActive = true

        // AppKit sizes a constraint-driven window to the fitting size of its
        // content. Nothing above gives the reading area a height of its own —
        // every edge is pinned to a neighbour — so without these the window
        // opens as a bare title bar over the bottom strip. The floor keeps it
        // from collapsing on resize; the preference is what the first window
        // opens at, and it yields to the saved frame on every later launch.
        //
        // Their priority has to stay under 510: a drag on a window edge reaches
        // the layout as a constraint at `dragThatCanResizeWindow`, and anything
        // in the content that outranks it wins, which leaves a window nobody can
        // resize. `.defaultHigh` is 750 and did exactly that.
        let preferredWidth = scrollView.widthAnchor.constraint(equalToConstant: 900)
        preferredWidth.priority = .defaultLow
        let preferredHeight = scrollView.heightAnchor.constraint(equalToConstant: 810)
        preferredHeight.priority = .defaultLow
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(baselineScrollDidChange),
            name: NSView.boundsDidChangeNotification,
            object: baselineScroll.contentView
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
        let preferred = DocumentWindowController.columnWidth(for: layout.theme)
        layout.setColumnWidth(fitted(preferred, in: scrollView))
        baselineLayout.setColumnWidth(fitted(preferred, in: baselineScroll))
        baselineView.needsDisplay = true
        documentView.needsDisplay = true
        // A width change re-measures everything, so the old scroll offset means
        // nothing; the block that was at the top is what the reader tracks.
        documentView.reveal(ordinal: anchorOrdinal)
        rerunSearchIfActive()
    }

    /// A column never gets wider than the pane holding it. Half a window is
    /// narrower than the reading width most people choose, and a column that does
    /// not fit is a column with its right-hand words cut off.
    private func fitted(_ preferred: CGFloat, in pane: NSScrollView) -> CGFloat {
        let room = pane.contentView.bounds.width - 48
        guard room > 200 else { return preferred }
        return min(preferred, room)
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
        // A comparison survives the edit it exists to show: the baseline is read
        // again and merged again, rather than dropping back to the plain file.
        if baselineURL != nil { rebuildComparison() } else { showPlainDocument() }
    }

    // MARK: - Compare

    /// Compare the open file against an older version of it.
    ///
    /// The panel is the sandbox grant: choosing the baseline is what gives this
    /// app permission to read it. The baseline is read, never opened: it becomes
    /// marked-up source in this window, or the second column of it, but never a
    /// document with a life of its own.
    @objc func compareWithBaseline(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the version to compare against."
        panel.prompt = "Compare"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = markdownDocument.fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // A file against itself has nothing to show, so picking it changes
            // nothing rather than entering a comparison with no marks in it.
            guard url != self.markdownDocument.fileURL else { return }
            self.baselineURL = url
            self.rebuildComparison()
        }
    }

    /// Start a comparison against a known file, skipping the panel.
    ///
    /// The panel is how a reader grants access to the baseline, so this is only
    /// for a run that already has it: the capture flags.
    func compare(with url: URL, sideBySide: Bool) {
        baselineURL = url
        self.sideBySide = sideBySide
        rebuildComparison()
    }

    @objc func stopComparing(_ sender: Any?) {
        guard baselineURL != nil else { return }
        baselineURL = nil
        showPlainDocument()
    }

    var isComparing: Bool { baselineURL != nil }

    var isSideBySide: Bool { sideBySide }

    /// Give the baseline a column of its own, or take it back.
    @objc func toggleSideBySide(_ sender: Any?) {
        sideBySide.toggle()
        if isComparing { rebuildComparison() } else { applyPaneMode() }
    }

    /// Show or hide the second column and re-fit both to the room they have.
    private func applyPaneMode() {
        let two = sideBySide && isComparing
        guard two != !baselineScroll.isHidden else { return }
        baselineScroll.isHidden = !two
        paneDivider.isHidden = !two
        if two {
            onePaneConstraint.isActive = false
            NSLayoutConstraint.activate(twoPaneConstraints)
        } else {
            NSLayoutConstraint.deactivate(twoPaneConstraints)
            onePaneConstraint.isActive = true
        }
        // The panes have to take their new size before a column can be fitted
        // into one: the bounds are still yesterday's until the pass runs.
        window?.contentView?.layoutSubtreeIfNeeded()
        applyColumnWidth()
    }

    /// Keep the two columns level.
    ///
    /// The offset is copied rather than scaled: the versions share most of their
    /// text, so the same distance down the page is the same passage until a
    /// change pushes them apart — which is exactly where the reader is looking.
    private func syncScroll(from source: NSScrollView, to target: NSScrollView) {
        guard sideBySide, isComparing, !target.isHidden, !syncingScroll else { return }
        syncingScroll = true
        defer { syncingScroll = false }
        let travel = max(
            0, (target.documentView?.frame.height ?? 0) - target.contentView.bounds.height)
        let y = min(max(0, source.contentView.bounds.minY), travel)
        guard abs(target.contentView.bounds.minY - y) > 0.5 else { return }
        target.contentView.setBoundsOrigin(
            CGPoint(x: target.contentView.bounds.minX, y: y))
        target.reflectScrolledClipView(target.contentView)
    }

    @objc private func baselineScrollDidChange() {
        syncScroll(from: baselineScroll, to: scrollView)
    }

    /// Read the baseline, merge, show the result.
    ///
    /// An unreadable baseline ends the comparison instead of leaving a stale one
    /// on screen: the version it named is gone, and a diff nobody can reproduce
    /// is worse than no diff.
    private func rebuildComparison() {
        guard let url = baselineURL, let baseline = try? Data(contentsOf: url) else {
            baselineURL = nil
            showPlainDocument()
            return
        }
        applyPaneMode()
        guard sideBySide else {
            let result = CompareEngine.merge(
                current: markdownDocument.sourceBytes,
                baseline: [UInt8](baseline)
            )
            show(document: MarkdownKit.Document(bytes: result.bytes), comparison: result)
            return
        }
        let sides = CompareEngine.split(
            current: markdownDocument.sourceBytes,
            baseline: [UInt8](baseline)
        )
        baselineLayout.comparison = sides.baseline
        baselineLayout.replace(document: MarkdownKit.Document(bytes: sides.baseline.bytes))
        baselineView.needsDisplay = true
        show(document: MarkdownKit.Document(bytes: sides.current.bytes), comparison: sides.current)
    }

    private func showPlainDocument() {
        applyPaneMode()
        show(document: markdownDocument.parsed, comparison: nil)
    }

    /// Swap what the window shows, keeping the reader roughly where they were.
    private func show(document: MarkdownKit.Document, comparison: CompareEngine.Result?) {
        let anchor = layout.index(atOffset: scrollView.contentView.bounds.minY)
        displayed = document
        layout.comparison = comparison
        layout.replace(document: document)
        documentView.needsDisplay = true
        refreshOutline()
        documentView.reveal(ordinal: min(anchor, max(0, layout.blockCount - 1)))
        rerunSearchIfActive()
        updateTitle()
    }

    private func appearanceChanged() {
        let theme = Theme(isDark: NSApp.effectiveAppearance.isDark)
        layout.setTheme(theme)
        baselineLayout.setTheme(theme)
        scrollView.backgroundColor =
            NSColor(cgColor: theme.palette.background) ?? .textBackgroundColor
        baselineScroll.backgroundColor = scrollView.backgroundColor
        baselineView.needsDisplay = true
        documentView.needsDisplay = true
    }

    private func updateTitle() {
        window?.title = markdownDocument.fileURL?.path ?? "Markio 2"
        window?.representedURL = nil
        // The subtitle is the only sign that the marks on screen are a diff and
        // not part of the file, and it says when the diff found nothing.
        guard let baselineURL else {
            window?.subtitle = ""
            return
        }
        let changed = layout.comparison?.hasChanges ?? false
        window?.subtitle =
            changed
            ? "comparing with \(baselineURL.lastPathComponent)"
            : "comparing with \(baselineURL.lastPathComponent) — no differences"
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
        syncScroll(from: scrollView, to: baselineScroll)
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
        headings = displayed.headings()
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
        findEngine.search(query, in: displayed) { [weak self] result in
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
            jumpToAnchor(slug)
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

    /// Scroll to whatever the anchor names: a heading, or the text of a
    /// footnote. Footnote anchors carry a prefix of their own, so the two kinds
    /// can never be confused for one another.
    func jumpToAnchor(_ slug: String) {
        if let index = headings.firstIndex(where: { $0.slug == slug }) {
            jumpToHeading(index)
            return
        }
        for (label, block) in displayed.footnotes where Footnote.anchor(label: label) == slug {
            guard let ordinal = layout.ordinal(ofLeaf: block) else { return }
            documentView.reveal(ordinal: ordinal)
            return
        }
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

extension DocumentWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Only items routed to this window controller arrive here, so the
        // default is yes and the one exception is the command that needs a
        // comparison to stop.
        if item.action == #selector(stopComparing(_:)) { return isComparing }
        if item.action == #selector(toggleSideBySide(_:)) {
            item.state = sideBySide ? .on : .off
            return true
        }
        return true
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
