import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App-level state: the current document, the preview controller, and the
/// reading width. Wires the file loader + watcher to the web view and owns the
/// open/drop/reload flows. [REF:sds:app-shell]
@MainActor
final class AppModel: ObservableObject {
    let preview = PreviewController()
    private let widthStore = ContentWidthStore()
    private var watcher: FileWatcher?
    private var bootstrapped = false

    @Published var contentWidth: Double
    @Published var documentTitle = "Markview"
    @Published private(set) var currentURL: URL?

    static let markdownTypes: [UTType] = {
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.insert(md, at: 0) }
        if let markdown = UTType(filenameExtension: "markdown") { types.insert(markdown, at: 1) }
        return types
    }()

    init() {
        contentWidth = Double(widthStore.width)
    }

    /// One-time page setup; safe to call from `.task` on every view appearance.
    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await preview.loadTemplate()
        await preview.setContentWidth(Int(contentWidth))
        await preview.setDark(Self.systemIsDark)
        if let url = currentURL {
            await reload(url)
        } else {
            await preview.render(Self.welcome)
        }
    }

    // MARK: - Opening documents [REF:fr:open]

    func open(_ url: URL) {
        currentURL = url
        documentTitle = url.lastPathComponent
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        startWatching(url)
        Task { await reload(url) }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.markdownTypes
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
            guard let url, url.isMarkdown else { return }
            Task { @MainActor in self?.open(url) }
        }
        return true
    }

    // MARK: - Rendering

    private func reload(_ url: URL) async {
        let text = await Task.detached { try? FileLoader.load(url) }.value
        await preview.render(text ?? "# Unable to read file\n\n`\(url.path)`")
    }

    func setWidth(_ pixels: Double) {
        let clamped = Double(ContentWidthStore.clamp(Int(pixels)))
        contentWidth = clamped
        widthStore.width = Int(clamped)
        Task { await preview.setContentWidth(Int(clamped)) }
    }

    /// Re-render so Mermaid picks up the new theme on a live appearance switch.
    /// [REF:fr:appearance]
    func appearanceChanged(dark: Bool) {
        Task {
            await preview.setDark(dark)
            if let url = currentURL {
                await reload(url)
            } else {
                await preview.render(Self.welcome)
            }
        }
    }

    // MARK: - Watching [REF:fr:live-reload]

    private func startWatching(_ url: URL) {
        watcher?.stop()
        let newWatcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in
                guard let self, let current = self.currentURL else { return }
                await self.reload(current)
            }
        }
        watcher = newWatcher
        newWatcher.start()
    }

    static var systemIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static let welcome = """
        # Markview

        A native macOS viewer for **Markdown** — GFM and Mermaid, nothing more.

        Open a `.md` file (⌘O, drag-and-drop, or *Open With* from Finder).

        ## Features

        - GitHub Flavored Markdown
        - Mermaid diagrams
        - Syntax highlighting
        - Adjustable line width (toolbar slider)

        | Feature | State |
        | --- | --- |
        | GFM tables | ✓ |
        | Task lists | ✓ |

        - [x] Render GFM
        - [ ] Read your document

        ```swift
        print("Hello, Markview")
        ```

        ```mermaid
        flowchart LR
          File --> Render --> Preview
        ```
        """
}

extension URL {
    var isMarkdown: Bool {
        ["md", "markdown"].contains(pathExtension.lowercased())
    }
}
