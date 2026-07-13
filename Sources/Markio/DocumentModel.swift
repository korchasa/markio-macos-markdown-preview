import AppKit
import SwiftUI

/// Per-window document state: owns this window's preview controller, file
/// watcher, and reading width. One instance per `DocumentGroup` window — there
/// is no shared app-wide model. Renders the document's text and re-renders on
/// appearance changes and live reloads. [REF:sds:document-model]
@MainActor
final class DocumentModel: ObservableObject {
    let preview = PreviewController()
    private let widthStore = ContentWidthStore()
    private let tocStore = TOCStore()
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

    init() {
        contentWidth = Double(widthStore.width)
        tocVisible = tocStore.visible
        preview.onCurrentSectionChange = { [weak self] id in
            self?.currentHeadingID = id
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
