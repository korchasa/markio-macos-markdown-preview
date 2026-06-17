import SwiftUI
import UniformTypeIdentifiers

/// One document window: the rendered preview plus the one on-screen reading
/// control — line width. Owns its own `DocumentModel` (no shared singleton).
/// [REF:sds:line-width] [REF:fr:line-width] [REF:fr:multidoc]
struct ContentView: View {
    let document: MarkdownDocument
    let fileURL: URL?

    @StateObject private var model = DocumentModel()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openDocument) private var openDocument

    var body: some View {
        PreviewView(webView: model.preview.webView)
            .frame(minWidth: 480, minHeight: 320)
            // Show the document's full filesystem path in the title bar instead
            // of the bare file name (DocumentGroup's default). The proxy icon
            // (represented URL) is kept. [REF:fr:multidoc]
            .background(WindowTitleSetter(title: fileURL?.path ?? "Markview"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) { widthControl }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0) }
            .task { await model.start(text: document.text, url: fileURL) }
            .onChange(of: colorScheme) { _, scheme in
                Task { await model.appearanceChanged(dark: scheme == .dark) }
            }
    }

    /// Dropping a file opens it in a NEW window rather than replacing this one.
    /// [REF:fr:multidoc]
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isMarkdown else { return }
            Task { @MainActor in try? await openDocument(at: url) }
        }
        return true
    }

    /// Always-reachable line-width slider — the one persistent reading control.
    private var widthControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.and.right.text.vertical")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { model.contentWidth }, set: { model.setWidth($0) }),
                in: Double(ContentWidthStore.minWidth)...Double(ContentWidthStore.maxWidth)
            )
            .frame(width: 160)
            .help("Adjust reading width")
        }
    }
}
