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
    private var watcher: FileWatcher?
    private var started = false
    private var currentText = ""
    private var url: URL?

    @Published var contentWidth: Double

    init() {
        contentWidth = Double(widthStore.width)
    }

    /// One-time page setup + initial render; safe to call from `.task` on every
    /// view appearance. Arms the watcher when the document has a file URL.
    /// [REF:fr:multidoc] [REF:fr:live-reload]
    func start(text: String, url: URL?) async {
        guard !started else { return }
        started = true
        self.url = url
        currentText = text
        await preview.loadTemplate()
        await preview.setContentWidth(Int(contentWidth))
        await preview.setDark(Self.systemIsDark)
        await preview.render(text)
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
    }

    static var systemIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension URL {
    var isMarkdown: Bool {
        ["md", "markdown"].contains(pathExtension.lowercased())
    }
}
