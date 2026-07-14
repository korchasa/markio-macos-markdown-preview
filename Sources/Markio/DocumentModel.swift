import AppKit
import SwiftUI

/// Per-window document state: owns this window's preview controller, file
/// watcher, and reading width. One instance per `DocumentGroup` window — there
/// is no shared app-wide model. Renders the document's text and re-renders on
/// appearance changes and live reloads. [REF:sds:document-model]
@MainActor
final class DocumentModel: ObservableObject {
    let preview = PreviewController()
    private let widthStore: ContentWidthStore
    private let tocStore: TOCStore
    private let scrollStore: ScrollPositionStore
    private let linkNavigator: LocalLinkNavigator
    private let compareCoordinator: CompareCoordinator
    private var watcher: FileWatcher?
    private var started = false
    private var currentText = ""
    private var url: URL?

    @Published var contentWidth: Double

    // Find state, mirrored to the find bar. [REF:fr:find]
    @Published var findPresented = false
    @Published var findQuery = ""
    @Published var findResult = FindResult.empty

    // TOC state, mirrored to the sidebar. [REF:fr:toc]
    @Published var tocVisible: Bool
    @Published var outline: [TOCItem] = []
    @Published var currentHeadingID: String?

    // Compare state, mirrored to the Window menu. [REF:fr:compare]
    @Published private(set) var isCompared = false

    init(
        defaults: UserDefaults = .standard,
        linkNavigator: LocalLinkNavigator = .shared,
        compareCoordinator: CompareCoordinator = .shared
    ) {
        widthStore = ContentWidthStore(defaults: defaults)
        tocStore = TOCStore(defaults: defaults)
        scrollStore = ScrollPositionStore(defaults: defaults)
        self.linkNavigator = linkNavigator
        self.compareCoordinator = compareCoordinator
        contentWidth = Double(widthStore.width)
        tocVisible = tocStore.visible
        preview.onCurrentSectionChange = { [weak self] id in
            self?.currentHeadingID = id
        }
        // Persist the reading place continuously (the page debounces), so the
        // position survives window close, quit, and even a force quit.
        // [REF:fr:session-restore]
        preview.onScrollPositionChange = { [weak self] y in
            guard let self, let url = self.url else { return }
            self.scrollStore.setPosition(y, for: url)
        }
        // A clicked relative Markdown link: resolve + open natively (new
        // window per document, powerbox grant when the sandbox denies).
        // [REF:fr:local-links]
        preview.onLinkActivated = { [weak self] href in
            guard let self, let url = self.url else { return }
            self.linkNavigator.follow(href: href, from: url)
        }
        // Live scroll fraction while this window is half of a compare pair:
        // the coordinator mirrors it to the peer. [REF:fr:compare]
        preview.onSyncScroll = { [weak self] fraction in
            guard let self else { return }
            self.compareCoordinator.scrollChanged(from: self, fraction: fraction)
        }
    }

    /// One-time page setup + initial render; safe to call from `.task` on every
    /// view appearance. Arms the watcher when the document has a file URL.
    /// [REF:fr:multidoc] [REF:fr:live-reload]
    func start(text: String, url: URL?) async {
        guard !started else { return }
        started = true
        self.url = url
        currentText = text
        do {
            try await preview.loadTemplate()
        } catch {
            // Without the shell loaded, rendering is impossible — log and stop
            // rather than silently driving a blank page. [REF:fr:offline]
            Log.app.error("template load failed: \(error.localizedDescription)")
            return
        }
        await preview.setContentWidth(Int(contentWidth))
        await preview.setDark(Self.systemIsDark)
        await preview.render(text)
        await refreshOutline()
        // Reopening a known document restores the reader's last position —
        // once per window (this method is `started`-guarded), covering
        // relaunch, Open Recent, and plain reopen alike. A position beyond a
        // now-shorter document is clamped by the browser.
        // [REF:fr:session-restore]
        if let url, let savedY = scrollStore.position(for: url) {
            await preview.setScrollY(savedY)
        }
        // A link-driven open lands on its section: the pending anchor wins
        // over the saved reading position — the user explicitly asked for it.
        // [REF:fr:local-links]
        if let url {
            linkNavigator.attach(self)
            if let anchor = linkNavigator.consumePendingAnchor(for: url) {
                await preview.scrollToHeading(anchor)
            }
            // Attach AFTER the first render so a pending compare pair links
            // against a page that is already scrollable. [REF:fr:compare]
            compareCoordinator.attach(self)
        }
        if let url { startWatching(url) }
    }

    /// Set the reading width in characters; clamps + snaps to a preset step.
    func setWidth(_ chars: Double) {
        let clamped = Double(ContentWidthStore.clamp(Int(chars)))
        contentWidth = clamped
        widthStore.width = Int(clamped)
        Task { await preview.setContentWidth(Int(clamped)) }
    }

    /// Re-render so Mermaid picks up the new theme on a live appearance switch.
    /// [REF:fr:appearance]
    func appearanceChanged(dark: Bool) async {
        await preview.setDark(dark)
        await preview.render(currentText)
        await reapplyFindIfActive()
        await refreshOutline()
    }

    // MARK: - TOC [REF:fr:toc]

    /// Show/hide the sidebar; the choice is a global reading preference
    /// persisted across launches.
    func toggleTOC() {
        tocVisible.toggle()
        tocStore.visible = tocVisible
    }

    /// Jump the preview to a heading. The highlight updates optimistically; the
    /// page's scroll-spy confirms with the same id through the message handler.
    func jumpToHeading(_ id: String) {
        currentHeadingID = id
        Task { await preview.scrollToHeading(id) }
    }

    /// Re-pull the heading tree after a render — heading DOM nodes are
    /// re-created on every render, so the outline is refreshed alongside the
    /// find re-apply on live reload / appearance switches. [REF:fr:live-reload]
    private func refreshOutline() async {
        outline = await preview.outline()
        currentHeadingID = await preview.currentSection()
    }

    // MARK: - Compare [REF:fr:compare]

    /// Start a side-by-side compare from this window (Window menu): pick the
    /// second document, pair, tile, mirror.
    func startCompare() {
        compareCoordinator.beginCompare(from: self)
    }

    /// Break this window's compare pair; both windows stay open, unlinked.
    func stopCompare() {
        compareCoordinator.unlink(for: self)
    }

    // MARK: - Find [REF:fr:find]

    /// Open the find bar (the view focuses the field on this transition).
    func openFind() { findPresented = true }

    /// Close the find bar and drop all highlights.
    func closeFind() {
        findPresented = false
        findQuery = ""
        findResult = .empty
        Task { await preview.clearSearch() }
    }

    /// Run the current query live (called on every keystroke). An empty query
    /// clears highlights rather than matching everything.
    func runSearch() {
        Task {
            if findQuery.isEmpty {
                await preview.clearSearch()
                findResult = .empty
            } else {
                findResult = await preview.search(findQuery)
            }
        }
    }

    func findNext() {
        Task { findResult = await preview.findNext() }
    }

    func findPrev() {
        Task { findResult = await preview.findPrev() }
    }

    /// After a re-render (live reload / appearance switch) the previous marks
    /// are gone; re-run the active query against the fresh content.
    private func reapplyFindIfActive() async {
        guard findPresented, !findQuery.isEmpty else { return }
        findResult = await preview.search(findQuery)
    }

    // MARK: - Watching [REF:fr:live-reload]

    private func startWatching(_ url: URL) {
        watcher?.stop()
        let newWatcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in await self?.reloadFromDisk() }
        }
        watcher = newWatcher
        newWatcher.start()
    }

    private func reloadFromDisk() async {
        guard let url else { return }
        let text = await Task.detached { try? FileLoader.load(url) }.value
        if let text {
            currentText = text
            await preview.render(text)
        } else {
            await preview.render("# Unable to read file\n\n`\(url.path)`")
        }
        await reapplyFindIfActive()
        await refreshOutline()
    }

    /// True when the system appearance resolves to Dark Aqua. Uses optional
    /// `NSApp` so it is safe to read before the app object exists (early launch).
    static var systemIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// This window as a cross-file anchor target: when a link in another window
/// points at this document (`other.md#section`) and it is already open, the
/// navigator scrolls it here directly — the window never re-renders.
/// [REF:fr:local-links]
extension DocumentModel: LocalLinkTarget {
    var documentURL: URL? { url }

    func navigate(toAnchor anchor: String) {
        Task { await preview.scrollToHeading(anchor) }
    }
}

/// This window as a compare peer: the coordinator toggles the page's live
/// mirroring channel and pushes the peer's scroll fraction here. TOC, find,
/// width, and scroll persistence stay untouched per-window state.
/// [REF:fr:compare]
extension DocumentModel: CompareTarget {
    var hostWindow: NSWindow? { preview.webView.window }

    func setCompareSyncEnabled(_ enabled: Bool) {
        isCompared = enabled
        Task { await preview.setCompareSync(enabled) }
    }

    func applyScrollFraction(_ fraction: Double) {
        Task { await preview.setScrollFraction(fraction) }
    }

    func currentScrollFraction() async -> Double? {
        await preview.scrollFraction()
    }
}
