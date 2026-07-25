import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    private let compareLayoutStore: CompareLayoutStore
    private let linkNavigator: LocalLinkNavigator
    private let comparePick: ComparePick
    private var watcher: FileWatcher?
    /// Baseline of the active inline-diff compare; session-only. [REF:fr:compare]
    private var compareBaselineURL: URL?
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

    // Compare state, mirrored to the File menu. [REF:fr:compare]
    @Published private(set) var isCompared = false
    /// Layout of the compare view: side-by-side columns when true, inline
    /// annotations when false. Persisted global reading preference.
    @Published private(set) var compareSplit: Bool

    /// Baseline picker: hand the document's URL to the user, call back with
    /// the picked baseline (`nil` = cancelled). Injected so tests drive the
    /// compare flow without AppKit UI. [REF:fr:compare]
    typealias ComparePick = @MainActor (URL, @escaping @MainActor (URL?) -> Void) -> Void

    init(
        defaults: UserDefaults = .standard,
        linkNavigator: LocalLinkNavigator = .shared,
        comparePick: @escaping ComparePick = DocumentModel.systemComparePick
    ) {
        widthStore = ContentWidthStore(defaults: defaults)
        tocStore = TOCStore(defaults: defaults)
        scrollStore = ScrollPositionStore(defaults: defaults)
        compareLayoutStore = CompareLayoutStore(defaults: defaults)
        compareSplit = CompareLayoutStore(defaults: defaults).split
        self.linkNavigator = linkNavigator
        self.comparePick = comparePick
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

    /// Pick a baseline version and render this window as an inline diff
    /// against it. Picking the document's own file is a no-op.
    func startCompare() {
        guard let url else { return }
        comparePick(url) { [weak self] picked in
            guard let self, let picked else { return }
            guard picked.standardizedFileURL.path != url.standardizedFileURL.path
            else { return }
            Task { await self.renderCompare(baseline: picked) }
        }
    }

    /// Switch the compare layout (inline ↔ split columns); re-renders the
    /// active diff live and persists the preference.
    func setCompareSplit(_ split: Bool) {
        guard split != compareSplit else { return }
        compareSplit = split
        compareLayoutStore.split = split
        guard isCompared, let baseline = compareBaselineURL else { return }
        Task { await renderCompare(baseline: baseline) }
    }

    /// Return to the plain render; the baseline choice is dropped.
    func stopCompare() {
        guard isCompared else { return }
        compareBaselineURL = nil
        isCompared = false
        Task {
            await preview.render(currentText)
            await reapplyFindIfActive()
            await refreshOutline()
        }
    }

    /// Read the baseline and render the diff. An unreadable baseline logs and
    /// leaves (or returns to) the plain view — never a broken diff.
    private func renderCompare(baseline: URL) async {
        let text = await Task.detached { try? FileLoader.load(baseline) }.value
        guard let text else {
            Log.app.error("compare baseline unreadable: \(baseline.path)")
            stopCompare()
            return
        }
        compareBaselineURL = baseline
        isCompared = true
        await preview.renderDiff(old: text, new: currentText, split: compareSplit)
        await reapplyFindIfActive()
        await refreshOutline()
    }

    /// Powerbox panel pre-pointed at the document's folder: the user's one
    /// "Compare" click grants sandbox read access to the picked baseline.
    /// Cancel is a no-op. [REF:fr:compare]
    private static func systemComparePick(
        _ sourceURL: URL, completion: @escaping @MainActor (URL?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.message = "Choose the version to compare against."
        panel.prompt = "Compare"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), .plainText]
            .compactMap { $0 }
        panel.begin { response in
            MainActor.assumeIsolated {
                completion(response == .OK ? panel.url : nil)
            }
        }
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
            // While compared, an external edit refreshes the DIFF view —
            // the baseline is re-read alongside. [REF:fr:compare]
            if isCompared, let baseline = compareBaselineURL {
                await renderCompare(baseline: baseline)
                return
            }
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
