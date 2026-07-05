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
            // The width control lives in a bottom bar (not the toolbar), pinned
            // below the preview. [REF:fr:line-width]
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            // Show the document's full filesystem path in the title bar instead
            // of the bare file name (DocumentGroup's default). The proxy icon
            // (represented URL) is kept. [REF:fr:multidoc]
            .background(WindowTitleSetter(title: fileURL?.path ?? "Markio"))
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
            Task { @MainActor in
                do {
                    try await openDocument(at: url)
                } catch {
                    Log.app.error(
                        "drop open failed for \(url.path): \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    /// Bottom bar holding the one persistent reading control: an absolute
    /// reading width in characters, stepped through presets (40…200 by 20).
    /// [REF:fr:line-width]
    private var bottomBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Image(systemName: "arrow.left.and.right.text.vertical")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { model.contentWidth }, set: { model.setWidth($0) }),
                in: Double(ContentWidthStore.minWidth)...Double(ContentWidthStore.maxWidth),
                step: Double(ContentWidthStore.step)
            )
            .frame(width: 180)
            .controlSize(.small)
            .help("Reading width in characters")
            Text("\(Int(model.contentWidth)) ch")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
