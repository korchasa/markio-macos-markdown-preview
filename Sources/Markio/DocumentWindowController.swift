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
    private let mapStrip: DocumentMapStrip
    private let findEngine = FindEngine()
    private let widthSlider = NSSlider()
    private let widthLabel = NSTextField(labelWithString: "")
    /// What the document says about itself — ticked boxes, reading time, open
    /// questions — counted in the background and shown at the left of the bar.
    private let summaryLabel = NSTextField(labelWithString: "")
    private let summaryEngine = DocumentSummary()

    private var findMatches: [DocumentView.FindMatch] = []
    private var currentMatch = -1
    private var headings: [Document.Heading] = []
    private var outlineOrdinals: [Int] = []
    private var restoredScroll = false
    /// What each block of the document is, for the map. Arrives in batches from
    /// the same background walk that counts the summary.
    private var mapClasses: [DocumentMap.Kind] = []
    private var rebinScheduled = false
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
    /// How much larger than the reading size this window draws.
    private var zoom: CGFloat
    /// The deck, while one is on screen.
    private var presentation: PresentationWindow?

    init(document: MarkdownDocument) {
        self.markdownDocument = document
        self.displayed = document.parsed
        // Each window carries its own zoom: two documents open side by side are
        // often read at different sizes, one being skimmed and one worked
        // through. A document opened again comes back at the size it was left,
        // and one never zoomed opens at whatever the system asks for.
        let zoom =
            document.fileURL.flatMap { Preferences.zoom(for: $0) } ?? SystemTextSize.zoom
        self.zoom = zoom
        let theme = DocumentWindowController.theme(zoom: zoom)
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
        self.mapStrip = DocumentMapStrip(theme: theme)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 480, height: 320)
        // One window per document is what this app is: find, the outline, the
        // reading width and the comparison all belong to a window. A system set
        // to "prefer tabs: always" merges new windows into the front one
        // regardless of `allowsAutomaticWindowTabbing`, so each window refuses
        // on its own account as well.
        window.tabbingMode = .disallowed
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
        // A separator box works out which way it runs from its own frame, and
        // until it has one it reports an intrinsic height of a single point and
        // holds it at 750 — far above the window's size preference at 250. The
        // pane divider is created with no frame at all and joins the layout on
        // the switch to two columns, so that one point is what the window's
        // height got fitted to: 200 of reading area over the 30-point bottom
        // bar. Both boxes are told outright not to ask for a height; their
        // width is given below.
        for box in [separator, paneDivider] {
            box.setContentHuggingPriority(.init(1), for: .vertical)
            box.setContentCompressionResistancePriority(.init(1), for: .vertical)
        }

        let bottomBar = buildBottomBar()

        for view in [
            outline, separator, baselineScroll, paneDivider, scrollView, mapStrip, findBar,
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

            mapStrip.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            mapStrip.topAnchor.constraint(equalTo: scrollView.topAnchor),
            mapStrip.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            mapStrip.widthAnchor.constraint(equalToConstant: DocumentMapStrip.width),

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
        // The text keeps its distance from the strip rather than running under
        // it — the overlay scroller already floats there, and a permanent strip
        // makes that permanent.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: 0, right: DocumentMapStrip.width)
        setMapVisible(Preferences.mapVisible)

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
        documentView.onSelectHeading = { [weak self] ordinal in self?.focus(on: ordinal) }

        findBar.onQueryChange = { [weak self] query in self?.runSearch(query) }
        findBar.onNext = { [weak self] in self?.step(by: 1) }
        findBar.onPrevious = { [weak self] in self?.step(by: -1) }
        findBar.onClose = { [weak self] in self?.closeFind() }
        mapStrip.onSelect = { [weak self] index in self?.jumpToMatch(index) }
        mapStrip.onGoTo = { [weak self] ordinal in self?.documentView.reveal(ordinal: ordinal) }
        mapStrip.onName = { [weak self] ordinal in self?.sectionName(at: ordinal) }

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

        summaryLabel.font = NSFont.systemFont(ofSize: 10)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail

        for view in [widthSlider, widthLabel, summaryLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            widthLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            widthSlider.trailingAnchor.constraint(equalTo: widthLabel.leadingAnchor, constant: -8),
            widthSlider.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            widthSlider.widthAnchor.constraint(equalToConstant: 120),
            summaryLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            summaryLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            summaryLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: widthSlider.leadingAnchor, constant: -12),
        ])
        return bar
    }

    // MARK: - Reading width

    /// The reader's chosen width, in points.
    private static func columnWidth(for theme: Theme) -> CGFloat {
        theme.columnWidth(characters: Preferences.readingWidth)
    }

    /// Draw at whatever `Preferences.readingWidth` now answers, slider and
    /// label included. The snapshot run pins that width; a reader changes it
    /// through the slider, which goes the other way round.
    func reapplyReadingWidth() {
        widthSlider.doubleValue = Double(Preferences.readingWidth)
        widthLabel.stringValue = "\(Preferences.readingWidth) ch"
        applyColumnWidth()
    }

    @objc private func widthChanged() {
        let value = Preferences.clampWidth(Int(widthSlider.doubleValue.rounded()))
        guard value != Preferences.readingWidth else { return }
        Preferences.readingWidth = value
        widthLabel.stringValue = "\(value) ch"
        applyColumnWidth()
    }

    private func applyColumnWidth() {
        let position = readingPosition()
        let preferred = DocumentWindowController.columnWidth(for: layout.theme)
        layout.setColumnWidth(fitted(preferred, in: scrollView))
        baselineLayout.setColumnWidth(fitted(preferred, in: baselineScroll))
        baselineView.needsDisplay = true
        documentView.needsDisplay = true
        restore(position)
        rerunSearchIfActive()
    }

    // MARK: - Holding the reader's place

    /// Where the reader is, in terms that survive re-measuring the page.
    ///
    /// A scroll offset does not: changing the width or the zoom re-measures
    /// every block, so the same number of points down is a different place in
    /// the text. What holds still is the block at the top of the window and how
    /// far into it the window has been scrolled.
    private struct ReadingPosition {
        var ordinal: Int
        /// How far down that block the top of the window sits, 0 to 1.
        var fraction: CGFloat
    }

    private func readingPosition() -> ReadingPosition {
        let y = max(0, scrollView.contentView.bounds.minY - documentView.verticalPadding)
        let ordinal = layout.index(atOffset: y)
        let height = layout.height(of: ordinal)
        guard height > 0 else { return ReadingPosition(ordinal: ordinal, fraction: 0) }
        let into = (y - layout.offset(of: ordinal)) / height
        return ReadingPosition(ordinal: ordinal, fraction: min(max(into, 0), 1))
    }

    private func restore(_ position: ReadingPosition) {
        guard position.ordinal >= 0, position.ordinal < layout.blockCount else { return }
        // Measured before it is asked about: after a re-measure the block's
        // height is an estimate until something types it, and an estimate is
        // exactly what the fraction must not be multiplied by.
        _ = layout.prepare(
            range: position.ordinal..<(position.ordinal + 1), anchor: position.ordinal)
        let top = layout.offset(of: position.ordinal) + documentView.verticalPadding
        let target = top + position.fraction * layout.height(of: position.ordinal)
        documentView.scroll(NSPoint(x: 0, y: max(0, target)))
        documentView.needsDisplay = true
    }

    /// A column never gets wider than the pane holding it. Half a window is
    /// narrower than the reading width most people choose, and a column that does
    /// not fit is a column with its right-hand words cut off.
    private func fitted(_ preferred: CGFloat, in pane: NSScrollView) -> CGFloat {
        let room = pane.contentView.bounds.width - 48
        guard room > 200 else { return preferred }
        return min(preferred, room)
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) {
        apply(zoom: Preferences.zoom(zoom, steppedBy: 1), remember: true)
    }

    @objc func zoomOut(_ sender: Any?) {
        apply(zoom: Preferences.zoom(zoom, steppedBy: -1), remember: true)
    }

    /// Back to the size the system asks for, and forget this window's own — so
    /// a reader who changes the system setting later gets it here too.
    @objc func actualSize(_ sender: Any?) {
        apply(zoom: SystemTextSize.zoom, remember: false)
    }

    private func apply(zoom newValue: CGFloat, remember: Bool) {
        // Recorded before the early return: Actual Size at the size the system
        // already asks for still has something to do, which is to forget the
        // size this window was told to keep.
        if let url = markdownDocument.fileURL {
            Preferences.setZoom(remember ? newValue : nil, for: url)
        }
        guard newValue != zoom else { return }
        zoom = newValue
        let position = readingPosition()
        let theme = DocumentWindowController.theme(zoom: zoom)
        layout.setTheme(theme)
        baselineLayout.setTheme(theme)
        mapStrip.setTheme(theme)
        // Type of a different size makes a document of a different height, so
        // every bin of the map is now about the wrong part of it.
        scheduleRebin()
        // The width follows the type: a column is so many characters wide, and
        // characters just changed size. `applyColumnWidth` holds the place too,
        // but from a page already re-measured — so the position taken above is
        // the one that means anything, and it is put back last.
        applyColumnWidth()
        restore(position)
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

    // MARK: - Folder access

    /// The folder this window's document sits in, which is the one it can be
    /// asked to grant.
    var documentFolder: URL? {
        markdownDocument.fileURL?.deletingLastPathComponent().standardizedFileURL
    }

    /// Ask for the folder a picture in this document lives in.
    ///
    /// The sandbox hands over the document and not the folder around it, and
    /// there is no entitlement that widens that — a panel is the only way in,
    /// which is why one appears the first time a document points at something
    /// beside it rather than on open. Refusing leaves the document exactly as
    /// it was drawn, and nothing asks again for that folder in this run.
    func askForFolder(_ folder: URL) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message =
            "Markio can open this document, but not the files beside it. "
            + "Choose its folder to show the pictures in it."
        panel.prompt = "Allow"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            guard FolderAccess.shared.remember(url) else { return }
            // Every open document is drawn again, not just this one: two
            // windows on files in the same folder both gained their pictures.
            for document in NSDocumentController.shared.documents {
                for controller in document.windowControllers {
                    (controller as? DocumentWindowController)?.documentDidReload()
                }
            }
        }
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

    private static func theme(zoom: CGFloat) -> Theme {
        Theme(
            isDark: NSApp.effectiveAppearance.isDark,
            metrics: Theme.Metrics().scaled(by: zoom))
    }

    private func appearanceChanged() {
        let theme = DocumentWindowController.theme(zoom: zoom)
        layout.setTheme(theme)
        baselineLayout.setTheme(theme)
        mapStrip.setTheme(theme)
        scrollView.backgroundColor =
            NSColor(cgColor: theme.palette.background) ?? .textBackgroundColor
        baselineScroll.backgroundColor = scrollView.backgroundColor
        baselineView.needsDisplay = true
        documentView.needsDisplay = true
    }

    private func updateTitle() {
        window?.title = markdownDocument.fileURL?.path ?? "Markio"
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

    /// Put the reader back where they left this document.
    ///
    /// Twice, and neither is redundant. `NSView.scroll(_:)` on a document view
    /// that has not drawn yet does nothing at all — the view learns its real
    /// height only when it is asked to draw the blocks it lands on — so the
    /// scroll goes through the clip view, which does not need it. And the
    /// height it lands on is an estimate until those blocks have been measured,
    /// so a second scroll on the next turn corrects for what the first one
    /// learned.
    private func restoreScrollPosition() {
        guard !restoredScroll, let url = markdownDocument.fileURL else { return }
        guard let y = Preferences.scrollPosition(for: url), y > 0 else {
            restoredScroll = true
            return
        }
        documentView.layoutSubtreeIfNeeded()
        scrollDocument(to: y)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollDocument(to: y)
            // Saving stays off until the position is actually back, or the
            // bounds change that arrives while the document still sits at its
            // first line writes a zero over the very position being restored —
            // which is how one failed restore erased the memory for good.
            self.restoredScroll = true
        }
    }

    private func scrollDocument(to y: CGFloat) {
        let limit = max(0, documentView.documentHeight - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(y, limit)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func scrollDidChange() {
        syncScroll(from: scrollView, to: baselineScroll)
        // The marker moves with the scroll, now, rather than a turn of the run
        // loop later; the window of lines behind it can wait for the turn.
        updateReadingMarker()
        scheduleRebin()
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
        recount()
    }

    // MARK: - Summary

    /// Count the document again, in the background.
    ///
    /// Nothing waits for this: the window is already on screen and the figures
    /// arrive as they are counted. A document with no checkboxes and no markers
    /// says only how long it takes to read, and one still being counted says so
    /// with an ellipsis rather than showing a number that is about to change.
    private func recount() {
        summaryLabel.stringValue = ""
        // A different document has a different shape, and the old rows would
        // otherwise sit on the strip until the new classes arrived.
        mapClasses = []
        summaryEngine.count(displayed) { [weak self] result in
            guard let self else { return }
            self.summaryLabel.stringValue = DocumentWindowController.summary(result.counts)
            self.outline.setProgress(result.sections)
            self.mapClasses = result.classes
            self.scheduleRebin()
        }
    }

    static func summary(_ counts: DocumentSummary.Counts) -> String {
        var parts: [String] = []
        if counts.tasks > 0 { parts.append("\(counts.tasksDone) of \(counts.tasks) done") }
        if let minutes = counts.readingMinutes {
            parts.append("\(minutes) min at \(DocumentSummary.readingRate) wpm")
        }
        if counts.openQuestions > 0 { parts.append("\(counts.openQuestions) open") }
        guard !parts.isEmpty else { return "" }
        // While the walk is still going the numbers are a lower bound, and the
        // ellipsis is what says so.
        return parts.joined(separator: " · ") + (counts.isComplete ? "" : " …")
    }

    private func visibleRangeChanged(_ range: Range<Int>) {
        // Every block laid out replaces an estimate, so this is where the map
        // learns the document got taller.
        scheduleRebin()
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

    // MARK: - The document map

    @objc func toggleDocumentMap(_ sender: Any?) {
        setMapVisible(!Preferences.mapVisible)
    }

    private func setMapVisible(_ visible: Bool) {
        Preferences.mapVisible = visible
        scrollView.contentInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: 0, right: visible ? DocumentMapStrip.width : 0)
        refreshMapVisibility()
        if visible { scheduleRebin() }
    }

    /// A document shorter than the window has no shape worth drawing, so the
    /// strip stays away rather than decorating the edge.
    ///
    /// Find is the exception in both directions: while there are matches the
    /// strip is there to show where they are, even on a short document and even
    /// with the map turned off, which is what it did before the map existed.
    private func refreshMapVisibility() {
        let tall = documentView.documentHeight > scrollView.contentView.bounds.height + 8
        mapStrip.isHidden = !((Preferences.mapVisible && tall) || !findMatches.isEmpty)
    }

    /// Redraw the map at most once a turn of the run loop.
    ///
    /// Without that, every block that scrolls into view and replaces its
    /// estimated height would rebuild the map.
    private func scheduleRebin() {
        guard !rebinScheduled else { return }
        rebinScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebinScheduled = false
            self.remapDocument()
        }
    }

    /// Build the window of lines the map is showing.
    ///
    /// A document taller than the strip cannot be drawn line by line all at
    /// once, so the map shows a window onto it and slides the window with the
    /// reader, the way an editor's minimap does with a long file. Only those
    /// lines are read, which is what keeps this affordable at 32 MB.
    private func remapDocument() {
        refreshMapVisibility()
        updateReadingMarker()
        updateComparisonMarks()
        updateFindOverview(force: false)
        guard !mapStrip.isHidden, !mapClasses.isEmpty else { return }
        let capacity = mapStrip.rowCapacity
        let columns = mapStrip.columnCount
        let start = mapWindowStart(capacity: capacity)
        guard mapStrip.needsRows(from: start, capacity: capacity, columns: columns) else { return }
        mapStrip.setRows(
            DocumentMap.rows(
                document: displayed, classes: mapClasses, fromLine: start,
                maxRows: capacity, columns: columns),
            startLine: start, capacity: capacity, columns: columns)
    }

    /// The first line of the window the map shows.
    ///
    /// Centred on what the reader is reading, and clamped at both ends so the
    /// first page of the document sits at the top of the map and the last at the
    /// bottom. Anchoring it on the same lines the reading rectangle uses is what
    /// keeps the rectangle inside its own window: the two would otherwise be
    /// computed from different things — heights and lines — and heights below
    /// the viewport are still estimates.
    private func mapWindowStart(capacity: Int) -> Int {
        let total = displayed.lines.count
        guard total > capacity else { return 0 }
        let lines = visibleLines()
        let span = lines.upperBound - lines.lowerBound + 1
        let start = lines.lowerBound - max(0, capacity - span) / 2
        return min(max(0, start), total - capacity)
    }

    /// The lines of the source the viewport is showing.
    private func visibleLines() -> ClosedRange<Int> {
        let visible = scrollView.contentView.bounds
        let first = layout.index(atOffset: visible.minY)
        let last = layout.index(atOffset: max(visible.minY, visible.maxY))
        let top = DocumentMap.firstLine(displayed, ordinal: first)
        let bottom = DocumentMap.firstLine(displayed, ordinal: last)
        return top...max(top, bottom)
    }

    private func updateReadingMarker() {
        guard !mapStrip.isHidden else { return }
        mapStrip.setReading(visibleLines())
    }

    /// While comparing, the blocks the two versions differ over.
    private func updateComparisonMarks() {
        guard layout.comparison != nil, !mapStrip.isHidden else {
            mapStrip.setChanges([])
            return
        }
        var changes: [(line: Int, isAdded: Bool)] = []
        var lastLine = -1
        for ordinal in 0..<layout.blockCount {
            guard let mark = layout.mark(at: ordinal) else { continue }
            let line = DocumentMap.firstLine(displayed, ordinal: ordinal)
            // One mark per line: a changed section is thousands of blocks and
            // a handful of stripes.
            guard line > lastLine else { continue }
            lastLine = line
            changes.append((line, mark == .added))
        }
        mapStrip.setChanges(changes)
    }

    /// The heading that owns a block.
    private func sectionName(at ordinal: Int) -> String? {
        guard !headings.isEmpty else { return nil }
        var current: Int?
        for (index, heading) in outlineOrdinals.enumerated() {
            if heading <= ordinal { current = index } else { break }
        }
        guard let current, current < headings.count else { return nil }
        return headings[current].text
    }

    private func jumpToHeading(_ index: Int) {
        guard index >= 0, index < outlineOrdinals.count else { return }
        // A folded document moves section by section: picking a heading in the
        // outline opens that one, rather than scrolling to a heading with
        // nothing under it.
        if layout.focusedHeading != nil {
            focus(on: outlineOrdinals[index])
            return
        }
        documentView.reveal(ordinal: outlineOrdinals[index])
    }

    // MARK: - Focus

    /// Fold the document down to the section the reader is in, or unfold it.
    ///
    /// The section comes from the top of the window rather than from the
    /// outline's idea of the current one: the reader means the passage in front
    /// of them, and those two disagree while a long section scrolls past.
    @objc func toggleFocus(_ sender: Any?) {
        guard layout.blockCount > 0 else { return }
        guard layout.focusedHeading == nil else {
            focus(on: nil)
            return
        }
        let top = max(0, scrollView.contentView.bounds.minY - documentView.verticalPadding)
        focus(on: layout.index(atOffset: top))
    }

    var isFocused: Bool { layout.focusedHeading != nil }

    private func focus(on ordinal: Int?) {
        layout.setFocus(ordinal)
        documentView.needsDisplay = true
        if let heading = layout.focusedHeading {
            documentView.reveal(ordinal: heading)
        }
        rerunSearchIfActive()
    }

    @objc func toggleOutline(_ sender: Any?) {
        setSidebarVisible(!Preferences.outlineVisible, animated: true)
    }

    /// Put the sidebar in a known state rather than flipping whatever it was
    /// in. A shot plan says whether the outline is open, and a toggle would
    /// make each picture depend on the one before it.
    func setOutline(visible: Bool) {
        setSidebarVisible(visible, animated: false)
    }

    /// Back to the first line, for the same reason.
    func scrollToTop() {
        documentView.layoutSubtreeIfNeeded()
        documentView.scroll(.zero)
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
        mapStrip.setMarks(lines: [], current: -1)
        scheduleRebin()
        window?.makeFirstResponder(documentView)
    }

    private func runSearch(_ query: String) {
        guard !query.isEmpty else {
            findMatches = []
            currentMatch = -1
            documentView.setFindMatches([], current: -1)
            mapStrip.setMarks(lines: [], current: -1)
            scheduleRebin()
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

    /// Which lines the matches are on, so they land on the map's own axis and
    /// slide with the window it is showing.
    private func updateFindOverview(force: Bool = true) {
        guard !findMatches.isEmpty else {
            mapStrip.setMarks(lines: [], current: -1)
            if force { scheduleRebin() }
            return
        }
        mapStrip.setMarks(
            lines: findMatches.map { DocumentMap.firstLine(displayed, ordinal: $0.ordinal) },
            current: currentMatch)
        if force { scheduleRebin() }
    }

    private func jumpToMatch(_ index: Int) {
        guard index >= 0, index < findMatches.count else { return }
        currentMatch = index
        documentView.setFindMatches(findMatches, current: currentMatch)
        documentView.reveal(ordinal: findMatches[currentMatch].ordinal)
        findBar.setCounter(current: currentMatch + 1, total: findMatches.count)
        updateFindOverview(force: false)
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
        case .file(let file, let line):
            CodeEditor.open(file, line: line)
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

    // MARK: - Presentation

    /// The deck this document makes, if it makes one.
    private var slideCount: Int { Slides.split(displayed).count }

    /// Show the document full screen, one slide at a time.
    @objc func present(_ sender: Any?) {
        present(slide: 0)
    }

    func present(slide: Int) {
        presentation?.leave()
        presentation = PresentationWindow.present(
            document: displayed, baseURL: markdownDocument.fileURL, over: window,
            startingAt: slide)
    }

    // MARK: - PDF

    /// Write the document out as a PDF.
    ///
    /// The save panel is also the sandbox grant for writing, which is why this
    /// is a command a reader gives rather than something the app does on its
    /// own. What is exported is what is on screen — a comparison exports with
    /// its marks — because that is the document the reader is looking at.
    @objc func exportPDF(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        let name = markdownDocument.fileURL?.deletingPathExtension().lastPathComponent ?? "Markio"
        panel.nameFieldStringValue = "\(name).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try PDFExport.write(
                    document: self.displayed,
                    baseURL: self.markdownDocument.fileURL,
                    to: url,
                    title: name
                )
            } catch {
                // Loudly: a silent failure here looks exactly like a PDF that
                // was written and then vanished.
                let alert = NSAlert()
                alert.messageText = "Markio could not write that PDF."
                alert.informativeText = "\(error)"
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
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
        if item.action == #selector(present(_:)) {
            // A document with no thematic breaks and no headings is not a deck,
            // and offering to present it would promise something this cannot
            // do: guess where the author wanted the screens to end.
            return slideCount > 0
        }
        if item.action == #selector(toggleFocus(_:)) {
            item.state = isFocused ? .on : .off
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
